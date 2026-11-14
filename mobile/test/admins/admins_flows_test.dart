import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/format/kv_format.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/mock_db.dart';
import 'package:kst_vizor/data/models/admin.dart';

import '../design/design_case.dart';
import 'admins_app.dart';

/// Своя роль «Старший инженер» уже создана.
void _senior(MockBackend b) => b.db.roles.add(b.db.seniorRoleTemplate!);

AdminUser _user(AdminsApp app, String id) => app.backend.db.users.firstWhere((AdminUser u) => u.id == id);

void main() {
  group('Админ ИБ', () {
    testWidgets('блокировка с причиной закрывает сеансы и меняет карточку', (WidgetTester tester) async {
      final AdminsApp app = await pumpAdminsApp(tester, '/sec/e-user/u-109');
      expect(find.text('Активна · Инженер'), findsOneWidget);
      await tapText(tester, 'Заблокировать учётную запись');
      expect(find.text('Заблокировать учётную запись?'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey<String>('block-reason')), 'Перевод в другое подразделение');
      await tapText(tester, 'Заблокировать', wait: const Duration(milliseconds: 1500));
      expect(find.text('Заблокирована · Инженер'), findsOneWidget);
      expect(find.textContaining('Перевод в другое подразделение'), findsOneWidget);
      expect(find.text('Разблокировать'), findsOneWidget);
      expect(_user(app, 'u-109').status, 'blocked');
      expect(app.backend.db.sessions.where((UserSession s) => s.userId == 'u-109'), isEmpty);
      expect(app.backend.db.seclog.first.text, startsWith('Заблокирована учётная запись s.belov'));
      await tapText(tester, 'Разблокировать');
      await tapText(tester, 'Разблокировать', index: 1, wait: const Duration(milliseconds: 1500));
      expect(find.text('Активна · Инженер'), findsOneWidget);
    });

    testWidgets('сброс пароля показывает временный пароль один раз', (WidgetTester tester) async {
      final AdminsApp app = await pumpAdminsApp(tester, '/sec/e-user/u-101');
      await tapText(tester, 'Пароль');
      expect(find.text('Сбросить пароль?'), findsOneWidget);
      await tapText(tester, 'Сбросить', wait: const Duration(milliseconds: 1500));
      final AdminUser u = _user(app, 'u-101');
      expect(u.status, 'temp');
      expect(find.text('Временный пароль'), findsWidgets);
      expect(find.text(u.tempPassword!), findsOneWidget);
      await tapLabel(tester, 'Копировать');
      expect(find.text('Пароль скопирован'), findsOneWidget);
      await settleToasts(tester);
    });

    testWidgets('новый пользователь: временный пароль и переход в карточку', (WidgetTester tester) async {
      final AdminsApp app = await pumpAdminsApp(tester, '/sec/e-user-new');
      await tester.enterText(find.byKey(const ValueKey<String>('user-name')), 'Олег Сидоров');
      await tester.enterText(find.byKey(const ValueKey<String>('user-email')), 'o.sidorov@kst-energo.ru');
      await tapText(tester, 'Создать учётную запись', wait: const Duration(milliseconds: 2400));
      expect(find.text('Учётная запись создана'), findsOneWidget);
      final AdminUser created = app.backend.db.users.last;
      expect(created.email, 'o.sidorov@kst-energo.ru');
      expect(find.text(created.tempPassword!), findsOneWidget);
      expect(app.backend.db.accounts.any((MockAccount a) => a.email == 'o.sidorov@kst-energo.ru'), isTrue);
      await tapText(tester, 'Открыть карточку', wait: const Duration(milliseconds: 1200));
      expect(app.path, '/sec/e-user/${created.id}');
      expect(find.text('Временный пароль · Инженер'), findsOneWidget);
    });

    testWidgets('назначение своей роли показывает плашку на карточке', (WidgetTester tester) async {
      final AdminsApp app = await pumpAdminsApp(tester, '/sec/e-user/u-106', setup: _senior);
      await tapText(tester, 'Инженер');
      expect(find.text('Роль сотрудника'), findsOneWidget);
      await tapText(tester, 'Старший инженер');
      await tapText(tester, 'Назначить роль', wait: const Duration(milliseconds: 1800));
      expect(_user(app, 'u-106').roleCode, 'senior');
      expect(find.textContaining('Роль «Старший инженер» назначена'), findsOneWidget);
      expect(find.text('Активна · Старший инженер'), findsOneWidget);
    });

    testWidgets('политика: блокировка входа сохраняется и видна в списке', (WidgetTester tester) async {
      final AdminsApp app = await pumpAdminsApp(tester, '/sec/policy');
      expect(find.text(KvFormat.typo('После 10 ошибок за 5 мин')), findsOneWidget);
      await tapText(tester, 'Блокировка входа');
      await tapText(tester, '20');
      await tapText(tester, 'Сохранить', wait: const Duration(milliseconds: 1500));
      expect(app.backend.db.policy!.lockAfter, 20);
      expect(find.text('Политика сохранена'), findsOneWidget);
      expect(find.text(KvFormat.typo('После 20 ошибок за 5 мин')), findsOneWidget);
      await settleToasts(tester);
    });

    testWidgets('завершение всех чужих сеансов оставляет только свой', (WidgetTester tester) async {
      final AdminsApp app = await pumpAdminsApp(tester, '/sec/e-sec-sessions');
      expect(find.text('5 устройств в сети'), findsOneWidget);
      await tapText(tester, 'Завершить все, кроме моего');
      expect(find.text('Завершить 4 сеанса?'), findsOneWidget);
      await tapText(tester, 'Завершить', index: 4, wait: const Duration(milliseconds: 1500));
      expect(find.text('Сеанс завершён'), findsOneWidget);
      expect(find.text('1 устройство в сети'), findsOneWidget);
      expect(find.text('Вы'), findsOneWidget);
      expect(app.backend.db.sessions.length, 1);
      await settleToasts(tester);
    });

    testWidgets('поиск подсвечивает совпадение и открывает карточку', (WidgetTester tester) async {
      await pumpAdminsApp(tester, '/sec/e-user-search');
      await tester.enterText(find.byKey(const ValueKey<String>('user-search')), 'ер');
      await pumpFor(tester, const Duration(milliseconds: 300));
      expect(find.text('Найдено 2'), findsOneWidget);
      await tapText(tester, 'Инженер · p.ershov@kst-energo.ru', wait: const Duration(milliseconds: 1000));
      expect(find.text('Павел Ершов'), findsOneWidget);
      expect(find.text('Временный пароль · Инженер'), findsOneWidget);
    });

    testWidgets('выход из учётной записи ведёт на вход', (WidgetTester tester) async {
      final AdminsApp app = await pumpAdminsApp(tester, '/sec/profile');
      await tapText(tester, 'Выйти из учётной записи');
      expect(find.text('Выйти из учётной записи?'), findsOneWidget);
      await tapText(tester, 'Выйти', wait: const Duration(milliseconds: 1500));
      expect(app.container.read(sessionProvider), isNull);
      expect(app.path, '/login');
    });
  });

  group('Админ', () {
    testWidgets('карточка сервера на экране «Система» открывает цеховой сервер', (WidgetTester tester) async {
      await pumpAdminsApp(tester, '/admin/system', email: 'admin@kst.demo');
      await tapText(tester, 'Цеховой сервер', wait: const Duration(milliseconds: 1000));
      expect(find.text('Перезапустить службы'), findsOneWidget);
      expect(find.text(KvFormat.typo('Работает · 18 сут 6 ч')), findsOneWidget);
    });

    testWidgets('отключение источника: диалог, уведомление и пункт «Подключить»', (WidgetTester tester) async {
      final AdminsApp app = await pumpAdminsApp(tester, '/admin/e-src/src-vib', email: 'admin@kst.demo');
      await tapLabel(tester, 'Ещё');
      await tapText(tester, 'Отключить источник');
      expect(find.text('Отключить источник?'), findsOneWidget);
      await tapText(tester, 'Отключить', wait: const Duration(milliseconds: 1500));
      expect(find.text('Источник отключён'), findsOneWidget);
      expect(app.backend.db.sources.firstWhere((DataSource s) => s.id == 'src-vib').enabled, isFalse);
      await settleToasts(tester);
      await tapLabel(tester, 'Ещё');
      expect(find.text('Подключить источник'), findsOneWidget);
    });

    testWidgets('активация тестовой модели', (WidgetTester tester) async {
      final AdminsApp app = await pumpAdminsApp(tester, '/admin/e-model/m-det-next', email: 'admin@kst.demo');
      await tapText(tester, 'Активировать версию 3.3');
      expect(find.text('Активировать 3.3?'), findsOneWidget);
      await tapText(tester, 'Активировать', wait: const Duration(milliseconds: 1800));
      expect(find.text('Версия 3.3 активирована'), findsOneWidget);
      expect(app.backend.db.models.firstWhere((RecognitionModel m) => m.id == 'm-det-next').status, 'active');
      await settleToasts(tester);
    });

    testWidgets('лист тега сохраняет привязку', (WidgetTester tester) async {
      await pumpAdminsApp(tester, '/admin/e-tags/N-101', email: 'admin@kst.demo');
      await tapText(tester, 'Вибрация 1X');
      expect(find.text('Шлюз вибродатчиков · Modbus'), findsOneWidget);
      await tapText(tester, 'Сохранить привязку', wait: const Duration(milliseconds: 1500));
      expect(find.text('Привязка сохранена'), findsOneWidget);
      await settleToasts(tester);
    });

    testWidgets('смена агрегата в привязке тегов', (WidgetTester tester) async {
      await pumpAdminsApp(tester, '/admin/e-tags/N-101', email: 'admin@kst.demo');
      await tapText(tester, 'АМС-2', wait: const Duration(milliseconds: 1000));
      expect(find.text(KvFormat.typo('АМС-2 · 7 тегов')), findsOneWidget);
      expect(find.textContaining('остановлен'), findsOneWidget);
    });
  });
}
