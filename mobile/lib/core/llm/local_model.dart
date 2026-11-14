import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';

/// Папка ассетов модели в приложении.
const String kLlmAssets = 'assets/llm';

/// Уровень модели из описания assets/llm/manifest.json: файл весов частями и требования к устройству.
class ModelTier {
  /// Создаёт уровень.
  const ModelTier({
    required this.id,
    required this.title,
    required this.parts,
    required this.bytes,
    required this.minRamMb,
    required this.contextSize,
    required this.threads,
    required this.maxTokens,
    required this.thinkPrefix,
    required this.snippets,
    required this.minIosAvailableMb,
    required this.version,
  });

  /// Из записи описания.
  factory ModelTier.fromJson(Map<String, dynamic> j) => ModelTier(
        id: '${j['id']}',
        title: '${j['title'] ?? j['id']}',
        parts: <String>[for (final Object? p in j['parts'] as List<Object?>? ?? const <Object?>[]) '$p'],
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        minRamMb: (j['min_ram_mb'] as num?)?.toInt() ?? 0,
        contextSize: (j['context'] as num?)?.toInt() ?? 1024,
        threads: (j['threads'] as num?)?.toInt() ?? 4,
        maxTokens: (j['max_tokens'] as num?)?.toInt() ?? 320,
        thinkPrefix: j['think_prefix'] != false,
        snippets: (j['snippets'] as num?)?.toInt() ?? 3,
        version: '${j['version'] ?? j['bytes'] ?? 0}',
        minIosAvailableMb: (j['min_ios_avail_mb'] as num?)?.toInt() ?? ((j['min_ram_mb'] as num?)?.toInt() ?? 0) ~/ 2,
      );

  /// Идентификатор и имя файла весов.
  final String id;

  /// Название для экрана: «Основная модель».
  final String title;

  /// Части файла весов в ассетах, по порядку.
  final List<String> parts;

  /// Размер собранного файла, байт.
  final int bytes;

  /// Наименьший объём памяти устройства, МБ.
  final int minRamMb;

  /// Длина контекста, токенов.
  final int contextSize;

  /// Потоков процессора.
  final int threads;

  /// Наибольшая длина ответа, токенов.
  final int maxTokens;

  /// Модели нужен пустой блок рассуждений перед ответом.
  final bool thinkPrefix;

  /// Версия весов (начало SHA-256 файла): новая версия в установщике заменяет распакованный файл.
  final String version;

  /// Сколько фрагментов справки идёт в запрос: на слабом процессоре длинный запрос долго читается.
  final int snippets;

  /// Наименьшая память, доступная приложению на iOS, МБ (iOS сообщает доступную, а не общую память).
  final int minIosAvailableMb;
}

/// Сведения об устройстве для выбора уровня модели.
class DeviceProfile {
  /// Создаёт сведения.
  const DeviceProfile({required this.ramMb, required this.supported, required this.cores});

  /// Объём памяти, МБ: общий на Android, доступный приложению на iOS.
  final int ramMb;

  /// Среда исполнения модели есть для этой архитектуры.
  final bool supported;

  /// Ядер процессора.
  final int cores;

  /// Определяет память и поддержку архитектуры без сети и без разрешений.
  static Future<DeviceProfile> detect() async {
    int ram = 0;
    bool supported = false;
    try {
      if (Platform.isAndroid) {
        final String info = await File('/proc/meminfo').readAsString();
        final RegExpMatch? m = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(info);
        ram = m == null ? 0 : int.parse(m.group(1)!) ~/ 1024;
        supported = ffi.Abi.current() == ffi.Abi.androidArm64;
      } else if (Platform.isIOS) {
        final int Function() available =
            ffi.DynamicLibrary.process().lookupFunction<ffi.Size Function(), int Function()>('os_proc_available_memory');
        ram = available() ~/ (1024 * 1024);
        supported = ffi.Abi.current() == ffi.Abi.iosArm64;
      }
    } catch (_) {
      supported = false;
    }
    return DeviceProfile(ramMb: ram, supported: supported, cores: Platform.numberOfProcessors);
  }
}

/// Описание моделей приложения: уровни от сильного к слабому.
class ModelManifest {
  /// Создаёт описание.
  const ModelManifest(this.tiers);

