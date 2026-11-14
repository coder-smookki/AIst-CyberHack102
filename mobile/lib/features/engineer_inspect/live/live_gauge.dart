import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../core/kv.dart';
import '../../../data/api/api_gauge.dart';
import '../../../data/providers.dart';
import '../inspect_actions.dart';
import '../scan_detail_screens.dart';
import '../widgets/inspect_camera.dart';
import 'frame_encoder.dart';
import 'live_detection.dart';

/// Манометр, выбранный инженером на живом видео: стоп-кадр и рамка прибора. Показание читает сервер.
class LiveGaugeController extends Notifier<LiveDetection?> {
  @override
  LiveDetection? build() => null;

  /// Запомнить манометр [d] для чтения.
  void open(LiveDetection d) => state = d;

  /// Забыть манометр.
  void clear() => state = null;
}

/// Манометр для чтения шкалы.
final NotifierProvider<LiveGaugeController, LiveDetection?> liveGaugeProvider = NotifierProvider<LiveGaugeController, LiveDetection?>(LiveGaugeController.new);

/// Чтение манометра сервером: вырезка прибора из стоп-кадра уходит на /recognize/gauge с номером осмотра.
/// Вынесено в провайдер, чтобы проверки подменяли сервер.
typedef GaugeReader = Future<GaugeReading> Function(String unitId, Uint8List crop, {String? inspectionId});

/// Чтение манометра на сервере подключения.
final Provider<GaugeReader> gaugeReaderProvider = Provider<GaugeReader>((Ref ref) => ApiGauge(ref.watch(apiClientProvider)).read);

/// Шкала манометра из карточки агрегата; null - манометра в карточке нет.
final gaugeScaleProvider = FutureProvider.autoDispose.family<GaugeScale?, String>(
  (Ref ref, String unitId) => ApiGauge(ref.watch(apiClientProvider)).scale(unitId),
);

/// Чтение манометра на настоящем сервере (b-scan-gauge): вырезка прибора из кадра, показание сервера на шкале
/// из карточки, сверка с электронным датчиком по R05. Если сервер не смог прочитать шкалу (кадр под углом,
/// мало контраста), экран показывает причину отказа и не показывает никакого числа.
class LiveScanGaugeScreen extends ConsumerStatefulWidget {
  /// Создаёт экран для манометра [d]; null - манометр на видео не выбран.
  const LiveScanGaugeScreen({super.key, required this.unitId, this.d});

  /// Агрегат.
  final String unitId;

  /// Манометр со стоп-кадром.
  final LiveDetection? d;

  @override
  ConsumerState<LiveScanGaugeScreen> createState() => _LiveScanGaugeScreenState();
}

class _LiveScanGaugeScreenState extends ConsumerState<LiveScanGaugeScreen> {
  GaugeReading? _reading;
  String? _error;
  bool _busy = false;
  bool _saved = false;
  String? _inspectionId;

