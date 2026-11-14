import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'bio_sheet.dart';
import 'entry_flow.dart';
import 'entry_state.dart';

/// Вход (эталонный экран раздела): фото оборудования в синем тоне, логотип, название и белый лист
/// «Вход в систему» с почтой, паролем, входом по биометрии и подсказкой о восстановлении пароля.
///
/// Пока сервер проверяет учётную запись, поля приглушены, кнопка показывает спиннер, а вместо подсказки -
/// «Проверяем учётную запись на КСТ-СРВ-02» (состояние a-login-loading). Ошибки входа - уведомление сверху;
/// заблокированная запись и недоступный сервер открывают свои экраны.
///
/// [scenario] - скрытый вариант входа прототипа (a-temp-login, a-blocked-login, a-login-master ...): поля
/// заполняются готовыми данными сценария. [checking] - экран «Вход · проверка»: повторяет последнюю попытку входа.
class LoginScreen extends ConsumerStatefulWidget {
  /// Создаёт экран входа.
  const LoginScreen({super.key, this.scenario, this.checking = false, this.email});

  /// Идентификатор скрытого варианта входа или null.
  final String? scenario;

  /// Почта, с которой открывается вход (после завершённого сеанса): готовые данные сценария тогда не подставляются,
  /// пароль сотрудник вводит сам; null - пустое поле или данные сценария.
  final String? email;

  /// Экран проверки учётной записи: вход повторяется сам.
  final bool checking;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();
  bool _busy = false;
  bool _noBio = false;

  @override
  void initState() {
    super.initState();
    _busy = widget.checking;
    _email.text = widget.email ?? '';
    final String? scenario = widget.scenario;
    if (scenario != null && widget.email == null) {
      unawaited(ref.read(authRepositoryProvider).scenarioLogin(scenario).then(_applyPreset));
    }
    if (widget.checking) {
      final PendingLogin? pending = ref.read(entryPendingLoginProvider);
      if (pending != null) {
        _email.text = pending.email;
        _password.text = pending.password;
        WidgetsBinding.instance.addPostFrameCallback((_) => _attempt(pending.email, pending.password, minimum: KvMotion.wait));
      } else {
        unawaited(ref.read(entrySavedAccountProvider.future).then(_applySaved));
      }
    }
  }

  void _applyPreset(LoginPreset? preset) {
    if (!mounted || preset == null) {
      return;
    }
    setState(() {
      _email.text = preset.email;
      _password.text = preset.password;
      _noBio = !preset.biometrics;
    });
  }

