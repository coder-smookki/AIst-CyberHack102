import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../core/llm/local_answer.dart';
import '../../../data/providers.dart';
import 'chat_widgets.dart';
import 'local_assistant.dart';

/// Подсказка под диалогом: подпись чипа и вопрос.
typedef _Suggestion = ({String label, String question});

/// Подсказки инженера: навигация, неисправность, состояние, обслуживание.
const List<_Suggestion> _suggestions = [
  (label: 'Как начать осмотр', question: 'Как начать осмотр агрегата?'),
  (label: 'Сильная вибрация', question: 'Агрегат сильно вибрирует, что проверить и как починить?'),
  (label: 'Ближайшие ТО', question: 'Ближайшие ТО'),
  (label: 'Что значит «проверить»', question: 'Что значит статус «проверить»?'),
];

/// Приветствие помощника в пустом диалоге.
const AssistantMessage _hello = AssistantMessage(
  fromUser: false,
  text: 'Я помощник на телефоне и работаю без интернета. Подскажу, где найти экран, как провести осмотр, что значат '
      'статусы и правила, что проверить при неисправности. Ссылки в ответе открывают нужный экран.',
  source: 'На устройстве',
);

/// Подпись состояния модели под шапкой.
String _modelLine(LocalAssistantState s) => switch (s.model) {
      LocalModelState.idle => 'На устройстве · без интернета',
      LocalModelState.installing => 'Готовлю модель ${(s.progress * 100).round()} %',
      LocalModelState.loading => 'Загружаю модель…',
      LocalModelState.ready => 'На устройстве · модель готова',
      LocalModelState.searchOnly => 'На устройстве · ответы по справке',
    };

KvStatus _modelStatus(LocalAssistantState s) => switch (s.model) {
      LocalModelState.ready => KvStatus.ok,
      LocalModelState.searchOnly => KvStatus.info,
      _ => KvStatus.warn,
    };

/// Ассистент (assistant): помощник на устройстве - поиск по справке приложения и малая языковая модель без сети;
/// ответ пишется потоком, ссылки открывают экраны, модель выгружается при уходе с экрана.
class AssistantScreen extends ConsumerStatefulWidget {
  /// Создаёт экран вкладки роли с путём [base] (/engineer/assistant или /senior/assistant).
  const AssistantScreen({super.key, this.base = EngineerServicePaths.assistant});

  /// Путь вкладки «Ассистент» роли.
  final String base;

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  late final LocalAssistantController _assistant = ref.read(localAssistantProvider.notifier);

  @override
  void initState() {
    super.initState();
    unawaited(_assistant.warmUp());
  }

  @override
  void dispose() {
    unawaited(_assistant.release());
    super.dispose();
  }

  void _openInput(String question) => context.kvFade(EngineerServicePaths.assistantInput(base: widget.base, question: question));

  @override
  Widget build(BuildContext context) {
    final LocalAssistantState s = ref.watch(localAssistantProvider);
    final AskContext ctx = ref.watch(assistantContextProvider);
    final DateTime now = ref.watch(clockProvider).now();
    final double tabTop = KvTabBarScope.bottomOf(context) + KvLayout.tabBarHeight;
    final bool hasTab = KvTabBarScope.maybeOf(context)?.visible ?? false;
    final double side = KvLayout.sideInset(MediaQuery.sizeOf(context).width);
    final List<AssistantMessage> dialog = s.messages.isEmpty ? const <AssistantMessage>[_hello] : s.messages;
    final List<Widget> items = chatItems(dialog, days: true, now: now);
    final List<_Suggestion> suggestions = [
      if (ctx.unitId != null) (label: 'Что проверить на ${ctx.unitId}', question: 'Что проверить на ${ctx.unitId} при осмотре?'),
      ..._suggestions,
    ];
    return KvScreen(
      header: KvRootHeader(title: 'Ассистент', subtitle: _modelLine(s), status: _modelStatus(s)),
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              children: [
                const _OfflineBadge(),
                for (final _Suggestion x in suggestions) ...[
                  const SizedBox(width: KvSpace.s2),
                  _SuggestionChip(label: x.label, onTap: s.busy ? null : () => unawaited(_assistant.ask(x.question))),
                ],
              ],
            ),
          ),
          const SizedBox(height: KvSpace.s2),
          Row(
            children: [
              Expanded(child: ChatAskField.button(onTap: () => _openInput(''))),
              const SizedBox(width: KvSpace.s2),
              ChatSendButton(onPressed: null, busy: s.busy),
            ],
          ),
        ],
      ),
      body: ListView.separated(
        reverse: true,
        padding: EdgeInsets.fromLTRB(KvSpace.gutter + side, KvSpace.s3, KvSpace.gutter + side, (hasTab ? tabTop : 0) + 152),
        itemCount: items.length,
        separatorBuilder: (BuildContext context, int i) => const SizedBox(height: 10),
        itemBuilder: (BuildContext context, int i) => items[items.length - 1 - i],
      ),
    );
  }
}

/// Значок «на устройстве»: ответы без сети.
class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return Semantics(
      label: 'Работает на устройстве без интернета',
      child: Container(
        height: 36,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(color: c.tint2, borderRadius: BorderRadius.circular(KvRadius.pill)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KvIcon(KvIcons.wifiOff, size: 16, color: c.brand),
            const SizedBox(width: 6),
            Text('на устройстве', style: context.kvText.sm.copyWith(fontWeight: FontWeight.w500, height: 1.2, color: c.brand)),
          ],
        ),
      ),
    );
  }
}

/// Чип подсказки (.c-sugg .fchip): белая таблетка 36 в области 44 с синим текстом.
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

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
/// кнопка отправки; после отправки - возврат к диалогу, где ответ пишется потоком.
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

  void _send() {
    final String q = _text.text.trim();
    if (q.isEmpty || _sending) {
      return;
    }
    setState(() => _sending = true);
    unawaited(ref.read(localAssistantProvider.notifier).ask(q));
    context.kvFade(widget.base);
  }

  @override
  Widget build(BuildContext context) {
    final LocalAssistantState s = ref.watch(localAssistantProvider);
    final DateTime now = ref.watch(clockProvider).now();
    final MediaQueryData mq = MediaQuery.of(context);
    final double keyboard = mq.viewInsets.bottom;
    final List<Widget> items = chatItems(s.messages, days: false, now: now);
    final double bottom = keyboard > 0 ? keyboard + 82 + 11 : KvLayout.footSpace + 13;
    return KvScreen(
      header: KvRootHeader(title: 'Ассистент', subtitle: _modelLine(s), status: _modelStatus(s)),
      stagger: KvStagger.none,
      foot: Row(
        children: [
          Expanded(
            child: ChatAskField.input(controller: _text, focusNode: _focus, onSubmitted: (String _) => _send()),
          ),
          const SizedBox(width: KvSpace.s2),
          ChatSendButton(onPressed: _text.text.trim().isEmpty || s.busy ? null : _send, busy: _sending),
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
