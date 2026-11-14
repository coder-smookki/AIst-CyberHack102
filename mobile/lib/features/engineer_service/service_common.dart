import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';

/// Версия приложения в профиле, настройках и окне «О приложении».
const String kvAppVersion = '1.4.2 (сборка 412)';

/// Короткая версия для строки «О приложении».
const String kvAppVersionShort = '1.4.2';

/// Осмотр, итог которого показывают «Итог осмотра», «Осмотр сохранён» и «Отчёт PDF»: черновик текущего
/// сотрудника, иначе его последний осмотр.
final FutureProvider<String?> currentInspectionIdProvider = FutureProvider.autoDispose<String?>((Ref ref) async {
  final String? me = ref.watch(sessionProvider.select((AuthSession? s) => s?.user.name));
  final List<Inspection> all = await ref.watch(inspectionsProvider(null).future);
  final List<Inspection> mine = all.where((Inspection i) => me == null || i.who == me).toList();
  final Inspection? draft = mine.where((Inspection i) => i.status == 'draft').firstOrNull;
  return (draft ?? mine.firstOrNull ?? all.firstOrNull)?.id;
});

/// Итог осмотра по номеру.
final inspectionSummaryProvider = FutureProvider.autoDispose.family<InspectionSummary, String>((Ref ref, String id) {
  ref.watch(revisionProvider(KvDomain.inspections));
  return ref.watch(inspectionRepositoryProvider).summary(id);
});

/// Общая лента осмотров и событий по всем агрегатам для вкладки «История».
final FutureProvider<List<HistoryEvent>> activityProvider = FutureProvider.autoDispose<List<HistoryEvent>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.inspections));
  ref.watch(revisionProvider(KvDomain.equipment));
  return ref.watch(inspectionRepositoryProvider).activity();
});

/// Задание по номеру.
final taskProvider = FutureProvider.autoDispose.family<InspectionTask, String>((Ref ref, String id) {
  ref.watch(revisionProvider(KvDomain.workflow));
  return ref.watch(workflowRepositoryProvider).task(id);
});

/// Время отклика цехового сервера, мс: строка «Сервер цеха» в профиле.
final FutureProvider<int> serverPingProvider = FutureProvider.autoDispose<int>((Ref ref) => ref.watch(siteRepositoryProvider).ping());

/// Число непрочитанных уведомлений инженера: счётчик в профиле и подпись «3 новых».
final Provider<int> unreadNotificationsProvider = Provider.autoDispose<int>((Ref ref) {
  final List<AppNotification> list = ref.watch(notificationsProvider('engineer')).value ?? const <AppNotification>[];
  return list.where((AppNotification n) => !n.read).length;
});

/// Чувствительность распознавания дефектов (сегмент в настройках сканера).
enum KvSensitivity {
  /// Меньше лишних срабатываний.
  careful('Осторожно', 'Меньше лишних срабатываний, слабые признаки могут быть пропущены.'),

  /// Средняя чувствительность.
  balance('Баланс', 'Средняя чувствительность для плановых обходов.'),

  /// Дефект не будет пропущен.
  max('Максимум', 'Дефект не будет пропущен, возможны лишние срабатывания.');

  const KvSensitivity(this.label, this.hint);

  /// Подпись пункта.
  final String label;

  /// Пояснение под сегментом.
  final String hint;

  /// Строка под сегментом: «Максимум: дефект не будет пропущен, …».
  String get caption => '$label: ${hint[0].toLowerCase()}${hint.substring(1)}';
}

/// Настройки сканера и данных на телефоне (KV.data.settings): подписи узлов, вибрация при находке,
/// чувствительность, вход по биометрии, фото в отчётах и кэш снимков.
@immutable
class ServiceSettings {
  /// Создаёт настройки.
  const ServiceSettings({
    this.labels = true,
    this.haptics = true,
    this.sensitivity = KvSensitivity.max,
    this.biometrics = true,
    this.reportPhotos = true,
    this.cacheMb = 312,
  });

  /// Подписи узлов на экране сканера.
  final bool labels;

  /// Вибрация при находке.
  final bool haptics;

  /// Чувствительность к дефектам.
  final KvSensitivity sensitivity;

  /// Вход по биометрии.
  final bool biometrics;

  /// Фото в отчётах.
  final bool reportPhotos;

  /// Кэш переданных снимков на телефоне, МБ.
  final int cacheMb;

  /// Размер кэша для строки настроек: «312 МБ».
  String get cacheLabel => '${KvFormat.num(cacheMb)} МБ';

  /// Копия с изменениями.
  ServiceSettings copyWith({bool? labels, bool? haptics, KvSensitivity? sensitivity, bool? biometrics, bool? reportPhotos, int? cacheMb}) =>
      ServiceSettings(
        labels: labels ?? this.labels,
        haptics: haptics ?? this.haptics,
        sensitivity: sensitivity ?? this.sensitivity,
        biometrics: biometrics ?? this.biometrics,
        reportPhotos: reportPhotos ?? this.reportPhotos,
        cacheMb: cacheMb ?? this.cacheMb,
      );
}

