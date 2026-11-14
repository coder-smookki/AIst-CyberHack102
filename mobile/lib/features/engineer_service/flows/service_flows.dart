import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../service_common.dart';

/// Строки диалога о новых правах: что добавилось к роли сотрудника.
const Map<String, String> _addedLabels = {
  'confirm': 'Находки: подтверждение и закрытие',
  'reports_all': 'Отчёты смены и участка',
  'plan': 'План ТО: планирование работ',
  'mode': 'Смена режима агрегата',
};

/// Уведомление о новом задании мастера (f-b-eng-push): номер, агрегат и срок, срочность, кто назначил и показания
/// сработавшего правила; касание открывает диагностику по правилам.
void showTaskPush(BuildContext context, {required InspectionTask task, required Equipment unit}) {
  final String due = task.due.contains(', ') ? task.due.split(', ').last : task.due;
  final String rule = RegExp(r'[RSV]\d{2}').firstMatch('${task.title} ${task.reason}')?.group(0) ?? '';
  final Reading? vib = unit.readings['vib1x'];
  final Reading? bearing = unit.readings['tBearing'];
  final String readings = vib == null || bearing == null
      ? task.reason
      : 'вибрация 1X ${KvFormat.num(vib.value, vib.digits)} ${vib.unit}, подшипник ${KvFormat.num(bearing.value, bearing.digits)} ${bearing.unit}';
  final String head = '${task.priority == 'urgent' ? 'Срочно · ' : ''}${ServiceFormat.short(task.from)}.';
  showKvToast(
    context,
    kind: KvToastKind.warn,
    icon: KvIcons.clipboard,
    title: KvFormat.typo('Задание ${task.id} · осмотр ${unit.code} до $due'),
    text: KvFormat.typo(rule.isEmpty ? '$head $readings.' : '$head Сработало $rule: $readings.'),
    onTap: () => context.kvPush(rule.isEmpty ? EngineerServicePaths.task(task.id) : EngineerInspectPaths.diagnostics),
  );
}

/// Диалог «Роль изменена» (f-d-role-changed): администратор ИБ назначил новую роль; перечислены добавленные права,
/// «Открыть разделы» обновляет сеанс и открывает объекты с панелью вкладок новой роли.
Future<void> showRoleChangedDialog(BuildContext context, {required String roleName, required List<String> added}) {
  return showKvDialog<void>(
    context,
    dismissible: false,
    builder: (BuildContext dialog) => _RoleChangedDialog(roleName: roleName, added: added),
  );
}

class _RoleChangedDialog extends ConsumerStatefulWidget {
  const _RoleChangedDialog({required this.roleName, required this.added});

  final String roleName;
  final List<String> added;

  @override
  ConsumerState<_RoleChangedDialog> createState() => _RoleChangedDialogState();
}

class _RoleChangedDialogState extends ConsumerState<_RoleChangedDialog> {
  bool _busy = false;

  Future<void> _open() async {
    setState(() => _busy = true);
    final NavigatorState nav = Navigator.of(context);
    final AuthSession? current = ref.read(sessionProvider);
    try {
      if (current != null) {
        ref.read(sessionProvider.notifier).restore(await ref.read(authRepositoryProvider).loginWithBiometrics(current.refreshToken));
      }
    } on KvApiException {
      if (mounted) {
        setState(() => _busy = false);
      }
      return;
    }
    if (!mounted) {
      return;
    }
    nav.pop();
    context.kvFade(EngineerServicePaths.fDSeniorHome);
  }

  @override
  Widget build(BuildContext context) {
    return KvDialog(
      icon: KvIcons.key,
      title: 'Роль изменена',
      text: 'Администратор ИБ назначил вам роль «${widget.roleName}». Набор разделов обновлён.',
      vertical: true,
      body: Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final String key in widget.added) ...[_AddedRow(text: _addedLabels[key] ?? key), const SizedBox(height: KvSpace.s2)],
            const _AddedRow(text: 'Осмотры, диагностика и ассистент - без изменений', same: true),
          ],
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: KvButton('Открыть разделы', loading: _busy, onPressed: _busy ? null : _open),
        ),
      ],
    );
  }
}

/// Строка изменения прав (.f-added-row): добавленное право на сером поле или неизменная часть серым текстом.
class _AddedRow extends StatelessWidget {
  const _AddedRow({required this.text, this.same = false});

  final String text;
  final bool same;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Container(
      padding: same ? const EdgeInsets.symmetric(horizontal: 12, vertical: 2) : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: same ? null : BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(KvRadius.sm)),
      child: Row(
        children: [
          KvIcon(same ? KvIcons.check : KvIcons.plus, size: 18, color: c.brand),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              textAlign: TextAlign.left,
              style: same
                  ? t.caption.copyWith(height: 1.3, color: c.text2)
                  : t.sm.copyWith(fontWeight: FontWeight.w500, height: 1.3, color: c.text),
            ),
          ),
        ],
      ),
    );
  }
}
