import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'inspect_actions.dart';
import 'inspect_catalog.dart';
import 'inspect_providers.dart';
import 'scan_detail_screens.dart';
import 'scanner_screen.dart';
import 'widgets/inspect_camera.dart';

/// Новый дефект (b-defect; вручную - b-defect-manual): кадр с видео, тип и критичность, узел, правило, комментарий
/// и решение инженера. Подтверждение создаёт находку и возвращает на живое видео с уведомлением (b-scan-added).
class DefectScreen extends ConsumerStatefulWidget {
  /// Создаёт форму дефекта по признаку [label] агрегата [unitId]; [manual] - открыта из меню карточки.
  const DefectScreen({super.key, this.unitId = kInspectDefaultUnit, this.label = kDefaultSign, this.manual = false});

  /// Агрегат.
  final String unitId;

  /// Подпись рамки признака на кадре.
  final String label;

  /// Дефект добавляется вручную: «Отмена» и «Сохранить дефект» вместо «Не дефект» и «Подтвердить».
  final bool manual;

  @override
  ConsumerState<DefectScreen> createState() => _DefectScreenState();
}

class _DefectScreenState extends ConsumerState<DefectScreen> {
  late final DefectClass _cls = kDefectClasses[widget.label] ?? kDefectClasses.values.first;
  late final TextEditingController _comment = TextEditingController(text: _cls.comment);
  late int _kind = kDefectKinds.indexOf(_cls.kind).clamp(0, kDefectKinds.length - 1);
  int? _level;
  String? _nodeId;

