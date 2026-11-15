import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/entry_routes.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_common.dart';

/// Сотрудник текущего сеанса из списка площадки (должность и рабочая почта) с запасным ключом роли [roleKey].
Person? moMe(WidgetRef ref, String roleKey) {
  final Map<String, Person> people = ref.watch(peopleProvider).value ?? const <String, Person>{};
  final String? name = ref.watch(sessionProvider.select((AuthSession? s) => s?.user.name));
  return people.values.where((Person p) => p.name == name).firstOrNull ?? people[roleKey];
}

/// Профиль мастера: карточка сотрудника, команда, отчёты, уведомления, настройки и выход.
class MasterProfileScreen extends ConsumerWidget {
  /// Создаёт экран.
  const MasterProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Site? site = ref.watch(siteProvider).value;
    final Person? me = moMe(ref, 'master');
    final List<AppNotification> notes = ref.watch(notificationsProvider('master')).value ?? const <AppNotification>[];
    final int unread = notes.where((AppNotification n) => !n.read).length;
    return KvScreen(
      header: KvRootHeader(title: 'Профиль', subtitle: site?.name ?? ' '),
      children: [
        if (me == null)
          const KvSkeleton.card(height: 230)
        else
          MoProfileCard(name: me.name, title: me.title, email: me.email, role: me.roleLabel, shift: me.shift),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.info,
              title: 'Как пользоваться',
              subtitle: 'Кнопки, экраны и порядок работы',
              onTap: () => context.kvPush(EntryPaths.guide),
            ),
            KvRow(
              icon: KvIcons.users,
              title: 'Команда смены',
              subtitle: KvFormat.typo('3 человека · охват 67 %'),
              onTap: () => context.kvPush(MasterOperatorPaths.dMTeam),
            ),
            KvRow(
              icon: KvIcons.file,
              title: 'Отчёты смены',
              subtitle: 'PDF и Excel',
              onTap: () => context.kvPush(MasterOperatorPaths.dMReports),
            ),
            KvRow(
              icon: KvIcons.bell,
              title: 'Уведомления',
              subtitle: unread == 0 ? 'Новых нет' : '$unread ${KvFormat.plural(unread, 'новое', 'новых', 'новых')}',
              trailing: unread > 0 ? KvBadge('$unread') : null,
              onTap: () => context.kvPush(MasterOperatorPaths.dMNotif),
            ),
            KvRow(
              icon: KvIcons.settings,
              title: 'Настройки',
              subtitle: 'Тема, уведомления, биометрия',
              onTap: () => showMoSettingsSheet(context, notifications: 'Находки, сообщения операторов'),
            ),
          ],
        ),
        KvButton(
          'Выйти из учётной записи',
          kind: KvButtonKind.secondary,
          icon: KvIcons.logout,
          onPressed: () => showMoLogoutDialog(context),
        ),
      ],
    );
  }
}

/// Отчёты смены: черновик сменного отчёта со счётчиками и выгрузкой PDF и Excel, ранее сформированные отчёты.
class MasterReportsScreen extends ConsumerWidget {
  /// Создаёт экран.
  const MasterReportsScreen({super.key});

