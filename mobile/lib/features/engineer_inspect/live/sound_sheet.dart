import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../../../core/kv.dart';
import '../../../data/api/api_repositories.dart';
import '../../../data/api/api_sound.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/inspection_repository.dart';

/// Открывает запись шума агрегата для осмотра [inspectionId].
Future<void> showSoundSheet(BuildContext context, {required String inspectionId, required String unitId}) =>
    showKvSheet<void>(context, builder: (BuildContext _) => SoundSheet(inspectionId: inspectionId, unitId: unitId));

enum _Step { idle, recording, uploading, result }

/// Лист «Шум агрегата»: запись 8 с с индикатором уровня, отправка на сервер и итог - уровень к норме, полосы,
/// спектр с пиками и признаки-кандидаты с решением инженера. Без «Это дефект» в осмотр ничего не записывается.
class SoundSheet extends ConsumerStatefulWidget {
  /// Создаёт лист.
  const SoundSheet({super.key, required this.inspectionId, required this.unitId});

  /// Осмотр.
  final String inspectionId;

  /// Агрегат.
  final String unitId;

  @override
  ConsumerState<SoundSheet> createState() => _SoundSheetState();
}

class _SoundSheetState extends ConsumerState<SoundSheet> {
  /// Длительность записи.
  static const int seconds = 8;

  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Amplitude>? _amp;
  Timer? _tick;
  _Step _step = _Step.idle;
  int _left = seconds;
  double _level = -60;
  bool _normal = false;
  SoundResult? _result;
  String? _error;
  final Set<String> _decided = {};

  @override
  void dispose() {
    _tick?.cancel();
    _amp?.cancel();
    unawaited(_rec.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _rec.hasPermission()) {
      setState(() => _error = 'Нет доступа к микрофону. Разрешите его в настройках телефона.');
      return;
    }
    final String path = '${Directory.systemTemp.path}/kst_sound_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 22050, numChannels: 1), path: path);
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((Amplitude a) {
      if (mounted) {
        setState(() => _level = a.current.isFinite ? a.current : -60);
      }
    });
    setState(() {
      _step = _Step.recording;
      _left = seconds;
      _error = null;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) {
        return;
      }
      setState(() => _left--);
      if (_left <= 0) {
        t.cancel();
        unawaited(_finish());
      }
    });
  }

  Future<void> _finish() async {
    await _amp?.cancel();
    final String? path = await _rec.stop();
    if (!mounted) {
      return;
    }
    setState(() => _step = _Step.uploading);
    try {
      final File f = File(path ?? '');
      final SoundResult r = await ApiSound(ref.read(apiClientProvider)).analyze(widget.inspectionId, await f.readAsBytes(), normal: _normal);
      unawaited(f.delete().catchError((Object _) => f));
      if (mounted) {
        setState(() {
          _result = r;
          _step = _Step.result;
        });
      }
    } on KvApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _step = _Step.idle;
        });
      }
    } on FileSystemException {
      if (mounted) {
        setState(() {
          _error = 'Запись не сохранилась - повторите';
          _step = _Step.idle;
        });
      }
    }
  }

  Future<void> _confirm(SoundCandidate c) async {
    final InspectionRepository repo = ref.read(inspectionRepositoryProvider);
    try {
      if (repo is ApiInspectionRepository) {
        await repo.addCameraFinding(widget.inspectionId, cls: c.sign, severity: 2, comment: '${c.title}. ${c.explanation} ${c.value}'.trim());
      }
      if (mounted) {
        setState(() => _decided.add(c.sign));
        showKvToast(context, kind: KvToastKind.ok, title: 'Находка сохранена', text: c.title);
      }
    } on KvApiException catch (e) {
      if (mounted) {
        showKvToast(context, title: 'Не удалось сохранить', text: e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final KvColors c = context.kv;
    final SoundResult? r = _result;
    return KvSheet(
      title: 'Шум агрегата',
      actions: switch (_step) {
        _Step.idle => [KvButton('Записать $seconds с', icon: KvIcons.mic, onPressed: _start)],
        _Step.recording => [KvButton('Остановить', kind: KvButtonKind.secondary, onPressed: () => _left = 0)],
        _Step.uploading => [const KvButton('Разбираю запись', loading: true)],
        _Step.result => [KvButton('Готово', onPressed: () => Navigator.of(context).pop())],
      },
      children: [
        if (_error != null) ...[KvNote(text: _error!, tone: KvStatus.bad), const SizedBox(height: KvSpace.s3)],
        if (_step == _Step.idle) ...[
          Text('Поднесите телефон к агрегату на 20-30 см и держите неподвижно $seconds секунд.', style: t.sm.copyWith(color: c.text2)),
          const SizedBox(height: KvSpace.s3),
          KvList(
            noIcons: true,
            children: [
              KvRow(
                title: 'Это нормальная работа',
                subtitle: 'Запись исправного агрегата - станет нормой',
                trailing: KvToggle(value: _normal, semanticLabel: 'Это нормальная работа', onChanged: (bool v) => setState(() => _normal = v)),
              ),
            ],
          ),
        ],
        if (_step == _Step.recording) _Meter(level: _level, left: _left),
        if (_step == _Step.result && r != null) ..._resultView(context, r),
      ],
    );
  }

  List<Widget> _resultView(BuildContext context, SoundResult r) {
    final KvTextStyles t = context.kvText;
    final KvColors c = context.kv;
    final double? d = r.deltaDb;
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(KvFormat.num(r.levelDb, 1), style: t.numL),
          const SizedBox(width: 4),
          Text('дБFS', style: t.unit),
          const Spacer(),
          if (d != null) KvChip('${d >= 0 ? '+' : ''}${KvFormat.num(d, 1)} дБ к норме', status: d > 6 ? KvStatus.bad : (d > 3 ? KvStatus.warn : KvStatus.ok)),
        ],
      ),
      if (r.baselineTitle.isNotEmpty) Text('Норма: ${r.baselineTitle}', style: t.caption),
      const SizedBox(height: KvSpace.s3),
      if (r.bands.isNotEmpty)
        KvBars(
          items: [for (final SoundBand b in r.bands) (label: b.title, value: b.share * 100, highlight: b.share >= 0.4)],
          height: 110,
        ),
      if (r.spectrum.length > 1) ...[
        const SizedBox(height: KvSpace.s3),
        SizedBox(height: 120, child: CustomPaint(painter: _SpectrumPainter(r, c), size: Size.infinite)),
        Text(
          [
            if (r.peaks.isNotEmpty) 'Пики: ${r.peaks.map((SoundPeak p) => '${KvFormat.num(p.hz, 0)} Гц${p.label.isEmpty ? '' : ' (${p.label})'}').join(', ')}',
            if (r.kurtosis != null) 'импульсность ${KvFormat.num(r.kurtosis!, 1)}',
          ].join(' · '),
          style: t.caption,
        ),
      ],
      const SizedBox(height: KvSpace.s3),
      if (r.candidates.isEmpty) KvNote(text: r.note.isEmpty ? 'Признаков неисправности по шуму нет' : r.note, tone: KvStatus.ok),
      for (final SoundCandidate k in r.candidates)
        if (!_decided.contains(k.sign))
          KvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(k.title, style: t.bodyM),
                if (k.value.isNotEmpty) Text(k.value, style: t.caption),
                const SizedBox(height: KvSpace.s2),
                Text(k.explanation, style: t.sm.copyWith(color: c.text2)),
                const SizedBox(height: KvSpace.s3),
                Row(
                  children: [
                    Expanded(child: KvButton('Не дефект', kind: KvButtonKind.secondary, small: true, onPressed: () => setState(() => _decided.add(k.sign)))),
                    const SizedBox(width: KvSpace.s3),
                    Expanded(child: KvButton('Это дефект', small: true, onPressed: () => _confirm(k))),
                  ],
                ),
              ],
            ),
          ),
    ];
  }
}

