import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/io.dart';

import '../../../core/kv.dart';
import '../../../data/api/api_client.dart';
import 'debug_frames.dart';
import 'frame_encoder.dart';

/// Состояние камеры живого видео.
enum LiveCameraState {
  /// Камера запускается.
  starting,

  /// Видео идёт.
  ready,

  /// Нет разрешения на камеру.
  denied,

  /// Камера недоступна по другой причине.
  failed,
}

/// Рамка распознавания, полученная от сервера: класс, уверенность, координаты в пикселях кадра, статус и узел.
@immutable
class LiveBox {
  /// Создаёт рамку.
  const LiveBox({required this.cls, required this.conf, required this.rect, required this.status, this.node});

  /// Из ответа сервера.
  factory LiveBox.fromJson(Map<String, dynamic> j) => LiveBox(
        cls: j['cls']?.toString() ?? '',
        conf: (j['conf'] as num?)?.toDouble() ?? 0,
        rect: Rect.fromLTRB(
          (j['x1'] as num?)?.toDouble() ?? 0,
          (j['y1'] as num?)?.toDouble() ?? 0,
          (j['x2'] as num?)?.toDouble() ?? 0,
          (j['y2'] as num?)?.toDouble() ?? 0,
        ),
        status: j['status']?.toString() ?? 'ok',
        node: j['node']?.toString(),
      );

  /// Класс детектора: motor, leak, gauge ...
  final String cls;

  /// Уверенность 0-1.
  final double conf;

  /// Рамка в пикселях кадра сервера.
  final Rect rect;

  /// Статус: defect, check, ok, unsure.
  final String status;

  /// Код узла агрегата во время осмотра.
  final String? node;

  /// Признак дефекта.
  bool get isDefect => status == 'defect';

  /// Признак «проверить».
  bool get isCheck => status == 'check' || status == 'unsure';
}

/// Русские подписи классов детектора.
const Map<String, String> kLiveClassLabels = {
  'motor': 'Двигатель',
  'pump_casing': 'Корпус насоса',
  'flange': 'Фланец',
  'coupling_guard': 'Кожух муфты',
  'coupling_no_guard': 'Нет кожуха муфты',
  'terminal_box': 'Клеммная коробка',
  'terminal_box_burnt': 'Следы подгорания',
  'nameplate': 'Шильдик',
  'gauge': 'Манометр',
  'leak': 'Подтёк',
  'corrosion': 'Коррозия',
  'damage': 'Повреждение',
  'crack': 'Трещина',
  'anchor_bolt_loose': 'Анкерный болт',
  'oil_dark': 'Тёмное масло',
  'pump_unit': 'Насосный агрегат',
  'control_cabinet': 'Шкаф управления',
  'transformer': 'Трансформатор',
  'electric_motor': 'Электродвигатель',
  'compressor': 'Компрессор',
  'valve': 'Задвижка',
};

/// Русская подпись класса детектора [cls]; неизвестный класс - как есть.
String liveClassLabel(String cls) => kLiveClassLabels[cls] ?? cls;