  @override
  void initState() {
    super.initState();
    if (widget.d != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _read());
    }
  }

  Future<void> _read() async {
    final LiveDetection? d = widget.d;
    if (d == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _reading = null;
    });
    try {
      final Rect b = d.box.rect;
      final Uint8List? crop = await cropJpegInBackground(d.jpeg, b.left, b.top, b.width, b.height);
      if (crop == null) {
        throw const KvApiException(KvFailure.validation, 'Манометр на кадре слишком мал - подойдите ближе');
      }
      final Inspection? ins = await ref.read(inspectionRepositoryProvider).activeInspection(widget.unitId);
      final String? id = ins == null || int.tryParse(ins.id) == null ? null : ins.id;
      final GaugeReading r = await ref.read(gaugeReaderProvider)(widget.unitId, crop, inspectionId: id);
      if (mounted) {
        setState(() {
          _reading = r;
          _inspectionId = id;
        });
        if (r.recorded) {
          ref.read(apiFeedProvider).notify(KvDomain.inspections);
        }
      }
    } on KvApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } on Object {
      if (mounted) {
        setState(() => _error = 'Показание не получено: нет ответа сервера. Проверьте связь и повторите.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// Сохраняет надёжное показание только по нажатию инженера. Расхождение больше допустимого записывается
  /// находкой по правилу R05 (если правило сработало в диагнозе осмотра), иначе узел отмечается проверенным.
  Future<void> _save(GaugeReading r) async {
    final double? value = r.value;
    if (!r.ok || value == null) {
      return;
    }
    final String note = 'Манометр ${KvFormat.withUnit(value, r.unit, 1)}'
        '${r.differencePercent == null ? '' : ' · расхождение с датчиком ${KvFormat.num(r.differencePercent!, 0)} %'}';
    final repo = ref.read(inspectionRepositoryProvider);
    try {
      if (r.exceeds == true && _inspectionId != null) {
        await repo.addFinding(
          _inspectionId!,
          node: 'gauge',
          title: 'Расхождение манометра и датчика',
          ruleId: 'R05',
          severity: 1,
          comment: note,
        );
        ref.read(apiFeedProvider).notify(KvDomain.inspections);
      } else {
        await repo.markRouteStep(widget.unitId, 'gauge', result: r.exceeds == true ? 'warn' : 'ok', note: note);
      }
    } on KvApiException catch (e) {
      if (mounted) {
        showKvToast(context, icon: KvIcons.alert, title: 'Показание не сохранено', text: e.message);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _saved = true);
    showKvToast(
      context,
      kind: KvToastKind.ok,
      icon: KvIcons.gauge,
      title: 'Показание сохранено',
      text: KvFormat.typo(r.exceeds == true ? '$note · записано по R05' : note),
    );
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final LiveDetection? d = widget.d;
    final GaugeScale? scale = ref.watch(gaugeScaleProvider(widget.unitId)).value;
    final GaugeReading? r = _reading;
    final String unit = r?.unit.isNotEmpty == true ? r!.unit : (scale?.unit ?? 'бар');
    final String scaleText = scale == null ? 'Манометр' : 'Манометр · шкала ${KvFormat.num(scale.min, 0)}-${KvFormat.num(scale.max, 0)} ${scale.unit}';
    final String? refused = _error ?? (r != null && !r.ok ? (r.reason ?? 'Манометр не прочитан') : null);
    void back() => context.kvBack(EngineerInspectPaths.scannerFor(widget.unitId));
    return ArCameraScreen(
      stage: d == null ? const ColoredBox(color: Color(0xFF0E141C)) : LiveCropView(d: d, margin: 0.2),
      top: ArTopBar(pill: _busy ? 'Читаю шкалу' : (d == null ? 'Манометр не выбран' : 'Кадр ${d.time}'), spinning: _busy, backIcon: KvIcons.back, onBack: back),
      panel: ArPanel(
        children: [
          if (d == null) ...[
            Text(scaleText, style: t.label),
            const KvNote(text: 'Наведите камеру на манометр и коснитесь его рамки на видео - показание прочитает сервер.', tone: KvStatus.info),
            KvButton('К сканеру', icon: KvIcons.scan, onPressed: () => backToScanner(context, widget.unitId)),
          ] else if (_busy || (r == null && refused == null)) ...[
            Text(scaleText, style: t.label),
            Row(children: [KvSpinner(color: c.brand), const SizedBox(width: KvSpace.s3), Expanded(child: Text('Сервер читает положение стрелки…', style: t.sm))]),
          ] else if (refused != null) ...[
            Text(scaleText, style: t.label),
            Text('Показание не прочитано', style: t.h2),
            KvNote(text: refused, tone: KvStatus.warn, icon: KvIcons.alert),
            Text('Держите телефон прямо напротив шкалы, без бликов, чтобы прибор занимал заметную часть кадра.', style: t.caption),
            Row(
              children: [
                Expanded(child: KvButton('Переснять', kind: KvButtonKind.secondary, icon: KvIcons.refresh, onPressed: () => backToScanner(context, widget.unitId))),
                const SizedBox(width: KvSpace.s3),
                Expanded(child: KvButton('Повторить', onPressed: _read)),
              ],
            ),
          ] else if (r != null) ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(scaleText, style: t.label),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(KvFormat.num(r.value!, 1), style: t.numXl),
                          const SizedBox(width: 6),
                          Text(unit, style: t.unit.copyWith(fontSize: 15)),
                        ],
                      ),
                      Text(KvFormat.typo('Прочитано сервером по кадру ${d.time}'), style: t.caption),
                    ],
                  ),
                ),
                const SizedBox(width: KvSpace.s3),
                SizedBox(
                  width: 112,
                  height: 92,
                  child: CustomPaint(painter: GaugeDialPainter(value: r.value!, max: scale?.max ?? 10, colors: c, labelStyle: t.base)),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: GaugeCompareBox(
                    label: 'Датчик давления',
                    value: r.sensorValue == null ? 'нет данных' : KvFormat.withUnit(r.sensorValue!, unit, 1),
                    style: t.h2.copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(width: KvSpace.s2),
                Expanded(
                  child: GaugeCompareBox(
                    label: 'Расхождение · R05',
                    value: r.differencePercent == null
                        ? 'не с чем сравнить'
                        : KvFormat.typo('${KvFormat.num(r.differencePercent!, 0)} % из ${KvFormat.num(r.limitPercent, 0)} %'),
                    style: t.h2.copyWith(fontWeight: FontWeight.w500, color: r.exceeds == true ? c.warnText : (r.exceeds == false ? c.ok : c.text)),
                  ),
                ),
              ],
            ),
            if (scale != null && scale.atEdge(r.value!))
              KvNote(
                text: KvFormat.typo('Стрелка у края шкалы ${KvFormat.num(scale.min, 0)}-${KvFormat.num(scale.max, 0)} ${scale.unit}: давление может быть вне диапазона прибора.'),
                tone: KvStatus.warn,
                icon: KvIcons.alert,
              )
            else if (scale != null)
              Text(
                KvFormat.typo('В пределах шкалы прибора ${KvFormat.num(scale.min, 0)}-${KvFormat.num(scale.max, 0)} ${scale.unit}'
                    '${scale.ratedMax == null ? '' : ' · предел агрегата по паспорту ${KvFormat.num(scale.ratedMax!, 0)} ${scale.unit}'}'),
                style: t.caption,
              ),
            if (r.sensorValue == null && r.sensorReason != null) Text(r.sensorReason!, style: t.caption),
            if (r.ruleTitle != null) KvNote(text: 'Сработало правило ${r.ruleTitle}', tone: KvStatus.warn, icon: KvIcons.flag),
            KvButton(_saved ? 'Сохранено' : 'Сохранить показание', icon: KvIcons.check, onPressed: _saved ? null : () => _save(r)),
          ],
        ],
      ),
    );
  }
}