/// Индикатор уровня при записи: обратный отсчёт и полоса уровня микрофона.
class _Meter extends StatelessWidget {
  const _Meter({required this.level, required this.left});

  final double level;
  final int left;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final double v = ((level + 60) / 60).clamp(0, 1).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(child: Text('$left', style: context.kvText.numXl)),
        Center(child: Text('Идёт запись · ${KvFormat.num(level, 0)} дБFS', style: context.kvText.caption)),
        const SizedBox(height: KvSpace.s3),
        KvProgress(value: v, status: v > 0.85 ? KvStatus.bad : KvStatus.ok),
        if (v > 0.85) ...[
          const SizedBox(height: KvSpace.s2),
          Text('Слишком громко - отодвиньте телефон', style: context.kvText.caption.copyWith(color: c.bad)),
        ],
      ],
    );
  }
}

/// Спектр шума на логарифмической шкале частот с отметками пиков 1×/2×.
class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(this.r, this.c);

  final SoundResult r;
  final KvColors c;

  @override
  void paint(Canvas canvas, Size size) {
    final List<SpectrumPoint> s = r.spectrum;
    final double fMin = math.log(math.max(1, s.first.hz));
    final double fMax = math.log(math.max(2, s.last.hz));
    final double dMin = s.map((SpectrumPoint p) => p.db).reduce(math.min);
    final double dMax = s.map((SpectrumPoint p) => p.db).reduce(math.max);
    double x(double hz) => (math.log(math.max(1, hz)) - fMin) / math.max(1e-6, fMax - fMin) * size.width;
    double y(double db) => size.height - (db - dMin) / math.max(1e-6, dMax - dMin) * (size.height - 14);
    final Path path = Path()..moveTo(x(s.first.hz), y(s.first.db));
    for (final SpectrumPoint p in s.skip(1)) {
      path.lineTo(x(p.hz), y(p.db));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = c.brand
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (final SoundPeak p in r.peaks) {
      final double px = x(p.hz);
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), Paint()..color = (p.match == null ? c.text3 : c.warn).withValues(alpha: 0.7));
      if (p.match != null) {
        final TextPainter tp = TextPainter(
          text: TextSpan(text: p.match == 'bpf' ? 'BPF' : '${p.match!.replaceAll('x', '')}×', style: TextStyle(color: c.warn, fontSize: 11)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(math.min(px + 2, size.width - tp.width), 0));
      }
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) => old.r != r;
}
