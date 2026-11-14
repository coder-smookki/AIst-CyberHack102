import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../core/kv.dart';
import '../../../data/api/api_repositories.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/inspection_repository.dart';
import '../inspect_actions.dart';
import '../inspect_providers.dart';
import '../widgets/inspect_camera.dart';
import 'live_camera.dart';

/// Признак со сканера, который ждёт решения инженера: стоп-кадр, рамка, класс и узел.
@immutable
class LiveDetection {
  /// Создаёт признак.
  const LiveDetection({required this.unitId, required this.jpeg, required this.frameSize, required this.box, required this.at});

  /// Агрегат.
  final String unitId;

  /// Стоп-кадр в JPEG, отправленный на сервер.
  final Uint8List jpeg;

  /// Размер стоп-кадра в пикселях.
  final Size frameSize;

  /// Рамка признака.
  final LiveBox box;

  /// Момент кадра.
  final DateTime at;

  /// Время кадра «09:31».
  String get time => '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
}

/// Узел агрегата по классу детектора, если сервер не прислал узел.
const Map<String, String> kLiveClassNodes = {
  'leak': 'seal',
  'corrosion': 'casing',
  'coupling_no_guard': 'coupling',
  'coupling_guard': 'coupling',
  'terminal_box_burnt': 'terminal_box',
  'terminal_box': 'terminal_box',
  'motor': 'motor',
  'pump_casing': 'casing',
  'flange': 'flanges',
  'gauge': 'gauge',
};

/// Подпись признака для решения: нейтральное название класса детектора без указания узла.
String liveSignTitle(String cls) => liveClassLabel(cls);

/// Признак на рассмотрении и признаки, которые инженер отметил «не дефект» в этом осмотре.
class LiveReview {
  /// Создаёт состояние.
  const LiveReview({this.pending, this.last, this.dismissed = const <String>{}});

  /// Признак, открытый для решения; null - нет.
  final LiveDetection? pending;

  /// Последний открытый признак: экраны решения показывают его и во время закрытия после решения.
  final LiveDetection? last;

  /// Признак для экранов решения.
  LiveDetection? get shown => pending ?? last;

  /// Отклонённые признаки «агрегат/класс»: сканер больше не предлагает их в этом осмотре.
  final Set<String> dismissed;
}

/// Решения инженера по признакам сканера. Ничего не записывается в осмотр без подтверждения «Это дефект».
class LiveReviewController extends Notifier<LiveReview> {
  @override
  LiveReview build() => const LiveReview();

  /// Открыть признак [d] для решения.
  void open(LiveDetection d) => state = LiveReview(pending: d, last: d, dismissed: state.dismissed);

  /// Отметить признак «не дефект»: он не сохраняется и не предлагается снова до конца осмотра.
  void dismiss(LiveDetection d) => state = LiveReview(last: state.last, dismissed: {...state.dismissed, '${d.unitId}/${d.box.cls}/${d.box.node ?? '*'}'});

  /// Закрыть признак после сохранения находки.
  void done() => state = LiveReview(last: state.last, dismissed: state.dismissed);

  /// Новый осмотр: отклонённые признаки забываются.
  void reset() => state = const LiveReview();

  /// Признак [cls] на узле [node] агрегата [unitId] отклонён инженером; отказ без узла скрывает признак на всём агрегате.
  bool isDismissed(String unitId, String cls, [String? node]) =>
      state.dismissed.contains('$unitId/$cls/*') || (node != null && state.dismissed.contains('$unitId/$cls/$node'));
}

/// Решения инженера по признакам сканера.
final NotifierProvider<LiveReviewController, LiveReview> liveReviewProvider = NotifierProvider<LiveReviewController, LiveReview>(LiveReviewController.new);

/// Стоп-кадр с рамкой признака: кадр заполняет область с обрезкой краёв, рамка - в тех же координатах.
class LiveFrameView extends StatelessWidget {
  /// Создаёт стоп-кадр признака [d].
  const LiveFrameView({super.key, required this.d, this.boxRadius = KvRadius.xs, this.glow = true});

  /// Признак.
  final LiveDetection d;

  /// Скругление рамки.
  final double boxRadius;

  /// Свечение рамки дефекта.
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final List<Rect> rects = coverPercentRects([d.box], d.frameSize, box.biggest);
        return KvArStage(
          background: SizedBox.expand(child: Image.memory(d.jpeg, fit: BoxFit.cover, gaplessPlayback: true)),
          boxRadius: boxRadius,
          glow: glow,
          boxes: [
            if (rects.isNotEmpty)
              KvArBoxData(
                rects.first,
                kind: d.box.isDefect ? KvArKind.defect : KvArKind.part,
                color: d.box.isCheck ? c.warn : null,
                label: liveClassLabel(d.box.cls),
                semanticLabel: liveClassLabel(d.box.cls),
              ),
          ],
        );
      },
    );
  }
}

