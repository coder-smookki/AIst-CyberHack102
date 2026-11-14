import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import 'chat_widgets.dart';

/// Подсказка под диалогом: подпись чипа и действие - сразу спросить или открыть ввод с готовым вопросом.
typedef _Suggestion = ({String label, String question, bool ask});

/// Подсказки инженера (.c-sugg).
const List<_Suggestion> _suggestions = [
  (label: 'Ближайшие ТО', question: 'Ближайшие ТО', ask: true),
  (label: 'Замена муфты АМС-1', question: 'Когда меняли муфту АМС-1?', ask: false),
];

/// Ассистент (assistant, c-assist-nf, c-assist-to): диалог по истории и паспортам на цеховом сервере, подсказки
/// и поле вопроса над панелью вкладок. Сообщения прижаты к низу, новые ответы появляются снизу.
class AssistantScreen extends ConsumerStatefulWidget {
  /// Создаёт экран вкладки роли с путём [base] (/engineer/assistant или /senior/assistant).
  const AssistantScreen({super.key, this.base = EngineerServicePaths.assistant});

  /// Путь вкладки «Ассистент» роли.
  final String base;

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  bool _asking = false;

  Future<void> _ask(String question) async {
    if (_asking) {
      return;
    }
    setState(() => _asking = true);
    try {
      await ref.read(assistantRepositoryProvider).ask(question);
    } finally {
      if (mounted) {
        setState(() => _asking = false);
      }
    }
  }

  void _openInput(String question) => context.kvFade(EngineerServicePaths.assistantInput(base: widget.base, question: question));

  @override
  Widget build(BuildContext context) {
    final List<AssistantMessage> dialog = ref.watch(assistantDialogProvider).value ?? const <AssistantMessage>[];
    final DateTime now = ref.watch(clockProvider).now();
    final double tabTop = KvTabBarScope.bottomOf(context) + KvLayout.tabBarHeight;
    final bool hasTab = KvTabBarScope.maybeOf(context)?.visible ?? false;
    final List<Widget> items = chatItems(dialog, days: true, now: now);
    return KvScreen(
      header: const KvRootHeader(title: 'Ассистент', subtitle: 'Отвечает по истории и паспортам, без интернета'),
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: KvSpace.s2,
            children: [
              for (final _Suggestion s in _suggestions)
                _SuggestionChip(label: s.label, onTap: () => s.ask ? unawaited(_ask(s.question)) : _openInput(s.question)),
            ],
          ),
          const SizedBox(height: KvSpace.s2),
          Row(
            children: [
              Expanded(child: ChatAskField.button(onTap: () => _openInput(''))),
              const SizedBox(width: KvSpace.s2),
              ChatSendButton(onPressed: null, busy: _asking),
            ],
          ),
        ],
      ),
      body: ListView.separated(
        reverse: true,
        padding: EdgeInsets.fromLTRB(KvSpace.gutter, KvSpace.s3, KvSpace.gutter, (hasTab ? tabTop : 0) + 152),
        itemCount: items.length,
        separatorBuilder: (BuildContext context, int i) => const SizedBox(height: 10),
        itemBuilder: (BuildContext context, int i) => items[items.length - 1 - i],
      ),
    );
  }
}

/// Чип подсказки (.c-sugg .fchip): белая таблетка 36 в области 44 с синим текстом.
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return KvPressable(
      onTap: onTap,
      highlight: false,
      semanticLabel: label,
      child: SizedBox(
        height: KvLayout.touch,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(KvRadius.pill), boxShadow: c.shadow1),
          child: Text(
            KvFormat.typo(label),
            maxLines: 1,
            softWrap: false,
            style: context.kvText.sm.copyWith(fontWeight: FontWeight.w500, height: 1.2, color: c.brand),
          ),
        ),
      ),
    );
  }
}

/// Ввод вопроса ассистенту (c-assist-input): диалог без панели вкладок, поле с курсором над клавиатурой и
/// кнопка отправки; после ответа - возврат к диалогу.
class AssistantInputScreen extends ConsumerStatefulWidget {
  /// Создаёт экран с готовым вопросом [question]; [base] - путь вкладки «Ассистент» роли.
  const AssistantInputScreen({super.key, this.question = '', this.base = EngineerServicePaths.assistant});

  /// Начальный текст вопроса.
  final String question;

  /// Путь вкладки «Ассистент» роли.
  final String base;

  @override
  ConsumerState<AssistantInputScreen> createState() => _AssistantInputScreenState();
}

class _AssistantInputScreenState extends ConsumerState<AssistantInputScreen> {
  late final TextEditingController _text = TextEditingController(text: widget.question);
  final FocusNode _focus = FocusNode();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onText);
  }

  void _onText() => setState(() {});

  @override
  void dispose() {
    _text.removeListener(_onText);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final String q = _text.text.trim();
    if (q.isEmpty || _sending) {
      return;
    }
    setState(() => _sending = true);
    await Future<void>.delayed(context.kvReduceMotion ? Duration.zero : const Duration(milliseconds: 700));
    await ref.read(assistantRepositoryProvider).ask(q);
    if (mounted) {
      context.kvFade(widget.base);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<AssistantMessage> dialog = ref.watch(assistantDialogProvider).value ?? const <AssistantMessage>[];
    final DateTime now = ref.watch(clockProvider).now();
    final MediaQueryData mq = MediaQuery.of(context);
    final double keyboard = mq.viewInsets.bottom;
    final List<Widget> items = chatItems(dialog, days: false, now: now);
    final double bottom = keyboard > 0 ? keyboard + 82 + 11 : KvLayout.footSpace + 13;
    return KvScreen(
      header: const KvRootHeader(title: 'Ассистент', subtitle: 'Отвечает по истории и паспортам, без интернета'),
      stagger: KvStagger.none,
      foot: Row(
        children: [
          Expanded(
            child: ChatAskField.input(controller: _text, focusNode: _focus, onSubmitted: (String _) => _send()),
          ),
          const SizedBox(width: KvSpace.s2),
          ChatSendButton(onPressed: _text.text.trim().isEmpty ? null : _send, busy: _sending),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ListView.separated(
          reverse: true,
          shrinkWrap: true,
          padding: EdgeInsets.fromLTRB(KvSpace.gutter, 0, KvSpace.gutter, bottom),
          itemCount: items.length,
          separatorBuilder: (BuildContext context, int i) => const SizedBox(height: 10),
          itemBuilder: (BuildContext context, int i) => items[items.length - 1 - i],
        ),
      ),
    );
  }
}
