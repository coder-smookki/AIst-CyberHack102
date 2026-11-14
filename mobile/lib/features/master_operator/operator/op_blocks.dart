import 'package:flutter/material.dart';

import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/bridges.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_common.dart';

/// Ячейка живого показания в карточке агрегата оператора (.d-read > div): точка и подпись, значение с единицей.
class OpReadCell extends StatelessWidget {
  /// Создаёт ячейку показания [reading] с подписью [label] вместо короткой подписи показания.
  const OpReadCell({super.key, required this.reading, this.label});

  /// Показание.
  final Reading reading;

  /// Подпись; null - короткая подпись показания.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool narrow = moNarrow(context);
    final KvStatus st = reading.kvStatus;
    final Color color = switch (st) {
      KvStatus.warn => c.warnText,
      KvStatus.bad => c.bad,
      _ => c.text,
    };
    final double size = narrow ? 15 : 17;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 10, vertical: 8),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              KvDot(status: st, size: 6),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label ?? reading.short,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: t.micro.copyWith(color: c.text2, fontWeight: FontWeight.w400, height: KvTextStyles.normalHeight(11)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: KvFormat.num(reading.value, reading.digits)),
                const WidgetSpan(child: SizedBox(width: 3)),
                TextSpan(
                  text: reading.unit,
                  style: t.micro.copyWith(color: c.text2, fontWeight: FontWeight.w400),
                ),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            style: t.base.copyWith(fontSize: size, fontWeight: FontWeight.w500, height: 1.2, color: color),
          ),
        ],
      ),
    );
  }
}

/// Карточка агрегата на пульте оператора (.card.d-unit): обозначение, статус, модель и три живых показания
/// либо плашка остановки или ремонта.
class OpUnitCard extends StatelessWidget {
  /// Создаёт карточку агрегата [unit].
  const OpUnitCard({super.key, required this.unit, required this.onTap, this.stoppedChip = false, this.note});

  /// Агрегат.
  final Equipment unit;

  /// Касание карточки.
  final VoidCallback onTap;

  /// Чип «Остановлен по S05» вместо статуса (момент 07:30 сценария А).
  final bool stoppedChip;

  /// Плашка вместо показаний: остановка или ремонт.
  final Widget? note;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final Equipment u = unit;
    Reading? r(String key) => u.readings[key];
    final List<(Reading, String?)> cells = [
      if (r('vib1x') != null) (r('vib1x')!, 'Вибрация'),
      if (r('tBearing') != null) (r('tBearing')!, null),
      if (r('pressOut') != null) (r('pressOut')!, null),
    ];
    return KvCard(
      onTap: onTap,
      semanticLabel: u.code,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  u.code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.h2.copyWith(height: KvTextStyles.normalHeight(17)),
                ),
              ),
              const SizedBox(width: KvSpace.s2),
              if (stoppedChip) const KvChip('Остановлен по S05', status: KvStatus.unk) else KvChip(u.statusLabel, status: u.kvStatus),
              const SizedBox(width: KvSpace.s2),
              KvIcon(KvIcons.chevronRight, size: 20, color: c.text3),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            KvFormat.typo('${u.model} · ${u.kindShort}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.caption.copyWith(height: KvTextStyles.normalHeight(13)),
          ),
          const SizedBox(height: 10),
          note ??
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < cells.length; i++) ...[
                    if (i > 0) const SizedBox(width: KvSpace.s2),
                    Expanded(
                      child: OpReadCell(reading: cells[i].$1, label: cells[i].$2),
                    ),
                  ],
                ],
              ),
        ],
      ),
    );
  }
}

/// Карточка сообщения о неисправности в истории оператора (reportCard прототипа): агрегат, статус, текст,
/// полоса этапов с подписью и строка «номер · признак · автор».
class OpReportCard extends StatelessWidget {
  /// Создаёт карточку сообщения [report] агрегата [code] с подписью этапа [stage].
  const OpReportCard({super.key, required this.report, required this.code, required this.stage, required this.onTap});

  /// Сообщение.
  final FaultReport report;

  /// Обозначение агрегата.
  final String code;

  /// Подпись этапа: «Ремонт 15.11, 08:00 · этап 4 из 5».
  final String stage;

  /// Касание карточки.
  final VoidCallback onTap;

  /// Полоса этапов: закрытое - все зелёные, иначе пройденные этапы синие из пяти.
  static List<KvStatus?> steps(FaultReport r) {
    if (r.status == 'closed') {
      return const [KvStatus.ok, KvStatus.ok, KvStatus.ok, KvStatus.ok, KvStatus.ok];
    }
    final int done = r.timeline.isEmpty ? 1 : r.timeline.length.clamp(1, 4);
    return [for (int i = 0; i < 5; i++) i < done ? KvStatus.info : null];
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final FaultReport r = report;
    final bool closed = r.status == 'closed';
    final TextStyle caption = t.caption.copyWith(height: KvTextStyles.normalHeight(13));
    return KvCard(
      onTap: onTap,
      semanticLabel: '${r.id} · $code',
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(code, maxLines: 1, softWrap: false, style: t.h2.copyWith(height: KvTextStyles.normalHeight(17))),
              const SizedBox(width: KvSpace.s2),
              KvChip(r.statusLabel, status: closed ? KvStatus.ok : KvStatus.info),
              const Spacer(),
              const SizedBox(width: KvSpace.s2),
              Text(KvFormat.typo('${moDay(r.date)}, ${r.time}'), maxLines: 1, softWrap: false, style: caption),
            ],
          ),
          const SizedBox(height: KvSpace.s2),
          Text(KvFormat.typo(r.text), style: t.bodyM),
          const SizedBox(height: KvSpace.s2),
          MoStatusBar(steps(r)),
          const SizedBox(height: 6),
          Text(KvFormat.typo(stage), style: caption),
          const SizedBox(height: KvSpace.s2),
          Container(
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.divider)),
            ),
            child: Row(
              children: [
                KvIcon(KvIcons.megaphone, size: 18, color: c.brand),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(KvFormat.typo('${r.id} · ${r.kind}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: caption),
                ),
                const SizedBox(width: 10),
                KvAvatar(r.author, size: KvAvatarSize.small),
                const SizedBox(width: KvSpace.s2),
                Text(moSurname(r.author), maxLines: 1, softWrap: false, style: caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Стеклянная таблетка поверх видео (.ar-pill): высота 44, значок и текст белым.
class OpGlassPill extends StatelessWidget {
  /// Создаёт таблетку с текстом [text] и значком [icon].
  const OpGlassPill({super.key, required this.text, this.icon});

  /// Текст.
  final String text;

  /// Значок слева.
  final KvIcons? icon;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return KvGlass(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: c.arGlass, borderRadius: BorderRadius.circular(22)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[KvIcon(icon!, size: 18, color: c.arText), const SizedBox(width: KvSpace.s2)],
            Flexible(
              child: Text(
                KvFormat.typo(text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.kvText.sm.copyWith(fontWeight: FontWeight.w500, color: c.arText, height: 1.2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
