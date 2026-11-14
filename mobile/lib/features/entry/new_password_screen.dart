import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/entry_routes.dart';
import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'entry_state.dart';
import 'widgets/entry_motion.dart';

/// Состояние требования к паролю.
enum _Rule {
  /// Выполнено: зелёная галочка.
  ok,

  /// Не выполнено: красный крест и красный текст.
  bad,

  /// Пока не проверить: серый прочерк.
  unk,
}

/// «Новый пароль» при первом входе по временному паролю (a-new-pass, a-new-pass-weak): пояснение о сроке
/// временного пароля, два поля и карточка требований политики, которая проверяется на лету, с индикатором
/// «Надёжный» / «Слабый». «Сохранить и войти» меняет пароль на сервере и открывает «Пароль сохранён».
class NewPasswordScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const NewPasswordScreen({super.key});

  @override
  ConsumerState<NewPasswordScreen> createState() => _NewPasswordScreenState();
}

class _NewPasswordScreenState extends ConsumerState<NewPasswordScreen> {
  final TextEditingController _first = TextEditingController();
  final TextEditingController _second = TextEditingController();
  final FocusNode _firstFocus = FocusNode();
  bool _attempted = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _first.addListener(_changed);
    _second.addListener(_changed);
    _firstFocus.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    _firstFocus.dispose();
    super.dispose();
  }

  Future<void> _back() async {
    ref.read(entryPendingLoginProvider.notifier).clear();
    await ref.read(sessionProvider.notifier).logout();
    if (mounted) {
      context.kvBack(EntryPaths.login);
    }
  }

  Future<void> _save(PasswordRules rules, String? temp) async {
    FocusScope.of(context).unfocus();
    final String pw = _first.text;
    final ({bool length, bool classes, bool spaces}) check = rules.check(pw);
    final bool strong = check.length && check.classes && check.spaces && pw != temp;
    if (!strong || _second.text != pw) {
      setState(() => _attempted = true);
      showKvToast(
        context,
        kind: KvToastKind.warn,
        icon: KvIcons.key,
        title: 'Пароль не подходит',
        text: strong ? 'Пароли не совпадают' : 'Нужно не меньше ${rules.minLength} символов, буквы и цифры',
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final AuthSession session = await ref.read(authRepositoryProvider).changePassword(pw, currentPassword: temp);
      if (!mounted) {
        return;
      }
      ref.read(entryPendingLoginProvider.notifier).clear();
      context.kvFade(EntryPaths.aPassOk);
      ref.read(sessionProvider.notifier).restore(session);
    } on KvApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      showKvToast(context, kind: KvToastKind.warn, icon: KvIcons.key, title: 'Пароль не подходит', text: e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String name = ref.watch(sessionProvider.select((AuthSession? s) => s?.user.name ?? ''));
    final PasswordRules rules = ref.watch(entryPasswordRulesProvider).value ?? const PasswordRules(minLength: 10);
    final String? temp = ref.watch(entryPendingLoginProvider.select((PendingLogin? p) => p?.password));
    final String pw = _first.text;
    final String repeat = _second.text;
    final ({bool length, bool classes, bool spaces}) check = rules.check(pw);
    final bool empty = pw.isEmpty;
    final List<(_Rule, String)> list = [
      (
        empty ? _Rule.unk : (check.length ? _Rule.ok : _Rule.bad),
        'Не короче ${rules.minLength} символов${!empty && !check.length ? ' · сейчас ${pw.length}' : ''}',
      ),
      (empty ? _Rule.unk : (check.classes ? _Rule.ok : _Rule.bad), 'Есть буквы и цифры'),
      (empty ? _Rule.unk : (pw != temp ? _Rule.ok : _Rule.bad), 'Не совпадает с временным'),
      (repeat.isEmpty || empty ? _Rule.unk : (repeat == pw ? _Rule.ok : _Rule.bad), 'Пароли совпадают'),
    ];
    final bool strong = !empty && check.length && check.classes && check.spaces && pw != temp;
    final bool showError = !empty && !strong && (!_firstFocus.hasFocus || _attempted);
    final String until = rules.tempUntil == null ? '' : ' - временный действует до ${rules.tempUntil!.replaceFirst(' ', ', ')}';
    return KvScreen(
      header: KvHeader(
        title: 'Новый пароль',
        subtitle: name.isEmpty ? 'первый вход' : '$name · первый вход',
        status: KvStatus.info,
        onBack: _back,
      ),
      foot: KvButton('Сохранить и войти', loading: _busy, onPressed: () => _save(rules, temp)),
      children: [
        KvNote(icon: KvIcons.key, text: 'Вы вошли по временному паролю. Задайте свой$until.'),
        AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KvField(
                fieldKey: const Key('new-pass-1'),
                label: 'Новый пароль',
                controller: _first,
                focusNode: _firstFocus,
                lead: KvIcons.lock,
                obscure: true,
                reveal: pw.isNotEmpty,
                error: showError,
                enabled: !_busy,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
              ),
              const SizedBox(height: KvSpace.s3),
              KvField(
                fieldKey: const Key('new-pass-2'),
                label: 'Повторите пароль',
                placeholder: 'Ещё раз новый пароль',
                controller: _second,
                lead: KvIcons.lock,
                obscure: true,
                reveal: repeat.isNotEmpty,
                error: _attempted && repeat.isNotEmpty && repeat != pw,
                enabled: !_busy,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                onSubmitted: (_) => _save(rules, temp),
              ),
            ],
          ),
        ),
        KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Требования', style: context.kvText.h2.copyWith(fontSize: 15))),
                  const SizedBox(width: KvSpace.s3),
                  _Meter(state: empty ? null : strong),
                ],
              ),
              const SizedBox(height: KvSpace.s2),
              EntryStagger(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int i = 0; i < list.length; i++)
                      EntryStaggerItem(
                        index: i + 1,
                        child: _RuleRow(state: list[i].$1, text: list[i].$2),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: KvSpace.s2 + KvSpace.s1),
              Text(
                'Задано политикой администратора ИБ',
                style: context.kvText.label.copyWith(
                  fontWeight: FontWeight.w400,
                  color: context.kv.text3,
                  height: KvTextStyles.normalHeight(12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Индикатор надёжности (.pw-meter): четыре полоски и подпись «Надёжный» или «Слабый»; null - пароль не введён.
class _Meter extends StatelessWidget {
  const _Meter({required this.state});

  final bool? state;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final bool? ok = state;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          AnimatedContainer(
            duration: context.kvReduceMotion ? Duration.zero : KvMotion.std,
            width: 18,
            height: 5,
            decoration: BoxDecoration(
              color: ok == true ? c.ok : (ok == false && i == 0 ? c.bad : c.surface3),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
        if (ok != null) ...[
          const SizedBox(width: 4 + 6),
          Text(
            ok ? 'Надёжный' : 'Слабый',
            style: context.kvText.label.copyWith(
              fontWeight: FontWeight.w600,
              color: ok ? c.ok : c.bad,
              height: KvTextStyles.normalHeight(12),
            ),
          ),
        ],
      ],
    );
  }
}

/// Строка требования (.pw-rule): круг 22 со значком 14 и текст 14, высота от 30.
class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.state, required this.text});

  final _Rule state;
  final String text;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final (Color bg, Color fg, KvIcons icon, Color color) = switch (state) {
      _Rule.ok => (c.okBg, c.ok, KvIcons.check, c.text),
      _Rule.bad => (c.badBg, c.bad, KvIcons.close, c.bad),
      _Rule.unk => (c.surface2, c.text3, KvIcons.minus, c.text2),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 30),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: KvIcon(icon, size: 14, color: fg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: context.kvText.sm.copyWith(color: color, height: 1.3)),
          ),
        ],
      ),
    );
  }
}
