import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'api/api_config.dart';
import 'api/api_feed.dart';
import 'api/api_repositories.dart';
import 'api/bio_vault.dart';
import 'clock.dart';
import 'mock/mock_backend.dart';
import 'mock/repos/mock_admin_repository.dart';
import 'mock/repos/mock_assistant_repository.dart';
import 'mock/repos/mock_auth_repository.dart';
import 'mock/repos/mock_equipment_repository.dart';
import 'mock/repos/mock_inspection_repository.dart';
import 'mock/repos/mock_report_repository.dart';
import 'mock/repos/mock_security_repository.dart';
import 'mock/repos/mock_site_repository.dart';
import 'mock/repos/mock_telemetry_repository.dart';
import 'mock/repos/mock_workflow_repository.dart';
import 'models/admin.dart';
import 'models/equipment.dart';
import 'models/inspection.dart';
import 'models/people.dart';
import 'models/workflow.dart';
import 'repositories/admin_repository.dart';
import 'repositories/assistant_repository.dart';
import 'repositories/auth_repository.dart';
import 'repositories/change_feed.dart';
import 'repositories/equipment_repository.dart';
import 'repositories/inspection_repository.dart';
import 'repositories/report_repository.dart';
import 'repositories/security_repository.dart';
import 'repositories/site_repository.dart';
import 'repositories/telemetry_repository.dart';
import 'repositories/workflow_repository.dart';

export 'api/api_config.dart';
export 'api/bio_vault.dart';
export 'api_exception.dart';
export 'clock.dart';
export 'models/admin.dart';
export 'models/auth.dart';
export 'models/equipment.dart';
export 'models/inspection.dart';
export 'models/people.dart';
export 'models/workflow.dart';
export 'repositories/change_feed.dart';

/// Часы приложения: в демонстрации идут от 14.11.2026 09:41, на настоящем сервере - время телефона; в снимках дизайна остановлены.
final Provider<KvClock> clockProvider = Provider<KvClock>((Ref ref) => ref.watch(serverModeProvider) ? const SystemClock() : StoryClock());

/// Демонстрационный сервер в памяти. Подключение настоящего сервера заменяет провайдеры репозиториев ниже
/// и [changeFeedProvider], после чего этот провайдер и папка data/mock больше не нужны.
final Provider<MockBackend> mockBackendProvider = Provider<MockBackend>((Ref ref) {
  final MockBackend backend = MockBackend(clock: ref.watch(clockProvider));
  ref.onDispose(backend.dispose);
  return backend;
});

/// Поток изменений данных.
final Provider<KvChangeFeed> changeFeedProvider = Provider<KvChangeFeed>((Ref ref) {
  final KvChangeFeed mock = ref.watch(mockBackendProvider);
  return ref.watch(apiConfigProvider.select((ApiConfig c) => c.demo)) ? mock : MergedFeed(mock, ref.watch(apiFeedProvider));
});

/// Клиент цехового сервера по адресу из настроек подключения.
final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((Ref ref) {
  final ApiClient client = ApiClient(ref.watch(apiConfigProvider.select((ApiConfig c) => c.baseUrl)));
  final BioVault vault = ref.watch(bioVaultProvider);
  client.onRefreshToken = vault.rotate;
  ref.onDispose(client.close);
  return client;
});

/// Изменения данных на настоящем сервере, о которых сообщают репозитории после своих запросов.
final Provider<ApiFeed> apiFeedProvider = Provider<ApiFeed>((Ref ref) {
  final ApiFeed feed = ApiFeed();
  ref.onDispose(feed.dispose);
  return feed;
});

/// Работа с настоящим цеховым сервером (не демонстрационный режим).
final Provider<bool> serverModeProvider = Provider<bool>((Ref ref) => !ref.watch(apiConfigProvider.select((ApiConfig c) => c.demo)));

/// Вход и сеанс.
final Provider<AuthRepository> authRepositoryProvider = Provider<AuthRepository>((Ref ref) {
  final MockAuthRepository mock = MockAuthRepository(ref.watch(mockBackendProvider));
  return ref.watch(serverModeProvider) ? ApiAuthRepository(ref.watch(apiClientProvider), mock, ref.watch(apiFeedProvider), ref.watch(bioVaultProvider)) : mock;
});