/// Камера живого видео: просмотр, перевод кадров в JPEG и поток кадров на сервер по WebSocket.
///
/// В полёте не больше одного кадра: следующий уходит только после ответа на предыдущий (или через 3 с без
/// ответа) и не чаще [minInterval]. При уходе приложения в фон камера и соединение закрываются, при
/// возврате - открываются снова. Обрыв связи повторяется каждые 3 с.
class LiveCamera extends ChangeNotifier with WidgetsBindingObserver {
  /// Создаёт камеру для клиента сервера [client].
  LiveCamera({
    required this.client,
    this.preset = ResolutionPreset.medium,
    this.maxSide = 720,
    this.quality = 80,
    this.minInterval = const Duration(milliseconds: 170),
    this.onReply,
  }) {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Клиент сервера.
  final ApiClient client;

  /// Разрешение камеры.
  final ResolutionPreset preset;

  /// Наибольшая сторона кадра для сервера.
  final int maxSide;

  /// Качество JPEG.
  final int quality;

  /// Наименьший промежуток между кадрами.
  final Duration minInterval;

  /// Ответ сервера на кадр или сообщение о состоянии осмотра.
  void Function(Map<String, dynamic> reply)? onReply;

  /// Контроллер камеры; null - камера закрыта.
  CameraController? controller;

  /// Состояние камеры.
  LiveCameraState state = LiveCameraState.starting;

  /// Соединение с сервером открыто.
  bool connected = false;

  /// Причина обрыва связи для баннера; null - связь есть или поток не нужен.
  String? connectionProblem;

  /// Рамки последнего ответа.
  List<LiveBox> boxes = const <LiveBox>[];

  /// Следы рамок для плавного показа между ответами.
  final List<LiveTrack> tracks = [];

  /// Размер кадра последнего ответа.
  Size frameSize = Size.zero;

  /// Кадров в секунду по ответам сервера.
  double fps = 0;

  /// Полная задержка: от снятия кадра до прихода рамок, мс.
  int roundTripMs = 0;

  /// Время работы детектора на сервере, мс.
  int serverMs = 0;

  /// Последний кадр в JPEG.
  Uint8List? lastJpeg;

  /// Кадр, к которому относятся рамки последнего ответа сервера: по нему вырезаются признак и манометр.
  Uint8List? replyJpeg;

  /// Отправленные кадры по номеру кадра в соединении: ответ сервера несёт тот же номер seq.
  final Map<int, Uint8List> _sentFrames = {};

  int _sentSeq = 0;

  /// Ответы с номером кадра не больше этого относятся к прежнему отладочному снимку и рамок не меняют.
  int _staleSeq = 0;

  /// Связь потеряна и идёт повторное подключение (тихое состояние до третьей неудачи).
  bool reconnecting = false;

  /// Код и причина последнего закрытия соединения сервером: для баннера и разбора сбоев.
  String? lastClose;

  /// Сколько ждать ответа на кадр, прежде чем отправить следующий.
  static const Duration replyTimeout = Duration(seconds: 8);

  /// Как часто проверять связь, пока кадры не уходят.
  static const Duration keepAlive = Duration(seconds: 15);

  /// Отладочный снимок вместо видео (только отладочная сборка с источником кадров из файлов).
  Uint8List? debugImage;

  DebugFrameSource? _debug;
  Timer? _debugTick;
  Timer? _debugSwitch;

  int _attempts = 0;
  Timer? _pingTimer;

  String? _wsPath;
  IOWebSocketChannel? _socket;
  StreamSubscription<dynamic>? _sub;
  final List<DateTime> _pending = [];

  /// Сколько кадров может одновременно ждать ответа сервера.
  static const int maxInFlight = 2;

  bool get _full => _pending.length >= maxInFlight;
  bool _encoding = false;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _flightTimer;
  Timer? _retryTimer;
  final List<DateTime> _replies = [];
  bool _disposed = false;
  bool _starting = false;
  bool _torch = false;
  bool _suspended = false;

  /// Путь потока кадров: «/ws/inspect/12» или «/ws/detect»; null - только просмотр.
  String? get wsPath => _wsPath;

  /// Задать путь потока кадров и подключиться.
  void connect(String? path) {
    _wsPath = path;
    _closeSocket();
    if (path != null) {
      _openSocket();
    }
  }

  /// Запустить камеру.
  Future<void> start() async {
    if (_starting || _disposed || controller != null) {
      return;
    }
    _holdPortraitOnTablet(true);
    _starting = true;
    state = LiveCameraState.starting;
    _notify();
    if (kDebugFrames && await _startDebug()) {
      _starting = false;
      _notify();
      if (_wsPath != null && _socket == null) {
        unawaited(_openSocket());
      }
      return;
    }
    try {
      final List<CameraDescription> cams = await availableCameras();
      if (cams.isEmpty) {
        state = LiveCameraState.failed;
        return;
      }
      final CameraDescription cam = cams.firstWhere((CameraDescription c) => c.lensDirection == CameraLensDirection.back, orElse: () => cams.first);
      final CameraController c = CameraController(
        cam,
        preset,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21,
      );
      await c.initialize();
      if (_disposed) {
        await c.dispose();
        return;
      }
      controller = c;
      state = LiveCameraState.ready;
      await c.startImageStream(_onImage);
      if (_torch) {
        await c.setFlashMode(FlashMode.torch);
      }
    } on CameraException catch (e) {
      final String code = '${e.code} ${e.description ?? ''}';
      state = code.contains('ccess') || code.contains('ermission') ? LiveCameraState.denied : LiveCameraState.failed;
    } finally {
      _starting = false;
      _notify();
    }
    if (_wsPath != null && _socket == null) {
      unawaited(_openSocket());
    }
  }

  /// Включить или выключить фонарик.
  Future<void> setTorch(bool on) async {
    _torch = on;
    try {
      await controller?.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    } on CameraException {
      _torch = false;
    }
  }

  /// Повторить запуск камеры и подключение.
  Future<void> retry() async {
    await _stopCamera();
    await start();
    if (_wsPath != null) {
      connect(_wsPath);
    }
  }

  /// Отладочный источник: снимки из папки kst_frames вместо камеры, смена снимка каждые 8 с.
  Future<bool> _startDebug() async {
    final DebugFrameSource? src = _debug ?? await DebugFrameSource.load();
    if (src == null || _disposed) {
      return false;
    }
    _debug = src;
    debugImage = src.current;
    lastJpeg = src.current;
    state = LiveCameraState.ready;
    _debugTick?.cancel();
    _debugTick = Timer.periodic(minInterval, (_) {
      final Uint8List? frame = debugImage;
      if (frame != null && !_full) {
        lastJpeg = frame;
        _send(frame, DateTime.now());
      }
    });
    _debugSwitch?.cancel();
    int ticks = 0;
    _debugSwitch = Timer.periodic(const Duration(milliseconds: 500), (_) {
      ticks++;
      final bool changed = src.controlled ? src.sync() : ticks % 16 == 0;
      if (!src.controlled && changed) {
        src.next();
      }
      if (changed) {
        debugImage = src.current;
        boxes = const <LiveBox>[];
        tracks.clear();
        _staleSeq = _sentSeq;
        _notify();
      }
    });
    return true;
  }

  /// Приостановить камеру и поток кадров, пока поверх сканера открыт другой экран.
  Future<void> suspend() async {
    _suspended = true;
    _closeSocket();
    await _stopCamera();
  }

  /// Продолжить после [suspend]: камера и поток кадров по прежнему адресу осмотра.
  Future<void> resume() async {
    if (_disposed || !_suspended) {
      return;
    }
    _suspended = false;
    await start();
    if (_wsPath != null && _socket == null) {
      unawaited(_openSocket());
    }
  }

  /// Закрывает камеру. Сначала просмотр убирается из дерева виджетов и проходит кадр отрисовки, затем контроллер
  /// освобождается: иначе просмотр успевает перестроиться на освобождённом контроллере и экран остаётся чёрным.
  Future<void> _stopCamera() async {
    _debugTick?.cancel();
    _debugSwitch?.cancel();
    debugImage = null;
    final CameraController? c = controller;
    controller = null;
    _encoding = false;
    if (c != null) {
      _notify();
      await WidgetsBinding.instance.endOfFrame;
      try {
        if (c.value.isStreamingImages) {
          await c.stopImageStream();
        }
      } on CameraException {
        state = LiveCameraState.failed;
      }
      await c.dispose();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _closeSocket();
      _stopCamera();
    } else if (state == AppLifecycleState.resumed && controller == null && !_disposed && !_suspended) {
      start();
      if (_wsPath != null) {
        connect(_wsPath);
      }
    }
  }

  void _onImage(CameraImage image) {
    final DateTime now = DateTime.now();
    final bool streaming = _wsPath != null;
    final Duration gap = streaming ? minInterval : const Duration(milliseconds: 700);
    if (_encoding || (streaming && _full) || now.difference(_lastSent) < gap) {
      return;
    }
    final RawFormat? format = switch (image.format.group) {
      ImageFormatGroup.nv21 => RawFormat.nv21,
      ImageFormatGroup.bgra8888 => RawFormat.bgra8888,
      ImageFormatGroup.yuv420 => image.planes.length == 1 ? RawFormat.nv21 : RawFormat.yuv420,
      _ => null,
    };
    if (format == null) {
      return;
    }
    _encoding = true;
    _lastSent = now;
    final RawFrame raw = RawFrame(
      width: image.width,
      height: image.height,
      format: format,
      planes: [for (final Plane p in image.planes) Uint8List.fromList(p.bytes)],
      rowStrides: [for (final Plane p in image.planes) p.bytesPerRow],
      pixelStrides: [for (final Plane p in image.planes) p.bytesPerPixel ?? 1],
      rotation: frameRotation(image.width, image.height, controller?.description.sensorOrientation ?? 90),
      maxSide: maxSide,
      quality: quality,
    );
    encodeFrameInBackground(raw).then((Uint8List jpeg) {
      _encoding = false;
      if (_disposed) {
        return;
      }
      lastJpeg = jpeg;
      _send(jpeg, now);
    }).catchError((Object _) {
      _encoding = false;
    });
  }

  /// Отправляет кадр, снятый в момент [captured]; ответы приходят по порядку отправки.
  void _send(Uint8List jpeg, DateTime captured) {
    final IOWebSocketChannel? s = _socket;
    if (s == null || !connected || _full) {
      return;
    }
    _pending.add(captured);
    _sentSeq++;
    _sentFrames[_sentSeq] = jpeg;
    while (_sentFrames.length > 8) {
      _sentFrames.remove(_sentFrames.keys.first);
    }
    s.sink.add(jpeg);
    _flightTimer?.cancel();
    _flightTimer = Timer(replyTimeout, () => _pending.removeWhere((DateTime t) => DateTime.now().difference(t) >= replyTimeout));
  }

  Future<void> _openSocket() async {
    final String? path = _wsPath;
    if (path == null || _disposed || _suspended || _socket != null) {
      return;
    }
    _retryTimer?.cancel();
    final IOWebSocketChannel ch = IOWebSocketChannel.connect(
      client.ws(path),
      headers: client.wsHeaders,
      connectTimeout: const Duration(seconds: 8),
      pingInterval: const Duration(seconds: 20),
    );
    _socket = ch;
    _sentSeq = 0;
    _staleSeq = 0;
    _sentFrames.clear();
    _sub = ch.stream.listen(
      (dynamic data) {
        if (identical(_socket, ch)) {
          _onMessage(data);
        }
      },
      onError: (Object e) => _lost('Нет связи с сервером', from: ch),
      onDone: () => _onClosed(ch),
    );
    try {
      await ch.ready;
      if (identical(_socket, ch)) {
        connected = true;
        reconnecting = false;
        connectionProblem = null;
        _attempts = 0;
        _pending.clear();
        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(keepAlive, (_) {
          if (identical(_socket, ch) && connected && _pending.isEmpty) {
            ch.sink.add('ping');
          }
        });
        _notify();
      }
    } on Object {
      _lost('Нет связи с сервером', from: ch);
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String) {
      return;
    }
    try {
      _handle(jsonDecode(data) as Map<String, dynamic>);
    } on Object {
      _pending.clear();
      _sentFrames.clear();
    }
  }

  void _handle(Map<String, dynamic> j) {
    final String type = j['type']?.toString() ?? '';
    if (type == 'closed') {
      lastClose = '${j['status'] ?? ''} ${j['detail'] ?? ''}'.trim();
    }
    if (type == 'frame' || type == 'error') {
      final DateTime now = DateTime.now();
      final int? seq = (j['seq'] as num?)?.toInt();
      if (type == 'frame' && seq != null) {
        final Uint8List? sent = _sentFrames[seq];
        if (sent != null) {
          replyJpeg = sent;
        }
        _sentFrames.removeWhere((int k, Uint8List _) => k <= seq);
      }
      if (_pending.isNotEmpty) {
        roundTripMs = now.difference(_pending.removeAt(0)).inMilliseconds;
      }
      _replies.add(now);
      _replies.removeWhere((DateTime t) => now.difference(t) > const Duration(seconds: 2));
      fps = _replies.length / 2;
    }
    if (type == 'frame' && ((j['seq'] as num?)?.toInt() ?? _staleSeq + 1) > _staleSeq) {
      serverMs = (j['ms'] as num?)?.round() ?? 0;
      frameSize = Size((j['w'] as num?)?.toDouble() ?? 0, (j['h'] as num?)?.toDouble() ?? 0);
      boxes = [for (final dynamic b in (j['boxes'] as List<dynamic>? ?? const <dynamic>[])) LiveBox.fromJson(b as Map<String, dynamic>)];
      matchTracks(tracks, boxes, DateTime.now());
    }
    onReply?.call(j);
    _notify();
  }

  void _onClosed(IOWebSocketChannel ch) {
    if (!identical(_socket, ch)) {
      return;
    }
    final int? code = ch.closeCode;
    lastClose = code == null ? lastClose : '$code ${ch.closeReason ?? ''}'.trim();
    _socket = null;
    _sub = null;
    _pingTimer?.cancel();
    connected = false;
    _pending.clear();
    _sentFrames.clear();
    if (code == 4401) {
      client.refreshNow().then((bool ok) {
        if (ok) {
          _openSocket();
        } else {
          _lost('Сеанс завершён - войдите заново', retry: false);
        }
      });
      return;
    }
    if (code == 4409 || code == 4403 || code == 4404) {
      connectionProblem = ch.closeReason ?? 'Сервер закрыл соединение';
      _notify();
      return;
    }
    _lost('Нет связи с сервером');
  }

  /// Обрыв связи: повторное подключение с растущей паузой 1, 2, 4, 8, 10 с без смены осмотра. Первые две
  /// неудачи показываются тихо («Переподключение…»), дальше - баннер с причиной. Сбой старого соединения
  /// [from] не трогает уже открытое новое.
  void _lost(String why, {bool retry = true, IOWebSocketChannel? from}) {
    if (_disposed || (from != null && !identical(_socket, from))) {
      return;
    }
    _sub?.cancel();
    _sub = null;
    _socket?.sink.close();
    _socket = null;
    _pingTimer?.cancel();
    connected = false;
    _pending.clear();
    _sentFrames.clear();
    _attempts++;
    reconnecting = retry;
    connectionProblem = !retry || _attempts >= 3 ? (lastClose == null ? why : '$why · $lastClose') : null;
    boxes = const <LiveBox>[];
    tracks.clear();
    _notify();
    _retryTimer?.cancel();
    if (retry && _wsPath != null) {
      final int wait = math.min(10, 1 << math.min(_attempts - 1, 4));
      _retryTimer = Timer(Duration(seconds: wait), _openSocket);
    }
  }

  /// Переподключиться к серверу сейчас.
  void reconnect() {
    _attempts = 0;
    connectionProblem = null;
    _closeSocket();
    _openSocket();
  }

  void _closeSocket() {
    _retryTimer?.cancel();
    _pingTimer?.cancel();
    _flightTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _socket?.sink.close();
    _socket = null;
    connected = false;
    _pending.clear();
    _sentFrames.clear();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _closeSocket();
    _stopCamera();
    _holdPortraitOnTablet(false);
    super.dispose();
  }
}

/// На планшете живой осмотр держит портретную ориентацию: кадр сервера, превью и рамки посчитаны для портрета.
/// После осмотра планшету снова доступны все ориентации, как при запуске; телефон всегда в портрете и не меняется.
void _holdPortraitOnTablet(bool hold) {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) {
    return;
  }
  final view = views.first;
  if (view.physicalSize.shortestSide / view.devicePixelRatio < KvLayout.tablet) {
    return;
  }
  unawaited(SystemChrome.setPreferredOrientations(hold ? const <DeviceOrientation>[DeviceOrientation.portraitUp] : const <DeviceOrientation>[]));
}

