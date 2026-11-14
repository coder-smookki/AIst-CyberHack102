import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kst_vizor/features/engineer_inspect/live/frame_encoder.dart';
import 'package:kst_vizor/features/engineer_inspect/live/live_camera.dart';

/// Владелец кадра с полем, которое нельзя передать в другой изолят (как контроллер камеры и соединение).
class _Holder {
  final ReceivePort port = ReceivePort();

  Future<Uint8List> encode(RawFrame raw) => encodeFrameInBackground(raw).then((Uint8List jpeg) {
        port.close();
        return jpeg;
      });
}

void main() {
  test('кодирование в изоляте не тянет за собой объект камеры', () async {
    const int w = 8;
    const int h = 4;
    final Uint8List nv21 = Uint8List(w * h * 3 ~/ 2)..fillRange(0, w * h, 200);
    final Uint8List jpeg = await _Holder().encode(
      RawFrame(width: w, height: h, format: RawFormat.nv21, planes: [nv21], rowStrides: const [w], pixelStrides: const [1], rotation: 90, maxSide: 32, quality: 70),
    );
    expect(img.decodeJpg(jpeg)!.width, h);
  });

  test('кадр NV21 поворачивается в портрет и уменьшается по длинной стороне', () {
    const int w = 64;
    const int h = 32;
    final Uint8List nv21 = Uint8List(w * h * 3 ~/ 2)..fillRange(0, w * h, 200)..fillRange(w * h, w * h * 3 ~/ 2, 128);
    final Uint8List jpeg = encodeFrame(
      RawFrame(width: w, height: h, format: RawFormat.nv21, planes: [nv21], rowStrides: const [w], pixelStrides: const [1], rotation: 90, maxSide: 32, quality: 70),
    );
    final img.Image out = img.decodeJpg(jpeg)!;
    expect(out.width, 16);
    expect(out.height, 32);
    expect(out.getPixel(8, 16).r, closeTo(200, 6));
  });

  test('кадр BGRA без поворота сохраняет цвет', () {
    const int w = 8;
    const int h = 8;
    final Uint8List bgra = Uint8List(w * h * 4);
    for (int i = 0; i < w * h; i++) {
      bgra[i * 4 + 2] = 220;
      bgra[i * 4 + 3] = 255;
    }
    final img.Image out = img.decodeJpg(
      encodeFrame(RawFrame(width: w, height: h, format: RawFormat.bgra8888, planes: [bgra], rowStrides: const [w * 4], pixelStrides: const [4], rotation: 0, maxSide: 640, quality: 90)),
    )!;
    expect(out.width, 8);
    expect(out.getPixel(4, 4).r, greaterThan(180));
  });

  test('рамки кадра переводятся в проценты области с обрезкой краёв', () {
    const LiveBox box = LiveBox(cls: 'leak', conf: 0.9, rect: Rect.fromLTRB(0, 0, 240, 320), status: 'defect');
    final List<Rect> r = coverPercentRects(const [box], const Size(480, 640), const Size(390, 844));
    expect(r.single.top, closeTo(0, 0.01));
    expect(r.single.height, closeTo(50, 0.01));
    expect(r.single.left, lessThan(0));
  });

  test('ответ сервера с рамкой и подпись класса', () {
    final LiveBox b = LiveBox.fromJson(const {'cls': 'corrosion', 'conf': 0.6, 'x1': 1, 'y1': 2, 'x2': 30, 'y2': 40, 'status': 'check', 'node': 'casing'});
    expect(b.isCheck, isTrue);
    expect(b.node, 'casing');
    expect(liveClassLabel(b.cls), 'Коррозия');
    expect(liveClassLabel('anchor_bolt_loose'), 'anchor_bolt_loose');
  });
}