/// Настройки сканера и данных с сохранением на телефоне.
class ServiceSettingsController extends Notifier<ServiceSettings> {
  static const String _labels = 'scan_labels';
  static const String _haptics = 'scan_haptics';
  static const String _sensitivity = 'scan_sensitivity';
  static const String _biometrics = 'login_biometrics';
  static const String _photos = 'report_photos';
  static const String _cache = 'photo_cache_cleared';

  KvSettingsStore get _store => ref.read(settingsStoreProvider);

  @override
  ServiceSettings build() {
    final KvSettingsStore s = ref.watch(settingsStoreProvider);
    return ServiceSettings(
      labels: s.getBool(_labels) ?? true,
      haptics: s.getBool(_haptics) ?? true,
      sensitivity: KvSensitivity.values.where((KvSensitivity v) => v.name == s.getString(_sensitivity)).firstOrNull ?? KvSensitivity.max,
      biometrics: s.getBool(_biometrics) ?? true,
      reportPhotos: s.getBool(_photos) ?? true,
      cacheMb: (s.getBool(_cache) ?? false) ? 0 : 312,
    );
  }

  /// Подписи узлов на экране.
  Future<void> setLabels(bool v) async {
    state = state.copyWith(labels: v);
    await _store.setBool(_labels, v);
  }

  /// Вибрация при находке.
  Future<void> setHaptics(bool v) async {
    state = state.copyWith(haptics: v);
    await _store.setBool(_haptics, v);
  }

  /// Чувствительность к дефектам.
  Future<void> setSensitivity(KvSensitivity v) async {
    state = state.copyWith(sensitivity: v);
    await _store.setString(_sensitivity, v.name);
  }

  /// Вход по биометрии.
  Future<void> setBiometrics(bool v) async {
    state = state.copyWith(biometrics: v);
    await _store.setBool(_biometrics, v);
  }

  /// Фото в отчётах.
  Future<void> setReportPhotos(bool v) async {
    state = state.copyWith(reportPhotos: v);
    await _store.setBool(_photos, v);
  }

  /// Очистить кэш переданных снимков.
  Future<void> clearCache() async {
    state = state.copyWith(cacheMb: 0);
    await _store.setBool(_cache, true);
  }
}

/// Настройки сканера и данных.
final NotifierProvider<ServiceSettingsController, ServiceSettings> serviceSettingsProvider =
    NotifierProvider<ServiceSettingsController, ServiceSettings>(ServiceSettingsController.new);

/// Общие преобразования данных для экранов раздела.
abstract final class ServiceFormat {
  static const List<String> _months = [
    'января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
  ];

  /// Сокращённое имя «А. Смирнов»; «Система» и одно слово - без изменений.
  static String short(String name) {
    final List<String> p = name.split(' ').where((String w) => w.isNotEmpty).toList();
    if (p.length < 2) {
      return name;
    }
    return '${p.first[0]}. ${p[1]}';
  }

  /// Подпись дня ленты: «Сегодня, 14 ноября» или «13 ноября» для даты «13.11.2026».
  static String day(String date, DateTime now) {
    final List<String> p = date.split('.');
    if (p.length < 2) {
      return date;
    }
    final int d = int.tryParse(p[0]) ?? 0;
    final int m = int.tryParse(p[1]) ?? 1;
    final String label = '$d ${_months[(m - 1).clamp(0, 11)]}';
    final bool today = p.length > 2 && d == now.day && m == now.month && int.tryParse(p[2]) == now.year;
    return today ? 'Сегодня, $label' : label;
  }

  /// Группа тяжести находки итога: подпись и тон чипа.
  static (String, KvStatus) severity(String s) => switch (s) {
        'critical' => ('Критично', KvStatus.bad),
        'planned' => ('Планово', KvStatus.warn),
        _ => ('Проверить', KvStatus.info),
      };

  /// Значок строки уведомления по его виду и теме: задание, правило, ТО, синхронизация, тревога.
  static KvIcons notificationIcon(AppNotification n) {
    final String t = n.title.toLowerCase();
    if (n.kind.startsWith('task') || t.contains('задани')) {
      return KvIcons.clipboard;
    }
    if (n.kind.startsWith('fault')) {
      return KvIcons.megaphone;
    }
    if (t.contains('правил')) {
      return KvIcons.activity;
    }
    if (t.contains(' то-') || t.contains(' то ')) {
      return KvIcons.calendar;
    }
    if (t.contains('синхрониз')) {
      return KvIcons.sync;
    }
    if (t.contains('находк')) {
      return KvIcons.alertCircle;
    }
    return switch (n.kind) {
      'bad' || 'warn' => KvIcons.alert,
      'ok' => KvIcons.checkCircle,
      _ => KvIcons.bell,
    };
  }

  /// Тон значка уведомления: синий для заданий и сведений.
  static KvStatus? notificationTone(AppNotification n) => switch (n.kind) {
        'ok' => KvStatus.ok,
        'warn' => KvStatus.warn,
        'bad' => KvStatus.bad,
        _ => null,
      };
}