  Future<void> _make(BuildContext context, WidgetRef ref, String format, String size) async {
    await ref.read(reportRepositoryProvider).shiftReport('14.11.2026', format);
    if (context.mounted) {
      showKvToast(
        context,
        kind: KvToastKind.ok,
        icon: KvIcons.download,
        title: 'Отчёт сформирован',
        text: KvFormat.typo('Смена 14.11 · ${format == 'pdf' ? 'PDF' : 'Excel'} · $size · Загрузки'),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvTextStyles t = context.kvText;
    return KvScreen(
      header: KvHeader(
        title: 'Отчёты',
        subtitle: 'Смена 14.11 · 08:00-20:00',
        onBack: () => context.kvBack(MasterOperatorPaths.masterProfile),
      ),
      children: [
        KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Сменный отчёт · 14.11', style: t.h2)),
                  const KvChip('Черновик', dot: false),
                ],
              ),
              const SizedBox(height: KvSpace.s3),
              const Row(
                children: [
                  Expanded(
                    child: KvKpi(value: '2', label: 'Осмотра', status: KvStatus.info),
                  ),
                  SizedBox(width: KvSpace.s2),
                  Expanded(
                    child: KvKpi(value: '3', label: 'Находки', status: KvStatus.warn),
                  ),
                  SizedBox(width: KvSpace.s2),
                  Expanded(
                    child: KvKpi(value: '1', label: 'Ремонт', status: KvStatus.bad),
                  ),
                ],
              ),
              const SizedBox(height: KvSpace.s3),
              Row(
                children: [
                  Expanded(
                    child: KvButton(
                      'PDF',
                      kind: KvButtonKind.tonal,
                      icon: KvIcons.filePdf,
                      wait: true,
                      onPressed: () => _make(context, ref, 'pdf', '1,2 МБ'),
                    ),
                  ),
                  const SizedBox(width: KvSpace.s3),
                  Expanded(
                    child: KvButton(
                      'Excel',
                      kind: KvButtonKind.tonal,
                      icon: KvIcons.fileXls,
                      wait: true,
                      onPressed: () => _make(context, ref, 'xlsx', '86 КБ'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const MoLabel('Ранее'),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.filePdf,
              title: 'Смена 13.11',
              subtitle: KvFormat.typo('PDF · 1,0 МБ · Н. Гусев'),
              onTap: () => context.kvPush(MasterOperatorPaths.dMReport1311),
            ),
            KvRow(
              icon: KvIcons.fileXls,
              title: 'Отчёт за октябрь',
              subtitle: KvFormat.typo('Excel · 214 КБ · 02.11'),
              onTap: () => showMoShareSheet(context, title: 'Отчёт за октябрь · Excel', file: 'otchet_10-2026.xlsx', size: '214 КБ'),
            ),
            KvRow(
              icon: KvIcons.filePdf,
              title: KvFormat.typo('История Н-101'),
              subtitle: 'PDF · наработка и события',
              onTap: () async {
                await ref.read(reportRepositoryProvider).unitReport('N-101', 'pdf');
                if (context.mounted) {
                  showKvToast(
                    context,
                    kind: KvToastKind.ok,
                    icon: KvIcons.download,
                    title: 'Отчёт сформирован',
                    text: KvFormat.typo('История Н-101 · PDF · 0,9 МБ'),
                  );
                }
              },
            ),
          ],
        ),
        const KvNote(icon: KvIcons.server, text: 'Отчёты собираются на цеховом сервере и доступны без интернета.'),
      ],
    );
  }
}

/// Сменный отчёт 13.11: страница PDF в светлом виде, переключатель страниц, выгрузка Excel и «Поделиться».
class MasterShiftReportScreen extends ConsumerWidget {
  /// Создаёт экран.
  const MasterShiftReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final Site? site = ref.watch(siteProvider).value;
    void share() => showMoShareSheet(context, title: 'Сменный отчёт 13.11', file: 'smena_13-11-2026.pdf', size: '1,0 МБ');
    return KvScreen(
      header: KvHeader(
        title: 'Сменный отчёт 13.11',
        subtitle: KvFormat.typo('PDF · 2 страницы · 1,0 МБ'),
        status: KvStatus.info,
        onBack: () => context.kvBack(MasterOperatorPaths.dMReports),
        onMore: share,
      ),
      foot: Row(
        children: [
          Expanded(
            child: KvButton(
              'Excel',
              kind: KvButtonKind.secondary,
              icon: KvIcons.fileXls,
              onPressed: () =>
                  showMoShareSheet(context, title: 'Сменный отчёт 13.11 · Excel', file: 'smena_13-11-2026.xlsx', size: '84 КБ'),
            ),
          ),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: KvButton('Поделиться', icon: KvIcons.share, onPressed: share),
          ),
        ],
      ),
      children: [
        _ShiftPaper(site: site?.name ?? 'Насосная станция № 2', server: site?.server ?? 'КСТ-СРВ-02'),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 18,
              height: 6,
              decoration: BoxDecoration(color: c.brand, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 6),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: c.surface3, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 6),
            Text('Стр. 1 из 2', style: context.kvText.caption.copyWith(height: KvTextStyles.normalHeight(13))),
          ],
        ),
      ],
    );
  }
}

