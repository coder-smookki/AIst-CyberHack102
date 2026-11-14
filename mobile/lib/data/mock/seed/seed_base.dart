import '../../models/admin.dart';
import '../mock_db.dart';

/// Демонстрационные учётные записи и открытые сеансы поверх истории.
///
/// Пароль всех записей - demo12345. Почты сервера: engineer@kst.demo (Алексей Смирнов, инженер),
/// master@kst.demo (Марина Орлова, мастер), operator@kst.demo (Ольга Кузнецова, оператор),
/// admin@kst.demo (Игорь Власов, администратор системы), security@kst.demo (Дмитрий Захаров, администратор ИБ).
/// Почты сотрудников из истории (a.smirnov@kst-energo.ru и другие) тоже входят с паролем demo12345.
/// Особые состояния входа: blocked@kst.demo и v.panov@kst-energo.ru - заблокированная запись (экран «Учётная запись
/// заблокирована»); newbie@kst.demo и p.ershov@kst-energo.ru (также временный пароль Kv7-pT92-xR) - первый вход
/// с временным паролем и обязательной сменой; offline@kst.demo - цеховой сервер недоступен; неверный пароль -
/// уведомление «Не удалось войти» с числом оставшихся попыток, после пяти попыток вход закрывается на 30 минут.
void seedBase(MockDb db) {
  const String password = 'demo12345';
  for (final AdminUser u in db.users) {
    db.accounts.add(MockAccount(email: u.email, password: u.tempPassword ?? password, userId: u.id));
  }
  db.accounts.addAll([
    MockAccount(email: 'engineer@kst.demo', password: password, userId: 'u-101'),
    MockAccount(email: 'master@kst.demo', password: password, userId: 'u-102'),
    MockAccount(email: 'operator@kst.demo', password: password, userId: 'u-103'),
    MockAccount(email: 'admin@kst.demo', password: password, userId: 'u-104'),
    MockAccount(email: 'security@kst.demo', password: password, userId: 'u-105'),
    MockAccount(email: 'blocked@kst.demo', password: password, userId: 'u-111'),
    MockAccount(email: 'newbie@kst.demo', password: password, userId: 'u-110'),
    MockAccount(email: 'p.ershov@kst-energo.ru', password: password, userId: 'u-110'),
    MockAccount(email: 'offline@kst.demo', password: password, userId: 'u-101', offline: true),
  ]);
  db.sessions.addAll(const [
    UserSession(id: 'KV-T14', userId: 'u-101', device: 'KV-T14 · Galaxy Tab Active5', since: '14.11 08:02'),
    UserSession(id: 'KV-P03', userId: 'u-102', device: 'KV-P03 · Pixel 8', since: '14.11 07:55'),
    UserSession(id: 'KV-T02', userId: 'u-103', device: 'KV-T02 · Galaxy XCover7', since: '14.11 06:31'),
    UserSession(id: 'KV-P01', userId: 'u-105', device: 'KV-P01 · iPhone 15', since: '14.11 09:10'),
    UserSession(id: 'KV-T07', userId: 'u-109', device: 'KV-T07 · Galaxy Tab Active5', since: '14.11 08:15'),
  ]);
  db.counters.addAll({'F-': 1043, 'INS-': 2209, 'T-': 319, 'S-0': 77, 'P-': 505, 'u-': 111, 'R-': 0, 'n-': 0});
}
