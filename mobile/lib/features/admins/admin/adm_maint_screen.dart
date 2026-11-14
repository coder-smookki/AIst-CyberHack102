import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/adm_widgets.dart';

/// Обновления и резерв (e-adm-maint): доступная версия, резервные копии, создание копии и установка обновления.
class AdmMaintScreen extends ConsumerWidget {
  /// Создаёт экран.
  const AdmMaintScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerStatus? s = ref.watch(serverStatusProvider).value;
    final List<Backup> backups = ref.watch(backupsProvider).value ?? const <Backup>[];
    final String? next = s?.updateAvailable;
    final Backup? last = backups.firstOrNull;
    return KvScreen(
      header: KvHeader(
        title: 'Обновления и резерв',
        subtitle: s == null ? ' ' : 'Версия ${s.version}${last == null ? '' : ' · копия ${last.time}'}',
        status: KvStatus.ok,
        onBack: () => context.kvBack(AdminsPaths.admSystem),
        onMore: () => _menu(context),
      ),
      foot: next == null ? null : KvButton('Установить $next', icon: KvIcons.download, onPressed: () => _confirmUpdate(context, next, s!)),
      children: [
        if (s == null)
          const KvSkeleton.card(height: 180)
        else if (next != null)
          KvCard(
            title: 'Версия $next',
            trailing: const KvChip('Доступно', status: KvStatus.info),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(ty('${s.updateNotes ?? ''}.'), style: context.kvText.sm),
                const SizedBox(height: KvSpace.s2),
                KvKeyValues([('Сейчас', s.version), ('Размер', ty(s.updateSize ?? '')), ('Простой сервера', ty('около 6 мин'))]),
              ],
            ),
          )
        else
          KvCard(
            title: 'Версия ${s.version}',
            trailing: const KvChip('Установлена', status: KvStatus.ok),
            child: Text('Установлена последняя версия.', style: context.kvText.sm),
          ),
        const KvSectionLabel('Резервные копии'),
        KvList(
          children: [
            for (final Backup b in backups)
              KvRow(
                icon: KvIcons.archive,
                iconStatus: KvStatus.ok,
                title: '${b.date}, ${b.time}',
                subtitle: ty('${b.kind} · ${b.size}'),
                onTap: () => _backup(context, b),
              ),
          ],
        ),
        AdmBusyButton(
          'Создать копию сейчас',
          kind: KvButtonKind.secondary,
          icon: KvIcons.plus,
          wait: const Duration(milliseconds: 1400),
          work: () => ref.read(adminRepositoryProvider).createBackup(),
          onDone: () {
            final Backup? b = ref.read(backupsProvider).value?.firstOrNull;
            showKvToast(
              context,
              title: 'Копия создана',
              text: ty(b == null ? '' : '${b.date}, ${b.time} · ${b.size}'),
              kind: KvToastKind.ok,
            );
          },
        ),
      ],
    );
  }

  void _menu(BuildContext context) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Обновления и резерв',
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.calendar,
                title: 'Расписание копий',
                subtitle: ty('Ежедневно 03:00 · хранятся 14'),
                onTap: () => showKvToast(
                  sheet,
                  title: 'Расписание копий',
                  text: ty('Ежедневно в 03:00, хранятся 14 последних'),
                  kind: KvToastKind.info,
                ),
              ),
              KvRow(
                icon: KvIcons.list,
                title: 'Системный журнал',
                onTap: () => admCloseThen(sheet, () => screen.kvFade(AdminsPaths.admLog)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _backup(BuildContext context, Backup b) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Копия ${b.date}, ${b.time}',
        actions: [
          AdmBusyButton(
            'Проверить целостность',
            kind: KvButtonKind.secondary,
            icon: KvIcons.shieldCheck,
            wait: const Duration(milliseconds: 1200),
            onDone: () => showKvToast(sheet, title: 'Копия цела', text: 'Контрольная сумма совпадает', kind: KvToastKind.ok),
          ),
          KvButton(
            'Восстановить из копии',
            kind: KvButtonKind.dangerSoft,
            icon: KvIcons.history,
            onPressed: () => admCloseThen(sheet, () => _restore(screen, b)),
          ),
        ],
        children: [
          KvCard(
            style: KvCardStyle.outline,
            child: KvKeyValues([
              ('Тип', b.kind),
              ('Размер', ty(b.size)),
              ('Состав', 'база, модели, настройки'),
              ('Контрольная сумма', 'совпадает'),
            ]),
          ),
        ],
      ),
    );
  }

  void _restore(BuildContext screen, Backup b) {
    showKvDialog<void>(
      screen,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.history,
        tone: KvStatus.warn,
        title: 'Восстановить из копии?',
        text: ty(
          'Данные сервера после ${b.date}, ${b.time} будут заменены. Осмотры с телефонов загрузятся повторно. Лучше выполнять вне смены.',
        ),
        actions: [
          AdmDialogActions(
            okText: 'Запланировать',
            onDone: () => admCloseThen(
              dialog,
              () => showKvToast(
                screen,
                title: 'Восстановление запланировано',
                text: ty('Сегодня в 20:30, после смены'),
                kind: KvToastKind.info,
                icon: KvIcons.calendar,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmUpdate(BuildContext context, String next, ServerStatus s) {
    final BuildContext screen = context;
    showKvDialog<void>(
      context,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.download,
        title: 'Установить $next?',
        text: ty('Сначала будет создана резервная копия. Сервер будет недоступен около 6 минут, сканеры продолжат работу офлайн.'),
        actions: [AdmDialogActions(okText: 'Установить', onDone: () => admCloseThen(dialog, () => screen.kvPush(AdminsPaths.eUpdateRun)))],
      ),
    );
  }
}
