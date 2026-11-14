import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/api/api_client.dart';
import '../../../data/api/api_repositories.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/inspection_repository.dart';
import '../inspect_actions.dart';
import '../inspect_catalog.dart';
import '../scanner_screen.dart';
import '../widgets/inspect_camera.dart';
import 'live_camera.dart';

/// Подпись рамки сканера, по которой открывается готовый сценарий признака дефекта.
const Map<String, String> kLiveDefectFlows = {'leak': 'Течь у вала', 'terminal_box_burnt': 'Следы перегрева клемм'};

/// Узел агрегата по классу детектора, если сервер не прислал узел.
const Map<String, String> kLiveClassNodes = {
  'leak': 'seal',
  'corrosion': 'casing',
  'coupling_no_guard': 'coupling',
  'terminal_box_burnt': 'terminal_box',
};

/// Живой сканер на настоящем сервере: камера, поток кадров осмотра на /ws/inspect, рамки узлов и дефектов,
/// полнота обхода и запись находки с кадром камеры.
class LiveScannerScreen extends ConsumerStatefulWidget {
  /// Создаёт сканер агрегата [unitId].
  const LiveScannerScreen({super.key, required this.unitId});

  /// Агрегат.
  final String unitId;

  @override
  ConsumerState<LiveScannerScreen> createState() => _LiveScannerScreenState();
}

