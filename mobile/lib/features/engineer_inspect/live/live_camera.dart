import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
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
  'coupling_guard': 'Защита муфты',
  'coupling_no_guard': 'Муфта без защиты',
  'terminal_box': 'Клеммная коробка',
  'terminal_box_burnt': 'Нагар на клеммной коробке',
  'nameplate': 'Шильдик',
  'gauge': 'Манометр',
  'leak': 'Подтёк',
  'corrosion': 'Коррозия',
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
    this.maxSide = 640,
    this.quality = 70,
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

  /// Размер кадра последнего ответа.
  Size frameSize = Size.zero;

  /// Кадров в секунду по ответам сервера.
  double fps = 0;

  /// Время от отправки кадра до ответа, мс.
  int roundTripMs = 0;

  /// Время работы детектора на сервере, мс.
  int serverMs = 0;

  /// Последний кадр в JPEG.
  Uint8List? lastJpeg;

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

  late int _side = maxSide;
  late int _quality = quality;
  int _attempts = 0;
  Timer? _pingTimer;

  String? _wsPath;
  IOWebSocketChannel? _socket;
  StreamSubscription<dynamic>? _sub;
  bool _inFlight = false;
  bool _encoding = false;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _sentAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _flightTimer;
  Timer? _retryTimer;
  final List<DateTime> _replies = [];
  bool _disposed = false;
  bool _starting = false;
  bool _torch = false;

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
      if (frame != null && !_inFlight) {
        lastJpeg = frame;
        _send(frame);
      }
    });
    _debugSwitch?.cancel();
    _debugSwitch = Timer.periodic(const Duration(seconds: 8), (_) {
      src.next();
      debugImage = src.current;
      boxes = const <LiveBox>[];
      _notify();
    });
    return true;
  }

  Future<void> _stopCamera() async {
    _debugTick?.cancel();
    _debugSwitch?.cancel();
    final CameraController? c = controller;
    controller = null;
    _encoding = false;
    if (c != null) {
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
    } else if (state == AppLifecycleState.resumed && controller == null && !_disposed) {
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
    if (_encoding || (streaming && _inFlight) || now.difference(_lastSent) < gap) {
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
      rotation: controller?.description.sensorOrientation ?? 90,
      maxSide: _side,
      quality: _quality,
    );
    encodeFrameInBackground(raw).then((Uint8List jpeg) {
      _encoding = false;
      if (_disposed) {
        return;
      }
      lastJpeg = jpeg;
      _send(jpeg);
    }).catchError((Object _) {
      _encoding = false;
    });
  }

  void _send(Uint8List jpeg) {
    final IOWebSocketChannel? s = _socket;
    if (s == null || !connected || _inFlight) {
      return;
    }
    _inFlight = true;
    _sentAt = DateTime.now();
    s.sink.add(jpeg);
    _flightTimer?.cancel();
    _flightTimer = Timer(replyTimeout, () => _inFlight = false);
  }

  Future<void> _openSocket() async {
    final String? path = _wsPath;
    if (path == null || _disposed || _socket != null) {
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
        _inFlight = false;
        _pingTimer?.cancel();
        _pingTimer = Timer.periodic(keepAlive, (_) {
          if (identical(_socket, ch) && connected && !_inFlight) {
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
      _inFlight = false;
    }
  }

  void _adapt() {
    if (roundTripMs > 1500 && _side > 480) {
      _side = 480;
      _quality = math.min(quality, 60);
    } else if (roundTripMs > 0 && roundTripMs < 700 && _side < maxSide) {
      _side = maxSide;
      _quality = quality;
    }
  }

  void _handle(Map<String, dynamic> j) {
    final String type = j['type']?.toString() ?? '';
    if (type == 'closed') {
      lastClose = '${j['status'] ?? ''} ${j['detail'] ?? ''}'.trim();
    }
    if (type == 'frame' || type == 'error') {
      _inFlight = false;
      _flightTimer?.cancel();
      final DateTime now = DateTime.now();
      roundTripMs = now.difference(_sentAt).inMilliseconds;
      _replies.add(now);
      _replies.removeWhere((DateTime t) => now.difference(t) > const Duration(seconds: 2));
      fps = _replies.length / 2;
      _adapt();
    }
    if (type == 'frame') {
      serverMs = (j['ms'] as num?)?.round() ?? 0;
      frameSize = Size((j['w'] as num?)?.toDouble() ?? 0, (j['h'] as num?)?.toDouble() ?? 0);
      boxes = [for (final dynamic b in (j['boxes'] as List<dynamic>? ?? const <dynamic>[])) LiveBox.fromJson(b as Map<String, dynamic>)];
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
    _inFlight = false;
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
    _inFlight = false;
    _attempts++;
    reconnecting = retry;
    connectionProblem = !retry || _attempts >= 3 ? (lastClose == null ? why : '$why · $lastClose') : null;
    boxes = const <LiveBox>[];
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
    _inFlight = false;
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
    super.dispose();
  }
}

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

/// Живое видео с рамками ответа сервера поверх: красные - дефект, жёлтые - «проверить», синие - узлы.
class LiveCameraStage extends StatelessWidget {
  /// Создаёт видео камеры [camera]; [onBoxTap] - касание рамки.
  const LiveCameraStage({super.key, required this.camera, this.onBoxTap});

  /// Камера.
  final LiveCamera camera;

  /// Касание рамки; null - рамки не нажимаются.
  final VoidCallback? Function(LiveBox box)? onBoxTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return ListenableBuilder(
      listenable: camera,
      builder: (BuildContext context, Widget? _) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final Size stage = box.biggest;
          final CameraController? ctl = camera.controller;
          final List<LiveBox> found = [...camera.boxes]..sort((LiveBox a, LiveBox b) => _rank(a).compareTo(_rank(b)));
          final List<Rect> rects = coverPercentRects(found, camera.frameSize, stage);
          final List<KvArBoxData> boxes = [
            for (int i = 0; i < found.length; i++)
              KvArBoxData(
                rects[i],
                kind: found[i].isDefect ? KvArKind.defect : KvArKind.part,
                color: found[i].isCheck ? c.warn : null,
                label: found[i].isCheck ? '${liveClassLabel(found[i].cls)} · проверить' : liveClassLabel(found[i].cls),
                semanticLabel: liveClassLabel(found[i].cls),
                onTap: onBoxTap?.call(found[i]),
              ),
          ];
          return KvArStage(background: _preview(ctl), boxes: boxes);
        },
      ),
    );
  }

  static int _rank(LiveBox b) => b.isDefect ? 2 : (b.isCheck ? 1 : 0);

  Widget _preview(CameraController? ctl) {
    final Uint8List? still = camera.debugImage;
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
