import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/workflow_repository.dart';
import '../widgets/mo_blocks.dart';
import 'op_blocks.dart';

/// Путь экрана агрегата для оператора: на ремонте - карточка ремонта, иначе просмотр показаний.
String opUnitPath(Equipment u) => u.mode == 'repair' ? MasterOperatorPaths.opRepair(u.id) : MasterOperatorPaths.opUnit(u.id);

/// Агрегаты на пульте оператора: живые показания, свежее уведомление и карточки агрегатов.
///
/// [at] = «0730» - пульт в 07:30, до решения мастера (сценарий А): АМС-2 остановлен по S05, сообщение S-077 принято.
class OpObjectsScreen extends ConsumerWidget {
  /// Создаёт экран.
  const OpObjectsScreen({super.key, this.at});

  /// Момент истории или null - сейчас.
  final String? at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(liveUnitsPollProvider);
    final Site? site = ref.watch(siteProvider).value;
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final List<AppNotification> notes = ref.watch(notificationsProvider('operator')).value ?? const <AppNotification>[];
    final bool early = at == '0730';
    final String time = early ? '07:30' : KvFormat.time(ref.watch(clockProvider).now());
    final AppNotification? top = notes.firstOrNull;
    final List<Widget> body = [
      MoLiveLine('Показания в реальном времени · $time'),
      if (early)
        MoBanner(
          tone: KvStatus.info,
          icon: KvIcons.megaphone,
          title: KvFormat.typo('Сообщение S-077 принято'),
          subtitle: KvFormat.typo('Осмотр выполнен в 07:05 · ждёт решения мастера'),
          onTap: () => context.kvPush(MasterOperatorPaths.reportStatus('S-077')),
        )
      else if (top != null)
        MoBanner(
          tone: KvStatus.info,
          icon: KvIcons.bell,
          title: KvFormat.typo(top.title),
          subtitle: KvFormat.typo(
            '${notes.length} ${KvFormat.plural(notes.length, 'уведомление', 'уведомления', 'уведомлений')} · ${_brief(top)}',
          ),
          onTap: () => context.kvPush(MasterOperatorPaths.dOpNotif),
        ),
      if (units.isEmpty) ...const [KvSkeleton.card(height: 150), KvSkeleton.card(height: 150), KvSkeleton.card(height: 150)],
      for (final Equipment u in units) _card(context, u, early),
    ];
    return KvScreen(
      header: KvRootHeader(title: 'Агрегаты', subtitle: site == null ? ' ' : '${site.name} · ${site.shiftShort}'),
      children: body,
    );
  }

  /// Краткое содержание уведомления для подписи баннера: «ремонт 15.11, 08:00».
  String _brief(AppNotification n) {
    final String text = n.text.replaceFirst('Ремонт уплотнения', 'ремонт');
    return text.isEmpty ? text : text[0].toLowerCase() + text.substring(1);
  }

  Widget _card(BuildContext context, Equipment u, bool early) {
    if (early && u.id == 'AMS-2') {
      return OpUnitCard(
        unit: u,
        stoppedChip: true,
        note: const MoRepairNote(
          icon: KvIcons.pause,
          title: 'Остановлен автоматически в 06:44',
          text: 'S05: обмотка 112 °C · инженер провёл осмотр в 07:05',
        ),
        onTap: () => context.kvPush(MasterOperatorPaths.reportStatus('S-077')),
      );
    }
    final Widget? note = switch (u.mode) {
      'repair' => const MoRepairNote(
        icon: KvIcons.wrench,
        title: 'На ремонте · ремонт 15.11, 08:00',
        text: 'Остановлен 06:44 · обмотка 112 °C',
      ),
      'reserve' || 'stopped' => const MoRepairNote(
        icon: KvIcons.pause,
        title: 'Остановлен мастером',
        text: 'Наработка не начисляется · показания не обновляются',
      ),
      _ => null,
    };
    return OpUnitCard(unit: u, note: note, onTap: () => context.kvPush(opUnitPath(u)));
  }
}

/// Уведомления оператора: лента смены, вчерашнее закрытие сообщения и пояснение о правах роли.
///
/// Записи отмечаются прочитанными, когда оператор уходит с экрана.
class OpNotifScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const OpNotifScreen({super.key});

  @override
  ConsumerState<OpNotifScreen> createState() => _OpNotifScreenState();
}

class _OpNotifScreenState extends ConsumerState<OpNotifScreen> {
  late final WorkflowRepository _repo;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(workflowRepositoryProvider);
  }

  @override
  void dispose() {
    _repo.markNotificationsRead('operator');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<AppNotification> list = ref.watch(notificationsProvider('operator')).value ?? const <AppNotification>[];
    return KvScreen(
      header: KvHeader(
        title: 'Уведомления',
        subtitle: '${list.length} за смену',
        onBack: () => context.kvBack(MasterOperatorPaths.opObjects),
      ),
      children: [
        const MoLabel('Сегодня'),
        KvList(
          children: [
            for (final AppNotification n in list)
              KvRow(
                icon: n.kind == 'ok' ? KvIcons.checkCircle : KvIcons.wrench,
                iconStatus: n.kind == 'ok' ? KvStatus.ok : null,
                title: KvFormat.typo(n.title),
                subtitle: KvFormat.typo(n.text),
                value: n.time,
                onTap: n.target == null ? null : () => context.kvPush(n.target!),
              ),
          ],
        ),
        const MoLabel('Вчера'),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.checkCircle,
              iconStatus: KvStatus.ok,
              title: KvFormat.typo('Сообщение S-071 закрыто'),
              subtitle: KvFormat.typo('Н-101 · проверено инженером'),
              value: '10.11',
              onTap: () => context.kvPush(MasterOperatorPaths.reportStatus('S-071')),
            ),
          ],
        ),
        const KvNote(
          icon: KvIcons.info,
          text: 'Оператор видит состояние и показания. Осмотры, находки и режимы агрегатов меняют инженер и мастер.',
        ),
      ],
    );
  }
}