/// Площадка и сотрудники.
final Provider<SiteRepository> siteRepositoryProvider = Provider<SiteRepository>((Ref ref) {
  final MockSiteRepository mock = MockSiteRepository(ref.watch(mockBackendProvider));
  return ref.watch(serverModeProvider) ? ApiSiteRepository(ref.watch(apiClientProvider), mock) : mock;
});

/// Оборудование.
final Provider<EquipmentRepository> equipmentRepositoryProvider =
    Provider<EquipmentRepository>((Ref ref) {
  final MockEquipmentRepository mock = MockEquipmentRepository(ref.watch(mockBackendProvider));
  return ref.watch(serverModeProvider) ? ApiEquipmentRepository(ref.watch(apiClientProvider), mock, ref.watch(apiFeedProvider)) : mock;
});

/// Телеметрия.
final Provider<TelemetryRepository> telemetryRepositoryProvider =
    Provider<TelemetryRepository>((Ref ref) {
  final MockTelemetryRepository mock = MockTelemetryRepository(ref.watch(mockBackendProvider));
  return ref.watch(serverModeProvider) ? ApiTelemetryRepository(ref.watch(apiClientProvider), mock) : mock;
});

/// Диагностика, осмотры и находки.
final Provider<InspectionRepository> inspectionRepositoryProvider =
    Provider<InspectionRepository>((Ref ref) {
  final MockInspectionRepository mock = MockInspectionRepository(ref.watch(mockBackendProvider));
  return ref.watch(serverModeProvider) ? ApiInspectionRepository(ref.watch(apiClientProvider), mock, ref.watch(apiFeedProvider)) : mock;
});

/// Задания, сообщения, уведомления, план ТО.
final Provider<WorkflowRepository> workflowRepositoryProvider =
    Provider<WorkflowRepository>((Ref ref) {
  final MockWorkflowRepository mock = MockWorkflowRepository(ref.watch(mockBackendProvider));
  return ref.watch(serverModeProvider) ? ApiWorkflowRepository(ref.watch(apiClientProvider), mock) : mock;
});

/// Отчёты.
final Provider<ReportRepository> reportRepositoryProvider = Provider<ReportRepository>((Ref ref) {
  final MockReportRepository mock = MockReportRepository(ref.watch(mockBackendProvider));
  return ref.watch(serverModeProvider) ? ApiReportRepository(ref.watch(apiClientProvider), mock, ref.watch(apiFeedProvider)) : mock;
});

/// Ассистент.
final Provider<AssistantRepository> assistantRepositoryProvider =
    Provider<AssistantRepository>((Ref ref) {
  final MockAssistantRepository mock = MockAssistantRepository(ref.watch(mockBackendProvider));
  return ref.watch(serverModeProvider) ? ApiAssistantRepository(ref.watch(apiClientProvider), mock, ref.watch(apiFeedProvider)) : mock;
});

/// Администрирование системы.
final Provider<AdminRepository> adminRepositoryProvider = Provider<AdminRepository>((Ref ref) => MockAdminRepository(ref.watch(mockBackendProvider)));

/// Безопасность.
final Provider<SecurityRepository> securityRepositoryProvider =
    Provider<SecurityRepository>((Ref ref) => MockSecurityRepository(ref.watch(mockBackendProvider)));

/// Номер версии раздела данных: растёт при каждом изменении. Провайдеры данных следят за ним и перечитываются.
final revisionProvider = StreamProvider.family<int, KvDomain>((Ref ref, KvDomain domain) {
  int n = 0;
  return ref.watch(changeFeedProvider).changes.where((KvDomain d) => d == domain).map((KvDomain _) => ++n);
});

/// Площадка и смена.
final FutureProvider<Site> siteProvider = FutureProvider<Site>((Ref ref) => ref.watch(siteRepositoryProvider).site());

/// Сотрудники по ключу роли дизайна.
final FutureProvider<Map<String, Person>> peopleProvider = FutureProvider<Map<String, Person>>((Ref ref) => ref.watch(siteRepositoryProvider).people());

