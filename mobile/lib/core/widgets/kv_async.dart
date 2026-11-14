import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../icons/kv_icon.dart';
import 'kv_button.dart';
import 'kv_misc.dart';

/// Показ асинхронных данных: пока данных нет - [loading] (по умолчанию заглушки), при ошибке - пустое состояние
/// с повтором, при обновлении остаются прежние данные без мигания.
class KvAsync<T> extends StatelessWidget {
  /// Создаёт показ значения [value].
  const KvAsync({super.key, required this.value, required this.builder, this.loading, this.onRetry});

  /// Значение провайдера.
  final AsyncValue<T> value;

  /// Построение по данным.
  final Widget Function(BuildContext context, T data) builder;

  /// Что показывать до первых данных.
  final Widget? loading;

  /// Повтор после ошибки (обычно ref.invalidate).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (value.hasValue) {
      return builder(context, value.requireValue);
    }
    if (value.hasError) {
      return KvEmpty(
        icon: KvIcons.wifiOff,
        title: 'Не удалось загрузить',
        text: 'Проверьте подключение к цеховому серверу и повторите.',
        action: onRetry == null ? null : KvButton('Повторить', small: true, kind: KvButtonKind.secondary, onPressed: onRetry),
      );
    }
    return loading ?? const Column(mainAxisSize: MainAxisSize.min, children: [KvSkeleton.card(), SizedBox(height: 12), KvSkeleton.card()]);
  }
}
