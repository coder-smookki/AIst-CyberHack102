import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';

/// Ленточка дня над сообщениями (.c-day): «Сегодня, 09:38».
class ChatDay extends StatelessWidget {
  /// Создаёт подпись [text].
  const ChatDay(this.text, {super.key});

  /// Текст.
  final String text;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: t.label.copyWith(fontWeight: FontWeight.w400, color: context.kv.text3, height: KvTextStyles.normalHeight(12)),
      ),
    );
  }
}

/// Сообщение диалога (.c-msg): вопрос сотрудника справа синим, ответ ассистента слева на карточке
/// со ссылками-переходами и источником; ответ «не нашёл» - с заголовком и значком поиска.
class ChatMessage extends StatelessWidget {
  /// Создаёт сообщение [message].
  const ChatMessage({super.key, required this.message});

  /// Сообщение.
  final AssistantMessage message;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final TextStyle text = t.sm.copyWith(height: 1.45, color: c.text);
    final double maxWidth = (MediaQuery.sizeOf(context).width - KvSpace.gutter * 2) * 0.86;
    if (message.fromUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: c.btnPrimary,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Text(
              KvFormat.typo(message.text),
              style: text.copyWith(color: c.onBrand, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      );
    }
    final List<Widget> parts = [
      if (!message.found)
        Row(
          children: [
            KvIcon(KvIcons.search, size: 18, color: c.warn),
            const SizedBox(width: KvSpace.s2),
            Flexible(
              child: Text('Записей не нашёл', style: text.copyWith(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      if (message.text.isNotEmpty) Text(KvFormat.typo(message.text), style: text),
      if (message.facts.isNotEmpty)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < message.facts.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      KvFormat.typo(message.facts[i].label),
                      softWrap: false,
                      style: t.caption.copyWith(color: c.text, fontWeight: FontWeight.w600, height: 1.45),
                    ),
                    const SizedBox(width: KvSpace.s2),
                    Expanded(
                      child: Text(KvFormat.typo(message.facts[i].text), style: t.caption.copyWith(color: c.text, height: 1.45)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      for (final AssistantLink l in message.links) ChatRef(link: l),
      if (message.source != null && message.source!.isNotEmpty)
        Text(KvFormat.typo(message.source!), style: t.micro.copyWith(fontWeight: FontWeight.w400, height: 1.45)),
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: c.surface,
            boxShadow: c.shadow1,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomLeft: Radius.circular(6),
              bottomRight: Radius.circular(20),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < parts.length; i++) ...[if (i > 0) const SizedBox(height: KvSpace.s2), parts[i]],
            ],
          ),
        ),
      ),
    );
  }
}

/// Ссылка в ответе ассистента (.c-ref): значок вида объекта, подпись и шеврон; открывает экран или, для
/// «Спросить мастера», отправляет вопрос мастеру.
class ChatRef extends ConsumerWidget {
  /// Создаёт ссылку [link].
  const ChatRef({super.key, required this.link});

  /// Ссылка.
  final AssistantLink link;