  static const KvCamView _frame = KvCamView(k: 1.45, cx: 0.4, cy: 0.6, elementAspect: 16 / 9);

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String unitId = widget.unitId;
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    final Inspection? ins = ref.watch(activeInspectionProvider(unitId)).value;
    final RuleCheck? check = ref.watch(ruleCheckProvider((unitId: unitId, ruleId: _cls.ruleId))).value;
    final RuleDef? rule = (ref.watch(rulesProvider).value ?? const <RuleDef>[]).where((RuleDef r) => r.id == _cls.ruleId).firstOrNull;
    final Detection? det = (ref.watch(detectionsProvider(unitId)).value ?? const <Detection>[]).where((Detection d) => d.label == widget.label).firstOrNull;
    final int level = _level ?? ((rule?.severity ?? 3) - 1).clamp(0, kDefectLevels.length - 1);
    final List<EquipmentNode> nodes = unit?.nodes ?? const <EquipmentNode>[];
    final String nodeId = _nodeId ?? _cls.nodeId;
    final String nodeName = nodes.where((EquipmentNode n) => n.id == nodeId).firstOrNull?.name ?? _cls.node;
    final String back = widget.manual ? EngineerInspectPaths.card(unitId) : EngineerInspectPaths.scanDefectFor(unitId, widget.label);
    final List<String> sources = [
      if (check?.conditions.any((RuleCondition c) => c.source == 'camera' && c.state == 'met') ?? false) 'Камера',
      if (check?.conditions.any((RuleCondition c) => c.source == 'sensor' && c.state == 'met') ?? false) 'датчики',
    ];
    final String conditions = check == null ? '' : check.count.replaceFirst(RegExp(r'^Выполнен[оа]? '), '');
    return KvScreen(
      header: KvHeader(
        title: 'Новый дефект',
        subtitle: KvFormat.typo('${unit?.code ?? unitId} · ${ins == null ? 'новый осмотр' : 'осмотр ${ins.id}'}'),
        onBack: () => context.kvBack(back),
      ),
      foot: Row(
        children: widget.manual
            ? [
                Expanded(child: KvButton('Отмена', kind: KvButtonKind.secondary, onPressed: () => context.kvBack(back))),
                const SizedBox(width: KvSpace.s3),
                Expanded(child: KvButton('Сохранить дефект', wait: true, onPressed: () => _save(nodeName, level, check))),
              ]
            : [
                Expanded(
                  child: KvButton('Не дефект', kind: KvButtonKind.secondary, onPressed: () => dismissSign(context, ref, unitId, widget.label)),
                ),
                const SizedBox(width: KvSpace.s3),
                Expanded(child: KvButton('Подтвердить', wait: true, onPressed: () => _save(nodeName, level, check))),
              ],
      ),
      children: [
        CamFrame(
          view: _frame,
          aspectRatio: 16 / 9,
          boxes: [if (det != null) arBoxOf(_frame, detRect(det), kind: KvArKind.defect)],
          tag: 'Кадр с видео · ${check?.frameTime ?? ''}',
          onRetake: () => context.kvBack(EngineerInspectPaths.scanDefectFor(unitId, widget.label)),
        ),
        _TypeAndLevel(kind: _kind, level: level, onKind: (int i) => setState(() => _kind = i), onLevel: (int i) => setState(() => _level = i)),
        KvList(
          children: [
            KvRow(icon: KvIcons.box, title: nodeName, subtitle: 'Узел · уточнить', onTap: () => _pickNode(nodes, nodeId)),
            KvRow(
              icon: KvIcons.activity,
              iconStatus: KvStatus.bad,
              title: '${_cls.ruleId} · ${_cls.ruleShort}',
              subtitle: sources.isEmpty ? conditions : '${sources.join(' + ')}: $conditions',
              onTap: () => context.kvPush(EngineerInspectPaths.rule(_cls.ruleId, unitId)),
            ),
          ],
        ),
        KvField(
          label: 'Комментарий',
          controller: _comment,
          area: true,
          end: KvIcons.mic,
          fieldKey: const ValueKey<String>('defect-comment'),
          onEnd: () => showKvToast(
            context,
            kind: KvToastKind.info,
            icon: KvIcons.mic,
            title: 'Диктовка включена',
            text: 'Говорите, текст появится в комментарии',
          ),
        ),
      ],
    );
  }

  /// Лист выбора узла (b-defect-node): узлы агрегата с наработкой, выбранный отмечен галочкой.
  Future<void> _pickNode(List<EquipmentNode> nodes, String current) async {
    final String? picked = await showKvSheet<String>(
      context,
      builder: (BuildContext sheet) {
        String selected = current;
        return StatefulBuilder(
          builder: (BuildContext sheet, StateSetter setSheet) => KvSheet(
            title: 'Узел агрегата',
            actions: [KvButton('Готово', onPressed: () => Navigator.of(sheet).pop(selected))],
            children: [
              KvList(
                noIcons: true,
                children: [
                  for (final EquipmentNode n in nodes.take(6)) _NodeRow(node: n, on: n.id == selected, onTap: () => setSheet(() => selected = n.id)),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _nodeId = picked);
    }
  }

  /// Создаёт находку в идущем осмотре и возвращает на живое видео с уведомлением мастеру.
  Future<void> _save(String nodeName, int level, RuleCheck? check) async {
    final String unitId = widget.unitId;
    final Inspection ins = await ensureInspection(ref, unitId);
    final Finding f = await ref.read(inspectionRepositoryProvider).addFinding(
          ins.id,
          node: nodeName,
          title: _cls.findingTitle,
          ruleId: _cls.ruleId,
          severity: level + 1,
          comment: _comment.text.trim().isEmpty ? null : _comment.text.trim(),
          evidence: [for (final RuleCondition c in check?.conditions ?? const <RuleCondition>[]) if (c.state == 'met') c.value],
        );
    final Person? master = (await ref.read(peopleProvider.future))['master'];
    if (!mounted) {
      return;
    }
    showKvToast(
      context,
      kind: KvToastKind.ok,
      title: 'Дефект зафиксирован · ${f.id}',
      text: 'Ждёт подтверждения мастера. ${master == null ? 'Мастер' : master.name} получила уведомление.',
    );
    backToScanner(context, unitId);
  }
}

/// Карточка типа и критичности дефекта (.b-form): чипы типа и сегмент критичности.
class _TypeAndLevel extends StatelessWidget {
  const _TypeAndLevel({required this.kind, required this.level, required this.onKind, required this.onLevel});

  final int kind;
  final int level;
  final ValueChanged<int> onKind;
  final ValueChanged<int> onLevel;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    return KvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Тип дефекта · определён автоматически', style: t.label),
          const SizedBox(height: KvSpace.s3),
          KvFilterChips(items: [for (final String k in kDefectKinds) KvFilterItem(k)], selected: kind, onSelected: onKind, spacing: 6),
          const SizedBox(height: KvSpace.s3),
          Text('Критичность', style: t.label),
          const SizedBox(height: KvSpace.s3),
          KvSegment(items: kDefectLevels, index: level, onChanged: onLevel),
        ],
      ),
    );
  }
}

/// Строка узла в листе выбора (.b-radio .row): выбранный - синий заголовок и галочка.
class _NodeRow extends StatelessWidget {
  const _NodeRow({required this.node, required this.on, required this.onTap});

  final EquipmentNode node;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final double? hours = node.hours;
    final String sub = node.norm != null && hours != null
        ? '${KvFormat.num(hours)} из ${KvFormat.num(node.norm)} ч'
        : hours == null
            ? 'Наработка не учитывается'
            : 'Наработка ${KvFormat.num(hours)} ч';
    return KvRow(
      title: node.name,
      titleWidget: AnimatedDefaultTextStyle(
        duration: KvMotion.std,
        style: context.kvText.bodyM.copyWith(height: 1.3, color: on ? c.brand : c.text),
        child: Text(node.name),
      ),
      subtitle: KvFormat.typo(sub),
      chevron: false,
      onTap: onTap,
      trailing: AnimatedOpacity(
        opacity: on ? 1 : 0,
        duration: context.kvReduceMotion ? Duration.zero : KvMotion.std,
        curve: KvMotion.ease,
        child: KvIcon(KvIcons.check, size: 22, color: c.brand),
      ),
    );
  }
}
