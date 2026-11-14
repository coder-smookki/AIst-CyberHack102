import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Формат сырого кадра камеры.
enum RawFormat {
  /// NV21 одной плоскостью: яркость, затем чередующиеся V и U (Android).
  nv21,

  /// YUV 4:2:0 тремя плоскостями с шагами строк и пикселей (Android без NV21).
  yuv420,

  /// BGRA 8888 одной плоскостью (iOS).
  bgra8888,
}

/// Сырой кадр камеры, скопированный для обработки в отдельном изоляте.
class RawFrame {
  /// Создаёт кадр.
  const RawFrame({
    required this.width,
    required this.height,
    required this.format,
    required this.planes,
    required this.rowStrides,
    required this.pixelStrides,
    required this.rotation,
    required this.maxSide,
    required this.quality,
  });

  /// Ширина кадра датчика.
  final int width;

  /// Высота кадра датчика.
  final int height;

  /// Формат.
  final RawFormat format;

  /// Плоскости.
  final List<Uint8List> planes;

  /// Шаг строки каждой плоскости в байтах.
  final List<int> rowStrides;

  /// Шаг пикселя каждой плоскости в байтах.
  final List<int> pixelStrides;

  /// Поворот по часовой стрелке до портретного кадра: 0, 90, 180, 270.
  final int rotation;

  /// Наибольшая сторона результата в пикселях.
  final int maxSide;

  /// Качество JPEG 1-100.
  final int quality;
}

/// Переводит сырой кадр в JPEG: поворот до портрета, уменьшение до [RawFrame.maxSide] по длинной стороне.
Uint8List encodeFrame(RawFrame f) {
  final bool swap = f.rotation == 90 || f.rotation == 270;
  final int ow = swap ? f.height : f.width;
  final int oh = swap ? f.width : f.height;
  final double sc = math.max(1, math.max(ow, oh) / f.maxSide);
  final int tw = math.max(1, (ow / sc).floor());
  final int th = math.max(1, (oh / sc).floor());
  final Uint8List rgb = Uint8List(tw * th * 3);
  final Uint8List p0 = f.planes[0];
  final int w = f.width;
  final int h = f.height;
  int o = 0;
  for (int ty = 0; ty < th; ty++) {
    final int oy = math.min(oh - 1, (ty * sc).floor());
    for (int tx = 0; tx < tw; tx++) {
      final int ox = math.min(ow - 1, (tx * sc).floor());
      int sx;
      int sy;
      switch (f.rotation) {
        case 90:
          sx = oy;
          sy = h - 1 - ox;
        case 180:
          sx = w - 1 - ox;
          sy = h - 1 - oy;
        case 270:
          sx = w - 1 - oy;
          sy = ox;
        default:
          sx = ox;
          sy = oy;
      }
      int r;
      int g;
      int b;
      if (f.format == RawFormat.bgra8888) {
        final int i = sy * f.rowStrides[0] + sx * 4;
        b = p0[i];
        g = p0[i + 1];
        r = p0[i + 2];
      } else {
        int y;
        int u;
        int v;
        if (f.format == RawFormat.nv21) {
          y = p0[sy * w + sx];
          final int base = w * h + (sy >> 1) * w + (sx & ~1);
          v = base < p0.length ? p0[base] - 128 : 0;
          u = base + 1 < p0.length ? p0[base + 1] - 128 : 0;
        } else {
          y = p0[sy * f.rowStrides[0] + sx];
          final int ui = (sy >> 1) * f.rowStrides[1] + (sx >> 1) * f.pixelStrides[1];
          final int vi = (sy >> 1) * f.rowStrides[2] + (sx >> 1) * f.pixelStrides[2];
          u = ui < f.planes[1].length ? f.planes[1][ui] - 128 : 0;
          v = vi < f.planes[2].length ? f.planes[2][vi] - 128 : 0;
        }
        r = y + ((1436 * v) >> 10);
        g = y - ((352 * u + 731 * v) >> 10);
        b = y + ((1815 * u) >> 10);
      }
      rgb[o++] = r < 0 ? 0 : (r > 255 ? 255 : r);
      rgb[o++] = g < 0 ? 0 : (g > 255 ? 255 : g);
      rgb[o++] = b < 0 ? 0 : (b > 255 ? 255 : b);
    }
  }
  final img.Image image = img.Image.fromBytes(width: tw, height: th, bytes: rgb.buffer, numChannels: 3);
  return img.encodeJpg(image, quality: f.quality);
}

/// Кодирует кадр [raw] в отдельном изоляте. Функция верхнего уровня: замыкание видит только кадр, а не объект
/// камеры с контроллером и соединением, которые нельзя передать в другой изолят.
Future<Uint8List> encodeFrameInBackground(RawFrame raw) => Isolate.run(() => encodeFrame(raw));