/// Лист сменного отчёта (.c-paper): всегда светлая бумага A4 с шапкой, итогами, событиями и подписью.
class _ShiftPaper extends StatelessWidget {
  const _ShiftPaper({required this.site, required this.server});

  final String site;
  final String server;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: KvTheme.light,
      child: Builder(
        builder: (BuildContext context) {
          final KvColors c = context.kv;
          TextStyle s(double size, {FontWeight weight = FontWeight.w400, Color? color, double height = 1.35}) =>
              TextStyle(fontFamily: KvTextStyles.kvFontFamily, fontSize: size, fontWeight: weight, color: color ?? c.text, height: height);
          Widget res(String label, String value, String note, Color tone) => Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
              decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(6)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: s(8.5, color: c.text2),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    style: s(15, weight: FontWeight.w300, color: tone, height: 1),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: s(8.5, color: c.text2),
                  ),
                ],
              ),
            ),
          );
          const List<(KvIcons, String)> events = [
            (KvIcons.activity, '16:40 · Н-101 · плановый осмотр, отмечен шум подшипника'),
            (KvIcons.temp, 'Н-101 · подшипник 76-77 °C, уставка 75 °C · S04'),
            (KvIcons.checkCircle, 'АМС-1, АМС-2 · отклонений по датчикам не выявлено'),
            (KvIcons.clock, 'Наработка Н-101 за смену 12 ч · всего 19 178 ч'),
          ];
          return AspectRatio(
            aspectRatio: 1 / 1.414,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
              decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(8), boxShadow: c.shadow2),
              child: DefaultTextStyle(
                style: s(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: c.divider)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const KvLogo(height: 14),
                          const Spacer(),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('Сменный отчёт · смена Б', style: s(11, weight: FontWeight.w600)),
                              Text(KvFormat.typo('13.11.2026 · 20:00-08:00'), style: s(9, color: c.text2)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(site, style: s(14, weight: FontWeight.w600, height: 1.25)),
                    const SizedBox(height: 2),
                    Text(KvFormat.typo('Мастер Н. Гусев · инженер Е. Титова · оператор А. Лебедева'), style: s(9, color: c.text2)),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        res('Осмотры', '2', KvFormat.typo('Н-101, АМС-1'), c.brand),
                        const SizedBox(width: 6),
                        res('Находки', '0', 'новых нет', c.brand),
                        const SizedBox(width: 6),
                        res('События', '1', KvFormat.typo('шум Н-101'), c.warnText),
                      ],
                    ),
                    const SizedBox(height: 9),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'СОБЫТИЯ СМЕНЫ',
                        style: s(10, weight: FontWeight.w600, color: c.text2).copyWith(letterSpacing: 0.2),
                      ),
                    ),
                    const SizedBox(height: 9 + 4),
                    for (int i = 0; i < events.length; i++) ...[
                      if (i > 0) const SizedBox(height: 2),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: KvIcon(events[i].$1, size: 11, color: c.text3),
                          ),
                          const SizedBox(width: 5),
                          Expanded(child: Text(KvFormat.typo(events[i].$2), style: s(9))),
                        ],
                      ),
                    ],
                    const Spacer(),
                    const SizedBox(height: 9),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(text: 'Смену сдал\n'),
                                  TextSpan(
                                    text: KvFormat.typo('Мастер участка · 14.11.2026, 08:00'),
                                    style: s(8.5, color: c.text2, height: 1.6),
                                  ),
                                ],
                              ),
                              style: s(9.5, weight: FontWeight.w600),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 130,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  padding: const EdgeInsets.only(bottom: 1),
                                  decoration: BoxDecoration(
                                    border: Border(bottom: BorderSide(color: c.text2)),
                                  ),
                                  child: Text(
                                    'Гусев',
                                    textAlign: TextAlign.center,
                                    style: s(13, color: c.brandDeep).copyWith(fontStyle: FontStyle.italic),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  KvFormat.typo('Н. Гусев'),
                                  textAlign: TextAlign.center,
                                  style: s(9, color: c.text2),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        Expanded(
                          child: Text('КСТ Визор · $server', style: s(8, color: c.text3)),
                        ),
                        Text('стр. 1 из 2', style: s(8, color: c.text3)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
