import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/navigation/kv_page.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../../data/repositories/inspection_repository.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_sheet_swap.dart';

/// Шкала тяжести находки (общая с диагностикой и итогом осмотра): подпись и тон.
(String, KvStatus) moSeverity(int severity) => switch (severity) {
  3 => ('Критично', KvStatus.bad),
  2 => ('Планово', KvStatus.warn),
  _ => ('Проверить', KvStatus.info),
};

/// Подпись и тон статуса находки (D.findingStatus).
(String, KvStatus) moFindingStatus(String status) => switch (status) {
  'new' => ('Ждёт подтверждения', KvStatus.warn),
  'confirmed' => ('Подтверждена', KvStatus.bad),
  'planned' => ('Запланировано ТО', KvStatus.info),
  'closed' => ('Закрыта', KvStatus.ok),
  _ => ('Отклонена', KvStatus.unk),
};

/// Глагол решения по роду сотрудника: «Подтвердила» / «Подтвердил».
String moVerb(String name, String female, String male) => name.trim().split(' ').first.endsWith('а') ? female : male;

/// Тексты решения мастера по находке (confirmSheet прототипа): что планируется, режим агрегата и итог.
@immutable
class MoDecision {
  /// Создаёт заготовку решения.
  const MoDecision({
    required this.summary,
    required this.summarySub,
    required this.planTitle,
    required this.planSub,
    required this.planWhen,
    required this.modeTitle,
    required this.modeSub,
    required this.modeOn,
    required this.comment,
    required this.doneTitle,
    required this.doneText,
    required this.donePairs,
    this.modeNote,
    this.keep,
    this.toPlan = false,
    this.rejectStays = false,
  });

  /// Сводка: «F-1043 · Н-101 · R01».
  final String summary;

  /// Подпись сводки.
  final String summarySub;

  /// Переключатель работ.
  final String planTitle;

  /// Подпись работ.
  final String planSub;

  /// Когда работы для плана ТО: «15.11, 10:00».
  final String planWhen;

  /// Переключатель режима.
  final String modeTitle;

  /// Подпись режима.
  final String modeSub;

  /// Режим включён по умолчанию.
  final bool modeOn;

  /// Пояснение под переключателями.
  final String? modeNote;

  /// Комментарий по умолчанию.
  final String comment;

  /// Итог.
  final String doneTitle;

  /// Текст итога.
  final String doneText;

  /// Значения итога.
  final List<(String, String)> donePairs;

  /// Решение «оставить в работе» (ссылка в листе), если оно возможно.
  final MoKeepDecision? keep;

  /// Итог ведёт в план ТО, иначе к находкам.
  final bool toPlan;

  /// После отклонения остаться на экране находки, иначе вернуться к списку.
  final bool rejectStays;

  /// Заготовка для находки [f] агрегата [code].
  static MoDecision of(Finding f, String code) => _presets[f.id] ?? _generic(f, code);

  static MoDecision _generic(Finding f, String code) {
    final bool critical = f.severity >= 3;
    return MoDecision(
      summary: '${f.id} · $code · ${f.ruleId}',
      summarySub: '${f.title} · ${moSeverity(f.severity).$1.toLowerCase()}',
      planTitle: 'Запланировать работы',
      planSub: 'По рекомендации ${f.ruleId}',
      planWhen: '15.11, 10:00',
      modeTitle: 'Перевести $code в резерв',
      modeSub: 'Наработка не будет начисляться',
      modeOn: critical,
      comment: '',
      doneTitle: 'Находка подтверждена',
      doneText: 'Инженер и оператор смены получили уведомление.',
      donePairs: [('Статус ${f.id}', 'Запланировано ТО')],
      toPlan: true,
      rejectStays: true,
    );
  }