/// Инженеры смены.
final FutureProvider<List<Person>> engineersProvider = FutureProvider<List<Person>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(siteRepositoryProvider).engineers();
});

/// Все агрегаты.
final FutureProvider<List<Equipment>> unitsProvider = FutureProvider<List<Equipment>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.equipment));
  return ref.watch(equipmentRepositoryProvider).units();
});

/// Опрос цехового сервера, пока список агрегатов на экране: раз в 5 секунд перечитывает агрегаты, чтобы
/// сценарии телеметрии и решения других сотрудников были видны без ручного обновления. В демонстрационном режиме выключен.
final Provider<void> liveUnitsPollProvider = Provider.autoDispose<void>((Ref ref) {
  if (ref.watch(apiConfigProvider).demo) {
    return;
  }
  final Timer timer = Timer.periodic(const Duration(seconds: 5), (_) => ref.invalidate(unitsProvider));
  ref.onDispose(timer.cancel);
});

/// Агрегат по идентификатору.
final unitProvider = FutureProvider.autoDispose.family<Equipment, String>((Ref ref, String id) {
  ref.watch(revisionProvider(KvDomain.equipment));
  return ref.watch(equipmentRepositoryProvider).unit(id);
});

/// История агрегата.
final unitHistoryProvider =
    FutureProvider.autoDispose.family<List<HistoryEvent>, String>((Ref ref, String id) {
  ref.watch(revisionProvider(KvDomain.equipment));
  return ref.watch(equipmentRepositoryProvider).history(id);
});

/// Живые показания агрегата.
final readingsProvider =
    StreamProvider.autoDispose.family<Map<String, Reading>, String>((Ref ref, String id) => ref.watch(telemetryRepositoryProvider).watchReadings(id));

/// Ряд показания за период.
final seriesProvider =
    FutureProvider.autoDispose.family<TelemetrySeries, ({String unitId, String key, TelemetryPeriod period})>(
  (Ref ref, ({String unitId, String key, TelemetryPeriod period}) a) {
    ref.watch(revisionProvider(KvDomain.telemetry));
    return ref.watch(telemetryRepositoryProvider).series(a.unitId, a.key, a.period);
  },
);

/// Все правила диагностики.
final FutureProvider<List<RuleDef>> rulesProvider = FutureProvider<List<RuleDef>>((Ref ref) => ref.watch(inspectionRepositoryProvider).rules());

/// Результаты правил по агрегату.
final diagnosisProvider =
    FutureProvider.autoDispose.family<List<DiagnosisResult>, String>((Ref ref, String unitId) {
  ref.watch(revisionProvider(KvDomain.inspections));
  return ref.watch(inspectionRepositoryProvider).diagnosis(unitId);
});

/// Осмотры; аргумент - агрегат или null для всех.
final inspectionsProvider =
    FutureProvider.autoDispose.family<List<Inspection>, String?>((Ref ref, String? unitId) {
  ref.watch(revisionProvider(KvDomain.inspections));
  return ref.watch(inspectionRepositoryProvider).inspections(unitId: unitId);
});

/// Находки с отбором по статусу и агрегату.
final findingsProvider =
    FutureProvider.autoDispose.family<List<Finding>, ({String? status, String? unitId})>((Ref ref, ({String? status, String? unitId}) a) {
  ref.watch(revisionProvider(KvDomain.findings));
  return ref.watch(inspectionRepositoryProvider).findings(status: a.status, unitId: a.unitId);
});

/// Находка по номеру.
final findingProvider = FutureProvider.autoDispose.family<Finding, String>((Ref ref, String id) {
  ref.watch(revisionProvider(KvDomain.findings));
  return ref.watch(inspectionRepositoryProvider).finding(id);
});

/// Задания; аргумент - исполнитель или null для всех.
final tasksProvider =
    FutureProvider.autoDispose.family<List<InspectionTask>, String?>((Ref ref, String? assignee) {
  ref.watch(revisionProvider(KvDomain.workflow));
  return ref.watch(workflowRepositoryProvider).tasks(assignee: assignee);
});

/// Сообщения о неисправностях; аргумент - автор или null для всех.
final faultReportsProvider =
    FutureProvider.autoDispose.family<List<FaultReport>, String?>((Ref ref, String? author) {
  ref.watch(revisionProvider(KvDomain.workflow));
  return ref.watch(workflowRepositoryProvider).faultReports(author: author);
});

