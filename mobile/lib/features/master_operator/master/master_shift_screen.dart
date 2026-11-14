import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/navigation/kv_page.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/workflow_repository.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_common.dart';

/// Смена (домашний экран мастера): новая находка, сводка смены плитками и что требует внимания.
///
/// [at] - момент истории смены для сценариев: «0640» (06:41, до остановки АМС-2) и «0812» (08:12, АМС-2 уже
/// на ремонте); без него экран показывает текущее состояние по данным сервера.
class MasterShiftScreen extends ConsumerWidget {
  /// Создаёт экран.
  const MasterShiftScreen({super.key, this.at});

  /// Момент истории или null - сейчас.
  final String? at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Site? site = ref.watch(siteProvider).value;
    final bool early = at == '0640';
    final bool morning = at == '0812';
    final String sub = site == null ? ' ' : '${site.name} · ${early ? '14.11, до начала смены' : site.shiftShort}';
    final List<Widget> body;
    if (early || morning) {
      body = _moment(context, early);
    } else {
      body = _live(context, ref);
    }
    return KvScreen(header: KvRootHeader(title: 'Смена', subtitle: sub), children: body);
  }

  void _tab(BuildContext context, String path) => context.go(path, extra: const KvNavExtra(transition: KvTransition.fade));

  List<Widget> _live(BuildContext context, WidgetRef ref) {
    final List<Finding> fresh = ref.watch(findingsProvider((status: 'new', unitId: null))).value ?? const <Finding>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final List<AppNotification> notes = ref.watch(notificationsProvider('master')).value ?? const <AppNotification>[];
    final Finding? top = fresh.firstOrNull;
    final int unread = notes.where((AppNotification n) => !n.read).length;
    String code(String id) => units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id;
    return [
      if (top != null)
        MoBanner(
          tone: KvStatus.warn,
          icon: KvIcons.alertCircle,
          iconStatus: KvStatus.warn,
          title: 'Новая находка ждёт подтверждения',
          subtitle: KvFormat.typo('${code(top.unitId)} · ${top.ruleId} · ${top.time}${top.author == 'Система' ? '' : ' · ${moShortName(top.author)}'}'),
          onTap: () => context.kvPush(MasterOperatorPaths.finding(top.id)),
        ),
      MoGridRow(
        minHeight: 146,
        children: [
          MoKpiTile(label: 'Агрегаты', value: '${units.isEmpty ? 3 : units.length}', unit: 'в работе 1', bar: _bar(units), sub: 'Норма 1 · внимание 1 · ремонт 1'),
          MoKpiTile(
            label: 'Находки',
            value: '${fresh.length}',
            unit: KvFormat.plural(fresh.length, 'новая', 'новые', 'новых'),
            spark: const [0, 0, 1, 0, 1, 0, 3],
            sub: '+3 за сегодня',
            subWarn: true,
            onTap: () => _tab(context, MasterOperatorPaths.masterFindings),
          ),
        ],
      ),
      MoGridRow(
        minHeight: 146,
        children: [
          MoKpiTile(
            label: 'Осмотры',
            value: '2',
            unit: 'из 3 сегодня',
            spark: const [3, 2, 3, 4, 2, 3, 2],
            sub: KvFormat.typo('1 идёт сейчас · Н-101'),
            onTap: () => context.kvPush(MasterOperatorPaths.dMTeam),
          ),
          MoKpiTile(label: 'Охват смены', value: '2', unit: 'из 3', ring: 67, sub: KvFormat.typo('АМС-1 - обход в 14:00'), onTap: () => context.kvPush(MasterOperatorPaths.dMTeam)),
        ],
      ),
      const MoLabel('Требуют внимания'),
      KvList(
        children: [
          KvRow(
            icon: KvIcons.activity,
            iconStatus: KvStatus.warn,
            title: KvFormat.typo('Н-101 · внимание'),
            subtitle: KvFormat.typo('Вибрация 1X 3,1 мм/с · подшипник 78 °C'),
            onTap: () => context.kvPush(MasterOperatorPaths.unit('N-101')),
          ),
          KvRow(
            icon: KvIcons.wrench,
            title: KvFormat.typo('АМС-2 · на ремонте'),
            subtitle: KvFormat.typo('Ремонт уплотнения 15.11, 08:00'),
            onTap: () => context.kvPush(MasterOperatorPaths.unit('AMS-2')),
          ),
          KvRow(
            icon: KvIcons.bell,
            title: 'Уведомления смены',
            subtitle: notes.isEmpty ? 'Новых нет' : KvFormat.typo('${notes.length} за смену · последнее ${notes.first.time}'),
            trailing: unread > 0 ? KvBadge('$unread') : null,
            onTap: () => context.kvPush(MasterOperatorPaths.dMNotif),
          ),
        ],
      ),
    ];
  }

  List<KvStatus?> _bar(List<Equipment> units) {
    if (units.isEmpty) {
      return const [KvStatus.ok, KvStatus.warn, KvStatus.info];
    }
    const List<String> order = ['ok', 'warn', 'bad', 'info', 'unk'];
    final List<Equipment> sorted = [...units]..sort((Equipment a, Equipment b) => order.indexOf(a.status).compareTo(order.indexOf(b.status)));
    return [for (final Equipment u in sorted) KvStatus.parse(u.status)];
  }

  List<Widget> _moment(BuildContext context, bool early) {
    return [
      if (!early)
        MoBanner(
          tone: KvStatus.info,
          icon: KvIcons.wrench,
          title: KvFormat.typo('АМС-2 на ремонте'),
          subtitle: KvFormat.typo('F-1041 подтверждена в 07:30 · ремонт 15.11, 08:00'),
          onTap: () => context.kvPush(MasterOperatorPaths.unit('AMS-2')),
        ),
      MoGridRow(
        minHeight: 146,
        children: [
          MoKpiTile(
            label: 'Агрегаты',
            value: '3',
            unit: early ? 'в работе 3' : 'в работе 2',
            bar: early ? const [KvStatus.ok, KvStatus.warn, KvStatus.warn] : const [KvStatus.ok, KvStatus.warn, KvStatus.info],
            sub: early ? 'Норма 1 · внимание 2' : 'Норма 1 · внимание 1 · ремонт 1',
          ),
          MoKpiTile(
            label: 'Находки',
            value: early ? '0' : '1',
            unit: early ? 'новых' : 'в работе',
            spark: [0, 0, 1, 0, 1, 0, early ? 0 : 1],
            sub: early ? 'за смену пока нет' : KvFormat.typo('F-1041 · АМС-2'),
            onTap: () => _tab(context, MasterOperatorPaths.dMFindingsAll),
          ),
        ],
      ),
      MoGridRow(
        minHeight: 146,
        children: [
          MoKpiTile(
            label: 'Осмотры',
            value: early ? '0' : '1',
            unit: 'из 3 сегодня',
            spark: [3, 2, 3, 4, 2, 3, early ? 0 : 1],
            sub: early ? 'Первый осмотр - по заданию' : KvFormat.typo('АМС-2 · 06:58-07:10'),
            onTap: () => context.kvPush(MasterOperatorPaths.dMTeam),
          ),
          MoKpiTile(
            label: 'Охват смены',
            value: early ? '0' : '1',
            unit: 'из 3',
            ring: early ? 0 : 33,
            sub: KvFormat.typo('АМС-1 - обход в 14:00'),
            onTap: () => context.kvPush(MasterOperatorPaths.dMTeam),
          ),
        ],
      ),
      const MoLabel('Требуют внимания'),
      KvList(
        children: early
            ? [
                KvRow(
                  icon: KvIcons.temp,
                  iconStatus: KvStatus.warn,
                  title: KvFormat.typo('Н-101 · внимание'),
                  subtitle: KvFormat.typo('Подшипник 77 °C, уставка 75 °C'),
                  onTap: () => context.kvPush(MasterOperatorPaths.unit('N-101')),
                ),
                KvRow(
                  icon: KvIcons.temp,
                  iconStatus: KvStatus.warn,
                  title: KvFormat.typo('АМС-2 · внимание'),
                  subtitle: KvFormat.typo('Обмотка 104 °C, уставка 90 °C · растёт'),
                  onTap: () => context.kvPush(MasterOperatorPaths.report('S-077')),
                ),
              ]
            : [
                KvRow(
                  icon: KvIcons.activity,
                  iconStatus: KvStatus.warn,
                  title: KvFormat.typo('Н-101 · внимание'),
                  subtitle: KvFormat.typo('Вибрация 1X 3,1 мм/с · подшипник 78 °C'),
                  onTap: () => context.kvPush(MasterOperatorPaths.unit('N-101')),
                ),
                KvRow(
                  icon: KvIcons.wrench,
                  title: KvFormat.typo('АМС-2 · на ремонте'),
                  subtitle: KvFormat.typo('Ремонт уплотнения 15.11, 08:00'),
                  onTap: () => context.kvPush(MasterOperatorPaths.unit('AMS-2')),
                ),
              ],
      ),
    ];
  }
}