  /// Экран проверки без попытки входа (открыт напрямую): почта сохранённой учётной записи и маска пароля.
  void _applySaved(SavedAccount? account) {
    if (!mounted || account == null) {
      return;
    }
    setState(() {
      _email.text = account.email;
      _password.text = '•' * 10;
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    final String email = _email.text.trim();
    if (email.isEmpty || _password.text.isEmpty) {
      showKvToast(context, title: 'Не удалось войти', text: 'Введите почту и пароль.');
      return;
    }
    await _attempt(email, _password.text);
  }

  /// Вход с почтой [email] и паролем [password]; [minimum] - сколько показывать проверку как минимум.
  Future<void> _attempt(String email, String password, {Duration minimum = Duration.zero}) async {
    if (!mounted) {
      return;
    }
    ref.read(entryPendingLoginProvider.notifier).remember(email, password);
    setState(() => _busy = true);
    final Future<void> pause = minimum == Duration.zero || context.kvReduceMotion ? Future<void>.value() : Future<void>.delayed(minimum);
    try {
      final AuthSession session = await ref.read(sessionProvider.notifier).login(email, password);
      await pause;
      if (mounted) {
        entryOpenHome(context, session);
      }
    } on KvApiException catch (e) {
      await pause;
      _failed(e, email);
    }
  }

  void _failed(KvApiException e, String email) {
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    entryShowLoginFailure(context, e, email: email);
  }

  void _forgot() {
    final SupportContact? sec = ref.read(entrySecurityContactProvider).value;
    showKvToast(
      context,
      kind: KvToastKind.info,
      icon: KvIcons.shield,
      title: 'Пароль восстанавливает администратор ИБ',
      text: sec == null ? null : '${sec.name} · ${sec.email}',
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(entrySecurityContactProvider);
    final String server = ref.watch(siteProvider.select((AsyncValue<Site> s) => s.value?.server ?? ''));
    final bool saved = ref.watch(entrySavedAccountProvider.select((AsyncValue<SavedAccount?> a) => a.value != null || a.isLoading));
    final bool noBio = _noBio || !saved;
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final MediaQueryData mq = MediaQuery.of(context);
    final double keyboard = mq.viewInsets.bottom;
    final double bottomPad = 28 + math.max(0, mq.viewPadding.bottom - KvLayout.homeIndicator);
    final Duration fade = context.kvReduceMotion ? Duration.zero : KvMotion.std;

    final Widget hero = DecoratedBox(
      decoration: BoxDecoration(
        color: c.brandDeep,
        image: const DecorationImage(image: AssetImage('assets/images/hero.jpg'), fit: BoxFit.cover),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: c.heroOverlay),
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, math.max(68, mq.padding.top + 14), 24, 54),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const KvLogo(white: true, height: 40),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'КСТ Визор',
                    style: t.title.copyWith(fontSize: 34, height: 1.1, letterSpacing: -0.34, color: const Color(0xFFFFFFFF)),
                  ),
                  const SizedBox(height: 8),
                  Opacity(
                    opacity: 0.86,
                    child: Text('AR-ассистент инженера', style: t.base.copyWith(color: const Color(0xFFFFFFFF))),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    final Widget fields = AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KvField(
            fieldKey: const Key('login-email'),
            label: 'Почта',
            placeholder: 'name@company.ru',
            controller: _email,
            lead: KvIcons.mail,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email, AutofillHints.username],
            onSubmitted: (_) => _passwordFocus.requestFocus(),
          ),
          const SizedBox(height: KvSpace.s3),
          KvField(
            fieldKey: const Key('login-password'),
            label: 'Пароль',
            placeholder: 'Введите пароль',
            controller: _password,
            focusNode: _passwordFocus,
            lead: KvIcons.lock,
            obscure: true,
            reveal: !_busy,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _login(),
          ),
        ],
      ),
    );

    final Widget sheet = Container(
      padding: EdgeInsets.fromLTRB(20, 26, 20, bottomPad),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(KvRadius.sheet)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Вход в систему', style: t.title),
          const SizedBox(height: 18),
          IgnorePointer(
            ignoring: _busy,
            child: AnimatedOpacity(opacity: _busy ? 0.55 : 1, duration: fade, curve: KvMotion.ease, child: fields),
          ),
          const SizedBox(height: 18 + 2),
          KvButton('Войти', loading: _busy, onPressed: _login),
          const SizedBox(height: KvSpace.s2),
          if (noBio)
            const _LoginWait(icon: KvIcons.finger, text: 'Биометрия - после первого входа с паролем')
          else
            KvButton(
              'Войти по биометрии',
              kind: KvButtonKind.secondary,
              icon: KvIcons.finger,
              onPressed: _busy ? null : () => showEntryBioSheet(context),
            ),
          const SizedBox(height: KvSpace.s2),
          if (_busy)
            _LoginWait(icon: KvIcons.server, text: 'Проверяем учётную запись на $server')
          else
            Center(child: KvLink('Забыли пароль?', onPressed: _forgot)),
        ],
      ),
    );

    return KvScreen(
      immersive: true,
      surface: true,
      lightStatusBar: true,
      lightHome: c.isDark,
      stagger: KvStagger.none,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) => SingleChildScrollView(
          padding: EdgeInsets.only(bottom: keyboard),
          physics: const ClampingScrollPhysics(),
          child: KvHeroSheetLayout(minHeight: math.max(0, box.maxHeight - keyboard), hero: hero, sheet: sheet),
        ),
      ),
    );
  }
}

/// Строка ожидания под кнопками входа (.login-wait): синий значок 18 и подпись 13 по центру, высота 44.
class _LoginWait extends StatelessWidget {
  const _LoginWait({required this.icon, required this.text});

  final KvIcons icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: KvLayout.touch),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          KvIcon(icon, size: 18, color: c.brand),
          const SizedBox(width: KvSpace.s2),
          Flexible(
            child: Text(
              KvFormat.typo(text),
              textAlign: TextAlign.center,
              style: context.kvText.caption.copyWith(height: KvTextStyles.normalHeight(13)),
            ),
          ),
        ],
      ),
    );
  }
}
