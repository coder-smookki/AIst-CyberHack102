import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/mo_blocks.dart';
import 'master_assign_sheet.dart';

/// Команда смены: охват осмотров, кто на смене и задания смены.
class MasterTeamScreen extends ConsumerWidget {
  /// Создаёт экран.
  const MasterTeamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final Site? site = ref.watch(siteProvider).value;
    final List<InspectionTask> tasks = ref.watch(tasksProvider(null)).value ?? const <InspectionTask>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    String code(String id) => units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id;
    return KvScreen(
      header: KvHeader(title: 'Команда смены', subtitle: site?.shift ?? ' ', onBack: () => context.kvBack(MasterOperatorPaths.masterShift)),
      children: [
        KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const MoRing(67),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: 'Осмотрено 2 из 3 агрегатов\n', style: t.sm.copyWith(fontWeight: FontWeight.w500, color: c.text, height: 1.38)),
                          const TextSpan(text: 'Осмотры по заданиям и обходу смены'),
                        ],
                      ),
                      style: t.caption.copyWith(height: 1.38),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: KvSpace.s3),
              KvKeyValues([
                ('Н-101', KvFormat.typo('09:20-09:34 · А. Смирнов')),
                ('АМС-2', KvFormat.typo('06:58-07:10 · А. Смирнов')),
                ('АМС-1', KvFormat.typo('обход в 14:00 · Е. Титова')),
              ]),
            ],
          ),
        ),
        const MoLabel('На смене'),
        KvList(
          children: [
            KvRow(
              avatar: 'Алексей Смирнов',
              title: 'Алексей Смирнов',
              subtitle: KvFormat.typo('Инженер · 2 осмотра · идёт осмотр Н-101'),
              trailing: const KvChip('Осмотр', status: KvStatus.info),
              onTap: () => showKvToast(
                context,
                kind: KvToastKind.info,
                icon: KvIcons.scan,
                title: 'Алексей Смирнов на осмотре',
                text: KvFormat.typo('Н-101 · INS-2209 · с 09:20'),
              ),
            ),
            KvRow(
              avatar: 'Елена Титова',
              title: 'Елена Титова',
              subtitle: KvFormat.typo('Инженер · задание T-319 в 14:00'),
              trailing: const KvChip('Свободна', status: KvStatus.ok),
              onTap: () => showMoAssignSheet(context, MoAssignPreset.team),
            ),
            KvRow(
              avatar: 'Ольга Кузнецова',
              title: 'Ольга Кузнецова',
              subtitle: KvFormat.typo('Оператор · сообщение S-077'),
              trailing: const KvChip('Пульт'),
              onTap: () => context.kvPush(MasterOperatorPaths.report('S-077')),
            ),
          ],
        ),
        const MoLabel('Задания смены'),
        KvList(
          children: [
            for (final InspectionTask task in tasks)
              KvRow(
                icon: task.status == 'done' ? KvIcons.checkCircle : KvIcons.clipboard,
                iconStatus: task.status == 'done' ? KvStatus.ok : null,
                title: KvFormat.typo('${code(task.unitId)} · ${task.title}'),
                subtitle: KvFormat.typo('${task.to} · до ${task.due} · ${task.statusLabel.toLowerCase()}'),
                chevron: false,
              ),
          ],
        ),
      ],
    );
  }
}
