/// Вид отказа сервера, общий для демонстрационного и настоящего сервера.
enum KvFailure {
  /// Неверная почта или пароль (401).
  invalidCredentials,

  /// Учётная запись заблокирована (403 при входе).
  blocked,

  /// Вход временно закрыт после неудачных попыток.
  locked,

  /// Нет прав на действие (403).
  forbidden,

  /// Объект не найден (404).
  notFound,

  /// Данные не прошли проверку (422).
  validation,

  /// Цеховой сервер недоступен: нет сети или ответа.
  network,
}

/// Ошибка обращения к серверу с русским текстом для уведомления.
class KvApiException implements Exception {
  /// Создаёт ошибку вида [failure] с сообщением [message].
  const KvApiException(this.failure, this.message, {this.attemptsLeft});

  /// Вид отказа.
  final KvFailure failure;

  /// Текст для сотрудника.
  final String message;

  /// Сколько попыток входа осталось до блокировки.
  final int? attemptsLeft;

  @override
  String toString() => 'KvApiException($failure, $message)';
}