/// Название узла по коду из карточки агрегата.
String liveNodeName(Equipment? unit, String code) => unit?.nodes.where((EquipmentNode n) => n.id == code).firstOrNull?.name ?? code;

/// Участок стоп-кадра вокруг рамки признака с полями: кадр заполняет область, рамка выделена.
class LiveCropView extends StatelessWidget {
  /// Создаёт участок кадра признака [d].
  const LiveCropView({super.key, required this.d, this.margin = 0.6});

  /// Признак.
  final LiveDetection d;

  /// Поля вокруг рамки в долях её размера.
  final double margin;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Rect frame = Offset.zero & d.frameSize;
    final Rect b = d.box.rect;
    final double side = math.max(b.width, b.height) * (1 + margin * 2);
    Rect crop = Rect.fromCenter(center: b.center, width: math.max(side, b.width), height: math.max(side, b.height)).intersect(frame);
    if (crop.isEmpty) {
      crop = frame;
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final Size area = box.biggest;
        final double k = math.max(area.width / crop.width, area.height / crop.height);
        final double dx = (area.width - crop.width * k) / 2 - crop.left * k;
        final double dy = (area.height - crop.height * k) / 2 - crop.top * k;
        final Rect shown = Rect.fromLTRB(dx + b.left * k, dy + b.top * k, dx + b.right * k, dy + b.bottom * k);
        final Color tone = d.box.isDefect ? c.arDefect : (d.box.isCheck ? c.warn : c.arPart);
        return ClipRect(
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Color(0xFF0E141C))),
              Positioned(
                left: dx,
                top: dy,
                width: d.frameSize.width * k,
                height: d.frameSize.height * k,
                child: Image.memory(d.jpeg, fit: BoxFit.fill, gaplessPlayback: true),
              ),
              Positioned.fromRect(
                rect: shown,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: tone, width: 3),
                    borderRadius: BorderRadius.circular(KvRadius.xs),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Признак со сканера крупным планом на настоящем сервере (b-scan-defect): участок того кадра, где камера нашла
/// признак, класс, уверенность, узел по сопоставлению сервера, время кадра, показания агрегата с сервера (если
/// есть) и правило - только если диагноз сервера его связывает. «Это дефект» сохраняет находку с этим кадром,
/// «Не дефект» ничего не сохраняет.
class LiveScanDefectScreen extends ConsumerStatefulWidget {
  /// Создаёт экран признака [d].
  const LiveScanDefectScreen({super.key, required this.d});

  /// Признак.
  final LiveDetection d;

  @override
  ConsumerState<LiveScanDefectScreen> createState() => _LiveScanDefectScreenState();
}

class _LiveScanDefectScreenState extends ConsumerState<LiveScanDefectScreen> {
  bool _saving = false;

