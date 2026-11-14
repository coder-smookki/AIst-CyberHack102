import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/adm_widgets.dart';

/// Вид записи журнала безопасности: login, fail, change, block (по полю kind или уровню).
String secKind(SecLogEntry e) => e.kind.isNotEmpty
    ? e.kind
    : switch (e.level) {
        'bad' => 'block',
        'warn' => 'fail',
        _ => 'change',
      };

/// Значок, тон и подпись вида записи журнала безопасности.
(KvIcons, KvStatus?, String) secKindStyle(String kind) => switch (kind) {
  'login' => (KvIcons.key, KvStatus.ok, 'Вход'),
  'fail' => (KvIcons.alert, KvStatus.warn, 'Ошибка входа'),
  'block' => (KvIcons.ban, KvStatus.bad, 'Блокировка'),
  _ => (KvIcons.userPlus, null, 'Изменение'),
};

/// Журнал безопасности (sec-log): входы, ошибки входа и изменения учётных записей за сегодня, выгрузка.
class SecLogScreen extends ConsumerStatefulWidget {
  /// Создаёт экран; [open] - вид записи, которую открыть сразу (fail - e-slog-fail).
  const SecLogScreen({super.key, this.open});

  /// Вид записи для открытия при переходе.
  final String? open;

  @override
  ConsumerState<SecLogScreen> createState() => _SecLogScreenState();
}

class _SecLogScreenState extends ConsumerState<SecLogScreen> {
  int _filter = 0;
  bool _opened = false;

  void _maybeOpen(List<SecLogEntry> log) {
    if (_opened || widget.open == null || log.isEmpty) {
      return;
    }
    _opened = true;
    final SecLogEntry? e = log.where((SecLogEntry x) => secKind(x) == widget.open).firstOrNull;
    if (e != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showSecLogEntry(context, e, dayMonth: KvFormat.dayMonth(ref.read(clockProvider).now()));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<SecLogEntry>> async = ref.watch(securityLogProvider);
    final List<SecLogEntry> log = async.value ?? const <SecLogEntry>[];
    _maybeOpen(log);
    final List<SecLogEntry> today = log.where((SecLogEntry e) => e.time.contains(':')).toList();
    final int logins = today.where((SecLogEntry e) => secKind(e) == 'login').length;
    final int failed = today
        .where((SecLogEntry e) => secKind(e) == 'fail')
        .fold<int>(0, (int a, SecLogEntry e) => a + (int.tryParse(RegExp(r'^\d+').stringMatch(e.title ?? '') ?? '') ?? 1));
    final int changes = today.where((SecLogEntry e) => secKind(e) == 'change' || secKind(e) == 'block').length;
    final List<SecLogEntry> shown = switch (_filter) {
      1 => log.where((SecLogEntry e) => secKind(e) == 'login').toList(),
      2 => log.where((SecLogEntry e) => secKind(e) == 'fail').toList(),
      3 => log.where((SecLogEntry e) => secKind(e) == 'change' || secKind(e) == 'block').toList(),
      _ => log,
    };
    final String date = KvFormat.date(ref.watch(clockProvider).now());
    return KvScreen(
      header: KvRootHeader(title: 'Журнал безопасности', subtitle: 'Сегодня · $date'),
      children: [
        AdmGrid(
          columns: 3,
          gap: KvSpace.s2,
          children: [
            KvKpi(value: '$logins', label: KvFormat.plural(logins, 'Вход', 'Входа', 'Входов'), status: KvStatus.ok),
            KvKpi(value: '$failed', label: KvFormat.plural(failed, 'Неудачный', 'Неудачных', 'Неудачных'), status: KvStatus.warn),
            KvKpi(value: '$changes', label: KvFormat.plural(changes, 'Изменение', 'Изменения', 'Изменений'), status: KvStatus.info),
          ],
        ),
        KvFilterChips(
          items: const [KvFilterItem('Все'), KvFilterItem('Входы'), KvFilterItem('Ошибки'), KvFilterItem('Изменения')],
          selected: _filter,
          onSelected: (int i) => setState(() => _filter = i),
        ),
        if (!async.hasValue)
          const KvSkeleton.card(height: 420)
        else
          KvList(
            children: [
              for (final SecLogEntry e in shown)
                KvRow(
                  icon: secKindStyle(secKind(e)).$1,
                  iconStatus: secKindStyle(secKind(e)).$2,
                  title: e.title ?? e.text,
                  subtitle: '${e.time} · ${e.who}',
                  onTap: () => showSecLogEntry(context, e, dayMonth: KvFormat.dayMonth(ref.read(clockProvider).now())),
                ),
            ],
          ),
        KvButton(
          'Выгрузить журнал',
          kind: KvButtonKind.secondary,
          icon: KvIcons.download,
          onPressed: () => _export(context, date, log.length),
        ),
      ],
    );
  }

  void _export(BuildContext context, String date, int n) {
    final String file = 'journal_${date.replaceAll('.', '-')}';
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Выгрузить журнал',
        children: [
          AdmCaption('За $date · $n ${KvFormat.plural(n, 'запись', 'записи', 'записей')}'),
          KvList(
            children: [
              KvRow(
                icon: KvIcons.filePdf,
                iconStatus: KvStatus.bad,
                title: 'PDF',
                subtitle: 'Для подписи и архива',
                onTap: () => showKvToast(
                  sheet,
                  title: 'Журнал выгружен',
                  text: ty('$file.pdf · 84 КБ'),
                  kind: KvToastKind.ok,
                  icon: KvIcons.filePdf,
                ),
              ),
              KvRow(
                icon: KvIcons.fileXls,
                iconStatus: KvStatus.ok,
                title: 'Excel',
                subtitle: 'Для анализа',
                onTap: () => showKvToast(
                  sheet,
                  title: 'Журнал выгружен',
                  text: ty('$file.xlsx · 22 КБ'),
                  kind: KvToastKind.ok,
                  icon: KvIcons.fileXls,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Запись журнала безопасности (e-slog-*): вид, время, подробности и переход к учётной записи.
void showSecLogEntry(BuildContext context, SecLogEntry e, {required String dayMonth}) {
  final BuildContext screen = context;
  final (KvIcons _, KvStatus? tone, String label) = secKindStyle(secKind(e));
  showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => KvSheet(
      title: e.title ?? e.text,
      actions: [
        if (e.userId != null)
          KvButton(
            'Открыть учётную запись',
            kind: KvButtonKind.secondary,
            icon: KvIcons.user,
            onPressed: () => admCloseThen(sheet, () => screen.kvPush(AdminsPaths.user(e.userId!))),
          ),
      ],
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: KvChip('$label · ${e.time.contains(':') ? '$dayMonth ' : ''}${e.time}', status: tone ?? KvStatus.info),
        ),
        KvCard(style: KvCardStyle.outline, child: KvKeyValues(e.details.isEmpty ? [('Событие', e.text), ('Кто', e.who)] : e.details)),
      ],
    ),
  );
}
