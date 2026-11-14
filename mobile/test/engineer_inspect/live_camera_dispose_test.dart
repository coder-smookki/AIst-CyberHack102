import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/core/theme/kv_theme.dart';
import 'package:kst_vizor/data/api/api_client.dart';
import 'package:kst_vizor/features/engineer_inspect/live/live_camera.dart';

/// Камера телефона в тесте: одна задняя камера, просмотр - цветной прямоугольник, кадры не приходят.
class _FakeCamera extends CameraPlatform {
  final StreamController<CameraImageData> _frames = StreamController<CameraImageData>.broadcast();

  final StreamController<CameraErrorEvent> _errors = StreamController<CameraErrorEvent>.broadcast();

  int disposed = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async =>
      const [CameraDescription(name: '0', lensDirection: CameraLensDirection.back, sensorOrientation: 90)];

  @override
  Future<int> createCameraWithSettings(CameraDescription cameraDescription, MediaSettings mediaSettings) async => 1;

  @override
  Future<void> initializeCamera(int cameraId, {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {}

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream<CameraInitializedEvent>.value(const CameraInitializedEvent(1, 640, 480, ExposureMode.auto, true, FocusMode.auto, true));

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() => const Stream<DeviceOrientationChangedEvent>.empty();

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(int cameraId, {CameraImageStreamOptions? options}) => _frames.stream;

  @override
  bool supportsImageStreaming() => true;

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Color(0xFF00AA00));

  @override
  Future<void> dispose(int cameraId) async => disposed++;
}

void main() {
  testWidgets('остановка камеры убирает просмотр до освобождения контроллера: экран не чернеет при перестройке',
      (WidgetTester tester) async {
    final _FakeCamera fake = _FakeCamera();
    CameraPlatform.instance = fake;
    final LiveCamera camera = LiveCamera(client: ApiClient('http://test'));
    addTearDown(camera.dispose);
    await tester.pumpWidget(MaterialApp(theme: KvTheme.light, home: Scaffold(body: LiveCameraStage(camera: camera))));
    await tester.runAsync(camera.start);
    await tester.pump();
    expect(find.byWidgetPredicate((Widget w) => w is ColoredBox && w.color == const Color(0xFF00AA00)), findsOneWidget);

    unawaited(camera.suspend());
    await tester.pump();
    expect(find.byWidgetPredicate((Widget w) => w is ColoredBox && w.color == const Color(0xFF00AA00)), findsNothing);
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.reset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });
}