  static const Map<String, MoDecision> _presets = {
    'F-1043': MoDecision(
      summary: 'F-1043 · Н-101 · R01',
      summarySub: 'Деградация уплотнения вала · критично',
      planTitle: 'Запланировать замену уплотнения',
      planSub: 'Вместе с ТО-2 · 15.11, 10:00',
      planWhen: '15.11, 10:00',
      modeTitle: 'Перевести Н-101 в резерв',
      modeSub: 'До замены уплотнения · наработка не начисляется',
      modeOn: true,
      modeNote: 'По R01 рекомендуется резерв до замены уплотнения.',
      comment: 'Подтверждаю. Перевести в резерв, заменить уплотнение и проверить смазку подшипника при ТО-2.',
      doneTitle: 'Находка подтверждена',
      doneText: 'Н-101 переведён в резерв, замена уплотнения добавлена в ТО-2. Инженер и оператор смены получили уведомление.',
      donePairs: [('Н-101', 'резерв с 09:41'), ('Работы', '15.11, 10:00 · ТО-2'), ('Статус F-1043', 'Запланировано ТО')],
      keep: MoKeepDecision(
        link: 'Оставить в работе до ТО-2',
        modeSub: 'Выключено: решение мастера',
        note: 'Без резерва признак R01 остаётся под наблюдением. Решение и обоснование попадут в историю Н-101 и отчёт.',
        justification: 'Резервный насос на ремонте, течь слабая. Контроль каждые 2 ч до ТО-2.',
        doneText: 'Решение мастера: оставить Н-101 в работе до ТО-2. Инженер получил задание на контроль каждые 2 ч.',
        donePairs: [('Решение мастера', 'оставить в работе'), ('Работы', '15.11, 10:00 · ТО-2'), ('Статус F-1043', 'Запланировано ТО')],
      ),
      rejectStays: true,
    ),
    'F-1042': MoDecision(
      summary: 'F-1042 · Н-101 · R08',
      summarySub: 'Признаки износа подшипника двигателя',
      planTitle: 'Запланировать замену подшипников',
      planSub: '19.12.2026 · ресурс 810 ч',
      planWhen: '19.12.2026, 09:00',
      modeTitle: 'Перевести Н-101 в резерв',
      modeSub: 'Наработка не будет начисляться',
      modeOn: false,
      comment: 'Проверить смазку при ТО-2, замену подшипников - по плану.',
      doneTitle: 'Находка подтверждена',
      doneText: 'Замена подшипников Н-101 добавлена в план ТО.',
      donePairs: [('Работы', '19.12, 09:00'), ('Статус F-1042', 'Запланировано ТО')],
      toPlan: true,
    ),
    'F-1041': MoDecision(
      summary: 'F-1041 · АМС-2 · R01',
      summarySub: 'Течь торцевого уплотнения, перегрев обмоток',
      planTitle: 'Запланировать ремонт уплотнения',
      planSub: '15.11, 08:00 · А. Смирнов',
      planWhen: '15.11.2026, 08:00',
      modeTitle: 'Режим АМС-2: на ремонте',
      modeSub: 'Остановлен по S05 в 06:44',
      modeOn: true,
      comment: 'Подтверждаю. Заменить уплотнение, проверить изоляцию обмоток.',
      doneTitle: 'Ремонт запланирован',
      doneText: 'АМС-2 переведён в режим «На ремонте». Оператор видит новый статус агрегата.',
      donePairs: [('Работы', 'Ремонт уплотнения · 15.11, 08:00'), ('Исполнитель', 'Алексей Смирнов'), ('Уведомлены', 'оператор, инженер')],
      toPlan: true,
    ),
  };
}

/// Решение «оставить агрегат в работе» без резерва: обязательное обоснование и свой итог.
@immutable
class MoKeepDecision {
  /// Создаёт заготовку.
  const MoKeepDecision({
    required this.link,
    required this.modeSub,
    required this.note,
    required this.justification,
    required this.doneText,
    required this.donePairs,
  });

  /// Ссылка в листе подтверждения.
  final String link;

  /// Подпись выключенного режима.
  final String modeSub;

