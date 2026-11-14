import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Источник данных (e-src-vib, e-src-opc, e-src-plc): отклик за час, параметры подключения, теги и проверка связи.
class AdmSourceScreen extends ConsumerWidget {
  /// Создаёт экран источника [sourceId].
  const AdmSourceScreen({super.key, required this.sourceId});

  /// Код источника: src-vib, src-opc, src-plc.
  final String sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DataSource? s = ref.watch(sourcesProvider.select((AsyncValue<List<DataSource>> a) => a.value?.where((DataSource x) => x.id == sourceId).firstOrNull));
    if (s == null) {
      return KvScreen(
        header: KvHeader(title: kAdmSourceShort[sourceId] ?? 'Источник', onBack: () => context.kvBack(AdminsPaths.admSources)),
        children: const [KvSkeleton.card(height: 220), KvSkeleton.card(height: 160)],
      );
    }
    final bool warn = s.status == 'warn';
    final List<String> lat = s.latency.split(' ');
    final bool plc = s.id == 'src-plc';
    return KvScreen(
      header: KvHeader(
        title: admSourceShort(s),
        subtitle: ty('${s.statusLabel} · ${s.proto.split(' ').first}'),
        status: KvStatus.parse(s.status),
        onBack: () => context.kvBack(AdminsPaths.admSources),
        onMore: () => _menu(context, ref, s),
      ),
      foot: AdmBusyButton(
        'Проверить связь',
        kind: KvButtonKind.secondary,
        icon: KvIcons.refresh,
        wait: const Duration(milliseconds: 1200),
        onDone: () {
          if (!s.enabled) {
            showKvToast(context, title: 'Опрос выключен', text: 'Подключите источник в меню источника', kind: KvToastKind.warn);
          } else if (warn) {
            showKvToast(context, title: 'Связь есть, ответ медленный', text: ty('Ответ 2,3 с · ${s.tags} из ${s.tags} тегов читаются'), kind: KvToastKind.warn);
          } else {
            showKvToast(context, title: 'Связь в норме', text: ty('Ответ ${s.latency} · ${s.tags} из ${admTagsWord(s.tags)}'), kind: KvToastKind.ok);
          }
        },
      ),
      children: [
        if (warn)
          KvNote(
            tone: KvStatus.warn,
            icon: KvIcons.alert,
            text: ty(
              s.id == 'src-vib'
                  ? 'Показания вибрации Н-101 приходят с опозданием. Рекомендуется проверить линию RS-485 и питание шлюза.'
                  : 'Показания приходят с опозданием. Рекомендуется проверить линию связи.',
            ),
          ),
        KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdmBigNum(
                value: lat.first,
                unit: lat.length > 1 ? lat[1] : '',
                warn: warn,
                title: 'Отклик за последний час',
                text: warn ? 'Норма до 1 с, рост с 09:20' : 'Норма до 1 с · без пропусков',
              ),
              KvAreaChart(
                height: 110,
                setpoints: warn,
                bubble: s.latency,
                data: KvSeriesData(
                  values: kAdmLatency[s.id] ?? kAdmLatency['src-opc']!,
                  warn: 1000,
                  alarm: 3000,
                  unit: 'мс',
                  digits: 0,
                  labels: const ['08:41', '09:00', '09:20', '09:41'],
                ),
              ),
            ],
          ),
        ),
        KvCard(
          title: 'Подключение',
          child: KvKeyValues([
            ('Адрес', s.addr),
            ('Опрос', ty('каждые ${s.poll}')),
            ('Безопасность', s.security),
            if (!RegExp('чтени', caseSensitive: false).hasMatch(s.security)) ('Режим', 'только чтение'),
          ]),
        ),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.tag,
              title: 'Теги источника',
              subtitle: ty('${admTagsWord(s.tags)} · ${plc ? 'АМС-1, АМС-2' : 'Н-101'}'),
              onTap: () => context.kvPush(AdminsPaths.tags(plc ? 'AMS-1' : 'N-101')),
            ),
          ],
        ),
      ],
    );
  }

  void _menu(BuildContext context, WidgetRef ref, DataSource s) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: admSourceShort(s),
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.edit,
                title: 'Изменить параметры',
                subtitle: 'Адрес, опрос, безопасность',
                onTap: () => admCloseThen(sheet, () => screen.kvPush(AdminsPaths.sourceEdit(s.id))),
              ),
              KvRow(
                icon: KvIcons.tag,
                title: 'Привязка тегов',
                onTap: () => admCloseThen(sheet, () => screen.kvPush(AdminsPaths.tags(s.id == 'src-plc' ? 'AMS-1' : 'N-101'))),
              ),
              if (s.enabled)
                KvRow(
                  icon: KvIcons.power,
                  iconStatus: KvStatus.bad,
                  danger: true,
                  title: 'Отключить источник',
                  subtitle: 'Теги покажут «нет данных»',
                  onTap: () => admCloseThen(sheet, () => _off(screen, ref, s)),
                )
              else
                KvRow(
                  icon: KvIcons.power,
                  iconStatus: KvStatus.ok,
                  title: 'Подключить источник',
                  subtitle: 'Опрос возобновится',
                  onTap: () => admCloseThen(sheet, () async {
                    await ref.read(adminRepositoryProvider).setSourceEnabled(s.id, true);
                    if (screen.mounted) {
                      showKvToast(screen, title: 'Источник подключён', text: 'Опрос возобновлён', kind: KvToastKind.ok, icon: KvIcons.power);
                    }
                  }),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _off(BuildContext screen, WidgetRef ref, DataSource s) {
    showKvDialog<void>(
      screen,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.power,
        tone: KvStatus.bad,
        title: 'Отключить источник?',
        text: ty('${admTagsWord(s.tags)} перестанут обновляться. Правила по этим показаниям не сработают, пока источник отключён.'),
        actions: [
          AdmDialogActions(
            okText: 'Отключить',
            kind: KvButtonKind.danger,
            work: () => ref.read(adminRepositoryProvider).setSourceEnabled(s.id, false),
            onDone: () => admCloseThen(
              dialog,
              () => showKvToast(screen, title: 'Источник отключён', text: 'Подключить снова можно в меню источника', kind: KvToastKind.warn, icon: KvIcons.power),
            ),
          ),
        ],
      ),
    );
  }
}