  /// Читает assets/llm/manifest.json; без файла - пустое описание (ответы только поиском).
  static Future<ModelManifest> load(AssetBundle bundle) async {
    try {
      final Map<String, dynamic> j = jsonDecode(await bundle.loadString('$kLlmAssets/manifest.json')) as Map<String, dynamic>;
      return ModelManifest(<ModelTier>[
        for (final Object? t in j['tiers'] as List<Object?>? ?? const <Object?>[])
          if (t is Map<String, dynamic>) ModelTier.fromJson(t),
      ]);
    } catch (_) {
      return const ModelManifest(<ModelTier>[]);
    }
  }

  /// Уровни от сильного к слабому.
  final List<ModelTier> tiers;

  /// Первый уровень, который помещается в память устройства [device]; null - только поиск по справке.
  ModelTier? pick(DeviceProfile device) {
    if (!device.supported) {
      return null;
    }
    for (final ModelTier t in tiers) {
      if (t.parts.isNotEmpty && device.ramMb >= (Platform.isIOS ? t.minIosAvailableMb : t.minRamMb)) {
        return t;
      }
    }
    return null;
  }
}

/// Закрытая папка приложения для весов без лишних плагинов: на Android временная папка движка лежит в
/// /data/user/0/<пакет>/cache, веса кладутся в соседнюю files; на iOS временная папка - tmp контейнера,
/// веса кладутся в Library/Caches (не попадают в резервную копию, при нехватке места собираются заново).
String modelDirectory() {
  final Directory root = Directory.systemTemp.parent;
  return Platform.isIOS ? '${root.path}/Library/Caches' : '${root.path}/files';
}

/// Распаковывает веса из ассетов в папку приложения частями по 16-32 МБ, чтобы не держать файл в памяти целиком.
/// [onProgress] получает долю от 0 до 1. Повторный вызов при целом файле сразу возвращает путь.
Future<String> installModel(AssetBundle bundle, ModelTier tier, {void Function(double)? onProgress}) async {
  final Directory base = Directory('${modelDirectory()}/llm');
  await base.create(recursive: true);
  final File target = File('${base.path}/${tier.id}-${tier.version}.gguf');
  if (await target.exists() && await target.length() == tier.bytes) {
    onProgress?.call(1);
    return target.path;
  }
  await for (final FileSystemEntity e in base.list()) {
    if (e is File && e.path.endsWith('.gguf')) {
      await e.delete();
    }
  }
  final File part = File('${target.path}.part');
  final RandomAccessFile out = await part.open(mode: FileMode.write);
  int written = 0;
  try {
    for (final String name in tier.parts) {
      final ByteData data = await bundle.load('$kLlmAssets/$name');
      await out.writeFrom(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      written += data.lengthInBytes;
      onProgress?.call(tier.bytes == 0 ? 0 : written / tier.bytes);
    }
  } finally {
    await out.close();
  }
  if (written != tier.bytes) {
    await part.delete();
    throw StateError('Файл модели собран не полностью: $written из ${tier.bytes} байт');
  }
  await part.rename(target.path);
  return target.path;
}

/// Обёртка над движком llama.cpp: загрузка файла весов, потоковая генерация, остановка и освобождение памяти.
class LocalModel {
  LocalModel._(this.tier, this._engine);

  /// Уровень загруженной модели.
  final ModelTier tier;

  final LlamaEngine _engine;
  bool _disposed = false;

  /// Загружает веса из файла [path] для уровня [tier].
  static Future<LocalModel> open(String path, ModelTier tier) async {
    final LlamaEngine engine = await LlamaEngine.load(
      LlamaModel(ModelSource.path(path)),
      params: LlamaCppModelParams(
        contextSize: tier.contextSize,
        numberOfThreads: tier.threads,
        numberOfThreadsBatch: tier.threads,
        gpuLayers: Platform.isIOS ? 99 : 0,
      ),
    );
    return LocalModel._(tier, engine);
  }

  /// Потоковый ответ на готовый запрос ChatML [prompt].
  Stream<String> generate(String prompt) => _engine.generate(
        prompt,
        params: GenerationParams(
          maxTokens: tier.maxTokens,
          temp: 0.2,
          stopSequences: const <String>['<|im_end|>', '<|im_start|>'],
          streamBatchTokenThreshold: 1,
        ),
      );

  /// Прерывает текущий ответ.
  void cancel() {
    if (!_disposed) {
      _engine.cancelGeneration();
    }
  }

  /// Освобождает память модели.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _engine.dispose();
  }
}
