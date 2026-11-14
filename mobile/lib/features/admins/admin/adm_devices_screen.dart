import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/adm_widgets.dart';

/// Устройства (e-adm-devices): версии приложения на телефонах и планшетах смены, обновление устаревших.
class AdmDevicesScreen extends ConsumerWidget {
  /// Создаёт экран.
  const AdmDevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Device> devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final String current = ref.watch(serverStatusProvider.select((AsyncValue<ServerStatus> s) => s.value?.version)) ?? '1.4.2';
    final List<Device> old = devices.where((Device d) => d.version != current).toList();
    final int fresh = devices.length - old.length;
    final String oldVersion = old.firstOrNull?.version ?? '';
    final String codes = old.map((Device d) => d.name.split(' · ').first).join(' и ');
    return KvScreen(
      header: KvHeader(
        title: 'Устройства',
        subtitle: ty('${devices.length} в сети · ${old.length} ${KvFormat.plural(old.length, 'требует', 'требуют', 'требуют')} обновления'),
        status: old.isEmpty ? KvStatus.ok : KvStatus.warn,
        onBack: () => context.kvBack(AdminsPaths.admSystem),
        onMore: () => _menu(context, devices.length),
      ),
      foot: old.isEmpty
          ? null
          : AdmBusyButton(
              'Обновить ${old.length} ${KvFormat.plural(old.length, 'устройство', 'устройства', 'устройств')}',
              icon: KvIcons.download,
              onDone: () => showKvToast(
                context,
                title: 'Обновление отправлено',
                text: ty('$codes установ${old.length == 1 ? 'ит' : 'ят'} $current при простое'),
                kind: KvToastKind.ok,
              ),
            ),
      children: [
        AdmGrid(
          children: [
            KvKpi(value: '$fresh', label: 'Версия $current', status: KvStatus.ok),
            KvKpi(value: '${old.length}', label: oldVersion.isEmpty ? 'Устарели' : 'Версия $oldVersion', status: KvStatus.warn),
          ],
        ),
        KvList(
          children: [
            for (final Device d in devices)
              KvRow(
                icon: KvIcons.phone,
                iconStatus: d.version != current ? KvStatus.warn : null,
                title: d.name,
                subtitle: ty('${d.who} · приложение ${d.version}'),
                trailing: d.version != current ? const KvChip('Обновить', status: KvStatus.warn, dot: false) : null,
              ),
          ],
        ),
      ],
    );
  }

  void _menu(BuildContext context, int count) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Устройства',
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.wifi,
                title: 'Проверить связь со всеми',
                subtitle: 'Сеть KST-NS2-Field',
                onTap: () => showKvToast(
                  sheet,
                  title: ty('Все $count ${KvFormat.plural(count, 'устройство', 'устройства', 'устройств')} на связи'),
                  text: ty('Средний отклик 18 мс'),
                  kind: KvToastKind.ok,
                ),
              ),
              KvRow(
                icon: KvIcons.list,
                title: 'Системный журнал',
                subtitle: 'Подключения устройств',
                onTap: () => admCloseThen(sheet, () => screen.kvFade(AdminsPaths.admLog)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