  /// Пояснение.
  final String note;

  /// Обоснование по умолчанию.
  final String justification;

  /// Текст итога.
  final String doneText;

  /// Значения итога.
  final List<(String, String)> donePairs;
}

/// Перейти на вкладку роли наплывом.
void moGoTab(BuildContext context, String path) => context.go(path, extra: const KvNavExtra(transition: KvTransition.fade));

/// Лист подтверждения находки [f]: работы, режим агрегата, решение «оставить в работе» с обоснованием,
/// комментарий; «Подтвердить» сохраняет решение на сервере и показывает итог в том же листе.
/// [story] - экран момента истории: решение уже принято, данные не меняются.
Future<void> showMoConfirmSheet(BuildContext context, Finding f, String code, {bool story = false}) {
  final BuildContext screen = context;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => _ConfirmSheet(finding: f, code: code, story: story, screen: screen),
  );
}

class _ConfirmSheet extends ConsumerStatefulWidget {
  const _ConfirmSheet({required this.finding, required this.code, required this.story, required this.screen});

  final Finding finding;
  final String code;
  final bool story;
  final BuildContext screen;

  @override
  ConsumerState<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends ConsumerState<_ConfirmSheet> {
  late final MoDecision _d = MoDecision.of(widget.finding, widget.code);
  late bool _plan = true;
  late bool _mode = _d.modeOn;
  bool _keep = false;
  bool _done = false;
  late final TextEditingController _text = TextEditingController(text: _d.comment);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _toKeep() {
    final MoKeepDecision? k = _d.keep;
    if (k == null) {
      return;
    }
    setState(() {
      _keep = true;
      _mode = false;
      _text.text = k.justification;
    });
  }

  Future<void> _confirm() async {
    final Finding f = widget.finding;
    if (!widget.story) {
      final InspectionRepository inspections = ref.read(inspectionRepositoryProvider);
      final bool keepRunning = f.severity >= 3 && !_mode;
      await inspections.confirmFinding(f.id, keepRunning: keepRunning, justification: _text.text.trim().isEmpty ? null : _text.text.trim());
      if (_mode && f.severity < 3) {
        await ref.read(equipmentRepositoryProvider).setMode(f.unitId, 'reserve', reason: 'По находке ${f.id}');
      }
      if (_plan) {
        await inspections.scheduleFinding(f.id, when: _d.planWhen);
      }
    }
    if (mounted) {
      setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) => MoSheetSwap(child: _done ? _result(context) : _form(context));

  Widget _form(BuildContext context) {
    final MoKeepDecision? k = _d.keep;
    final bool needText = _keep;
    final String? note = _keep ? k?.note : _d.modeNote;
    return KvSheet(
      key: const ValueKey<String>('form'),
      title: 'Подтвердить находку',
      actions: [
        ListenableBuilder(
          listenable: _text,
          builder: (BuildContext context, Widget? _) =>
              KvButton('Подтвердить', icon: KvIcons.check, wait: true, onPressed: needText && _text.text.trim().isEmpty ? null : _confirm),
        ),
      ],
      children: [
        KvRow(
          icon: KvIcons.alertCircle,
          iconStatus: KvStatus.bad,
          title: KvFormat.typo(_d.summary),
          subtitle: KvFormat.typo(_d.summarySub),
          chevron: false,
        ),
        KvList(
          children: [
            MoSwitchRow(
              icon: KvIcons.calendar,
              title: _d.planTitle,
              subtitle: _d.planSub,
              value: _plan,
              onChanged: (bool v) => setState(() => _plan = v),
            ),
            MoSwitchRow(
              icon: KvIcons.power,
              iconStatus: _mode ? KvStatus.bad : null,
              title: KvFormat.typo(_d.modeTitle),
              subtitle: _keep && !_mode ? k?.modeSub : _d.modeSub,
              value: _mode,
              onChanged: (bool v) {
                if (!v && k != null && !_keep) {
                  _toKeep();
                } else {
                  setState(() => _mode = v);
                }
              },
            ),
          ],
        ),
        if (note != null) KvNote(tone: KvStatus.warn, icon: KvIcons.alert, text: KvFormat.typo(note)),
        if (k != null && !_keep) Center(child: KvLink(k.link, onPressed: _toKeep)),
        ListenableBuilder(
          listenable: _text,
          builder: (BuildContext context, Widget? _) => KvField(
            key: ValueKey<bool>(_keep),
            label: _keep ? 'Обоснование · обязательно' : 'Комментарий',
            controller: _text,
            area: true,
            autofocus: _keep,
            help: _keep ? 'Без обоснования оставить в работе нельзя' : null,
            error: needText && _text.text.trim().isEmpty,
            fieldKey: const ValueKey<String>('mo-confirm-text'),
          ),
        ),
      ],
    );
  }

  Widget _result(BuildContext context) {
    final bool keep = _keep && !_mode && _d.keep != null;
    return MoDoneSheet(
      key: const ValueKey<String>('done'),
      title: _d.doneTitle,
      text: keep ? _d.keep!.doneText : _d.doneText,
      pairs: keep ? _d.keep!.donePairs : _d.donePairs,
      actions: [
        KvButton(
          _d.toPlan ? 'Открыть план ТО' : 'К находкам',
          onPressed: () {
            Navigator.of(context).pop();
            if (widget.screen.mounted) {
              moGoTab(widget.screen, _d.toPlan ? MasterOperatorPaths.masterPlan : MasterOperatorPaths.masterFindings);
            }
          },
        ),
      ],
    );
  }
}

/// Причины отклонения находки и типовые описания проверки на месте.
const List<(String, String)> moRejectReasons = [
  ('Ложное срабатывание', 'Капель нет, пятно - конденсат на корпусе.'),
  ('Уже устранено', 'Уплотнение подтянуто при обходе 09:40, течи нет.'),
  ('Дубликат', 'Та же течь, что в F-1043.'),
];

/// Диалог отклонения находки: без причины и описания проверки «Отклонить» недоступна. После отклонения
/// находка остаётся в истории агрегата, инженер получает уведомление.
Future<void> showMoRejectDialog(BuildContext context, Finding f, {bool story = false, bool stay = true}) {
  final BuildContext screen = context;
  return showKvDialog<void>(
    context,
    builder: (BuildContext dialog) => _RejectDialog(finding: f, story: story, stay: stay, screen: screen),
  );
}

class _RejectDialog extends ConsumerStatefulWidget {
  const _RejectDialog({required this.finding, required this.story, required this.stay, required this.screen});

  final Finding finding;
  final bool story;
  final bool stay;
  final BuildContext screen;

  @override
  ConsumerState<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends ConsumerState<_RejectDialog> {
  int? _reason;
  final TextEditingController _note = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _note.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _pick(int i) {
    final bool preset = _note.text.isEmpty || moRejectReasons.any(((String, String) r) => r.$2 == _note.text);
    setState(() {
      _reason = i;
      if (preset) {
        _note.text = moRejectReasons[i].$2;
      }
    });
    _focus.requestFocus();
  }

  Future<void> _reject() async {
    if (!widget.story) {
      await ref
          .read(inspectionRepositoryProvider)
          .rejectFinding(widget.finding.id, reason: moRejectReasons[_reason!].$1, note: _note.text.trim());
    }
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
    if (!widget.stay && widget.screen.mounted) {
      moGoTab(widget.screen, MasterOperatorPaths.masterFindings);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KvDialog(
      icon: KvIcons.ban,
      tone: KvStatus.warn,
      title: KvFormat.typo('Отклонить ${widget.finding.id}?'),
      text: 'Находка останется в истории агрегата с пометкой «Отклонена». Инженер получит уведомление.',
      body: Padding(
        padding: const EdgeInsets.only(top: KvSpace.s2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            MoSuggestChips(
              children: [
                for (int i = 0; i < moRejectReasons.length; i++)
                  MoSuggestChip(label: moRejectReasons[i].$1, on: _reason == i, onTap: () => _pick(i)),
              ],
            ),
            const SizedBox(height: KvSpace.s3),
            KvField(
              label: 'Что проверено на месте · обязательно',
              placeholder: 'Опишите проверку',
              controller: _note,
              focusNode: _focus,
              area: true,
              onChanged: (String _) => setState(() {}),
              fieldKey: const ValueKey<String>('mo-reject-note'),
            ),
          ],
        ),
      ),
      actions: [
        KvButton('Отмена', kind: KvButtonKind.secondary, onPressed: () => Navigator.of(context).pop()),
        if (_reason != null && _note.text.trim().isNotEmpty)
          KvButton('Отклонить', kind: KvButtonKind.danger, wait: true, onPressed: _reject)
        else
          const KvButton('Отклонить', kind: KvButtonKind.secondary),
      ],
    );
  }
}

/// Лист «Назначить на ТО»: включить работу в ТО-2 или отдельный ремонт, исполнитель; итог - в том же листе.
Future<void> showMoScheduleSheet(BuildContext context, Finding f, String code) {
  final BuildContext screen = context;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => _ScheduleSheet(finding: f, code: code, screen: screen),
  );
}

class _ScheduleSheet extends ConsumerStatefulWidget {
  const _ScheduleSheet({required this.finding, required this.code, required this.screen});

  final Finding finding;
  final String code;
  final BuildContext screen;

  @override
  ConsumerState<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends ConsumerState<_ScheduleSheet> {
  static const List<String> _who = ['Елена Титова', 'Алексей Смирнов'];
  int _work = 0;
  int _person = 0;
  bool _done = false;

  Future<void> _add() async {
    await ref.read(inspectionRepositoryProvider).scheduleFinding(widget.finding.id, when: _work == 0 ? '15.11, 10:00' : '16.11, 08:00');
    if (mounted) {
      setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MoSheetSwap(
      child: _done
          ? MoDoneSheet(
              key: const ValueKey<String>('done'),
              icon: KvIcons.calendar,
              tone: KvStatus.info,
              title: 'Добавлено в план ТО',
              text: _work == 0 ? 'Замена уплотнения ${widget.code} войдёт в ТО-2.' : 'Ремонт ${widget.code} добавлен в план ТО.',
              pairs: [('Дата', _work == 0 ? '15.11, 10:00' : '16.11, 08:00'), ('Исполнитель', _who[_person])],
              actions: [
                KvButton(
                  'Открыть план ТО',
                  onPressed: () {
                    Navigator.of(context).pop();
                    if (widget.screen.mounted) {
                      moGoTab(widget.screen, MasterOperatorPaths.masterPlan);
                    }
                  },
                ),
                KvButton('Остаться', kind: KvButtonKind.ghost, onPressed: () => Navigator.of(context).pop()),
              ],
            )
          : KvSheet(
              key: const ValueKey<String>('form'),
              title: 'Назначить на ТО',
              actions: [KvButton('Добавить в план', icon: KvIcons.plus, wait: true, onPressed: _add)],
              children: [
                const MoLabel('Работы'),
                KvList(
                  children: [
                    MoRadioRow(
                      icon: KvIcons.calendar,
                      title: 'Включить в ТО-2',
                      subtitle: '15.11, 10:00 · через 10 ч наработки',
                      on: _work == 0,
                      onTap: () => setState(() => _work = 0),
                    ),
                    MoRadioRow(
                      icon: KvIcons.wrench,
                      title: 'Отдельный ремонт',
                      subtitle: 'Выбрать дату и время',
                      on: _work == 1,
                      onTap: () => setState(() => _work = 1),
                    ),
                  ],
                ),
                const MoLabel('Исполнитель'),
                KvFilterChips(
                  items: [for (final String n in _who) KvFilterItem(n)],
                  selected: _person,
                  onSelected: (int i) => setState(() => _person = i),
                ),
                KvNote(
                  tone: KvStatus.warn,
                  icon: KvIcons.alert,
                  text: 'По ${widget.finding.ruleId} рекомендуется перевести насос в резерв до замены уплотнения.',
                ),
              ],
            ),
    );
  }
}

/// Лист «Комментарий мастера»: текст и быстрые пометки; сохранённый комментарий видит инженер.
Future<void> showMoCommentSheet(BuildContext context, Finding f) {
  return showKvSheet<void>(context, builder: (BuildContext sheet) => _CommentSheet(finding: f));
}

class _CommentSheet extends ConsumerStatefulWidget {
  const _CommentSheet({required this.finding});

  final Finding finding;

  @override
  ConsumerState<_CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends ConsumerState<_CommentSheet> {
  static const List<String> _tags = ['Нужен повторный осмотр', 'Приложить к отчёту', 'Проверить смазку'];
  late final TextEditingController _text = TextEditingController(
    text: widget.finding.masterComment ?? 'Проверить смазку подшипника при ТО-2, кадр уплотнения приложить к отчёту',
  );
  final Set<int> _on = {1};
  bool _done = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String tags = [for (final int i in _on.toList()..sort()) _tags[i]].join(', ');
    await ref
        .read(inspectionRepositoryProvider)
        .commentFinding(widget.finding.id, tags.isEmpty ? _text.text.trim() : '${_text.text.trim()} · $tags');
    if (mounted) {
      setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Finding f = widget.finding;
    final String engineer = f.author == 'Система' ? 'инженера смены' : f.author;
    return MoSheetSwap(
      child: _done
          ? MoDoneSheet(
              key: const ValueKey<String>('done'),
              title: 'Комментарий сохранён',
              text: 'Инженер $engineer увидит его в находке ${f.id}.',
              actions: [KvButton('Готово', onPressed: () => Navigator.of(context).pop())],
            )
          : KvSheet(
              key: const ValueKey<String>('form'),
              title: 'Комментарий мастера',
              actions: [KvButton('Сохранить', wait: true, onPressed: _save)],
              children: [
                KvField(controller: _text, area: true, autofocus: true, fieldKey: const ValueKey<String>('mo-comment-text')),
                MoSuggestChips(
                  children: [
                    for (int i = 0; i < _tags.length; i++)
                      MoSuggestChip(
                        label: _tags[i],
                        on: _on.contains(i),
                        onTap: () => setState(() => _on.contains(i) ? _on.remove(i) : _on.add(i)),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// Меню находки: карточка агрегата, PDF с кадром и доказательствами, сообщение инженеру.
Future<void> showMoFindingMenu(BuildContext context, Finding f, String code) {
  final BuildContext screen = context;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => KvSheet(
      title: f.id,
      children: [
        KvList(
          children: [
            KvRow(
              icon: KvIcons.grid,
              title: KvFormat.typo('Карточка $code'),
              subtitle: 'Показания, режим, план',
              onTap: () {
                Navigator.of(sheet).pop();
                screen.kvPush(MasterOperatorPaths.unit(f.unitId));
              },
            ),
            KvRow(
              icon: KvIcons.filePdf,
              title: 'Находка в PDF',
              subtitle: 'С кадром и доказательствами',
              onTap: () {
                Navigator.of(sheet).pop();
                showKvToast(
                  screen,
                  kind: KvToastKind.ok,
                  icon: KvIcons.download,
                  title: 'PDF сформирован',
                  text: KvFormat.typo('${f.id} · 1,1 МБ · Загрузки'),
                );
              },
            ),
            KvRow(
              icon: KvIcons.user,
              title: 'Написать инженеру',
              subtitle: f.author,
              onTap: () {
                Navigator.of(sheet).pop();
                showMoCommentSheet(screen, f);
              },
            ),
          ],
        ),
      ],
    ),
  );
}
