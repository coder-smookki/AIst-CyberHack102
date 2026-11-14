import '../models/workflow.dart';

/// Ассистент на цеховом сервере (POST /assistant/ask).
abstract interface class AssistantRepository {
  /// Подсказки вопросов.
  Future<List<String>> suggestions();

  /// Диалог текущей сессии.
  Future<List<AssistantMessage>> dialog();

  /// Задать вопрос; ответ добавляется в диалог.
  Future<AssistantMessage> ask(String question, {String? unitId});
}
