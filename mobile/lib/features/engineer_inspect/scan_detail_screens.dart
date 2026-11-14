import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../app/routes/engineer_service_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'inspect_actions.dart';
import 'inspect_catalog.dart';
import 'inspect_providers.dart';
import 'live/live_detection.dart';
import 'live/live_gauge.dart';
import 'scanner_screen.dart';
import 'widgets/inspect_camera.dart';

/// Признак дефекта крупным планом (b-scan-defect): рамка признака, правило, основания и решение инженера.
class ScanDefectScreen extends ConsumerWidget {
  /// Создаёт экран признака [label] агрегата [unitId].
  const ScanDefectScreen({super.key, this.unitId = kInspectDefaultUnit, this.label = kDefaultSign});

  /// Агрегат.
  final String unitId;

  /// Подпись рамки признака.
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool server = ref.watch(serverModeProvider);
    final LiveDetection? live = server ? ref.watch(liveReviewProvider).shown : null;
    if (live != null) {
      return LiveScanDefectScreen(d: live);
    }
    if (server) {
      return ArCameraScreen(
        stage: const ColoredBox(color: Color(0xFF0E141C)),
        top: ArTopBar(pill: 'Признак не выбран', backIcon: KvIcons.back, onBack: () => context.kvBack(EngineerInspectPaths.scannerFor(unitId))),
        panel: ArPanel(
          children: [
            const KvNote(text: 'Наведите камеру на признак и коснитесь его рамки на видео - решение принимается по стоп-кадру.', tone: KvStatus.info),
            KvButton('К сканеру', icon: KvIcons.scan, onPressed: () => backToScanner(context, unitId)),
          ],
        ),
      );
    }
    final DefectClass cls = kDefectClasses[label] ?? kDefectClasses.values.first;
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    final Detection? det = (ref.watch(detectionsProvider(unitId)).value ?? const <Detection>[]).where((Detection d) => d.label == label).firstOrNull;
    final RuleCheck? check = ref.watch(ruleCheckProvider((unitId: unitId, ruleId: cls.ruleId))).value;
    final List<HistoryEvent> history = ref.watch(unitHistoryProvider(unitId)).value ?? const <HistoryEvent>[];
    final KvCamView view = cls.closeUpView;
    void confirm() => context.kvPush(EngineerInspectPaths.defectFor(unitId, label: label));
    return ArCameraScreen(
      stage: KvArStage(
        view: view,
        boxes: [
          if (det != null)
            arBoxOf(view, detRect(det), kind: KvArKind.defect, label: det.label, icon: cls.icon, semanticLabel: det.label, onTap: confirm),
        ],
      ),
      top: ArTopBar(pill: 'Удерживайте кадр', waiting: true, backIcon: KvIcons.back, onBack: () => context.kvBack(EngineerInspectPaths.scannerFor(unitId))),
      panel: ArPanel(
        children: [
          KvRow(
            icon: cls.icon,
            iconStatus: KvStatus.bad,
            title: cls.title,
            subtitle: '${cls.node} · ${cls.ruleId}',
            padding: const EdgeInsets.symmetric(vertical: 4),
            minHeight: 56,
            onTap: () => context.kvPush(EngineerInspectPaths.rule(cls.ruleId, unitId)),
          ),
          EvidenceBox(
            lines: [
              EvidenceLine(KvIcons.camera, '${cls.seen}${check == null ? '' : ' · кадр ${check.frameTime}'}'),
              if (unit != null) sensorContextLine(unit, history),
            ],
          ),
          Row(
            children: [
              Expanded(child: KvButton('Не дефект', kind: KvButtonKind.secondary, onPressed: () => dismissSign(context, ref, unitId, label))),
              const SizedBox(width: KvSpace.s3),
              Expanded(child: KvButton('Подтвердить', onPressed: confirm)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Отметка признака [label] «не дефект» в осмотре: кадр уходит на проверку модели, сканер показывает уведомление
/// (b-scan-dismissed).
Future<void> dismissSign(BuildContext context, WidgetRef ref, String unitId, String label) async {
  final Inspection ins = await ensureInspection(ref, unitId);
  await ref.read(inspectionRepositoryProvider).dismissDetection(ins.id, label);
  if (!context.mounted) {
    return;
  }
  showKvToast(
    context,
    kind: KvToastKind.info,
    icon: KvIcons.info,
    title: 'Отмечено: не дефект',
    text: 'Признак останется в отчёте с вашей отметкой. Кадр сохранён для проверки модели.',
  );
  backToScanner(context, unitId);
}

/// Чтение манометра (b-scan-gauge): стрелка крупным планом, показание со шкалой, сверка с датчиком по R05
/// и сохранение показания в маршрут осмотра.
class ScanGaugeScreen extends ConsumerWidget {
  /// Создаёт экран манометра агрегата [unitId].
  const ScanGaugeScreen({super.key, this.unitId = kInspectDefaultUnit});

  /// Агрегат.
  final String unitId;

  /// Верх шкалы манометра, бар.
  static const double scaleMax = 10;

  /// Допустимое расхождение манометра и датчика по правилу R05, %.
  static const double allowedDiff = 15;

  static const KvCamView _view = KvCamView(k: 3.2, cx: 0.755, cy: 0.58, ty: 0.3);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(serverModeProvider)) {
      final LiveDetection? live = ref.watch(liveGaugeProvider);
      return LiveScanGaugeScreen(unitId: unitId, d: live?.unitId == unitId ? live : null);
    }
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool narrow = MediaQuery.sizeOf(context).width <= 370;
    final Detection? det = (ref.watch(detectionsProvider(unitId)).value ?? const <Detection>[]).where((Detection d) => d.kind == 'gauge').firstOrNull;
    final Reading? sensor = ref.watch(unitProvider(unitId)).value?.readings['pressOut'];
    final String reading = det == null ? '' : gaugeValueOf(det.label);
    final double value = double.tryParse(reading.split(' ').first.replaceAll(',', '.')) ?? 0;
    final String number = KvFormat.num(value, 1);
    final double diff = sensor == null || sensor.value == 0 ? 0 : ((value - sensor.value).abs() / sensor.value * 100);
    final bool diffOk = diff <= allowedDiff;
    final TextStyle cmp = t.h2.copyWith(fontWeight: FontWeight.w500, fontSize: narrow ? 15 : 17, height: KvTextStyles.normalHeight(narrow ? 15 : 17));
    Future<void> save() async {
      final List<RouteStep> route = await ref
          .read(inspectionRepositoryProvider)
          .markRouteStep(unitId, 'gauge', result: diffOk ? 'ok' : 'warn', note: KvFormat.withUnit(value, 'бар', 1));
      if (!context.mounted) {
        return;
      }
      showKvToast(
        context,
        kind: KvToastKind.ok,
        icon: KvIcons.gauge,
        title: 'Показание сохранено',
        text: KvFormat.typo('Манометр ${KvFormat.withUnit(value, 'бар', 1)} · осмотрено ${route.checked} из ${route.length} узлов'),
      );
    }

    return ArCameraScreen(
      stage: KvArStage(
        view: _view,
        boxes: [
          if (det != null)
            arBoxOf(_view, detRect(det), kind: KvArKind.gauge, label: '${det.label.split(' · ').first} · стрелка $number', icon: KvIcons.gauge),
        ],
      ),
      top: ArTopBar(pill: 'Чтение шкалы · 12 кадр/с', backIcon: KvIcons.back, onBack: () => context.kvBack(EngineerInspectPaths.scannerFor(unitId))),
      panel: ArPanel(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Манометр · шкала 0-${scaleMax.round()} бар', style: t.label),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(number, style: t.numXl),
                        const SizedBox(width: 6),
                        Text('бар', style: t.unit.copyWith(fontSize: 15)),
                      ],
                    ),
                    Text(KvFormat.typo('Среднее по 36 кадрам · ±0,1 бар'), style: t.caption),
                  ],
                ),
              ),
              const SizedBox(width: KvSpace.s3),
              SizedBox(
                width: narrow ? 96 : 112,
                height: narrow ? 80 : 92,
                child: CustomPaint(painter: GaugeDialPainter(value: value, max: scaleMax, colors: c, labelStyle: t.base)),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(child: GaugeCompareBox(label: 'Датчик давления', value: sensor == null ? '-' : KvFormat.withUnit(sensor.value, sensor.unit, 1), style: cmp)),
              const SizedBox(width: KvSpace.s2),
              Expanded(
                child: GaugeCompareBox(
                  label: 'Расхождение · R05',
                  value: KvFormat.typo('${KvFormat.num(diff, 0)} % из ${KvFormat.num(allowedDiff, 0)} %'),
                  style: cmp.copyWith(color: diffOk ? c.ok : c.warnText),
                ),
              ),
            ],
          ),
          KvButton('Сохранить показание', icon: KvIcons.check, wait: true, onPressed: det == null ? null : save),
        ],
      ),
    );
  }
}

