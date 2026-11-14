import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/adm_widgets.dart';

/// Значок, тон и подпись уровня записи системного журнала.
(KvIcons, KvStatus, String) admLevel(String level) => switch (level) {
  'warn' => (KvIcons.alert, KvStatus.warn, 'Предупреждение'),
  'bad' => (KvIcons.alertCircle, KvStatus.bad, 'Ошибка'),
  'ok' => (KvIcons.checkCircle, KvStatus.ok, 'Успешно'),
  _ => (KvIcons.info, KvStatus.info, 'Инфо'),
};

/// Системный журнал (adm-log): события сервера за сегодня с отбором по важности.
class AdmLogScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const AdmLogScreen({super.key});

  @override
  ConsumerState<AdmLogScreen> createState() => _AdmLogScreenState();
}

class _AdmLogScreenState extends ConsumerState<AdmLogScreen> {
  int _filter = 0;

  static bool _important(SysLogEntry e) => e.level == 'bad' || e.level == 'warn';

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<SysLogEntry>> async = ref.watch(syslogProvider);
    final List<SysLogEntry> all = async.value ?? const <SysLogEntry>[];
    final int important = all.where(_important).length;
    final List<SysLogEntry> shown = switch (_filter) {
      1 => all.where(_important).toList(),
      2 => all.where((SysLogEntry e) => !_important(e)).toList(),
      _ => all,
    };
    final String date = KvFormat.date(ref.watch(clockProvider).now());
    return KvScreen(
      header: KvRootHeader(title: 'Системный журнал', subtitle: 'Сегодня · $date'),
      children: [
        KvFilterChips(
          items: [
            KvFilterItem('Все', count: '${all.length}'),
            KvFilterItem('Важные', count: '$important'),
            KvFilterItem('Инфо', count: '${all.length - important}'),
          ],
          selected: _filter,
          onSelected: (int i) => setState(() => _filter = i),
        ),
        if (!async.hasValue)
          const KvSkeleton.card(height: 400)
        else
          KvList(
            children: [
              for (final SysLogEntry e in shown)
                KvRow(
                  icon: admLevel(e.level).$1,
                  iconStatus: admLevel(e.level).$2,
                  title: ty(e.text),
                  titleWidget: admWrapTitle(context, ty(e.text)),
                  subtitle: '${e.time} · ${e.source}',
                  onTap: () => showSysLogEntry(context, e, date),
                ),
            ],
          ),
      ],
    );
  }
}

/// Запись системного журнала (e-alog-*): уровень, текст, подробности и переход к связанному объекту.
void showSysLogEntry(BuildContext context, SysLogEntry e, String date) {
  final BuildContext screen = context;
  final (KvIcons _, KvStatus status, String label) = admLevel(e.level);
  final (String, String)? link = switch (e.ref) {
    final String r when r.startsWith('source:') => ('Открыть источник', AdminsPaths.source(r.substring(7))),
    final String r when r.startsWith('tags:') => (
      'Открыть теги ${r.substring(5) == 'N-101' ? 'Н-101' : r.substring(5).replaceFirst('AMS', 'АМС')}',
      AdminsPaths.tags(r.substring(5)),
    ),
    'maint' => ('Обновления и резерв', AdminsPaths.eAdmMaint),
    _ => null,
  };
  showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => KvSheet(
      title: '${e.source} · ${e.time}',
      actions: [
        if (link != null)
          KvButton(link.$1, kind: KvButtonKind.secondary, onPressed: () => admCloseThen(sheet, () => screen.kvPush(link.$2)))
        else
          KvButton(
            'Копировать запись',
            kind: KvButtonKind.secondary,
            icon: KvIcons.copy,
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: '$date ${e.time} · ${e.source} · ${e.text}')));
              showKvToast(sheet, title: 'Запись скопирована', text: '${e.time} · ${e.source}', kind: KvToastKind.ok);
            },
          ),
      ],
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: KvChip(label, status: status),
        ),
        Text(ty(e.text), style: sheet.kvText.bodyM),
        KvCard(style: KvCardStyle.outline, child: KvKeyValues([('Время', '$date ${e.time}'), ...e.details, ('Узел', 'КСТ-СРВ-02')])),
      ],
    ),
  );
}