  static KvIcons _icon(String kind) => switch (kind) {
    'rule' => KvIcons.activity,
    'chart' => KvIcons.wave,
    'history' => KvIcons.clock,
    'card' || 'equipment' => KvIcons.grid,
    'ask_master' => KvIcons.send,
    'document' => KvIcons.file,
    _ => KvIcons.link,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final BorderRadius radius = BorderRadius.circular(12);
    return KvPressable(
      borderRadius: radius,
      semanticLabel: link.title,
      onTap: () {
        if (link.kind == 'ask_master') {
          final String master = ref.read(peopleProvider).value?['master']?.name ?? 'Мастер';
          showKvToast(
            context,
            kind: KvToastKind.ok,
            icon: KvIcons.send,
            title: 'Вопрос отправлен мастеру',
            text: KvFormat.typo('$master ответит в приложении'),
          );
        } else if (link.deeplink.startsWith('/')) {
          context.kvPush(link.deeplink);
        }
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.only(left: 12, right: 10),
        decoration: BoxDecoration(color: c.tint2, borderRadius: radius),
        child: Row(
          children: [
            KvIcon(_icon(link.kind), size: 16, color: c.brand),
            const SizedBox(width: KvSpace.s2),
            Expanded(
              child: Text(
                KvFormat.typo(link.title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.caption.copyWith(color: c.brand, fontWeight: FontWeight.w500, height: 1.45),
              ),
            ),
            const SizedBox(width: KvSpace.s2),
            KvIcon(KvIcons.chevronRight, size: 16, color: c.brand),
          ],
        ),
      ),
    );
  }
}

/// Сообщения диалога с подписями дней: подпись ставится перед первым вопросом и перед вопросом с другим временем.
List<Widget> chatItems(List<AssistantMessage> dialog, {required bool days, required DateTime now}) {
  final List<Widget> out = [];
  String? lastTime;
  for (final AssistantMessage m in dialog) {
    if (days && m.fromUser && m.time != null && m.time != lastTime) {
      lastTime = m.time;
      out.add(ChatDay('Сегодня, ${m.time}'));
    }
    out.add(ChatMessage(message: m));
  }
  return out;
}

/// Поле вопроса (.c-ask-field): таблетка 52 с подсказкой и микрофоном; в режиме ввода - настоящее поле
/// с синей рамкой и курсором.
class ChatAskField extends StatelessWidget {
  /// Создаёт поле-кнопку, открывающее ввод вопроса.
  const ChatAskField.button({super.key, required this.onTap}) : controller = null, focusNode = null, onSubmitted = null;

  /// Создаёт поле ввода.
  const ChatAskField.input({super.key, required this.controller, required this.focusNode, required this.onSubmitted}) : onTap = null;

  /// Касание поля-кнопки.
  final VoidCallback? onTap;

  /// Текст вопроса.
  final TextEditingController? controller;

  /// Фокус поля.
  final FocusNode? focusNode;

  /// Отправка с клавиатуры.
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool typing = controller != null;
    final BorderRadius radius = BorderRadius.circular(26);
    final Widget box = Container(
      height: 52,
      padding: const EdgeInsets.only(left: 18, right: 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: radius,
        border: Border.all(color: typing ? c.brand : c.border, width: typing ? 1.5 : 1),
        boxShadow: typing ? [BoxShadow(color: c.tint2, spreadRadius: 4)] : c.shadow1,
      ),
      child: Row(
        children: [
          Expanded(
            child: typing
                ? TextField(
                    key: const ValueKey<String>('assistant-question'),
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    textInputAction: TextInputAction.send,
                    onSubmitted: onSubmitted,
                    cursorColor: c.brand,
                    cursorHeight: 20,
                    style: t.body.copyWith(color: c.text, height: KvTextStyles.normalHeight(15)),
                    decoration: InputDecoration.collapsed(
                      hintText: 'Вопрос об оборудовании',
                      hintStyle: t.body.copyWith(color: c.text3, height: KvTextStyles.normalHeight(15)),
                    ),
                  )
                : Text(
                    'Вопрос об оборудовании',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.body.copyWith(color: c.text3, height: KvTextStyles.normalHeight(15)),
                  ),
          ),
          if (!typing) ...[const SizedBox(width: KvSpace.s2), KvIcon(KvIcons.mic, size: 20, color: c.text3)],
        ],
      ),
    );
    if (typing) {
      return box;
    }
    return KvPressable(onTap: onTap, borderRadius: radius, pressedScale: 0.985, semanticLabel: 'Вопрос об оборудовании', child: box);
  }
}

/// Круглая кнопка отправки (.c-send) 52 × 52: синяя, серая без текста, со спиннером во время ответа.
class ChatSendButton extends StatelessWidget {
  /// Создаёт кнопку.
  const ChatSendButton({super.key, required this.onPressed, this.busy = false});

  /// Отправка; null - кнопка неактивна.
  final VoidCallback? onPressed;

  /// Идёт ответ.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final bool on = onPressed != null || busy;
    return KvPressable(
      onTap: busy ? null : onPressed,
      shape: BoxShape.circle,
      semanticLabel: 'Отправить',
      child: AnimatedContainer(
        duration: KvMotion.std,
        width: 52,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: on ? c.btnPrimary : c.surface3, shape: BoxShape.circle),
        child: busy ? KvSpinner(color: c.onBrand, size: 20) : KvIcon(KvIcons.send, size: 22, color: on ? c.onBrand : c.text3),
      ),
    );
  }
}
