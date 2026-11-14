import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/api/api_client.dart';
import '../../../data/api/api_repositories.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/inspection_repository.dart';
import '../inspect_actions.dart';
import '../inspect_providers.dart';
import '../scanner_screen.dart';
import '../widgets/inspect_camera.dart';
import '../works_sheet.dart';
import 'live_camera.dart';
import 'live_detection.dart';
import 'live_gauge.dart';
import 'sound_sheet.dart';

/// Живой сканер на настоящем сервере: камера, поток кадров осмотра на /ws/inspect, рамки узлов и дефектов,
/// полнота обхода и запись находки с кадром камеры.
class LiveScannerScreen extends ConsumerStatefulWidget {
  /// Создаёт сканер агрегата [unitId].
  const LiveScannerScreen({super.key, required this.unitId, this.byNameplate = false, this.byQr = false, this.aim});

  /// Агрегат.
  final String unitId;

  /// Агрегат определён по шильдику; false - выбран вручную.
  final bool byNameplate;

  /// Агрегат определён по QR-коду на агрегате.
  final bool byQr;

  /// Код узла, на который инженер наводит камеру первым (блок «Сначала проверьте»); подсказка держится,
  /// пока сервер не отметит узел осмотренным.
  final String? aim;

  @override
  ConsumerState<LiveScannerScreen> createState() => _LiveScannerScreenState();
}

class _LiveScannerScreenState extends ConsumerState<LiveScannerScreen> {
  late final ApiClient _client = ref.read(apiClientProvider);
  late final LiveCamera _camera = LiveCamera(client: _client, onReply: _onReply);
  Map<String, dynamic>? _coverage;

  @override
  void initState() {
    super.initState();
    _camera.start();
    _openInspection();
  }

  Future<void> _openInspection() async {
    try {
      ApiInspectionRepository.identifiedBy[widget.unitId] = widget.byQr ? 'qr' : (widget.byNameplate ? 'nameplate' : 'manual');
      final Inspection insp = await ensureInspection(ref, widget.unitId);
      if (!mounted) {
        return;
      }
      _camera.connect('/ws/inspect/${insp.id}');
    } on Object {
      if (mounted) {
        _camera.connect('/ws/detect');
      }
    }
  }

  DateTime _plateAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _plateBusy = false;
  String? _otherUnit;

  /// Шильдик в кадре во время осмотра: раз в 5 с стоп-кадр уходит на распознавание; если это другой агрегат,
  /// сканер предлагает перейти к нему (осмотр и полнота обхода относятся к агрегату по шильдику).
  Future<void> _checkPlate(Map<String, dynamic> j) async {
    final List<dynamic> boxes = j['boxes'] as List<dynamic>? ?? const <dynamic>[];
    final bool plate = boxes.any((dynamic b) => b is Map<String, dynamic> && b['cls'] == 'nameplate' && ((b['conf'] as num?) ?? 0) >= 0.5);
    final Uint8List? frame = _camera.lastJpeg;
    if (!plate || frame == null || _plateBusy || DateTime.now().difference(_plateAt) < const Duration(seconds: 5)) {
      return;
    }
    _plateBusy = true;
    _plateAt = DateTime.now();
    try {
      final Map<String, dynamic> r = (await _client.postForm('/recognize/nameplate', frame: frame)) as Map<String, dynamic>;
      final String? id = (r['match'] as Map<String, dynamic>?)?['equipment_id']?.toString();
      if (mounted && r['found'] == true && id != null && id != widget.unitId) {
        setState(() => _otherUnit = id);
      }
    } on KvApiException {
      _plateAt = DateTime.now();
    } finally {
      _plateBusy = false;
    }
  }

