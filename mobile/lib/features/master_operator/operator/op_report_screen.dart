import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/navigation/kv_page.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../master/master_finding_sheets.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_frame.dart';

/// Черновик сообщения сценария А: что оператор отметил у АМС-2 в 06:40.
const List<String> _draftSigns = ['Течь', 'Шум или стук'];

/// Текст черновика сценария А.
const String _draftText = 'Течь под агрегатом, повышенный шум';

/// Вырез кадра камеры для агрегата: у АМС-2 - пол и лужа, у остальных - узел уплотнения.
MoFrameCrop opCropOf(String unitId) => unitId == 'AMS-2' ? MoFrameCrop.ams2 : MoFrameCrop.n101;

/// Сообщение о неисправности мастеру: агрегат, признаки, комментарий и кадр камеры по желанию.
///
/// Без [unitId] (центральная кнопка панели) открывается черновик сценария А по АМС-2 с отмеченными признаками
/// и кадром 06:39; с [unitId] - пустое сообщение по агрегату. Без признаков отправка не проходит.
class OpReportScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const OpReportScreen({super.key, this.unitId});

  /// Агрегат пустого сообщения или null - черновик сценария.
  final String? unitId;

  @override
  ConsumerState<OpReportScreen> createState() => _OpReportScreenState();
}

class _OpReportScreenState extends ConsumerState<OpReportScreen> {
  late final bool _draft = widget.unitId == null;
  late String _unitId = widget.unitId ?? 'AMS-2';
  late final Set<String> _signs = _draft ? {..._draftSigns} : <String>{};
  late final TextEditingController _text = TextEditingController(text: _draft ? _draftText : '');
  late String? _photo = _draft ? '06:39' : null;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _close() => context.kvBack(widget.unitId == null ? MasterOperatorPaths.opObjects : MasterOperatorPaths.opUnit(widget.unitId!));

  Future<void> _camera() async {
    final bool? shot = await context.kvUp<bool>(MasterOperatorPaths.dOpCamera);
    if (shot == true && mounted) {
      setState(() => _photo = KvFormat.time(ref.read(clockProvider).now()));
    }
  }

  Future<void> _send(List<String> kinds) async {
    if (_signs.isEmpty) {
      showKvToast(
        context,
        kind: KvToastKind.warn,
        icon: KvIcons.alert,
        title: 'Выберите, что заметили',
        text: 'Отметьте хотя бы один признак: течь, шум, вибрация, нагрев, запах.',
      );
      return;
    }
    final String author = ref.read(sessionProvider)?.user.name ?? 'Оператор';
    final List<String> ordered = [
      for (final String k in kinds)
        if (_signs.contains(k)) k,
    ];
    final FaultReport r = await ref
        .read(workflowRepositoryProvider)
        .reportFault(unitId: _unitId, kind: ordered.join(', '), text: _text.text.trim(), author: author);
    if (mounted) {
      context.pushReplacement(
        MasterOperatorPaths.reportSent(r.id, photo: _photo != null),
        extra: const KvNavExtra(transition: KvTransition.push),
      );
    }
  }

  Future<void> _pick(List<Equipment> units) async {
    final String? id = await showKvSheet<String>(
      context,
      builder: (BuildContext sheet) => _PickUnitSheet(units: units, selected: _unitId),
    );
    if (id != null && mounted) {
      setState(() => _unitId = id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final List<String> kinds = ref.watch(_faultKindsProvider).value ?? const <String>[];
    final Equipment? u = units.where((Equipment x) => x.id == _unitId).firstOrNull;
    return KvScreen(
      header: KvHeader(
        title: 'Новое сообщение',
        subtitle: 'О неисправности · мастеру сразу',
        leading: KvRoundButton(icon: KvIcons.close, onPressed: _close, semanticLabel: 'Закрыть'),
      ),
      foot: KvButton('Отправить мастеру', icon: KvIcons.send, wait: true, onPressed: () => _send(kinds)),
      children: [
        const MoLabel('Агрегат'),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.box,
              title: u?.code ?? ' ',
              subtitle: u == null ? null : KvFormat.typo('${u.kind} · ${u.location}'),
              onTap: units.isEmpty ? null : () => _pick(units),
            ),
          ],
        ),
        const MoLabel('Что заметили'),
        KvFilterChips.multi(
          items: [for (final String k in kinds) KvFilterItem(k)],
          selectedSet: {
            for (int i = 0; i < kinds.length; i++)
              if (_signs.contains(kinds[i])) i,
          },
          onSelected: (int i) => setState(() => _signs.contains(kinds[i]) ? _signs.remove(kinds[i]) : _signs.add(kinds[i])),
        ),
        KvField(
          label: 'Комментарий',
          controller: _text,
          placeholder: 'Где, когда, что слышно или видно',
          area: true,
          fieldKey: const ValueKey<String>('op-report-text'),
        ),
        const MoLabel('Кадр с камеры · по желанию'),
        if (_photo != null)
          MoFrame(
            crop: opCropOf(_unitId),
            chip: 'Кадр $_photo',
            action: KvRoundButton(
              icon: KvIcons.camera,
              iconSize: 22,
              variant: KvRoundVariant.glass,
              onPressed: _camera,
              semanticLabel: 'Переснять',
            ),
          )
        else
          KvButton('Снять кадр камерой', kind: KvButtonKind.secondary, icon: KvIcons.camera, onPressed: _camera),
      ],
    );
  }
}

