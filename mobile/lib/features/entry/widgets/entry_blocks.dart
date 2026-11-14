import 'package:flutter/widgets.dart';

import '../../../core/kv.dart';
import 'entry_motion.dart';

/// Ширина, до которой экраны раздела уменьшают крупный текст (@container max-width 370px прототипа).
bool entryNarrow(BuildContext context) => MediaQuery.sizeOf(context).width <= 370;

/// Тон круга [EntryStateHero].
enum EntryHeroTone {
  /// Красный замок: доступ закрыт.
  bad,

  /// Зелёная галочка в мягком кольце: готово.
  ok,

  /// Синий: сведения.
  info,
}

/// Центрированное состояние (.st-hero): круглый значок 84 с ореолом, заголовок и пояснение.
///
/// Используется экранами «Учётная запись заблокирована» и «Пароль сохранён». Значок всплывает при появлении.
class EntryStateHero extends StatelessWidget {
  /// Создаёт состояние со значком [icon], заголовком [title] и пояснением [text] (можно с выделением).
  const EntryStateHero({super.key, required this.icon, required this.title, required this.text, this.tone = EntryHeroTone.bad});

  /// Значок в круге.
  final KvIcons icon;

  /// Тон круга.
  final EntryHeroTone tone;

  /// Заголовок.
  final String title;

  /// Пояснение: обычный текст 15 второстепенного цвета; выделенные части - [TextSpan] с весом 500 и основным цветом.
  final InlineSpan text;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool narrow = entryNarrow(context);
    final (Color bg, Color fg, Color halo, double haloOpacity, double haloSpread) = switch (tone) {
      EntryHeroTone.bad => (c.badBg, c.bad, c.badBg, 0.55, 10.0),
      EntryHeroTone.ok => (c.ok, c.onBrand, c.okBg, 1.0, 12.0),
      EntryHeroTone.info => (c.tint2, c.brand, c.tint2, 0.55, 10.0),
    };
    final Widget circle = SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            left: -haloSpread,
            top: -haloSpread,
            right: -haloSpread,
            bottom: -haloSpread,
            child: Opacity(
              opacity: haloOpacity,
              child: DecoratedBox(
                decoration: BoxDecoration(color: halo, shape: BoxShape.circle),
              ),
            ),
          ),
          Container(
            width: 84,
            height: 84,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: KvIcon(icon, size: 38, color: fg),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.s3, KvSpace.s4, KvSpace.s3, KvSpace.s3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          EntryPopIn(child: circle),
          const SizedBox(height: KvSpace.s4 + KvSpace.s2),
          Text(
            title,
            textAlign: TextAlign.center,
            style: t.title.copyWith(fontSize: narrow ? 20 : 22, height: 1.25),
          ),
          const SizedBox(height: KvSpace.s2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 330),
            child: Text.rich(
              text,
              textAlign: TextAlign.center,
              style: t.body.copyWith(fontSize: narrow ? 14 : 15, color: c.text2, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// Выделенная часть пояснения [EntryStateHero] (.st-text b): основной цвет, вес 500.
TextSpan entryStrong(BuildContext context, String text) => TextSpan(
  text: text,
  style: TextStyle(color: context.kv.text, fontWeight: FontWeight.w500),
);

/// Карточка строк «ключ - значение» с полями 4 × 16 (card + kvs прототипа); [outline] - с рамкой без тени.
class EntryKeyValueCard extends StatelessWidget {
  /// Создаёт карточку из пар [pairs].
  const EntryKeyValueCard(this.pairs, {super.key, this.outline = false});

  /// Пары ключ - значение.
  final List<(String, String)> pairs;

  /// Вид с рамкой (в листе снизу).
  final bool outline;

  @override
  Widget build(BuildContext context) {
    return KvCard(
      style: outline ? KvCardStyle.outline : KvCardStyle.normal,
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s4, vertical: KvSpace.s1),
      child: KvKeyValues(pairs),
    );
  }
}