/// Уведомления мастера: лента смены сегодня, вчерашняя передача смены и пояснение о доставке по Wi-Fi.
///
/// Записи отмечаются прочитанными, когда мастер уходит с экрана.
class MasterNotifScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const MasterNotifScreen({super.key});

  @override
  ConsumerState<MasterNotifScreen> createState() => _MasterNotifScreenState();
}

class _MasterNotifScreenState extends ConsumerState<MasterNotifScreen> {
  late final WorkflowRepository _repo = ref.read(workflowRepositoryProvider);

  @override
  void dispose() {
    _repo.markNotificationsRead('master');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<AppNotification> list = ref.watch(notificationsProvider('master')).value ?? const <AppNotification>[];
    final int unread = list.where((AppNotification n) => !n.read).length;
    return KvScreen(
      header: KvHeader(
        title: 'Уведомления',
        subtitle: '${list.length} за смену · $unread ${KvFormat.plural(unread, 'новое', 'новых', 'новых')}',
        onBack: () => context.kvBack(MasterOperatorPaths.masterShift),
      ),
      children: [
        const MoLabel('Сегодня'),
        KvList(
          children: [
            for (final AppNotification n in list)
              KvRow(
                icon: switch (n.kind) {
                  'bad' => KvIcons.alertCircle,
                  'warn' => KvIcons.activity,
                  'ok' => KvIcons.checkCircle,
                  _ => KvIcons.info,
                },
                iconStatus: KvStatus.parse(n.kind),
                title: n.title,
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
              title: 'Смена принята',
              subtitle: KvFormat.typo('Н. Гусев передал смену · 20:05'),
              value: '20:05',
              onTap: () => context.kvPush(MasterOperatorPaths.dMTeam),
            ),
          ],
        ),
        const KvNote(icon: KvIcons.wifi, text: 'Уведомления приходят по Wi-Fi от цехового сервера, интернет не нужен.'),
      ],
    );
  }
}