/// Плашка сверки (.b-cmp): подпись и значение.
class GaugeCompareBox extends StatelessWidget {
  /// Создаёт плашку.
  const GaugeCompareBox({super.key, required this.label, required this.value, required this.style});

  /// Подпись.
  final String label;

  /// Значение.
  final String value;

  /// Шрифт значения.
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: context.kv.surface2, borderRadius: BorderRadius.circular(KvRadius.sm)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.kvText.label),
          const SizedBox(height: 2),
          Text(value, maxLines: 1, softWrap: false, style: style),
        ],
      ),
    );
  }
}

/// Шкала манометра (.b-dial): дуга 240°, деления, подписи 0, 5, 10, заполненная часть до показания и стрелка.
class GaugeDialPainter extends CustomPainter {
  /// Создаёт шкалу.
  GaugeDialPainter({required this.value, required this.max, required this.colors, required this.labelStyle});

  /// Показание.
  final double value;

  /// Верх шкалы.
  final double max;

  /// Цвета темы.
  final KvColors colors;

  /// Шрифт подписей.
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = math.min(size.width / 112, size.height / 92);
    canvas.save();
    canvas.translate((size.width - 112 * s) / 2, (size.height - 92 * s) / 2);
    canvas.scale(s);
    const Offset c = Offset(56, 52);
    const double r = 40;
    double ang(double v) => (-210 + 240 * v / max) * math.pi / 180;
    Offset pt(double v, double rr) => c + Offset(rr * math.cos(ang(v)), rr * math.sin(ang(v)));
    final Rect arc = Rect.fromCircle(center: c, radius: r);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arc, ang(0), ang(max) - ang(0), false, stroke
      ..strokeWidth = 5
      ..color = colors.surface3);
    if (value > 0) {
      canvas.drawArc(arc, ang(0), ang(value.clamp(0, max)) - ang(0), false, stroke..color = colors.arGauge);
    }
    stroke
      ..strokeWidth = 1.4
      ..color = colors.text3;
    for (int i = 0; i <= max; i++) {
      canvas.drawLine(pt(i.toDouble(), r - (i.isOdd ? 4 : 7)), pt(i.toDouble(), r), stroke);
    }
    for (final double v in [0, max / 2, max]) {
      final TextPainter tp = TextPainter(
        text: TextSpan(text: KvFormat.num(v, 0), style: labelStyle.copyWith(fontSize: 9, height: 1, color: colors.text3, fontWeight: FontWeight.w400)),
        textDirection: TextDirection.ltr,
      )..layout();
      final Offset p = pt(v, r + 9);
      tp.paint(canvas, Offset(p.dx - tp.width / 2, p.dy + 4 - tp.height * 0.8));
      tp.dispose();
    }
    canvas.drawLine(c, pt(value.clamp(0, max), r - 12), stroke
      ..strokeWidth = 2.6
      ..color = colors.text);
    canvas.drawCircle(c, 4, Paint()..color = colors.text);
    canvas.restore();
  }

  @override
  bool shouldRepaint(GaugeDialPainter old) => old.value != value || old.max != max || old.colors != colors;
}

