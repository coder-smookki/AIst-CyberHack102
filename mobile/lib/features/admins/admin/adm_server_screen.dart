import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Цеховой сервер (e-adm-server): загрузка процессора за сутки, память, диск, подключение и перезапуск служб.
class AdmServerScreen extends ConsumerWidget {
  /// Создаёт экран.
  const AdmServerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerStatus? s = ref.watch(serverStatusProvider).value;
    return KvScreen(
      header: KvHeader(
        title: 'Цеховой сервер',
        subtitle: s == null ? ' ' : ty('Работает · ${s.uptime}'),
        status: KvStatus.ok,
        onBack: () => context.kvBack(AdminsPaths.admSystem),
        onMore: () => showServerMenu(context, ref),
      ),
      foot: KvButton(
        'Перезапустить службы',
        kind: KvButtonKind.secondary,
        icon: KvIcons.refresh,
        onPressed: () => showRestartDialog(context, ref),
      ),
      children: s == null
          ? const [KvSkeleton.card(height: 260), KvSkeleton.card(height: 110)]
          : [
              KvCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AdmBigNum(
                      value: '${s.cpu}',
                      unit: '%',
                      title: 'Загрузка процессора',
                      text: 'Пик 62 % в 03:00 во время резервного копирования',
                    ),
                    KvAreaChart(
                      height: 120,
                      showBubble: true,
                      data: KvSeriesData(
                        values: kAdmCpu24,
                        warn: 80,
                        alarm: 95,
                        unit: '%',
                        digits: 0,
                        labels: const ['10:00', '16:00', '22:00', '04:00', '09:41'],
                      ),
                    ),
                  ],
                ),
              ),
              KvCard(
                child: AdmDividedRow(
                  top: 0,
                  gap: admNarrow(context) ? 10 : 14,
                  divider: false,
                  children: [
                    AdmMeter(label: 'Память', pct: s.ram, extra: '13 из 32 ГБ'),
                    AdmMeter(label: 'Диск', pct: s.disk, extra: '1,1 из 1,9 ТБ'),
                  ],
                ),
              ),
              KvCard(
                title: 'Подключение',
                child: KvKeyValues([
                  ('Адрес', s.ip),
                  ('Сеть Wi-Fi', s.wifi),
                  ('Версия сервера', s.version),
                  ('Устройств в сети', '${s.clients}'),
                ]),
              ),
            ],
    );
  }

  /// Меню сервера (e-adm-server-menu).
  static void showServerMenu(BuildContext context, WidgetRef ref) {
    final BuildContext screen = context;
    final ServerStatus? s = ref.read(serverStatusProvider).value;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Цеховой сервер',
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.list,
                title: 'Системный журнал',
                subtitle: 'События сервера и служб',
                onTap: () => admCloseThen(sheet, () => screen.kvFade(AdminsPaths.admLog)),
              ),
              KvRow(
                icon: KvIcons.archive,
                title: 'Обновления и резерв',
                subtitle: s?.updateAvailable == null
                    ? 'Установлена последняя версия'
                    : ty('Версия ${s!.updateAvailable} готова к установке'),
                onTap: () => admCloseThen(sheet, () => screen.kvPush(AdminsPaths.eAdmMaint)),
              ),
              KvRow(
                icon: KvIcons.file,
                title: 'Собрать диагностический пакет',
                subtitle: ty('Логи служб за 24 ч'),
                onTap: () => showKvToast(
                  sheet,
                  title: 'Пакет собран',
                  text: ty('diag_KST-SRV-02_14-11.zip · 18 МБ на сервере'),
                  kind: KvToastKind.ok,
                ),
              ),
              KvRow(
                icon: KvIcons.refresh,
                iconStatus: KvStatus.warn,
                title: 'Перезапустить службы',
                subtitle: ty('Опрос и распознавание ~40 с'),
                onTap: () => admCloseThen(sheet, () => showRestartDialog(screen, ref)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Подтверждение перезапуска служб (e-adm-restart) и уведомление о результате (e-adm-restart-ok).
  static void showRestartDialog(BuildContext context, WidgetRef ref) {
    final BuildContext screen = context;
    showKvDialog<void>(
      context,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.refresh,
        tone: KvStatus.warn,
        title: 'Перезапустить службы?',
        text: ty(
          'Опрос датчиков и распознавание остановятся примерно на 40 с. Телефоны продолжат работу офлайн и передадут данные после перезапуска.',
        ),
        actions: [
          AdmDialogActions(
            okText: 'Перезапустить',
            wait: const Duration(milliseconds: 1200),
            work: () => ref.read(adminRepositoryProvider).restartServer(),
            onDone: () => admCloseThen(
              dialog,
              () =>
                  showKvToast(screen, title: 'Службы перезапущены', text: ty('Опрос датчиков восстановлен за 38 с'), kind: KvToastKind.ok),
            ),
          ),
        ],
      ),
    );
  }
}
