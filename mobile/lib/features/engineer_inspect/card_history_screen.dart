import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/navigation/kv_page.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../app/routes/engineer_service_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'card_now_screen.dart';

/// Названия месяцев для подписи «ноябрь 302 ч».
const List<String> _months = [
  'январь',
  'февраль',
  'март',
  'апрель',
  'май',
  'июнь',
  'июль',
  'август',
  'сентябрь',
  'октябрь',
  'ноябрь',
  'декабрь',
];

/// Полная история агрегата в разделе «История» инженера.
String _fullHistoryPath(String unitId) => switch (unitId) {
      'AMS-1' => EngineerServicePaths.cHistoryAms1,
      'AMS-2' => EngineerServicePaths.cHistoryAms2,
      _ => EngineerServicePaths.cHistoryN101,
    };

/// Карточка агрегата, вкладка «История» (card-history): наработка по месяцам столбиками и пять последних событий
/// со ссылкой на всю историю.
class CardHistoryScreen extends ConsumerWidget {
  /// Создаёт вкладку для агрегата [unitId].
  const CardHistoryScreen({super.key, required this.unitId, this.fromSegment});

  /// Агрегат.
  final String unitId;

  /// Пункт сегмента предыдущего экрана карточки.
  final int? fromSegment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvTextStyles t = context.kvText;
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    final List<HistoryEvent>? history = ref.watch(unitHistoryProvider(unitId)).value;
    final DateTime now = ref.watch(clockProvider).now();
    final bool segSwap = KvNavExtra.of(GoRouterState.of(context))?.transition == KvTransition.seg;
    final MonthRun? current = unit?.runByMonth.where((MonthRun m) => m.highlight).firstOrNull ?? unit?.runByMonth.lastOrNull;
    return KvScreen(
      header: unit == null ? KvHeader(title: unitId, onBack: () => context.kvBack(EngineerInspectPaths.objects)) : CardHeader(unit: unit),
      stagger: segSwap ? KvStagger.seg : KvStagger.appear,
      staggerSkip: segSwap ? 1 : 0,
      children: [
        CardTabs(unitId: unitId, index: 2, fromSegment: fromSegment),
        if (unit == null)
          const KvSkeleton.card(height: 236)
        else
          KvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Наработка по месяцам · моточасы', style: t.label),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(KvFormat.num(unit.runHours), style: t.numXl),
                    const SizedBox(width: KvSpace.s2),
                    Flexible(
                      child: Text(
                        KvFormat.typo('ч всего${current == null ? '' : ' · ${_months[now.month - 1]} ${KvFormat.num(current.value)} ч'}'),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: t.caption,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                KvBars(items: [for (final MonthRun m in unit.runByMonth) (label: m.label, value: m.value, highlight: m.highlight)], height: 130),
              ],
            ),
          ),
        KvCard(
          title: 'События',
          trailing: KvLink('Вся история', onPressed: () => context.kvPush(_fullHistoryPath(unitId))),
          child: history == null
              ? const KvSkeleton(height: 180)
              : KvTimeline(
                  items: [
                    for (final HistoryEvent e in history.take(5))
                      KvTimelineItem(
                        time: '${e.date} · ${e.time}',
                        title: e.title,
                        text: KvFormat.typo([e.text, e.who].where((String s) => s.isNotEmpty).join(' · ')),
                        status: KvStatus.parse(e.status),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
