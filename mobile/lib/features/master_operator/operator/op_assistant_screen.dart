import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/mo_blocks.dart';

/// Ответ ассистента оператору: вопрос, текст ответа и ссылки на основания.
@immutable
class _Exchange {
  const _Exchange(this.question, this.answer, this.refs);

  final String question;
  final String answer;
  final List<String> refs;
}

/// Вопрос о статусе Н-101 и ответ цехового сервера на 09:41.
const _Exchange _whyAttention = _Exchange(
  'Почему у Н-101 статус «Внимание»?',
  'Вибрация 1X - 3,1 мм/с при уставке 2,8 мм/с, температура подшипника 78 °C при уставке 75 °C. Инженер провёл осмотр в 09:20-09:34, находка ждёт решения мастера. Агрегат в работе, действий от оператора не требуется.',
  ['S01', 'S04', 'INS-2209'],
);

/// Вопрос о ремонте АМС-2 и ответ цехового сервера.
const _Exchange _whenRepair = _Exchange(
  'Когда закончится ремонт АМС-2?',
  'Ремонт торцевого уплотнения АМС-2 запланирован на 15.11, 08:00, исполнитель Алексей Смирнов. До окончания работ агрегат остановлен, наработка не начисляется. Новый статус появится в карточке АМС-2 и в уведомлениях.',
  ['F-1041', 'S-077', 'План ТО'],
);

/// Ассистент оператора: последний вопрос и ответ с основаниями, подсказки «Спросить ещё» и строка ввода
/// с голосом. [question] = «repair» - ответ про ремонт АМС-2; без него - про статус Н-101.
class OpAssistantScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const OpAssistantScreen({super.key, this.question});

  /// Ключ заданного вопроса или null.
  final String? question;

  @override
  ConsumerState<OpAssistantScreen> createState() => _OpAssistantScreenState();
}

class _OpAssistantScreenState extends ConsumerState<OpAssistantScreen> {
  late _Exchange _shown = widget.question == 'repair'
      ? _whenRepair
      : _whyAttention;
  final TextEditingController _input = TextEditingController();
  bool _busy = false;

  bool get _repair => identical(_shown, _whenRepair);

  @override
  void didUpdateWidget(OpAssistantScreen old) {
    super.didUpdateWidget(old);
    if (old.question != widget.question) {
      _shown = widget.question == 'repair' ? _whenRepair : _whyAttention;
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _other() => context.kvFade(
    _repair
        ? MasterOperatorPaths.opAssistant
        : MasterOperatorPaths.dOpAssistantAns,
  );

  Future<void> _send() async {
    final String q = _input.text.trim();
    if (q.isEmpty) {
      _other();
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final AssistantMessage a = await ref
        .read(assistantRepositoryProvider)
        .ask(q);
    if (mounted) {
      _input.clear();
      setState(() {
        _busy = false;
        _shown = _Exchange(q, a.text, a.refs);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final _Exchange next = _repair ? _whyAttention : _whenRepair;
    return KvScreen(
      header: const KvRootHeader(
        title: 'Ассистент',
        subtitle: 'Работает на цеховом сервере, без интернета',
      ),
      foot: _InputBar(controller: _input, busy: _busy, onSend: _send),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Bubble.user(_shown.question),
            const SizedBox(height: 10),
            _Bubble.bot(_shown.answer, refs: _shown.refs),
          ],
        ),
        const MoLabel('Спросить ещё'),
        MoSuggestChips(
          children: [
            MoSuggestChip(label: next.question, onTap: _other),
            MoSuggestChip(
              label: 'Как сообщить о течи?',
              onTap: () => context.kvUp(MasterOperatorPaths.opReport),
            ),
          ],
        ),
      ],
    );
  }
}

/// Пузырь переписки (.d-msg): вопрос справа синим, ответ слева на карточке с подписью «КСТ Визор» и основаниями.
class _Bubble extends StatelessWidget {
  const _Bubble.user(this.text) : bot = false, refs = const <String>[];

  const _Bubble.bot(this.text, {required this.refs}) : bot = true;

  final String text;
  final bool bot;
  final List<String> refs;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final TextStyle style = t.sm.copyWith(
      height: 1.45,
      color: bot ? c.text : c.onBrand,
    );
    return Align(
      alignment: bot ? Alignment.centerLeft : Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 0.88,
        alignment: bot ? Alignment.centerLeft : Alignment.centerRight,
        child: Align(
          alignment: bot ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: bot ? c.surface : c.btnPrimary,
              boxShadow: bot ? c.shadow1 : null,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(bot ? 6 : 20),
                bottomRight: Radius.circular(bot ? 20 : 6),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (bot) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      KvIcon(KvIcons.sparkle, size: 16, color: c.brand),
                      const SizedBox(width: 6),
                      Text(
                        'КСТ Визор',
                        style: t.label.copyWith(
                          color: c.brand,
                          fontWeight: FontWeight.w600,
                          height: KvTextStyles.normalHeight(12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
                Text(KvFormat.typo(text), style: style),
                if (refs.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final String r in refs)
                        Container(
                          height: 26,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: c.tint2,
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Align(
                            widthFactor: 1,
                            child: Text(
                              KvFormat.typo(r),
                              maxLines: 1,
                              softWrap: false,
                              style: t.label.copyWith(
                                color: c.brand,
                                fontWeight: FontWeight.w500,
                                height: KvTextStyles.normalHeight(12),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Строка ввода вопроса (.d-input): поле, голос и отправка.
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Container(
      height: 56,
      padding: const EdgeInsets.only(left: 18, right: 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(28),
        boxShadow: c.shadow2,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey<String>('op-assistant-input'),
              controller: controller,
              style: t.body,
              cursorColor: c.brand,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration.collapsed(
                hintText: 'Спросите про агрегат',
                hintStyle: t.body.copyWith(color: c.text3),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _RoundAction(
            icon: KvIcons.mic,
            iconSize: 22,
            background: c.surface2,
            color: c.text,
            label: 'Голос',
            onTap: () => showKvToast(
              context,
              kind: KvToastKind.info,
              icon: KvIcons.mic,
              title: 'Слушаю',
              text: 'Голосовой запрос обрабатывается на цеховом сервере',
            ),
          ),
          const SizedBox(width: 6),
          _RoundAction(
            icon: KvIcons.send,
            iconSize: 20,
            background: c.btnPrimary,
            color: c.onBrand,
            label: 'Отправить',
            busy: busy,
            onTap: busy ? null : onSend,
          ),
        ],
      ),
    );
  }
}

/// Круглая кнопка 44 строки ввода без тени: голос на сером, отправка на синем.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.iconSize,
    required this.background,
    required this.color,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final KvIcons icon;
  final double iconSize;
  final Color background;
  final Color color;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return KvPressable(
      onTap: onTap,
      shape: BoxShape.circle,
      semanticLabel: label,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: background, shape: BoxShape.circle),
        child: busy
            ? KvSpinner(color: color, size: 18)
            : KvIcon(icon, size: iconSize, color: color),
      ),
    );
  }
}
