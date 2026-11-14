import '../models/admin.dart';
import '../models/equipment.dart';
import '../models/inspection.dart';
import '../models/people.dart';
import '../models/workflow.dart';

/// Учётная запись демонстрационного входа: почта, пароль и номер сотрудника в [MockDb.users].
class MockAccount {
  /// Создаёт учётную запись.
  MockAccount({required this.email, required this.password, required this.userId, this.offline = false});

  /// Почта для входа (без учёта регистра).
  final String email;

  /// Пароль.
  String password;

  /// Номер сотрудника.
  final String userId;

  /// Вход с этой почтой имитирует недоступный цеховой сервер.
  final bool offline;
}

/// Состояние демонстрационного сервера в памяти: всё, что видят и меняют роли, за одну сессию приложения.
///
/// Наполняется историей 14.11.2026 (seed_story.dart, перенос js/data.js) и дополнениями разделов
/// (seed_<раздел>.dart). Списки изменяются только через репозитории MockBackend.
class MockDb {
  /// Площадка.
  Site site = const Site(name: '', shift: '', shiftShort: '', server: '', wifi: '');

  /// Сотрудники по ключу роли дизайна: engineer, master, operator, admin, sec.
  final Map<String, Person> people = {};

  /// Учётные записи (Админ ИБ).
  final List<AdminUser> users = [];

  /// Данные для входа.
  final List<MockAccount> accounts = [];

  /// Агрегаты.
  final List<Equipment> units = [];

  /// Уставки заказчика по ключам показаний.
  final Map<String, ({double warn, double alarm, String unit, String label})> thresholds = {};

  /// Правила диагностики.
  final List<RuleDef> rules = [];

  /// Подписи тяжести правил.
  final Map<int, String> severityLabels = {};

  /// Результаты правил текущего осмотра по агрегатам.
  final Map<String, List<DiagnosisResult>> diagnostics = {};

  /// Чек-лист осмотра.
  final List<ChecklistItem> checklist = [];

  /// Рамки распознавания на кадре camera.jpg.
  final List<Detection> detections = [];

  /// Находки.
  final List<Finding> findings = [];

  /// Осмотры.
  final List<Inspection> inspections = [];

  /// Задания.
  final List<InspectionTask> tasks = [];

  /// Сообщения о неисправностях.
  final List<FaultReport> faultReports = [];

  /// Виды неисправностей для сообщения оператора.
  final List<String> faultKinds = [];

  /// План ТО.
  final List<PlanItem> plan = [];

  /// История по агрегатам, новые сверху.
  final Map<String, List<HistoryEvent>> history = {};

  /// Общая лента осмотров и событий по всем агрегатам, новые сверху.
  final List<HistoryEvent> activity = [];

  /// Итоги осмотров по номеру осмотра.
  final Map<String, InspectionSummary> summaries = {};

  /// Маршруты осмотра по агрегатам: узлы по приоритету с итогами текущего обхода.
  final Map<String, List<RouteStep>> routes = {};

  /// Разборы правил по ключу «агрегат/правило»: условия, основания и вывод.
  final Map<String, RuleCheck> ruleChecks = {};

  /// Пики по журналу датчика по ключу «агрегат/показание»: значение и дата, которые прорежённый ряд может сгладить.
  final Map<String, ({double value, String label})> sensorPeaks = {};

  /// Время отклика цехового сервера, мс.
  int pingMs = 38;

  /// Уведомления по ключу роли дизайна.
  final Map<String, List<AppNotification>> notifications = {};

  /// Подсказки ассистента.
  final List<String> assistantSuggestions = [];

  /// Диалог с ассистентом.
  final List<AssistantMessage> assistantDialog = [];

  /// Отчёты.
  final List<Report> reports = [];

  /// Цеховой сервер.
  ServerStatus? server;

  /// Источники данных.
  final List<DataSource> sources = [];

  /// Привязки тегов.
  final List<TagBinding> tags = [];

  /// Модели распознавания.
  final List<RecognitionModel> models = [];

  /// Системный журнал.
  final List<SysLogEntry> syslog = [];

  /// Резервные копии.
  final List<Backup> backups = [];

  /// Права доступа.
  final List<Permission> permissions = [];

  /// Роли.
  final List<Role> roles = [];

  /// Заготовка роли «Старший инженер» из сценария Г (ещё не создана).
  Role? seniorRoleTemplate;

  /// Кому назначается роль из сценария Г.
  String seniorRoleAssignee = '';

  /// Политика безопасности.
  SecurityPolicy? policy;

  /// Журнал безопасности, новые сверху.
  final List<SecLogEntry> seclog = [];

  /// Устройства сотрудников.
  final List<Device> devices = [];

  /// Открытые сеансы.
  final List<UserSession> sessions = [];

  /// Настройки приложения по умолчанию (KV.data.settings).
  final Map<String, Object> settingsDefaults = {};

  /// Неудачные попытки входа по почте.
  final Map<String, int> failedLogins = {};

  /// Счётчики новых номеров по префиксу: F-, INS-, T-, S-, P-.
  final Map<String, int> counters = {};

  /// Следующий номер с префиксом [prefix], начиная после [start].
  String nextId(String prefix, int start) {
    final int n = (counters[prefix] ?? start) + 1;
    counters[prefix] = n;
    return '$prefix$n';
  }
}
