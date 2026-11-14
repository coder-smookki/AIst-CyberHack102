import 'package:go_router/go_router.dart';

import '../navigation/kv_page.dart';
import '../navigation/placeholder.dart';

/// Пути экранов раздела «Инженер: итоги и сервис». Идентификаторы прототипа - имена маршрутов go_router.
abstract final class EngineerServicePaths {
  /// Итог осмотра.
  static const String cSummary = '/engineer/c-summary';
  /// Осмотр сохранён.
  static const String cSaved = '/engineer/c-saved';
  /// Предпросмотр отчёта.
  static const String cReport = '/engineer/c-report';
  /// История.
  static const String history = '/engineer/history';
  /// История · Н-101.
  static const String cHistoryN101 = '/engineer/history/c-history-n101';
  /// История · АМС-1.
  static const String cHistoryAms1 = '/engineer/history/c-history-ams1';
  /// История · АМС-2.
  static const String cHistoryAms2 = '/engineer/history/c-history-ams2';
  /// Ассистент.
  static const String assistant = '/engineer/assistant';
  /// Ассистент · ввод вопроса.
  static const String cAssistInput = '/engineer/c-assist-input';
  /// Ассистент · не нашёл.
  static const String cAssistNf = '/engineer/assistant/c-assist-nf';
  /// Ассистент · ближайшие ТО.
  static const String cAssistTo = '/engineer/assistant/c-assist-to';
  /// Уведомления.
  static const String cNotif = '/engineer/c-notif';
  /// Задание по правилу R08.
  static const String cTask = '/engineer/c-task';
  /// Задание по сообщению оператора.
  static const String cTaskAms2 = '/engineer/c-task-ams2';
  /// Профиль.
  static const String profile = '/engineer/profile';
  /// Настройки.
  static const String cSettings = '/engineer/c-settings';
  /// Настройки · прокрутка.
  static const String cSettingsEnd = '/engineer/c-settings-end';
  /// Очередь отправки · нет связи.
  static const String cQueue = '/engineer/c-queue';
  /// Очередь отправки · всё передано.
  static const String cQueueOk = '/engineer/c-queue-ok';
  /// Объекты · старший инженер.
  static const String fDSeniorHome = '/senior/objects';
  /// Находки · старший инженер.
  static const String fDSeniorFindings = '/senior/findings';
  /// Профиль · старший инженер.
  static const String fDSeniorProfile = '/senior/profile';
}

/// Экраны раздела внутри оболочки инженера (с панелью вкладок).
final List<RouteBase> engineerServiceEngineerShellRoutes = <RouteBase>[
  kvPlaceholderRoute('/engineer/history', id: 'history', title: 'История', transition: KvTransition.fade, routes: <RouteBase>[
      kvPlaceholderRoute('c-history-n101', id: 'c-history-n101', title: 'История · Н-101'),
      kvPlaceholderRoute('c-history-ams1', id: 'c-history-ams1', title: 'История · АМС-1'),
      kvPlaceholderRoute('c-history-ams2', id: 'c-history-ams2', title: 'История · АМС-2'),
  ]),
  kvPlaceholderRoute('/engineer/assistant', id: 'assistant', title: 'Ассистент', transition: KvTransition.fade, routes: <RouteBase>[
      kvPlaceholderRoute('c-assist-nf', id: 'c-assist-nf', title: 'Ассистент · не нашёл'),
      kvPlaceholderRoute('c-assist-to', id: 'c-assist-to', title: 'Ассистент · ближайшие ТО'),
  ]),
  kvPlaceholderRoute('/engineer/profile', id: 'profile', title: 'Профиль', transition: KvTransition.fade),
];

/// Экраны раздела внутри оболочки старшего инженера (с панелью вкладок).
final List<RouteBase> engineerServiceSeniorShellRoutes = <RouteBase>[
  kvPlaceholderRoute('/senior/assistant', id: 'senior-assistant', title: 'Ассистент · старший инженер', transition: KvTransition.fade),
  kvPlaceholderRoute('/senior/objects', id: 'f-d-senior-home', title: 'Объекты · старший инженер', transition: KvTransition.fade),
  kvPlaceholderRoute('/senior/findings', id: 'f-d-senior-findings', title: 'Находки · старший инженер', transition: KvTransition.fade),
  kvPlaceholderRoute('/senior/profile', id: 'f-d-senior-profile', title: 'Профиль · старший инженер', transition: KvTransition.fade),
];

/// Экраны раздела поверх оболочек (без панели вкладок): формы, камера, вход.
final List<RouteBase> engineerServiceRootRoutes = <RouteBase>[
  kvPlaceholderRoute('/engineer/c-summary', id: 'c-summary', title: 'Итог осмотра'),
  kvPlaceholderRoute('/engineer/c-saved', id: 'c-saved', title: 'Осмотр сохранён', transition: KvTransition.fade),
  kvPlaceholderRoute('/engineer/c-report', id: 'c-report', title: 'Предпросмотр отчёта'),
  kvPlaceholderRoute('/engineer/c-assist-input', id: 'c-assist-input', title: 'Ассистент · ввод вопроса'),
  kvPlaceholderRoute('/engineer/c-notif', id: 'c-notif', title: 'Уведомления'),
  kvPlaceholderRoute('/engineer/c-task', id: 'c-task', title: 'Задание по правилу R08'),
  kvPlaceholderRoute('/engineer/c-task-ams2', id: 'c-task-ams2', title: 'Задание по сообщению оператора'),
  kvPlaceholderRoute('/engineer/c-settings', id: 'c-settings', title: 'Настройки'),
  kvPlaceholderRoute('/engineer/c-settings-end', id: 'c-settings-end', title: 'Настройки · прокрутка'),
  kvPlaceholderRoute('/engineer/c-queue', id: 'c-queue', title: 'Очередь отправки · нет связи'),
  kvPlaceholderRoute('/engineer/c-queue-ok', id: 'c-queue-ok', title: 'Очередь отправки · всё передано'),
];
