import 'package:flutter/material.dart';

import '../../../core/kv.dart';

/// Тонированная карточка-действие (.card.tinted с .hstack): значок на фоне карточки, заголовок, пояснение и шеврон.
class TintedAction extends StatelessWidget {
  /// Создаёт карточку.
  const TintedAction({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap});

  /// Значок 22.
  final KvIcons icon;

  /// Заголовок 15.
  final String title;

  /// Пояснение 13.
  final String subtitle;

  /// Касание.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return KvCard(
      style: KvCardStyle.tinted,
      onTap: onTap,
      semanticLabel: title,
      child: Row(
        children: [
          KvRowIcon(icon: icon, background: c.tint2),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: t.bodyM),
                Text(subtitle, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
              ],
            ),
          ),
          const SizedBox(width: KvSpace.s3),
          KvIcon(KvIcons.chevronRight, size: 20, color: c.text),
        ],
      ),
    );
  }
}
