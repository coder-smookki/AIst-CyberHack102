import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../service_common.dart';

/// Находки старшего инженера (f-d-senior-findings): находки, ждущие подтверждения, и находки в работе.
/// Планирование ТО и смена режима остаются у мастера.
class SeniorFindingsScreen extends ConsumerWidget {
  /// Создаёт экран.
  const SeniorFindingsScreen({super.key});

  /// Подписи состояний находки (D.findingStatus прототипа).
  static const Map<String, String> _status = {
    'new': 'Ждёт подтверждения',
    'confirmed': 'Подтверждена',
    'planned': 'Запланировано ТО',
    'closed': 'Закрыта',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Finding>> value = ref.watch(findingsProvider((status: null, unitId: null)));
    final List<Finding> all = value.value ?? const <Finding>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final String? since = ref.watch(roleChangeProvider).value?.when;
    String code(String id) => units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id;
    final List<Finding> fresh = all.where((Finding f) => f.status == 'new').toList();
    final List<Finding> work = all.where((Finding f) => f.status == 'planned' || f.status == 'confirmed').toList();
    return KvScreen(
      header: KvRootHeader(
        title: 'Находки',
        subtitle: value.hasValue ? '${fresh.length} ${KvFormat.plural(fresh.length, 'ждёт', 'ждут', 'ждут')} подтверждения' : ' ',
      ),
      children: [
        KvNote(icon: KvIcons.key, text: KvFormat.typo('Раздел открыт${since == null ? '' : ' с $since'} · роль «Старший инженер»')),
        if (!value.hasValue) const KvSkeleton.card(height: 220),
        if (fresh.isNotEmpty)
          KvList(
            children: [
              for (final Finding f in fresh)
                KvRow(
                  icon: KvIcons.alertCircle,
                  iconStatus: f.severity >= 3 ? KvStatus.bad : KvStatus.warn,
                  title: f.title,
                  subtitle: KvFormat.typo(
                    '${code(f.unitId)} · ${f.ruleId} · ${f.time} · ${f.author == 'Система' ? 'по датчикам' : ServiceFormat.short(f.author)}',
                  ),
                  onTap: () => context.kvPush(EngineerServicePaths.seniorFinding(f.id)),
                ),
            ],
          ),
        if (work.isNotEmpty) ...[
          const KvSectionLabel('В работе'),
          KvList(
            children: [
              for (final Finding f in work)
                KvRow(
                  icon: f.status == 'planned' ? KvIcons.calendar : KvIcons.checkCircle,
                  title: f.title,
                  subtitle: KvFormat.typo('${code(f.unitId)} · ${_status[f.status]}'),
                  onTap: () => context.kvPush(EngineerServicePaths.seniorFinding(f.id)),
                ),
            ],
          ),
        ],
        const KvNote(icon: KvIcons.info, text: 'Подтверждение и закрытие находок. Планирование ТО и смена режима остаются у мастера.'),
      ],
    );
  }
}
