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

  test('следы рамок: та же рамка сдвигается, а не появляется заново; пропавшая держится до 600 мс', () {
    final List<LiveTrack> tracks = [];
    final DateTime t0 = DateTime(2026, 11, 14, 9, 30);
    matchTracks(tracks, const [LiveBox(cls: 'motor', conf: 0.9, rect: Rect.fromLTRB(100, 100, 300, 300), status: 'ok')], t0);
    matchTracks(
      tracks,
      const [LiveBox(cls: 'motor', conf: 0.9, rect: Rect.fromLTRB(120, 110, 320, 310), status: 'ok')],
      t0.add(const Duration(milliseconds: 200)),
    );
    expect(tracks, hasLength(1));
    expect(tracks.single.box.rect.left, 120);
    expect(tracks.single.shown.left, 100);
    matchTracks(tracks, const [], t0.add(const Duration(milliseconds: 600)));
    expect(tracks, hasLength(1));
    expect(tracks.single.opacity(t0.add(const Duration(milliseconds: 600))), closeTo(0.5, 0.01));
    matchTracks(tracks, const [], t0.add(const Duration(milliseconds: 900)));
    expect(tracks, isEmpty);
  });

  test('признак дефекта показывается после двух ответов подряд или при уверенности от 0,5; узлы - сразу', () {
    final List<LiveTrack> tracks = [];
    final DateTime t0 = DateTime(2026, 11, 14, 9, 30);
    const LiveBox weak = LiveBox(cls: 'leak', conf: 0.3, rect: Rect.fromLTRB(10, 10, 60, 60), status: 'check');
    const LiveBox part = LiveBox(cls: 'motor', conf: 0.3, rect: Rect.fromLTRB(100, 100, 300, 300), status: 'ok');
    matchTracks(tracks, const [weak, part], t0);
    expect(tracks.firstWhere((LiveTrack t) => t.box.cls == 'leak').confirmed, isFalse);
    expect(tracks.firstWhere((LiveTrack t) => t.box.cls == 'motor').confirmed, isTrue);
    matchTracks(tracks, const [weak], t0.add(const Duration(milliseconds: 250)));
    expect(tracks.firstWhere((LiveTrack t) => t.box.cls == 'leak').confirmed, isTrue);
    final List<LiveTrack> strong = [];
    matchTracks(strong, const [LiveBox(cls: 'corrosion', conf: 0.7, rect: Rect.fromLTRB(0, 0, 50, 50), status: 'defect')], t0);
    expect(strong.single.confirmed, isTrue);
  });

  test('поворот кадра: альбомный кадр Android поворачивается, портретный кадр iOS - нет', () {
    expect(frameRotation(720, 480, 90), 90);
    expect(frameRotation(640, 480, 270), 270);
    expect(frameRotation(480, 640, 90), 0);
    expect(frameRotation(480, 480, 90), 0);
  });

  test('рамка в центре портретного кадра остаётся в центре экрана при заполнении с обрезкой', () {
    const LiveBox box = LiveBox(cls: 'motor', conf: 0.9, rect: Rect.fromLTRB(140, 220, 340, 420), status: 'ok');
    final Rect r = coverPercentRects(const [box], const Size(480, 640), const Size(430, 932)).single;
    expect(r.center.dx, closeTo(50, 0.01));
    expect(r.center.dy, closeTo(50, 0.01));
    expect(r.height, closeTo(200 / 640 * 100, 0.01));
  });

  test('альбомный кадр на портретном экране: обрезка по бокам, рамка у края уходит за экран', () {
    const LiveBox box = LiveBox(cls: 'gauge', conf: 0.9, rect: Rect.fromLTRB(0, 0, 64, 48), status: 'check');
    final Rect r = coverPercentRects(const [box], const Size(640, 480), const Size(390, 844)).single;
    expect(r.top, closeTo(0, 0.01));
    expect(r.height, closeTo(10, 0.01));
    expect(r.left, closeTo(-94.25, 0.05));
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
    expect(liveClassLabel('damage'), 'Повреждение');
    expect(liveClassLabel('valve_new_class'), 'valve_new_class');
  });
}