/// Лента уведомлений роли (engineer, master, operator, admin, sec).
final notificationsProvider =
    FutureProvider.autoDispose.family<List<AppNotification>, String>((Ref ref, String roleKey) {
  ref.watch(revisionProvider(KvDomain.notifications));
  return ref.watch(workflowRepositoryProvider).notifications(roleKey);
});

/// План ТО.
final FutureProvider<List<PlanItem>> planProvider = FutureProvider<List<PlanItem>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.plan));
  return ref.watch(workflowRepositoryProvider).plan();
});

/// Отчёты.
final FutureProvider<List<Report>> reportsProvider = FutureProvider<List<Report>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.reports));
  return ref.watch(reportRepositoryProvider).reports();
});

/// Диалог с ассистентом.
final FutureProvider<List<AssistantMessage>> assistantDialogProvider = FutureProvider<List<AssistantMessage>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.assistant));
  return ref.watch(assistantRepositoryProvider).dialog();
});

/// Подсказки ассистента.
final FutureProvider<List<String>> assistantSuggestionsProvider =
    FutureProvider<List<String>>((Ref ref) => ref.watch(assistantRepositoryProvider).suggestions());

/// Цеховой сервер.
final FutureProvider<ServerStatus> serverStatusProvider = FutureProvider<ServerStatus>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.admin));
  return ref.watch(adminRepositoryProvider).server();
});

/// Источники данных.
final FutureProvider<List<DataSource>> sourcesProvider = FutureProvider<List<DataSource>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.admin));
  return ref.watch(adminRepositoryProvider).sources();
});

/// Привязки тегов; аргумент - агрегат или null.
final tagsProvider = FutureProvider.autoDispose.family<List<TagBinding>, String?>((Ref ref, String? unitId) {
  ref.watch(revisionProvider(KvDomain.admin));
  return ref.watch(adminRepositoryProvider).tags(unitId: unitId);
});

/// Модели распознавания.
final FutureProvider<List<RecognitionModel>> modelsProvider = FutureProvider<List<RecognitionModel>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.admin));
  return ref.watch(adminRepositoryProvider).models();
});

/// Системный журнал.
final FutureProvider<List<SysLogEntry>> syslogProvider = FutureProvider<List<SysLogEntry>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.admin));
  return ref.watch(adminRepositoryProvider).syslog();
});

/// Резервные копии.
final FutureProvider<List<Backup>> backupsProvider = FutureProvider<List<Backup>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.admin));
  return ref.watch(adminRepositoryProvider).backups();
});

/// Устройства сотрудников.
final FutureProvider<List<Device>> devicesProvider = FutureProvider<List<Device>>((Ref ref) => ref.watch(adminRepositoryProvider).devices());

/// Учётные записи.
final FutureProvider<List<AdminUser>> adminUsersProvider = FutureProvider<List<AdminUser>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(securityRepositoryProvider).users();
});

/// Учётная запись по номеру.
final adminUserProvider = FutureProvider.autoDispose.family<AdminUser, String>((Ref ref, String id) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(securityRepositoryProvider).user(id);
});

/// Открытые сеансы; аргумент - сотрудник или null.
final sessionsProvider =
    FutureProvider.autoDispose.family<List<UserSession>, String?>((Ref ref, String? userId) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(securityRepositoryProvider).sessions(userId: userId);
});

/// Перечень прав.
final FutureProvider<List<Permission>> permissionsProvider = FutureProvider<List<Permission>>((Ref ref) => ref.watch(securityRepositoryProvider).permissions());

/// Роли.
final FutureProvider<List<Role>> rolesProvider = FutureProvider<List<Role>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(securityRepositoryProvider).roles();
});

/// Политика безопасности.
final FutureProvider<SecurityPolicy> policyProvider = FutureProvider<SecurityPolicy>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(securityRepositoryProvider).policy();
});

/// Журнал безопасности.
final FutureProvider<List<SecLogEntry>> securityLogProvider = FutureProvider<List<SecLogEntry>>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(securityRepositoryProvider).securityLog();
});