/// Список признаков неисправности с сервера.
final FutureProvider<List<String>> _faultKindsProvider = FutureProvider<List<String>>(
  (Ref ref) => ref.watch(workflowRepositoryProvider).faultKinds(),
);

/// Лист выбора агрегата сообщения: строки-радио и подсказка про шильдик; «Выбрать» возвращает агрегат.
class _PickUnitSheet extends StatefulWidget {
  const _PickUnitSheet({required this.units, required this.selected});

  final List<Equipment> units;
  final String selected;

  @override
  State<_PickUnitSheet> createState() => _PickUnitSheetState();
}

class _PickUnitSheetState extends State<_PickUnitSheet> {
  late String _id = widget.selected;

  @override
  Widget build(BuildContext context) {
    return KvSheet(
      title: 'Агрегат',
      actions: [KvButton('Выбрать', onPressed: () => Navigator.of(context).pop(_id))],
      children: [
        KvList(
          children: [
            for (final Equipment u in widget.units)
              MoRadioRow(
                icon: KvIcons.box,
                title: KvFormat.typo('${u.code} · ${u.modelShort}'),
                subtitle: u.location,
                on: u.id == _id,
                onTap: () => setState(() => _id = u.id),
              ),
          ],
        ),
        const KvNote(icon: KvIcons.scan, text: 'Агрегат можно выбрать и по шильдику: наведите камеру на табличку.'),
      ],
    );
  }
}

/// Сообщение отправлено: результат, кто получил сообщение, переход к пульту или к статусу сообщения.
class OpReportSentScreen extends ConsumerWidget {
  /// Создаёт экран сообщения [reportId]; [photo] - к сообщению приложен кадр.
  const OpReportSentScreen({super.key, required this.reportId, this.photo = false});

  /// Номер сообщения.
  final String reportId;

  /// Кадр приложен.
  final bool photo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final List<FaultReport> reports = ref.watch(faultReportsProvider(null)).value ?? const <FaultReport>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final Map<String, Person> people = ref.watch(peopleProvider).value ?? const <String, Person>{};
    final FaultReport? r = reports.where((FaultReport x) => x.id == reportId).firstOrNull;
    final String code = units.where((Equipment u) => u.id == r?.unitId).firstOrNull?.code ?? r?.unitId ?? '';
    final List<String> signs = r == null
        ? const <String>[]
        : (r.id == 'S-077'
              ? _draftSigns
              : [
                  for (final String s in r.kind.split(', '))
                    if (s.isNotEmpty) s,
                ]);
    final String time = r?.time ?? '';
    final String text = '$code · ${signs.join(', ').toLowerCase()}${photo ? ' · кадр приложен' : ''}. Ответ мастера придёт уведомлением.';
    final Widget ok = KvIcon(KvIcons.checkCircle, size: 22, color: c.ok);
    final Person? master = people['master'];
    final Person? engineer = people['engineer'];
    return KvScreen(
      header: KvHeader(title: reportId, subtitle: 'Отправлено · $time', status: KvStatus.ok),
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KvButton('Готово', onPressed: () => moGoTab(context, MasterOperatorPaths.opObjects)),
          const SizedBox(height: KvSpace.s2),
          KvButton(
            'Открыть сообщение',
            kind: KvButtonKind.ghost,
            onPressed: () => context.go(MasterOperatorPaths.reportStatus(reportId), extra: const KvNavExtra(transition: KvTransition.push)),
          ),
        ],
      ),
      children: [
        MoResult(status: true, iconSize: 38, title: 'Сообщение отправлено', text: r == null ? null : text),
        const MoLabel('Кто получил'),
        KvList(
          children: [
            if (master != null)
              KvRow(avatar: master.name, title: master.name, subtitle: 'Мастер смены · доставлено $time', trailing: ok, chevron: false),
            if (engineer != null)
              KvRow(
                avatar: engineer.name,
                title: engineer.name,
                subtitle: 'Инженер смены · доставлено $time',
                trailing: ok,
                chevron: false,
              ),
            KvRow(
              icon: KvIcons.server,
              title: 'Цеховой сервер',
              subtitle: KvFormat.typo('Событие записано в историю $code'),
              chevron: false,
            ),
          ],
        ),
      ],
    );
  }
}