  void _onReply(Map<String, dynamic> j) {
    if (j['type'] == 'frame') {
      unawaited(_checkPlate(j));
    }
    final Object? cov = j['coverage'];
    if (cov is Map<String, dynamic>) {
      _coverage = cov;
      final InspectionRepository repo = ref.read(inspectionRepositoryProvider);
      if (repo is ApiInspectionRepository) {
        repo.applyCoverage(widget.unitId, cov);
      }
    }
    if (j['diagnosis_changed'] == true) {
      ref.read(apiFeedProvider).notify(KvDomain.inspections);
    }
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  /// Касание рамки признака открывает решение инженера (b-scan-defect); рамки узлов не нажимаются.
  VoidCallback? _tapOf(LiveBox b) {
    if (b.cls == 'gauge') {
      return () => _gauge(b);
    }
    if (!b.isDefect && !b.isCheck) {
      return null;
    }
    return () => _review(b);
  }

  /// Касание рамки манометра: стоп-кадр с рамкой уходит на экран чтения шкалы, показание читает сервер.
  Future<void> _gauge(LiveBox b) async {
    final Uint8List? frame = _camera.replyJpeg ?? _camera.lastJpeg;
    if (frame == null) {
      return;
    }
    ref.read(liveGaugeProvider.notifier).open(
          LiveDetection(unitId: widget.unitId, jpeg: frame, frameSize: _camera.frameSize, box: b, at: DateTime.now()),
        );
    await _open(EngineerInspectPaths.scanGaugeFor(widget.unitId));
  }

  /// Рамки ответа без признаков, которые инженер отметил «не дефект».
  List<LiveBox> _visible(List<LiveBox> boxes) {
    final LiveReviewController review = ref.read(liveReviewProvider.notifier);
    return [for (final LiveBox b in boxes) if (!(b.isDefect || b.isCheck) || !review.isDismissed(widget.unitId, b.cls, b.node)) b];
  }

  /// Открывает признак [box] (или первый признак в кадре) для решения инженера. В осмотр ничего не записывается,
  /// пока инженер не подтвердит дефект.
  Future<void> _review(LiveBox? box) async {
    final List<LiveBox> shown = _visible(_camera.boxes);
    final LiveBox? b = box ?? shown.where((LiveBox x) => x.isDefect).firstOrNull ?? shown.where((LiveBox x) => x.isCheck).firstOrNull;
    final Uint8List? frame = _camera.replyJpeg ?? _camera.lastJpeg;
    if (b == null || frame == null) {
      showKvToast(context, title: 'Признаков в кадре нет', text: 'Наведите камеру на признак дефекта', kind: KvToastKind.info);
      return;
    }
    ref.read(liveReviewProvider.notifier).open(
          LiveDetection(unitId: widget.unitId, jpeg: frame, frameSize: _camera.frameSize, box: b, at: DateTime.now()),
        );
    await _open(EngineerInspectPaths.scanDefectFor(widget.unitId, liveClassLabel(b.cls)));
  }

  /// Название узла из блока «Сначала проверьте», пока сервер не отметил его осмотренным; null - подсказки нет.
  String? _aimName() {
    final String? aim = widget.aim;
    if (aim == null || aim.isEmpty) {
      return null;
    }
    final Object? nodes = _coverage?['nodes'];
    final Object? node = nodes is Map ? nodes[aim] : null;
    if (node is Map && node['inspected'] == true) {
      return null;
    }
    final String named = node is Map ? (node['name']?.toString() ?? '') : '';
    if (named.isNotEmpty) {
      return named;
    }
    final List<RouteStep> route = ref.read(routeProvider(widget.unitId)).value ?? const <RouteStep>[];
    return route.where((RouteStep r) => r.nodeId == aim).firstOrNull?.name ?? aim;
  }

  /// Запись шума агрегата: камера на это время останавливается, после листа видео продолжается.
  Future<void> _sound() async {
    final String id = (await ensureInspection(ref, widget.unitId)).id;
    await _camera.suspend();
    if (!mounted) {
      return;
    }
    await showSoundSheet(context, inspectionId: id, unitId: widget.unitId);
    if (mounted) {
      await _camera.resume();
    }
  }

  /// Открывает экран поверх сканера: камера и поток кадров на это время останавливаются и продолжаются после возврата.
  Future<void> _open(String path) async {
    await _camera.suspend();
    if (!mounted) {
      return;
    }
    await context.kvPush<void>(path);
    if (mounted) {
      await _camera.resume();
    }
  }

  void _finish() {
    final int done = (_coverage?['inspected'] as num?)?.toInt() ?? 0;
    final int total = (_coverage?['total'] as num?)?.toInt() ?? 0;
    showKvDialog<void>(
      context,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.clipboard,
        title: 'Завершить осмотр?',
        text: 'Осмотрено $done из $total узлов. Непросмотренные узлы попадут в отчёт с отметкой «не осмотрено».',
        actions: [
          KvButton('Продолжить', kind: KvButtonKind.secondary, onPressed: () => Navigator.of(dialog).pop()),
          KvButton(
            'Завершить',
            onPressed: () {
              Navigator.of(dialog).pop();
              ref.read(liveReviewProvider.notifier).reset();
              _open(EngineerServicePaths.cSummary);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Equipment? unit = ref.watch(unitProvider(widget.unitId)).value;
    if (widget.aim != null) {
      ref.watch(routeProvider(widget.unitId));
    }
    final double top = MediaQuery.paddingOf(context).top;
    return ListenableBuilder(
      listenable: _camera,
      builder: (BuildContext context, Widget? _) {
        final int defects = _visible(_camera.boxes).where((LiveBox b) => b.isDefect).length;
        final int done = (_coverage?['inspected'] as num?)?.toInt() ?? 0;
        final int total = (_coverage?['total'] as num?)?.toInt() ?? 0;
        final int percent = (_coverage?['percent'] as num?)?.round() ?? 0;
        final String? aimName = _aimName();
        final String hint = aimName != null ? aimHint(aimName) : (_coverage?['hint']?.toString() ?? '');
        final String pill = _camera.connected
            ? 'Анализ видео · ${KvFormat.num(_camera.fps, 1)} кадр/с · ${_camera.roundTripMs} мс'
            : (_camera.wsPath == null ? 'Подготовка осмотра' : (_camera.reconnecting ? 'Переподключение…' : 'Подключение к серверу'));
        return ArCameraScreen(
          stage: LiveCameraStage(camera: _camera, onBoxTap: _tapOf, filter: _visible),
          top: ArTopBar(
            pill: pill,
            spinning: !_camera.connected,
            onBack: () => context.kvBack(EngineerInspectPaths.objects),
            onFlash: _camera.setTorch,
          ),
          layers: [
            if (_camera.state == LiveCameraState.denied || _camera.state == LiveCameraState.failed)
              Positioned(left: KvSpace.gutter, right: KvSpace.gutter, top: top + 78, child: LiveCameraProblem(camera: _camera))
            else if (_otherUnit != null)
              Positioned(
                left: KvSpace.gutter,
                right: KvSpace.gutter,
                top: top + 60,
                child: KvGlass(
                  borderRadius: BorderRadius.circular(KvRadius.card),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(KvSpace.s4, 6, 6, 6),
                    decoration: BoxDecoration(color: c.arGlass, borderRadius: BorderRadius.circular(KvRadius.card)),
                    child: Row(
                      children: [
                        KvIcon(KvIcons.tag, size: 20, color: c.arText),
                        const SizedBox(width: KvSpace.s2),
                        Expanded(
                          child: Text(
                            'Шильдик другого агрегата: ${ref.watch(unitProvider(_otherUnit!)).value?.code ?? _otherUnit}',
                            maxLines: 2,
                            style: context.kvText.sm.copyWith(color: c.arText, fontWeight: FontWeight.w500),
                          ),
                        ),
                        KvButton('Перейти', small: true, onPressed: () => context.kvFade(EngineerInspectPaths.scannerFor(_otherUnit!, via: 'nameplate'))),
                      ],
                    ),
                  ),
                ),
              )
            else if (_camera.connectionProblem != null)
              Positioned(
                left: KvSpace.gutter,
                right: KvSpace.gutter,
                top: top + 60,
                child: LiveConnectionBanner(text: _camera.connectionProblem!, onRetry: _camera.reconnect),
              ),
          ],
          panel: ArPanel(
            children: [
              ArPanelTitle(
                title: unit == null ? ' ' : '${unit.code} · ${unit.modelShort}',
                caption: unit == null ? ' ' : '${widget.byQr ? 'По QR-коду' : (widget.byNameplate ? 'По шильдику' : 'Выбран вручную')} · № ${unit.serial}',
                chip: defects == 0 ? null : KvChip('$defects ${KvFormat.plural(defects, 'признак', 'признака', 'признаков')}', status: KvStatus.bad),
                chipLabel: 'Признаки дефектов',
                onChip: () => _review(null),
              ),
              NextNodeCard(
                done: done,
                total: total == 0 ? 1 : total,
                title: hint.isNotEmpty ? hint : (total > 0 && done >= total ? 'Все узлы осмотрены' : 'Обойдите агрегат с камерой'),
                subtitle: 'Осмотрено $done из $total узлов · $percent %',
                onTap: () => _open(EngineerInspectPaths.routeFor(widget.unitId)),
              ),
              Row(
                children: [
                  Expanded(
                    child: KvButton('Зафиксировать', kind: KvButtonKind.secondary, icon: KvIcons.camera, small: true, onPressed: () => _review(null)),
                  ),
                  const SizedBox(width: KvSpace.s3),
                  Expanded(child: KvButton('Записать шум', kind: KvButtonKind.secondary, icon: KvIcons.mic, small: true, onPressed: _sound)),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: KvButton(
                      'Карточка',
                      kind: KvButtonKind.secondary,
                      onPressed: () => _open(EngineerInspectPaths.card(widget.unitId)),
                    ),
                  ),
                  const SizedBox(width: KvSpace.s3),
                  Expanded(
                    child: KvButton('Работы', kind: KvButtonKind.secondary, onPressed: () => showWorksSheet(context, widget.unitId)),
                  ),
                  const SizedBox(width: KvSpace.s3),
                  Expanded(child: KvButton('Завершить', onPressed: _finish)),
                ],
              ),
            ],
          ),
          lightHome: c.isDark,
        );
      },
    );
  }
}

/// Поиск шильдика на настоящем сервере: живое видео, стоп-кадр уходит на /recognize/nameplate по касанию рамки
/// и сам каждые 2,5 с; найденный агрегат открывает карточку, ручной выбор - «Ввести номер».
class LiveScanSearchScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const LiveScanSearchScreen({super.key, this.expected, this.aim});

  /// Агрегат, с карточки которого начат осмотр; null - центральная кнопка «Сканер».
  final String? expected;

  /// Узел из блока «Сначала проверьте», который передаётся живому сканеру того же агрегата.
  final String? aim;

  @override
  ConsumerState<LiveScanSearchScreen> createState() => _LiveScanSearchScreenState();
}

class _LiveScanSearchScreenState extends ConsumerState<LiveScanSearchScreen> {
  late final ApiClient _client = ref.read(apiClientProvider);
  late final LiveCamera _camera = LiveCamera(client: _client, preset: ResolutionPreset.high, maxSide: 1280, quality: 85);
  Timer? _auto;
  bool _busy = false;
  bool _done = false;
  String? _unitId;
  String _via = 'nameplate';

  @override
  void initState() {
    super.initState();
    _camera.start();
    _auto = Timer.periodic(const Duration(milliseconds: 2500), (_) => _recognize(manual: false));
  }

  @override
  void dispose() {
    _auto?.cancel();
    _camera.dispose();
    super.dispose();
  }

  Future<void> _recognize({required bool manual}) async {
    final Uint8List? frame = _camera.lastJpeg;
    if (_busy || _done || !mounted) {
      return;
    }
    if (frame == null) {
      if (manual) {
        showKvToast(context, title: 'Камера ещё запускается', kind: KvToastKind.info);
      }
      return;
    }
    _busy = true;
    if (manual) {
      setState(() {});
    }
    try {
      final Map<String, dynamic> j = (await _client.postForm('/recognize/nameplate', frame: frame)) as Map<String, dynamic>;
      if (!mounted) {
        return;
      }
      final Map<String, dynamic>? match = j['match'] as Map<String, dynamic>?;
      final String? id = match?['equipment_id']?.toString();
      if (j['found'] == true && id != null) {
        unawaited(_found(id, via: j['identified_by'] == 'qr' || match?['by'] == 'qr' ? 'qr' : 'nameplate'));
        return;
      }
      final List<Map<String, dynamic>> cands = [for (final dynamic e in (j['candidates'] as List<dynamic>? ?? const <dynamic>[])) e as Map<String, dynamic>];
      if (!manual) {
        return;
      }
      if (cands.isNotEmpty) {
        _pick(cands);
      } else {
        showKvToast(context, title: 'Шильдик не распознан', text: 'Выберите агрегат из списка вручную', kind: KvToastKind.warn);
        _pickUnit();
      }
    } on KvApiException catch (e) {
      if (manual && mounted) {
        final bool ocr = e.message.contains('Распознавание текста');
        showKvToast(context, title: ocr ? 'Распознавание текста недоступно на сервере' : 'Не удалось распознать', text: ocr ? 'Выберите агрегат вручную' : e.message);
      }
    } finally {
      _busy = false;
      if (mounted && manual) {
        setState(() {});
      }
    }
  }

  /// Агрегат определён: видео останавливается на кадре, снизу - агрегат и выбор «Карточка» или «Начать осмотр».
  /// Если шильдик принадлежит другому агрегату, чем карточка, с которой начат осмотр, инженер подтверждает переход.
  Future<void> _found(String id, {String via = 'nameplate'}) async {
    if (_done) {
      return;
    }
    _done = true;
    _auto?.cancel();
    final String? expected = widget.expected;
    if (via != 'manual' && expected != null && expected != id) {
      final bool? go = await showKvDialog<bool>(
        context,
        builder: (BuildContext dialog) => KvDialog(
          icon: KvIcons.alert,
          tone: KvStatus.warn,
          title: 'Это другой агрегат',
          text: '${via == 'qr' ? 'По QR-коду' : 'По шильдику'} это ${_codeOf(id)}, а осмотр начат с карточки ${_codeOf(expected)}. Перейти к ${_codeOf(id)}?',
          actions: [
            KvButton('Сканировать снова', kind: KvButtonKind.secondary, onPressed: () => Navigator.of(dialog).pop(false)),
            KvButton('Перейти к ${_codeOf(id)}', onPressed: () => Navigator.of(dialog).pop(true)),
          ],
        ),
      );
      if (go != true) {
        _done = false;
        _auto = Timer.periodic(const Duration(milliseconds: 2500), (_) => _recognize(manual: false));
        return;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _unitId = id;
      _via = via;
    });
    await _camera.suspend();
  }

  String _codeOf(String id) => ref.read(unitsProvider).value?.where((Equipment e) => e.id == id).firstOrNull?.code ?? id;

  /// Ручной выбор агрегата из списка (шильдик не читается): агрегат помечается «Выбран вручную».
  void _pickUnit() {
    final List<Equipment> units = ref.read(unitsProvider).value ?? const <Equipment>[];
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Выберите агрегат',
        children: [
          KvList(
            children: [
              for (final Equipment u in units)
                KvRow(
                  title: '${u.code} · ${u.modelShort}',
                  subtitle: KvFormat.typo('${u.location} · № ${u.serial}'),
                  chevron: true,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    unawaited(_found(u.id, via: 'manual'));
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _pick(List<Map<String, dynamic>> cands) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Выберите агрегат',
        children: [
          KvList(
            children: [
              for (final Map<String, dynamic> e in cands)
                KvRow(
                  title: e['name']?.toString() ?? e['id'].toString(),
                  subtitle: KvFormat.typo('${e['model'] ?? ''} · № ${e['serial'] ?? ''}'),
                  chevron: true,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    if (screen.mounted) {
                      unawaited(_found(e['id'].toString(), via: 'manual'));
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _identified(String id) {
    final Equipment? unit = ref.watch(unitProvider(id)).value;
    final String how = switch (_via) {
      'qr' => 'По QR-коду',
      'nameplate' => 'По шильдику',
      _ => 'Выбран вручную',
    };
    return ArPanel(
      children: [
        ArPanelTitle(
          title: unit == null ? id : '${unit.code} · ${unit.modelShort}',
          caption: unit == null ? how : '$how · № ${unit.serial}',
          chip: switch (_via) {
            'qr' => const KvChip('QR-код', status: KvStatus.ok),
            'nameplate' => const KvChip('Шильдик', status: KvStatus.ok),
            _ => null,
          },
        ),
        Row(
          children: [
            Expanded(child: KvButton('Карточка', kind: KvButtonKind.secondary, onPressed: () => context.go(EngineerInspectPaths.card(id)))),
            const SizedBox(width: KvSpace.s3),
            Expanded(
              child: KvButton(
                widget.expected == null ? 'Начать осмотр' : 'Продолжить',
                onPressed: () => context.kvFade(EngineerInspectPaths.scannerFor(id, via: _via, aim: id == widget.expected ? widget.aim : null)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Size size = MediaQuery.sizeOf(context);
    final double top = MediaQuery.paddingOf(context).top;
    final String? found = _unitId;
    if (found != null) {
      return ArCameraScreen(
        stage: _camera.lastJpeg == null
            ? const ColoredBox(color: Color(0xFF0E141C))
            : SizedBox.expand(child: Image.memory(_camera.lastJpeg!, fit: BoxFit.cover, gaplessPlayback: true)),
        top: ArTopBar(pill: 'Агрегат определён', onBack: () => context.kvBack(EngineerInspectPaths.objects)),
        panel: _identified(found),
      );
    }
    return ListenableBuilder(
      listenable: _camera,
      builder: (BuildContext context, Widget? _) => ArCameraScreen(
        lightHome: true,
        stage: LiveCameraStage(camera: _camera),
        top: ArTopBar(
          pill: _busy ? 'Читаю шильдик' : 'Ищу шильдик агрегата',
          spinning: true,
          onBack: () => context.kvBack(EngineerInspectPaths.objects),
          onFlash: _camera.setTorch,
        ),
        layers: [
          if (_camera.state == LiveCameraState.denied || _camera.state == LiveCameraState.failed)
            Positioned(left: KvSpace.gutter, right: KvSpace.gutter, top: top + 78, child: LiveCameraProblem(camera: _camera))
          else ...[
            Positioned(
              left: KvSpace.gutter,
              right: KvSpace.gutter,
              top: size.height * 0.22,
              child: const Center(child: ScanHintPill(icon: KvIcons.target, text: 'Наведите камеру на шильдик')),
            ),
            Positioned(
              left: size.width * 0.12,
              right: size.width * 0.12,
              top: size.height * 0.33,
              height: size.height * 0.2,
              child: KvPressable(
                onTap: () => _recognize(manual: true),
                highlight: false,
                semanticLabel: 'Шильдик в рамке',
                child: const ScanAimFrame(),
              ),
            ),
            Positioned(
              left: KvSpace.gutter,
              right: KvSpace.gutter,
              top: size.height * 0.57,
              child: IgnorePointer(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 290),
                    child: Text(
                      'Коснитесь рамки, чтобы прочитать заводскую табличку. Номер и серийный номер сверяются с сервером. QR-код на агрегате тоже читается.',
                      textAlign: TextAlign.center,
                      style: context.kvText.caption.copyWith(color: c.arText, shadows: [Shadow(color: c.arGlass, offset: const Offset(0, 1), blurRadius: 3)]),
                    ),
                  ),
                ),
              ),
            ),
          ],
          Positioned(
            left: KvSpace.gutter,
            right: KvSpace.gutter,
            bottom: 46,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ScanCamAction(icon: KvIcons.scan, label: 'Распознать', onTap: () => _recognize(manual: true)),
                ScanCamAction(icon: KvIcons.list, label: 'Из списка', onTap: _pickUnit),
                ScanCamAction(icon: KvIcons.hash, label: 'Ввести номер', onTap: () => context.kvPush(EngineerInspectPaths.search)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