/// Поворот сырого кадра камеры до портретного кадра для сервера. Android отдаёт кадр датчика в альбомной ориентации
/// (поворот на угол датчика), iOS - уже повёрнутым в портрет: портретный кадр не поворачивается, иначе рамки сервера
/// окажутся в чужих координатах.
int frameRotation(int width, int height, int sensorOrientation) => width > height ? sensorOrientation % 360 : 0;

/// Рамки ответа сервера в процентах области [stage] при заполнении области кадром [frame] с обрезкой краёв.
List<Rect> coverPercentRects(List<LiveBox> boxes, Size frame, Size stage) {
  if (frame.isEmpty || stage.isEmpty) {
    return const <Rect>[];
  }
  final double s = math.max(stage.width / frame.width, stage.height / frame.height);
  final double dx = (stage.width - frame.width * s) / 2;
  final double dy = (stage.height - frame.height * s) / 2;
  return [
    for (final LiveBox b in boxes)
      Rect.fromLTRB(
        (dx + b.rect.left * s) / stage.width * 100,
        (dy + b.rect.top * s) / stage.height * 100,
        (dx + b.rect.right * s) / stage.width * 100,
        (dy + b.rect.bottom * s) / stage.height * 100,
      ),
  ];
}

/// Рамка на экране между ответами сервера: плавно движется к последнему положению, появляется и гаснет.
class LiveTrack {
  /// Создаёт след рамки [box], впервые увиденной в момент [now].
  LiveTrack(this.box, DateTime now)
      : shown = box.rect,
        born = now,
        seen = now;