  Future<void> _confirm() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    final LiveDetection d = widget.d;
    final BuildContext screen = context;
    try {
      final Inspection ins = await ensureInspection(ref, d.unitId);
      final InspectionRepository repo = ref.read(inspectionRepositoryProvider);
      ref.read(apiClientProvider).lastFrame = d.jpeg;
      final String comment = '${liveClassLabel(d.box.cls)} · уверенность ${KvFormat.num(d.box.conf, 2)} · кадр ${d.time}';
      final int severity = d.box.isDefect ? 2 : 1;
      final Finding f = repo is ApiInspectionRepository
          ? await repo.addCameraFinding(ins.id, cls: d.box.cls, node: d.box.node, severity: severity, comment: comment)
          : await repo.addFinding(ins.id, node: d.box.node ?? '', title: liveClassLabel(d.box.cls), ruleId: '', severity: severity, comment: comment);
      ref.read(liveReviewProvider.notifier).done();
      if (!screen.mounted) {
        return;
      }
      showKvToast(screen, kind: KvToastKind.ok, title: 'Дефект зафиксирован · № ${f.id}', text: 'Кадр приложен к находке. Ждёт подтверждения мастера.');
      backToScanner(screen, d.unitId);
    } on KvApiException catch (e) {
      if (screen.mounted) {
        showKvToast(screen, title: 'Не удалось сохранить', text: e.message);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final LiveDetection d = widget.d;
    final Equipment? unit = ref.watch(unitProvider(d.unitId)).value;
    final Map<String, Reading> readings = ref.watch(readingsProvider(d.unitId)).value ?? const <String, Reading>{};
    final List<DiagnosisResult> diagnosis = ref.watch(diagnosisProvider(d.unitId)).value ?? const <DiagnosisResult>[];
    final List<DiagnosisResult> linked = [
      for (final DiagnosisResult r in diagnosis)
        if (r.evidence.any((Evidence e) => e.source == 'camera' && e.text.toLowerCase().contains(liveClassLabel(d.box.cls).toLowerCase()))) r,
    ];
    final Reading? vib = readings['vib1x'];
    final Reading? bearing = readings['tBearing'];
    final String node = d.box.node == null ? 'узел не определён' : liveNodeName(unit, d.box.node!);
    return ArCameraScreen(
      stage: LiveCropView(d: d),
      top: ArTopBar(pill: 'Кадр ${d.time}', waiting: true, backIcon: KvIcons.back, onBack: () => context.kvBack(EngineerInspectPaths.scannerFor(d.unitId))),
      panel: ArPanel(
        children: [
          KvRow(
            icon: d.box.isDefect ? KvIcons.alert : KvIcons.eye,
            iconStatus: d.box.isDefect ? KvStatus.bad : KvStatus.warn,
            title: liveClassLabel(d.box.cls),
            subtitle: '$node · уверенность ${KvFormat.num(d.box.conf, 2)}',
            padding: const EdgeInsets.symmetric(vertical: 4),
            minHeight: 56,
          ),
          EvidenceBox(
            lines: [
              EvidenceLine(KvIcons.camera, 'Камера: ${liveClassLabel(d.box.cls)} · кадр ${d.time} · ${d.box.isDefect ? 'признак дефекта' : 'нужна проверка'}'),
              if (vib != null || bearing != null)
                EvidenceLine(
                  KvIcons.activity,
                  [
                    if (vib != null) 'Вибрация ${KvFormat.withUnit(vib.value, vib.unit, vib.digits)}',
                    if (bearing != null) 'подшипник ${KvFormat.withUnit(bearing.value, bearing.unit, bearing.digits)}',
                  ].join(' · '),
                ),
              for (final DiagnosisResult r in linked) EvidenceLine(KvIcons.flag, '${r.ruleId} · ${r.title}'),
            ],
          ),
          Row(
            children: [
              Expanded(child: KvButton('Не дефект', kind: KvButtonKind.secondary, onPressed: _saving ? null : () => liveDismiss(context, ref, d))),
              const SizedBox(width: KvSpace.s3),
              Expanded(child: KvButton('Это дефект', loading: _saving, onPressed: _confirm)),
            ],
          ),
        ],
      ),
    );
  }
}

/// «Не дефект» (b-scan-dismissed): признак не сохраняется в осмотре и не предлагается снова, сканер показывает уведомление.
void liveDismiss(BuildContext context, WidgetRef ref, LiveDetection d) {
  ref.read(liveReviewProvider.notifier).dismiss(d);
  showKvToast(
    context,
    kind: KvToastKind.info,
    icon: KvIcons.info,
    title: 'Отмечено: не дефект',
    text: 'Признак не попадёт в осмотр и больше не будет предлагаться.',
  );
  backToScanner(context, d.unitId);
}

/// Новый дефект по признаку со сканера (b-defect): стоп-кадр, критичность, узел (b-defect-node), комментарий и решение.
/// «Подтвердить» сохраняет находку с кадром на сервере и возвращает на живое видео (b-scan-added).
class LiveDefectFormScreen extends ConsumerStatefulWidget {
  /// Создаёт форму для признака [d].
  const LiveDefectFormScreen({super.key, required this.d});

  /// Признак.
  final LiveDetection d;

  @override
  ConsumerState<LiveDefectFormScreen> createState() => _LiveDefectFormScreenState();
}

class _LiveDefectFormScreenState extends ConsumerState<LiveDefectFormScreen> {
  late final TextEditingController _comment = TextEditingController();
  late int _level = widget.d.box.isDefect ? 1 : 0;
  late String? _node = widget.d.box.node;
  bool _saving = false;