class _LiveScannerScreenState extends ConsumerState<LiveScannerScreen> {
  late final ApiClient _client = ref.read(apiClientProvider);
  late final LiveCamera _camera = LiveCamera(client: _client, onReply: _onReply);
  String? _inspectionId;
  Map<String, dynamic>? _coverage;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _camera.start();
    _openInspection();
  }

  Future<void> _openInspection() async {
    try {
      final Inspection insp = await ensureInspection(ref, widget.unitId);
      if (!mounted) {
        return;
      }
      _inspectionId = insp.id;
      _camera.connect('/ws/inspect/${insp.id}');
    } on Object {
      if (mounted) {
        _camera.connect('/ws/detect');
      }
    }
  }

  void _onReply(Map<String, dynamic> j) {
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

  /// Касание рамки: признак дефекта открывает готовый сценарий или сразу записывается находкой с кадром.
  VoidCallback? _tapOf(LiveBox b) {
    if (!b.isDefect && !b.isCheck) {
      return null;
    }
    return () => _record(b);
  }

  Future<void> _record(LiveBox? box) async {
    final LiveBox? b = box ??
        _camera.boxes.where((LiveBox x) => x.isDefect).firstOrNull ??
        _camera.boxes.where((LiveBox x) => x.isCheck).firstOrNull;
    if (b == null) {
      showKvToast(context, title: 'Признаков в кадре нет', text: 'Наведите камеру на признак дефекта', kind: KvToastKind.info);
      return;
    }
    final Uint8List? frame = _camera.lastJpeg;
    _client.lastFrame = frame;
    final String? flow = kLiveDefectFlows[b.cls];
    final DefectClass? cls = flow == null ? null : kDefectClasses[flow];
    if (cls != null) {
      if (cls.closeUp) {
        unawaited(context.kvPush(EngineerInspectPaths.scanDefectFor(widget.unitId, flow)));
      } else {
        unawaited(context.kvPush(EngineerInspectPaths.rule(cls.ruleId, widget.unitId)));
      }
      return;
    }
    if (_saving) {
      return;
    }
    _saving = true;
    final BuildContext screen = context;
    try {
      final String id = _inspectionId ?? (await ensureInspection(ref, widget.unitId)).id;
      _inspectionId = id;
      final InspectionRepository repo = ref.read(inspectionRepositoryProvider);
      final String node = b.node ?? kLiveClassNodes[b.cls] ?? 'casing';
      if (repo is ApiInspectionRepository) {
        await repo.addCameraFinding(
          id,
          cls: b.cls,
          node: node,
          severity: b.isDefect ? 2 : 1,
          comment: '${liveClassLabel(b.cls)}: зафиксировано со сканера',
        );
      } else {
        await repo.addFinding(id, node: node, title: liveClassLabel(b.cls), ruleId: '', severity: b.isDefect ? 2 : 1, comment: 'Зафиксировано со сканера');
      }
      if (screen.mounted) {
        showKvSnack(screen, text: 'Находка сохранена');
      }
    } on KvApiException catch (e) {
      if (screen.mounted) {
        showKvToast(screen, title: 'Не удалось сохранить', text: e.message);
      }
    } finally {
      _saving = false;
    }
  }

  void _finish() {
    final BuildContext screen = context;
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
              screen.kvPush(EngineerServicePaths.cSummary);
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
    final double top = MediaQuery.paddingOf(context).top;
    return ListenableBuilder(
      listenable: _camera,
      builder: (BuildContext context, Widget? _) {
        final int defects = _camera.boxes.where((LiveBox b) => b.isDefect).length;
        final int done = (_coverage?['inspected'] as num?)?.toInt() ?? 0;
        final int total = (_coverage?['total'] as num?)?.toInt() ?? 0;
        final int percent = (_coverage?['percent'] as num?)?.round() ?? 0;
        final String hint = _coverage?['hint']?.toString() ?? '';
        final String pill = _camera.connected
            ? 'Анализ видео · ${KvFormat.num(_camera.fps, 1)} кадр/с · ${_camera.roundTripMs} мс'
            : (_camera.wsPath == null ? 'Подготовка осмотра' : (_camera.reconnecting ? 'Переподключение…' : 'Подключение к серверу'));
        return ArCameraScreen(
          stage: LiveCameraStage(camera: _camera, onBoxTap: _tapOf),
          top: ArTopBar(
            pill: pill,
            spinning: !_camera.connected,
            onBack: () => context.kvBack(EngineerInspectPaths.objects),
            onFlash: _camera.setTorch,
          ),
          layers: [
            if (_camera.state == LiveCameraState.denied || _camera.state == LiveCameraState.failed)
              Positioned(left: KvSpace.gutter, right: KvSpace.gutter, top: top + 78, child: LiveCameraProblem(camera: _camera))
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
                caption: unit == null ? ' ' : 'По шильдику · № ${unit.serial}',
                chip: defects == 0 ? null : KvChip('$defects ${KvFormat.plural(defects, 'признак', 'признака', 'признаков')}', status: KvStatus.bad),
                chipLabel: 'Признаки дефектов',
                onChip: () => _record(null),
              ),
              NextNodeCard(
                done: done,
                total: total == 0 ? 1 : total,
                title: hint.isNotEmpty ? hint : (total > 0 && done >= total ? 'Все узлы осмотрены' : 'Обойдите агрегат с камерой'),
                subtitle: 'Осмотрено $done из $total узлов · $percent %',
                onTap: () => context.kvPush(EngineerInspectPaths.routeFor(widget.unitId)),
              ),
              Row(
                children: [
                  Expanded(
                    child: KvButton('Зафиксировать', kind: KvButtonKind.secondary, icon: KvIcons.camera, small: true, onPressed: () => _record(null)),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: KvButton(
                      'Карточка',
                      kind: KvButtonKind.secondary,
                      onPressed: () => context.kvPush(EngineerInspectPaths.card(widget.unitId)),
                    ),
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
  const LiveScanSearchScreen({super.key});

  @override
  ConsumerState<LiveScanSearchScreen> createState() => _LiveScanSearchScreenState();
}

class _LiveScanSearchScreenState extends ConsumerState<LiveScanSearchScreen> {
  late final ApiClient _client = ref.read(apiClientProvider);
  late final LiveCamera _camera = LiveCamera(client: _client, preset: ResolutionPreset.high, maxSide: 1280, quality: 85);
  Timer? _auto;
  bool _busy = false;
  bool _done = false;

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
        _found(id);
        return;
      }
      final List<Map<String, dynamic>> cands = [for (final dynamic e in (j['candidates'] as List<dynamic>? ?? const <dynamic>[])) e as Map<String, dynamic>];
      if (!manual) {
        return;
      }
      if (cands.isNotEmpty) {
        _pick(cands);
      } else {
        showKvToast(context, title: 'Шильдик не распознан', text: j['message']?.toString(), kind: KvToastKind.warn);
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

  void _found(String id) {
    if (_done) {
      return;
    }
    _done = true;
    _auto?.cancel();
    context.kvFade(EngineerInspectPaths.card(id));
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
                      _found(e['id'].toString());
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Size size = MediaQuery.sizeOf(context);
    final double top = MediaQuery.paddingOf(context).top;
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
              child: const Center(child: ScanHintPill(icon: KvIcons.target, text: 'Наведите рамку на шильдик')),
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
                      'Коснитесь рамки, чтобы прочитать заводскую табличку. Номер и серийный номер сверяются с сервером.',
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
                ScanCamAction(icon: KvIcons.list, label: 'Из списка', onTap: () => context.kvBack(EngineerInspectPaths.objects)),
                ScanCamAction(icon: KvIcons.hash, label: 'Ввести номер', onTap: () => context.kvPush(EngineerInspectPaths.search)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