  /// Последняя рамка от сервера.
  LiveBox box;

  /// Положение на экране сейчас, в пикселях кадра.
  Rect shown;

  /// Когда рамка появилась.
  final DateTime born;

  /// Когда сервер видел её последний раз.
  DateTime seen;

  /// Сколько ответов подряд сервер видит эту рамку.
  int hits = 1;

  /// Рамку можно показывать: узлы - сразу; признак дефекта - после двух ответов подряд или при уверенности от 0,5,
  /// чтобы случайная рамка на одном кадре не мелькала.
  bool get confirmed => !(box.isDefect || box.isCheck) || hits >= 2 || box.conf >= 0.5;

  /// Прозрачность: появление за 150 мс, после пропажи рамка держится 200 мс и гаснет ещё за 400 мс.
  double opacity(DateTime now) {
    final double fadeIn = (now.difference(born).inMilliseconds / 150).clamp(0, 1).toDouble();
    final int gone = now.difference(seen).inMilliseconds;
    final double fadeOut = gone <= 200 ? 1 : (1 - (gone - 200) / 400).clamp(0, 1).toDouble();
    return math.min(fadeIn, fadeOut);
  }
}

/// Пересечение двух рамок к их объединению.
double _iou(Rect a, Rect b) {
  final Rect i = a.intersect(b);
  if (i.width <= 0 || i.height <= 0) {
    return 0;
  }
  final double inter = i.width * i.height;
  return inter / (a.width * a.height + b.width * b.height - inter);
}

