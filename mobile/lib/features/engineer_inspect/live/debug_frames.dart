import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Отладочный источник кадров вместо камеры: только в отладочной сборке с --dart-define=KST_DEBUG_FRAMES=true.
/// В выпускной сборке всегда выключен.
const bool kDebugFrames = !kReleaseMode && bool.fromEnvironment('KST_DEBUG_FRAMES');

/// Снимки из папки kst_frames во внутренних файлах приложения (adb shell run-as ... cp) или в /sdcard/Android/data (только Android),
/// уменьшенные до 1280 пикселей по длинной стороне: сканер отправляет их на сервер вместо кадров камеры.
class DebugFrameSource {
  DebugFrameSource._(this.frames);

  /// Кадры в JPEG.
  final List<Uint8List> frames;

  int _index = 0;

  /// Текущий кадр.
  Uint8List get current => frames[_index];

  /// Перейти к следующему снимку.
  void next() => _index = (_index + 1) % frames.length;

  /// Загружает снимки; null - папки нет или в ней нет снимков.
  static Future<DebugFrameSource?> load() async {
    if (!Platform.isAndroid) {
      return null;
    }
    final Directory dir = [
      Directory('/data/user/0/ru.aist.kstvizor/files/kst_frames'),
      Directory('/storage/emulated/0/Android/data/ru.aist.kstvizor/files/kst_frames'),
    ].firstWhere((Directory d) => d.existsSync(), orElse: () => Directory(''));
    if (dir.path.isEmpty) {
      return null;
    }
    final List<File> files = dir.listSync().whereType<File>().where((File f) => RegExp(r'\.(jpe?g|png)$', caseSensitive: false).hasMatch(f.path)).toList()
      ..sort((File a, File b) => a.path.compareTo(b.path));
    final List<Uint8List> frames = [];
    for (final File f in files) {
      final Uint8List raw = f.readAsBytesSync();
      final Uint8List? jpeg = await Isolate.run(() => shrinkPhoto(raw));
      if (jpeg != null) {
        frames.add(jpeg);
      }
    }
    return frames.isEmpty ? null : DebugFrameSource._(frames);
  }
}

/// Снимок [raw] в JPEG не больше [side] пикселей по длинной стороне; null - файл не читается как изображение.
Uint8List? shrinkPhoto(Uint8List raw, {int side = 1280}) {
  final img.Image? src = img.decodeImage(raw);
  if (src == null) {
    return null;
  }
  final double k = math.min(1, side / math.max(src.width, src.height));
  final img.Image out = k < 1 ? img.copyResize(src, width: (src.width * k).round(), height: (src.height * k).round()) : src;
  return img.encodeJpg(out, quality: 80);
}
