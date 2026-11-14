import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/kv.dart';
import '../../data/providers.dart';
import '../../data/repositories/inspection_repository.dart';
import 'inspect_actions.dart';
import 'inspect_providers.dart';

/// Узел «агрегат целиком» в маршруте сервера: в записи работы он передаётся без узла.
const String kWholeUnitNode = 'equipment';

/// Виды обслуживания по регламенту агрегата.
final maintenanceKindsProvider = FutureProvider.autoDispose.family<List<MaintenanceKind>, String>(
  (Ref ref, String unitId) => ref.watch(inspectionRepositoryProvider).maintenanceKinds(unitId),
);

/// Открывает лист «Работы» агрегата [unitId] поверх экрана [context]; после сохранения показывает уведомление.
Future<void> showWorksSheet(BuildContext context, String unitId) async {
  final String? done = await showKvSheet<String>(context, builder: (BuildContext _) => WorksSheet(unitId: unitId));
  if (done == null || !context.mounted) {
    return;
  }
  showKvToast(context, kind: KvToastKind.ok, icon: KvIcons.wrench, title: 'Работа записана', text: KvFormat.typo(done));
}

/// Лист «Работы» в осмотре: Обслужил / Заменил / Заметка, узел, вид обслуживания по регламенту и комментарий.
/// В осмотр ничего не уходит, пока инженер не нажал «Сохранить». Замена обнуляет наработку узла на сервере.
class WorksSheet extends ConsumerStatefulWidget {
  /// Создаёт лист для агрегата [unitId].
  const WorksSheet({super.key, required this.unitId});

  /// Агрегат.
  final String unitId;

  @override
  ConsumerState<WorksSheet> createState() => _WorksSheetState();
}

class _WorksSheetState extends ConsumerState<WorksSheet> {
  final TextEditingController _comment = TextEditingController();
  WorkKind _kind = WorkKind.maintenance;
  int _node = 0;
  int _code = 0;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  /// Чего не хватает для записи; null - можно сохранять.
  String? _missing(List<RouteStep> nodes) {
    if (_kind == WorkKind.replacement && (_node == 0 || _node > nodes.length)) {
      return 'Для замены выберите узел';
    }
    if (_kind == WorkKind.note && _comment.text.trim().isEmpty) {
      return 'Напишите текст заметки';
    }
    return null;
  }

  Future<void> _save(List<RouteStep> nodes, List<MaintenanceKind> codes) async {
    if (_busy || _missing(nodes) != null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final RouteStep? node = _node == 0 || _node > nodes.length ? null : nodes[_node - 1];
    final MaintenanceKind? code = _kind != WorkKind.maintenance || _code == 0 || _code > codes.length ? null : codes[_code - 1];
    try {
      final Inspection ins = await ensureInspection(ref, widget.unitId);
      await ref.read(inspectionRepositoryProvider).addWork(
            ins.id,
            widget.unitId,
            kind: _kind,
            node: node?.nodeId,
            comment: _comment.text,
            maintenanceCode: code?.code,
          );
      if (!mounted) {
        return;
      }
      final String where = node?.name ?? 'агрегат целиком';
      Navigator.of(context).pop(switch (_kind) {
        WorkKind.maintenance => 'Обслуживание${code == null ? '' : ' ${code.name}'} · $where',
        WorkKind.replacement => 'Замена · $where · ресурс узла считается заново',
        WorkKind.note => 'Заметка · $where',
      });
    } on KvApiException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } on Object {
      if (mounted) {
        setState(() => _error = 'Не удалось записать: нет ответа сервера. Проверьте связь и повторите.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final KvColors c = context.kv;
    final List<RouteStep> nodes = [
      for (final RouteStep s in ref.watch(routeProvider(widget.unitId)).value ?? const <RouteStep>[])
        if (s.nodeId != kWholeUnitNode) s,
    ];
    final List<MaintenanceKind> codes = ref.watch(maintenanceKindsProvider(widget.unitId)).value ?? const <MaintenanceKind>[];
    final String? missing = _missing(nodes);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: KvSheet(
        title: 'Работы',
        actions: [
          if (missing != null) Text(missing, style: t.caption.copyWith(color: c.text2), textAlign: TextAlign.center),
          KvButton('Сохранить', icon: KvIcons.check, loading: _busy, onPressed: missing == null ? () => _save(nodes, codes) : null),
        ],
        children: [
          KvSegment(
            items: [for (final WorkKind k in WorkKind.values) k.label],
            index: WorkKind.values.indexOf(_kind),
            onChanged: (int i) => setState(() => _kind = WorkKind.values[i]),
          ),
          Text(
            switch (_kind) {
              WorkKind.maintenance => 'Обслуживание попадёт в историю работ агрегата; вид по регламенту сдвигает срок следующего ТО.',
              WorkKind.replacement => 'Замена обнуляет наработку выбранного узла: ресурс считается заново с сегодняшнего дня.',
              WorkKind.note => 'Заметка попадёт в осмотр и отчёт. Состояние узла она не подтверждает.',
            },
            style: t.sm.copyWith(color: c.text2),
          ),
          const KvSectionLabel('Узел'),
          KvFilterChips(
            items: [
              if (_kind != WorkKind.replacement) const KvFilterItem('Агрегат целиком'),
              for (final RouteStep s in nodes) KvFilterItem(s.name),
            ],
            selected: _kind == WorkKind.replacement ? _node - 1 : _node,
            onSelected: (int i) => setState(() => _node = _kind == WorkKind.replacement ? i + 1 : i),
          ),
          if (_kind == WorkKind.maintenance && codes.isNotEmpty) ...[
            const KvSectionLabel('Вид по регламенту'),
            KvFilterChips(
              items: [const KvFilterItem('Без регламента'), for (final MaintenanceKind m in codes) KvFilterItem(m.name)],
              selected: _code,
              onSelected: (int i) => setState(() => _code = i),
            ),
          ],
          KvField(
            label: _kind == WorkKind.note ? 'Текст заметки' : 'Комментарий',
            placeholder: switch (_kind) {
              WorkKind.maintenance => 'Что сделано: подтянул фланцы, смазал подшипники',
              WorkKind.replacement => 'Что поставлено: номер, производитель',
              WorkKind.note => 'Что заметили',
            },
            controller: _comment,
            area: true,
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null) KvNote(text: _error!, tone: KvStatus.bad, icon: KvIcons.alert),
        ],
      ),
    );
  }
}
