import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/adm_widgets.dart';

/// Система (adm-system): цеховой сервер, службы, резерв, обновление и устройства.
class AdmSystemScreen extends ConsumerWidget {
  /// Создаёт экран.
  const AdmSystemScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerStatus? s = ref.watch(serverStatusProvider).value;
    final List<DataSource> sources = ref.watch(sourcesProvider).value ?? const <DataSource>[];
    final List<RecognitionModel> models = ref.watch(modelsProvider).value ?? const <RecognitionModel>[];
    final List<Backup> backups = ref.watch(backupsProvider).value ?? const <Backup>[];
    final List<Device> devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final DataSource? opc = sources.where((DataSource x) => x.id == 'src-opc').firstOrNull;
    final DataSource? vib = sources.where((DataSource x) => x.id == 'src-vib').firstOrNull;
    final DataSource? slow = sources.where((DataSource x) => x.status == 'warn').firstOrNull;
    final int active = models.where((RecognitionModel m) => m.status == 'active').length;
    final String current = s?.version ?? '';
    final int outdated = devices.where((Device d) => d.version.isNotEmpty && d.version != current).length;
    final String oldVersion = devices.where((Device d) => d.version.isNotEmpty && d.version != current).firstOrNull?.version ?? '';
    final Backup? last = backups.firstOrNull;

    return KvScreen(
      header: KvRootHeader(
        title: 'Система',
        subtitle: s == null ? ' ' : ty('${s.name.replaceFirst('Цеховой сервер ', '')} · работает ${s.uptime}'),
        status: KvStatus.ok,
      ),
      children: [
        if (slow != null)
          AdmBoldNote(
            tone: KvStatus.warn,
            icon: KvIcons.alert,
            bold: slow.name,
            text: 'Задержка опроса ${slow.latency}, норма до 1 с',
            onTap: () => context.kvPush(AdminsPaths.source(slow.id)),
          ),
        if (s == null)
          const KvSkeleton.card(height: 150)
        else
          KvCard(
            onTap: () => context.kvPush(AdminsPaths.eAdmServer),
            semanticLabel: 'Цеховой сервер',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AdmTop(icon: KvIcons.server, status: KvStatus.ok, title: 'Цеховой сервер', subtitle: '${s.ip} · версия ${s.version}'),
                AdmDividedRow(
                  top: 14,
                  gap: admNarrow(context) ? 10 : 14,
                  children: [
                    AdmMeter(label: 'ЦП', pct: s.cpu),
                    AdmMeter(label: 'Память', pct: s.ram),
                    AdmMeter(label: 'Диск', pct: s.disk),
                  ],
                ),
              ],
            ),
          ),
        const KvSectionLabel('Службы'),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.plug,
              iconStatus: KvStatus.parse(opc?.status ?? 'ok'),
              title: 'Сервер ввода-вывода',
              subtitle: ty('OPC UA · опрос ${opc?.poll ?? '1 с'}'),
              value: ty(opc?.enabled == false ? 'выкл.' : (opc?.latency ?? '120 мс')),
              onTap: () => context.kvPush(AdminsPaths.source('src-opc')),
            ),
            KvRow(
              icon: KvIcons.vibrate,
              iconStatus: KvStatus.parse(vib?.status ?? 'warn'),
              title: 'Шлюз вибродатчиков',
              subtitle: ty('Modbus · опрос ${vib?.poll ?? '2 с'}'),
              value: ty(vib?.enabled == false ? 'выкл.' : (vib?.latency ?? '2,4 с')),
              onTap: () => context.kvPush(AdminsPaths.source('src-vib')),
            ),
            KvRow(
              icon: KvIcons.cpu,
              iconStatus: KvStatus.ok,
              title: 'Распознавание',
              subtitle: ty('$active ${KvFormat.plural(active, 'модель', 'модели', 'моделей')} · 24 кадр/с'),
              value: ty('42 мс'),
              onTap: () => context.kvFade(AdminsPaths.admModels),
            ),
            KvRow(
              icon: KvIcons.database,
              iconStatus: KvStatus.ok,
              title: 'База данных',
              subtitle: ty('38 ГБ · запись без ошибок'),
              value: ty('4 мс'),
              onTap: () => context.kvPush(AdminsPaths.eAdmServer),
            ),
          ],
        ),
        AdmGrid(
          children: [
            KvActionCard(
              icon: KvIcons.archive,
              status: KvStatus.ok,
              title: 'Резерв',
              subtitle: last == null
                  ? null
                  : ty('${last.date == (s?.lastBackup.split(' ').first ?? '') ? 'Сегодня' : last.date} ${last.time} · ${last.size}'),
              onTap: () => context.kvPush(AdminsPaths.eAdmMaint),
            ),
            KvActionCard(
              icon: KvIcons.download,
              title: 'Обновление',
              subtitle: s?.updateAvailable == null ? 'Установлена последняя версия' : 'Версия ${s!.updateAvailable} готова',
              onTap: () => context.kvPush(AdminsPaths.eAdmMaint),
            ),
          ],
        ),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.phone,
              title: 'Устройства',
              subtitle: ty('${devices.length} в сети${outdated > 0 ? ' · $outdated на версии $oldVersion' : ''}'),
              onTap: () => context.kvPush(AdminsPaths.eAdmDevices),
            ),
          ],
        ),
      ],
    );
  }
}
