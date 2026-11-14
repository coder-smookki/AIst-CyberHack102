import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_common.dart';
import 'master_finding_sheets.dart';

/// Источник признака: камера, сообщение оператора или датчики (srcOf прототипа).
String moEvidenceSource(String text) => text.startsWith('Камера')
    ? 'camera'
    : text.contains('оператора')
        ? 'user'
        : 'sensor';

/// Карточка находки в списке (.card.d-find): тяжесть и правило, время, заголовок, агрегат и узел,
/// источники и автор.
class MoFindingCard extends StatelessWidget {
  /// Создаёт карточку находки [finding] агрегата [code].
  const MoFindingCard({super.key, required this.finding, required this.code, required this.onTap});

  /// Находка.
  final Finding finding;

  /// Обозначение агрегата.
  final String code;

  /// Касание карточки.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final Finding f = finding;
    final (String, KvStatus) sev = moSeverity(f.severity);
    final List<String> src = [for (final String e in f.evidence) moEvidenceSource(e)];
    final int cams = src.where((String s) => s == 'camera').length;
    final int sens = src.where((String s) => s == 'sensor').length;
    final String srcText = '${cams > 0 ? 'Камера' : ''}${cams > 0 && sens > 0 ? ' + ' : ''}${sens > 0 ? '$sens ${sens == 1 ? 'датчик' : 'датчика'}' : ''}';
    final bool system = f.author == 'Система';
    return KvCard(
      onTap: onTap,
      semanticLabel: f.title,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              KvChip(sev.$1, status: sev.$2),
              const SizedBox(width: KvSpace.s2),
              KvChip(f.ruleId, dot: false),
              const Spacer(),
              const SizedBox(width: KvSpace.s2),
              Text(f.time, maxLines: 1, softWrap: false, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
            ],
          ),
          const SizedBox(height: KvSpace.s2),
          Text(f.title, style: t.h2.copyWith(fontSize: moNarrow(context) ? 15 : 17)),
          const SizedBox(height: KvSpace.s2),
          Text(KvFormat.typo('$code · ${f.node} · ${f.id}'), style: t.caption),
          const SizedBox(height: KvSpace.s2),
          Container(
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.divider))),
            child: Row(
              children: [
                KvIcon(cams > 0 ? KvIcons.camera : KvIcons.activity, size: 18, color: c.brand),
                const SizedBox(width: 6),
                Expanded(child: Text(srcText, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13)))),
                const SizedBox(width: 10),
                KvAvatar(system ? 'КВ' : f.author, size: KvAvatarSize.small),
                const SizedBox(width: KvSpace.s2),
                Text(system ? 'Правило' : moSurname(f.author), style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Находки мастера: ждущие подтверждения находки карточками и переход к находкам в работе и закрытым.
class MasterFindingsScreen extends ConsumerWidget {
  /// Создаёт экран.
  const MasterFindingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Finding> all = ref.watch(findingsProvider((status: null, unitId: null))).value ?? const <Finding>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    String code(String id) => units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id;
    final List<Finding> fresh = all.where((Finding f) => f.status == 'new').toList();
    final int work = all.where((Finding f) => f.status == 'planned' || f.status == 'confirmed').length;
    final int closed = all.where((Finding f) => f.status == 'closed' || f.status == 'rejected').length;
    return KvScreen(
      header: KvRootHeader(title: 'Находки', subtitle: '${fresh.length} ${KvFormat.plural(fresh.length, 'ждёт', 'ждут', 'ждут')} подтверждения'),
      children: [
        KvFilterChips(
          items: [KvFilterItem('Ждут', count: '${fresh.length}'), KvFilterItem('В работе', count: '$work'), KvFilterItem('Закрыты', count: '$closed')],
          selected: 0,
          onSelected: (int i) {
            if (i > 0) {
              context.kvFade(MasterOperatorPaths.dMFindingsAll, data: i);
            }
          },
        ),
        if (fresh.isEmpty) const KvEmpty(icon: KvIcons.checkCircle, title: 'Новых находок нет', text: 'Все находки смены рассмотрены.'),
        for (final Finding f in fresh) MoFindingCard(finding: f, code: code(f.unitId), onTap: () => context.kvPush(MasterOperatorPaths.finding(f.id))),
        const KvNote(icon: KvIcons.shieldCheck, text: 'Пропущенный дефект опаснее ложной тревоги. Отклоняйте находку только после проверки.'),
      ],
    );
  }
}

/// Находки в работе и закрытые: строки со статусом решения; «Закрыты» оставляет только закрытые.
class MasterFindingsAllScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const MasterFindingsAllScreen({super.key});

  @override
  ConsumerState<MasterFindingsAllScreen> createState() => _MasterFindingsAllScreenState();
}

class _MasterFindingsAllScreenState extends ConsumerState<MasterFindingsAllScreen> {
  int _filter = 1;

  Widget _row(BuildContext context, Finding f, String code) {
    final KvColors c = context.kv;
    final (String, KvStatus) st = moFindingStatus(f.status);
    final Color tone = switch (st.$2) {
      KvStatus.info => c.brand,
      KvStatus.bad => c.bad,
      KvStatus.ok => c.ok,
      KvStatus.warn => c.warnText,
      KvStatus.unk => c.text2,
    };
    final KvTextStyles t = context.kvText;
    return KvRow(
      icon: switch (f.status) {
        'closed' => KvIcons.checkCircle,
        'planned' => KvIcons.calendar,
        'rejected' => KvIcons.ban,
        _ => KvIcons.alertCircle,
      },
      iconStatus: st.$2 == KvStatus.info ? null : st.$2,
      title: f.title,
      subtitleWidget: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: KvFormat.typo('$code · ${f.ruleId} · ${moDay(f.date)} · ')),
            TextSpan(text: st.$1.replaceAll(' ', KvFormat.nbsp), style: TextStyle(color: tone)),
          ],
        ),
        style: t.caption.copyWith(height: 1.35),
      ),
      onTap: () => context.kvPush(MasterOperatorPaths.finding(f.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Finding> all = ref.watch(findingsProvider((status: null, unitId: null))).value ?? const <Finding>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    String code(String id) => units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id;
    final int fresh = all.where((Finding f) => f.status == 'new').length;
    final List<Finding> work = all.where((Finding f) => f.status == 'planned' || f.status == 'confirmed').toList();
    final List<Finding> closed = all.where((Finding f) => f.status == 'closed' || f.status == 'rejected').toList();
    return KvScreen(
      header: KvRootHeader(title: 'Находки', subtitle: '${all.length} за неделю'),
      children: [
        KvFilterChips(
          items: [KvFilterItem('Ждут', count: '$fresh'), KvFilterItem('В работе', count: '${work.length}'), KvFilterItem('Закрыты', count: '${closed.length}')],
          selected: _filter,
          onSelected: (int i) {
            if (i == 0) {
              context.kvFade(MasterOperatorPaths.masterFindings);
            } else {
              setState(() => _filter = i);
            }
          },
        ),
        if (_filter == 1 && work.isNotEmpty) ...[
          const MoLabel('В работе'),
          KvList(children: [for (final Finding f in work) _row(context, f, code(f.unitId))]),
        ],
        if (closed.isNotEmpty) ...[
          const MoLabel('Закрыты'),
          KvList(children: [for (final Finding f in closed) _row(context, f, code(f.unitId))]),
        ],
      ],
    );
  }
}