/// Сканер на АМС-2, признак течи (f-a-scan-ams2, сценарий А): лужа под остановленным агрегатом, основания
/// и решение инженера по сообщению оператора.
class ScanAms2Screen extends ConsumerWidget {
  /// Создаёт экран.
  const ScanAms2Screen({super.key});

  static const String _unitId = 'AMS-2';
  static const String _label = 'Лужа под агрегатом';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final DefectClass cls = kDefectClasses[_label]!;
    final KvCamView view = cls.closeUpView;
    final Equipment? unit = ref.watch(unitProvider(_unitId)).value;
    final Detection? det = (ref.watch(detectionsProvider(_unitId)).value ?? const <Detection>[]).where((Detection d) => d.label == _label).firstOrNull;
    final RuleCheck? check = ref.watch(ruleCheckProvider((unitId: _unitId, ruleId: cls.ruleId))).value;
    final List<HistoryEvent> history = ref.watch(unitHistoryProvider(_unitId)).value ?? const <HistoryEvent>[];
    final InspectionTask? task = (ref.watch(tasksProvider(null)).value ?? const <InspectionTask>[]).where((InspectionTask t) => t.unitId == _unitId).firstOrNull;
    final KvStatus modeStatus = switch (unit?.mode) {
      'running' => KvStatus.ok,
      'repair' => KvStatus.info,
      _ => KvStatus.unk,
    };
    return ArCameraScreen(
      stage: Stack(
        children: [
          Positioned.fill(
            child: KvArStage(
              view: view,
              boxes: [
                if (det != null)
                  arBoxOf(
                    view,
                    detRect(det),
                    kind: KvArKind.defect,
                    label: det.label,
                    icon: KvIcons.drop,
                    semanticLabel: 'Признак течи',
                    onTap: () => showKvToast(
                      context,
                      kind: KvToastKind.info,
                      icon: KvIcons.drop,
                      title: 'Признак держится 36 кадров',
                      text: '${cls.seen} · уверенность 0,91',
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: MediaQuery.sizeOf(context).height * 0.34,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [c.arGlass, c.arGlass, c.arGlass.withValues(alpha: 0)],
                    stops: const [0, 0.45, 1],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      top: ArTopBar(pill: 'Анализ видео · 24 кадр/с', backIcon: KvIcons.back, onBack: () => context.kvBack(EngineerServicePaths.cTaskAms2)),
      panel: ArPanel(
        children: [
          ArPanelTitle(
            title: unit == null ? ' ' : '${unit.code} · распознан',
            caption: unit == null ? ' ' : 'По шильдику · № ${unit.serial}${task == null ? '' : ' · задание ${task.id}'}',
            chip: unit == null ? null : KvChip(unit.modeLabel, status: modeStatus),
          ),
          KvRow(
            icon: cls.icon,
            iconStatus: KvStatus.bad,
            title: cls.title,
            subtitle: '${cls.node} · ${cls.ruleId}',
            padding: const EdgeInsets.symmetric(vertical: 4),
            minHeight: 56,
          ),
          EvidenceBox(
            lines: [
              EvidenceLine(KvIcons.camera, '${cls.seen}${check == null ? '' : ' · кадр ${check.frameTime}'}'),
              if (unit != null) sensorContextLine(unit, history),
            ],
          ),
          Row(
            children: [
              Expanded(child: KvButton('Не дефект', kind: KvButtonKind.secondary, onPressed: () => _dismiss(context, ref))),
              const SizedBox(width: KvSpace.s3),
              Expanded(child: KvButton('Зафиксировать', wait: true, onPressed: () => _save(context, ref, cls, check))),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    final Inspection ins = await ensureInspection(ref, _unitId);
    await ref.read(inspectionRepositoryProvider).dismissDetection(ins.id, _label);
    if (!context.mounted) {
      return;
    }
    showKvToast(
      context,
      kind: KvToastKind.info,
      icon: KvIcons.info,
      title: 'Отмечено: не дефект',
      text: 'Кадр и ваша отметка сохранены. Мастер увидит их в отчёте осмотра.',
    );
  }

  Future<void> _save(BuildContext context, WidgetRef ref, DefectClass cls, RuleCheck? check) async {
    final Inspection ins = await ensureInspection(ref, _unitId);
    final RuleDef? rule = (await ref.read(rulesProvider.future)).where((RuleDef r) => r.id == cls.ruleId).firstOrNull;
    final Finding f = await ref.read(inspectionRepositoryProvider).addFinding(
          ins.id,
          node: cls.node,
          title: cls.findingTitle,
          ruleId: cls.ruleId,
          severity: rule?.severity ?? 3,
          evidence: [for (final RuleCondition c in check?.conditions ?? const <RuleCondition>[]) c.value],
        );
    final Person? master = (await ref.read(peopleProvider.future))['master'];
    if (!context.mounted) {
      return;
    }
    final Equipment? unit = ref.read(unitProvider(_unitId)).value;
    showKvToast(
      context,
      kind: KvToastKind.ok,
      title: 'Дефект зафиксирован · ${f.id}',
      text: KvFormat.typo(
        '${unit?.code ?? _unitId} · ${f.title.toLowerCase()}. Мастер ${master == null ? '' : '${_short(master.name)} '}получила находку на подтверждение.',
      ),
    );
  }

  static String _short(String name) {
    final List<String> p = name.split(' ');
    return p.length < 2 ? name : '${p[0][0]}. ${p[1]}';
  }
}