/// Сопоставляет рамки нового ответа [boxes] со следами [tracks]: тот же класс и наибольшее пересечение или близкий
/// центр. Несопоставленные рамки становятся новыми следами; следы без рамки дольше 600 мс удаляются.
void matchTracks(List<LiveTrack> tracks, List<LiveBox> boxes, DateTime now) {
  final Set<LiveTrack> used = {};
  for (final LiveBox b in boxes) {
    LiveTrack? best;
    double score = 0;
    for (final LiveTrack t in tracks) {
      if (t.box.cls != b.cls || used.contains(t)) {
        continue;
      }
      final double iou = _iou(t.box.rect, b.rect);
      final double near = (t.box.rect.center - b.rect.center).distance < math.max(b.rect.width, b.rect.height) ? 0.05 : 0;
      final double sc = math.max(iou, near);
      if (sc > score) {
        score = sc;
        best = t;
      }
    }
    if (best == null) {
      final LiveTrack t = LiveTrack(b, now);
      tracks.add(t);
      used.add(t);
    } else {
      best
        ..box = b
        ..seen = now
        ..hits += 1;
      used.add(best);
    }
  }
  for (final LiveTrack t in tracks) {
    if (!used.contains(t)) {
      t.hits = 0;
    }
  }
  tracks.removeWhere((LiveTrack t) => now.difference(t.seen) > const Duration(milliseconds: 600));
}