  static const List<String> _levels = ['Низкая', 'Средняя', 'Высокая'];

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    final LiveDetection d = widget.d;
    final BuildContext screen = context;
    try {
      final Inspection ins = await ensureInspection(ref, d.unitId);
      final InspectionRepository repo = ref.read(inspectionRepositoryProvider);
      ref.read(apiClientProvider).lastFrame = d.jpeg;
      final String comment = [liveSignTitle(d.box.cls), if (_comment.text.trim().isNotEmpty) _comment.text.trim()].join('. ');
      final Finding f = repo is ApiInspectionRepository
          ? await repo.addCameraFinding(ins.id, cls: d.box.cls, node: _node, severity: _level + 1, comment: comment)
          : await repo.addFinding(ins.id, node: _node ?? '', title: liveSignTitle(d.box.cls), ruleId: '', severity: _level + 1, comment: comment);
      ref.read(liveReviewProvider.notifier).done();
      if (!screen.mounted) {
        return;
      }
      showKvToast(screen, kind: KvToastKind.ok, title: 'Дефект зафиксирован · № ${f.id}', text: 'Ждёт подтверждения мастера. Кадр приложен к находке.');
      backToScanner(screen, d.unitId);
    } on KvApiException catch (e) {
      if (screen.mounted) {
        showKvToast(screen, title: 'Не удалось сохранить', text: e.message);
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _pickNode(List<EquipmentNode> nodes) async {
    final String? picked = await showKvSheet<String>(
      context,
      builder: (BuildContext sheet) {
        String? selected = _node;
        return StatefulBuilder(
          builder: (BuildContext sheet, StateSetter setSheet) => KvSheet(
            title: 'Узел агрегата',
            actions: [KvButton('Готово', onPressed: () => Navigator.of(sheet).pop(selected))],
            children: [
              KvList(
                noIcons: true,
                children: [
                  for (final EquipmentNode n in nodes)
                    KvRow(
                      title: n.name,
                      subtitle: n.hours == null ? null : 'Наработка ${KvFormat.num(n.hours!)} ч',
                      trailing: n.id == selected ? KvIcon(KvIcons.check, size: 22, color: sheet.kv.brand) : null,
                      onTap: () => setSheet(() => selected = n.id),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _node = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final LiveDetection d = widget.d;
    final Equipment? unit = ref.watch(unitProvider(d.unitId)).value;
    final Inspection? ins = ref.watch(activeInspectionProvider(d.unitId)).value;
    final List<EquipmentNode> nodes = unit?.nodes ?? const <EquipmentNode>[];
    final KvColors c = context.kv;
    return KvScreen(
      header: KvHeader(
        title: 'Новый дефект',
        subtitle: KvFormat.typo('${unit?.code ?? d.unitId} · ${ins == null ? 'новый осмотр' : 'осмотр № ${ins.id}'}'),
        onBack: () => context.kvBack(EngineerInspectPaths.scanDefectFor(d.unitId)),
      ),
      foot: Row(
        children: [
          Expanded(child: KvButton('Не дефект', kind: KvButtonKind.secondary, onPressed: _saving ? null : () => liveDismiss(context, ref, d))),
          const SizedBox(width: KvSpace.s3),
          Expanded(child: KvButton('Подтвердить', loading: _saving, onPressed: _save)),
        ],
      ),
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(KvRadius.card),
            child: Stack(
              children: [
                Positioned.fill(child: LiveFrameView(d: d, boxRadius: 10, glow: false)),
                Positioned(
                  left: 10,
                  top: 10,
                  child: KvGlass(
                    blur: 8,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      height: 28,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(color: c.arGlass, borderRadius: BorderRadius.circular(14)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          KvIcon(KvIcons.camera, size: 14, color: c.arText),
                          const SizedBox(width: 6),
                          Text('Кадр с видео · ${d.time}', maxLines: 1, softWrap: false, style: context.kvText.label.copyWith(color: c.arText, height: 1.2)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Признак · определён камерой', style: context.kvText.label),
              const SizedBox(height: KvSpace.s2),
              Text(liveSignTitle(d.box.cls), style: context.kvText.bodyM),
              const SizedBox(height: KvSpace.s3),
              Text('Критичность', style: context.kvText.label),
              const SizedBox(height: KvSpace.s2),
              KvSegment(items: _levels, index: _level, onChanged: (int i) => setState(() => _level = i)),
            ],
          ),
        ),
        KvList(
          children: [
            KvRow(icon: KvIcons.box, title: _node == null ? 'Узел не определён' : liveNodeName(unit, _node!), subtitle: 'Узел · уточнить', onTap: nodes.isEmpty ? null : () => _pickNode(nodes)),
          ],
        ),
        KvField(label: 'Комментарий', controller: _comment, area: true, fieldKey: const ValueKey<String>('live-defect-comment')),
      ],
    );
  }
}
