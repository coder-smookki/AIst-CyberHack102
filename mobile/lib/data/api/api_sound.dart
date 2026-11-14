import 'package:flutter/foundation.dart';

import '../models/json.dart';
import 'api_client.dart';

/// Полоса спектра шума: доля энергии и уровень.
@immutable
class SoundBand {
  /// Создаёт полосу.
  const SoundBand({required this.code, required this.title, required this.share, required this.db});

  /// Из ответа сервера.
  factory SoundBand.fromJson(Map<String, dynamic> j) =>
      SoundBand(code: Json.str(j, 'code'), title: Json.str(j, 'title'), share: Json.number(j, 'share'), db: Json.number(j, 'db'));

  /// low, mid, high, ultra.
  final String code;

  /// «Низкие 20-200 Гц».
  final String title;

  /// Доля энергии 0-1.
  final double share;

  /// Уровень, дБ.
  final double db;
}

/// Тональный пик спектра шума.
@immutable
class SoundPeak {
  /// Создаёт пик.
  const SoundPeak({required this.hz, required this.db, this.match, this.label = ''});

  /// Из ответа сервера.
  factory SoundPeak.fromJson(Map<String, dynamic> j) => SoundPeak(
        hz: Json.number(j, 'freq_hz', Json.number(j, 'hz')),
        db: Json.number(j, 'prominence_db', Json.number(j, 'db')),
        match: Json.strOrNull(j, 'match'),
        label: Json.str(j, 'match_title', Json.str(j, 'label')),
      );

  /// Частота, Гц.
  final double hz;

  /// Выступание над фоном, дБ.
  final double db;

  /// Совпадение с частотой агрегата: 1x, 2x, 3x, 4x, bpf или null.
  final String? match;

  /// Пояснение совпадения: «1× оборотов вала».
  final String label;
}

/// Точка спектра для графика.
@immutable
class SpectrumPoint {
  /// Создаёт точку.
  const SpectrumPoint(this.hz, this.db);

  /// Частота, Гц.
  final double hz;

  /// Уровень, дБ.
  final double db;
}

/// Признак-кандидат по шуму: ждёт решения инженера, сам в осмотр не записывается.
@immutable
class SoundCandidate {
  /// Создаёт кандидата.
  const SoundCandidate({required this.sign, required this.title, required this.explanation, this.value = ''});

  /// Из ответа сервера.
  factory SoundCandidate.fromJson(Map<String, dynamic> j) => SoundCandidate(
        sign: Json.str(Json.obj(j, 'confirm'), 'sign', Json.str(j, 'sign')),
        title: Json.str(j, 'title'),
        explanation: Json.str(j, 'text', Json.str(j, 'explanation')),
        value: Json.str(j, 'value'),
      );

  /// Код признака для записи находки: noise_high, noise_impulsive, noise_tonal, cavitation_noise.
  final String sign;

  /// Название признака по-русски.
  final String title;

  /// Объяснение по-русски.
  final String explanation;

  /// Измерение: «+8,4 дБ к норме».
  final String value;
}

/// Итог разбора записи шума (POST /inspections/{id}/sound).
@immutable
class SoundResult {
  /// Создаёт итог.
  const SoundResult({
    required this.levelDb,
    this.id,
    this.durationS = 0,
    this.peakDb,
    this.crestFactor,
    this.kurtosis,
    this.baselineDb,
    this.baselineTitle = '',
    this.deltaDb,
    this.bands = const <SoundBand>[],
    this.peaks = const <SoundPeak>[],
    this.spectrum = const <SpectrumPoint>[],
    this.candidates = const <SoundCandidate>[],
    this.shaftHz,
    this.note = '',
    this.normal = false,
  });

  /// Из ответа сервера.
  factory SoundResult.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> base = Json.obj(j, 'baseline');
    return SoundResult(
      id: Json.strOrNull(j, 'id'),
      levelDb: Json.number(j, 'level_dbfs', Json.number(j, 'level_db')),
      durationS: Json.number(j, 'duration_s'),
      peakDb: Json.numOrNull(j, 'peak_dbfs'),
      crestFactor: Json.numOrNull(j, 'crest_factor'),
      kurtosis: Json.numOrNull(j, 'kurtosis'),
      baselineDb: Json.numOrNull(base, 'dbfs'),
      baselineTitle: Json.str(base, 'title'),
      deltaDb: Json.numOrNull(base, 'delta_db'),
      bands: Json.list(j, 'bands', SoundBand.fromJson),
      peaks: Json.list(j, 'peaks', SoundPeak.fromJson),
      spectrum: [
        for (final Map<String, dynamic> p in Json.list(j, 'spectrum', (Map<String, dynamic> e) => e)) SpectrumPoint(Json.number(p, 'f'), Json.number(p, 'db')),
      ],
      candidates: Json.list(j, 'candidates', SoundCandidate.fromJson),
      shaftHz: Json.numOrNull(j, 'shaft_hz'),
      note: Json.str(j, 'note'),
      normal: Json.flag(j, 'normal'),
    );
  }

  /// Номер записи на сервере.
  final String? id;

  /// Уровень шума, дБFS.
  final double levelDb;

  /// Длительность записи, с.
  final double durationS;

  /// Пиковый уровень, дБFS.
  final double? peakDb;

  /// Пик-фактор.
  final double? crestFactor;

  /// Эксцесс (импульсность).
  final double? kurtosis;

  /// Уровень нормы, дБFS.
  final double? baselineDb;

  /// Откуда норма: «по трём записям исправного агрегата».
  final String baselineTitle;

  /// Отличие от нормы, дБ.
  final double? deltaDb;

  /// Полосы спектра.
  final List<SoundBand> bands;

  /// Тональные пики (до 5).
  final List<SoundPeak> peaks;

  /// Спектр для графика.
  final List<SpectrumPoint> spectrum;

  /// Признаки-кандидаты.
  final List<SoundCandidate> candidates;

  /// Частота вращения вала, Гц.
  final double? shaftHz;

  /// Пояснение сервера.
  final String note;

  /// Запись отмечена как нормальная работа.
  final bool normal;
}

/// Разбор шума агрегата на сервере.
class ApiSound {
  /// Создаёт клиент поверх [api].
  ApiSound(this.api);

  /// Клиент сервера.
  final ApiClient api;

  /// Отправляет запись [wav] (WAV PCM 16 бит, моно, 2-30 с) осмотра [inspectionId]; [normal] - запись исправной работы.
  Future<SoundResult> analyze(String inspectionId, Uint8List wav, {bool normal = false}) async {
    final dynamic j = await api.postForm(
      '/inspections/$inspectionId/sound',
      fields: {if (normal) 'normal': 'true'},
      fileField: 'audio',
      file: wav,
      fileName: 'sound.wav',
    );
    return SoundResult.fromJson(j as Map<String, dynamic>);
  }
}