/// Живое видео с рамками ответа сервера поверх: красные - дефект, жёлтые - «проверить», синие - узлы. Рамки
/// плавно перемещаются между ответами (около 150 мс), появляются и гаснут, чтобы не мигать.
class LiveCameraStage extends StatefulWidget {
  /// Создаёт видео камеры [camera]; [onBoxTap] - касание рамки.
  const LiveCameraStage({super.key, required this.camera, this.onBoxTap, this.filter});

  /// Камера.
  final LiveCamera camera;

  /// Отбор рамок для показа; null - все рамки ответа.
  final List<LiveBox> Function(List<LiveBox> boxes)? filter;

  /// Касание рамки; null - рамки не нажимаются.
  final VoidCallback? Function(LiveBox box)? onBoxTap;

  @override
  State<LiveCameraStage> createState() => _LiveCameraStageState();
}

class _LiveCameraStageState extends State<LiveCameraStage> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final double dt = (elapsed - _last).inMicroseconds / 1000;
    _last = elapsed;
    final List<LiveTrack> tracks = widget.camera.tracks;
    if (tracks.isEmpty) {
      return;
    }
    final double k = 1 - math.exp(-dt / 50);
    for (final LiveTrack t in tracks) {
      t.shown = Rect.lerp(t.shown, t.box.rect, k)!;
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final LiveCamera camera = widget.camera;
    return ListenableBuilder(
      listenable: camera,
      builder: (BuildContext context, Widget? _) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final Size stage = box.biggest;
          final DateTime now = DateTime.now();
          final Set<LiveBox> allowed = (widget.filter?.call([for (final LiveTrack t in camera.tracks) t.box]) ??
                  [for (final LiveTrack t in camera.tracks) t.box])
              .toSet();
          final List<LiveTrack> found = [
            for (final LiveTrack t in camera.tracks)
              if (allowed.contains(t.box) && t.confirmed && t.opacity(now) > 0) t,
          ]..sort((LiveTrack a, LiveTrack b) => _rank(a.box).compareTo(_rank(b.box)));
          final List<Rect> rects = coverPercentRects(
            [for (final LiveTrack t in found) LiveBox(cls: t.box.cls, conf: t.box.conf, rect: t.shown, status: t.box.status)],
            camera.frameSize,
            stage,
          );
          final List<KvArBoxData> boxes = [
            for (int i = 0; i < found.length; i++)
              KvArBoxData(
                rects[i],
                kind: found[i].box.isDefect ? KvArKind.defect : KvArKind.part,
                color: (found[i].box.isCheck ? c.warn : (found[i].box.isDefect ? c.arDefect : c.arPart))
                    .withValues(alpha: found[i].opacity(now)),
                label: found[i].box.isCheck ? '${liveClassLabel(found[i].box.cls)} · проверить' : liveClassLabel(found[i].box.cls),
                semanticLabel: liveClassLabel(found[i].box.cls),
                onTap: widget.onBoxTap?.call(found[i].box),
              ),
          ];
          return KvArStage(background: _preview(camera.controller), boxes: boxes, labelMinTop: MediaQuery.paddingOf(context).top + 68);
        },
      ),
    );
  }

  static int _rank(LiveBox b) => b.isDefect ? 2 : (b.isCheck ? 1 : 0);

  Widget _preview(CameraController? ctl) {
    final Uint8List? still = widget.camera.debugImage;
    if (still != null) {
      return SizedBox.expand(child: Image.memory(still, fit: BoxFit.cover, gaplessPlayback: true));
    }
    if (ctl == null || !ctl.value.isInitialized) {
      return const SizedBox.expand();
    }
    final Size p = ctl.value.previewSize ?? const Size(720, 480);
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(width: math.min(p.width, p.height), height: math.max(p.width, p.height), child: CameraPreview(ctl)),
      ),
    );
  }
}

/// Карточка поверх видео, когда камера недоступна: нет разрешения или ошибка запуска, с кнопкой «Повторить».
class LiveCameraProblem extends StatelessWidget {
  /// Создаёт карточку для камеры [camera].
  const LiveCameraProblem({super.key, required this.camera});

  /// Камера.
  final LiveCamera camera;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool denied = camera.state == LiveCameraState.denied;
    return KvGlass(
      blur: 14,
      borderRadius: BorderRadius.circular(KvRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(KvSpace.s5),
        decoration: BoxDecoration(color: c.arGlass, borderRadius: BorderRadius.circular(KvRadius.lg)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KvIcon(KvIcons.camera, size: 32, color: c.arText),
            const SizedBox(height: KvSpace.s3),
            Text(denied ? 'Нет доступа к камере' : 'Камера недоступна', style: t.hdr.copyWith(color: c.arText)),
            const SizedBox(height: KvSpace.s2),
            Text(
              denied ? 'Разрешите доступ к камере в настройках телефона' : 'Закройте другие приложения с камерой и повторите',
              style: t.sm.copyWith(color: c.arText),
            ),
            const SizedBox(height: KvSpace.s4),
            KvButton('Повторить', icon: KvIcons.refresh, onPressed: camera.retry),
          ],
        ),
      ),
    );
  }
}

/// Баннер обрыва связи с сервером поверх видео с кнопкой «Повторить».
class LiveConnectionBanner extends StatelessWidget {
  /// Создаёт баннер с текстом [text].
  const LiveConnectionBanner({super.key, required this.text, required this.onRetry});

  /// Причина.
  final String text;

  /// Повторить подключение.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return KvGlass(
      borderRadius: BorderRadius.circular(KvRadius.card),
      child: Container(
        padding: const EdgeInsets.fromLTRB(KvSpace.s4, 6, 6, 6),
        decoration: BoxDecoration(color: c.bad.withValues(alpha: 0.88), borderRadius: BorderRadius.circular(KvRadius.card)),
        child: Row(
          children: [
            KvIcon(KvIcons.wifiOff, size: 20, color: c.arText),
            const SizedBox(width: KvSpace.s2),
            Expanded(
              child: Text(text, maxLines: 2, style: context.kvText.sm.copyWith(color: c.arText, fontWeight: FontWeight.w500)),
            ),
            KvButton('Повторить', small: true, kind: KvButtonKind.secondary, onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
