import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'entry_flow.dart';
import 'entry_state.dart';
import 'widgets/entry_motion.dart';

/// Открывает лист входа по биометрии поверх экрана входа [screen].
Future<void> showEntryBioSheet(BuildContext screen) => showKvSheet<void>(screen, builder: (_) => EntryBioSheet(screen: screen));

/// Состояние листа биометрии.
enum _Bio {
  /// Ожидание касания сканера (login-bio).
  wait,

  /// Личность подтверждена (a-bio-ok).
  ok,

  /// Отпечаток не распознан (a-bio-fail).
  fail,
}

/// Лист «Вход по биометрии»: кольцо со сканером, затем «Личность подтверждена» с полосой ожидания
/// или «Отпечаток не распознан» с повтором. После подтверждения открывается домашний экран роли.
class EntryBioSheet extends ConsumerStatefulWidget {
  /// Создаёт лист поверх экрана входа [screen].
  const EntryBioSheet({super.key, required this.screen});

  /// Экран входа: с него выполняется переход после входа.
  final BuildContext screen;

  @override
  ConsumerState<EntryBioSheet> createState() => _EntryBioSheetState();
}

class _EntryBioSheetState extends ConsumerState<EntryBioSheet> {
  /// Попыток сканера на один лист, как у системного запроса биометрии.
  static const int _maxAttempts = 3;

  _Bio _state = _Bio.wait;
  int _failures = 0;
  int _shake = 0;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (ref.read(serverModeProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    if (_busy) {
      return;
    }
    _busy = true;
    final bool ok = await ref.read(bioScannerProvider).scan();
    _busy = false;
    if (!mounted) {
      return;
    }
    if (!ok) {
      setState(() {
        _failures++;
        _shake++;
        _state = _Bio.fail;
      });
      return;
    }
    setState(() => _state = _Bio.ok);
    _timer = Timer(context.kvReduceMotion ? Duration.zero : const Duration(milliseconds: 1700), _continue);
  }

  Future<void> _continue() async {
    _timer?.cancel();
    if (_busy || !mounted) {
      return;
    }
    _busy = true;
    final NavigatorState navigator = Navigator.of(context);
    try {
      final AuthSession session = await ref.read(sessionProvider.notifier).loginWithBiometrics();
      if (navigator.mounted) {
        navigator.pop();
      }
      if (widget.screen.mounted) {
        entryOpenHome(widget.screen, session);
      }
    } on KvApiException catch (e) {
      if (navigator.mounted) {
        navigator.pop();
      }
      if (widget.screen.mounted) {
        entryShowLoginFailure(widget.screen, e, email: ref.read(entrySavedAccountProvider).value?.email);
      }
    }
  }

  void _retry() => setState(() => _state = _Bio.wait);

  @override
  Widget build(BuildContext context) {
    final SavedAccount? account = ref.watch(entrySavedAccountProvider).value;
    final int left = math.max(0, _maxAttempts - _failures);
    final (String title, String text) = switch (_state) {
      _Bio.wait => ('Вход по биометрии', 'Приложите палец к сканеру отпечатка или посмотрите в камеру.'),
      _Bio.ok => ('Личность подтверждена', _okText(account)),
      _Bio.fail => (
        'Отпечаток не распознан',
        left > 0
            ? 'Приложите палец ещё раз или войдите с паролем. Осталось $left ${KvFormat.plural(left, 'попытка', 'попытки', 'попыток')}.'
            : 'Попытки закончились - войдите с паролем.',
      ),
    };
    final Widget password = KvButton('Войти с паролем', kind: KvButtonKind.secondary, onPressed: () => Navigator.of(context).maybePop());
    return AnimatedSize(
      duration: context.kvReduceMotion ? Duration.zero : KvMotion.std,
      curve: KvMotion.ease,
      alignment: Alignment.bottomCenter,
      child: KvSheet(
        actions: switch (_state) {
          _Bio.wait => [password],
          _Bio.ok => const <Widget>[],
          _Bio.fail => [if (left > 0) KvButton('Повторить', icon: KvIcons.refresh, onPressed: _retry), password],
        },
        children: [_BioBody(state: _state, title: title, text: text, shake: _shake, onRing: _onRing)],
      ),
    );
  }

  VoidCallback? get _onRing => switch (_state) {
    _Bio.wait => _scan,
    _Bio.ok => _continue,
    _Bio.fail => null,
  };

  /// «Алексей Смирнов, инженер-диагност. Открываем объекты смены.»
  String _okText(SavedAccount? a) {
    if (a == null) {
      return 'Открываем рабочий экран.';
    }
    final String target = switch (KvRole.fromCode(a.roleCode)) {
      KvRole.engineer || KvRole.senior => 'объекты смены',
      KvRole.master => 'смену',
      KvRole.operator => 'агрегаты',
      KvRole.admin => 'состояние системы',
      KvRole.sec => 'учётные записи',
    };
    return '${a.name}, ${a.title.toLowerCase()}. Открываем $target.';
  }
}

/// Содержимое листа (.bio): кольцо 128 со значком, заголовок, пояснение и полоса ожидания при подтверждении.
class _BioBody extends StatelessWidget {
  const _BioBody({required this.state, required this.title, required this.text, required this.shake, required this.onRing});

  final _Bio state;
  final String title;
  final String text;
  final int shake;
  final VoidCallback? onRing;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Padding(
      padding: const EdgeInsets.only(top: KvSpace.s2, bottom: KvSpace.s1),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BioRing(key: ValueKey<(_Bio, int)>((state, shake)), state: state, onTap: onRing),
          const SizedBox(height: KvSpace.s3 + KvSpace.s2),
          Text(title, textAlign: TextAlign.center, style: t.title.copyWith(height: 1.25)),
          const SizedBox(height: KvSpace.s2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: t.sm.copyWith(color: c.text2, height: 1.45),
            ),
          ),
          if (state == _Bio.ok) ...[const SizedBox(height: KvSpace.s2 + KvSpace.s3), const _BioBar()],
        ],
      ),
    );
  }
}

/// Кольцо сканера (.bio-ring): ожидание - расходящийся контур, подтверждение - всплывающий зелёный круг,
/// отказ - встряхивание красного кольца.
class _BioRing extends StatefulWidget {
  const _BioRing({super.key, required this.state, required this.onTap});

  final _Bio state;
  final VoidCallback? onTap;

  @override
  State<_BioRing> createState() => _BioRingState();
}

class _BioRingState extends State<_BioRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _duration);

  Duration get _duration => switch (widget.state) {
    _Bio.wait => const Duration(milliseconds: 2000),
    _Bio.ok => const Duration(milliseconds: 120 + 500),
    _Bio.fail => const Duration(milliseconds: 180 + 450),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.kvReduceMotion) {
      _c.value = widget.state == _Bio.wait ? 0 : 1;
    } else if (!_c.isAnimating && _c.value == 0) {
      widget.state == _Bio.wait ? _c.repeat() : _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final (Color ring, Color core, KvIcons icon) = switch (widget.state) {
      _Bio.wait => (c.tint2, c.btnPrimary, KvIcons.finger),
      _Bio.ok => (c.okBg, c.ok, KvIcons.check),
      _Bio.fail => (c.badBg, c.bad, KvIcons.finger),
    };
    final Widget coreCircle = Container(
      width: 84,
      height: 84,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: core, shape: BoxShape.circle),
      child: KvIcon(icon, size: 44, color: c.onBrand),
    );
    final Widget body = RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (BuildContext context, Widget? _) {
          final double v = _c.value;
          Widget inner = coreCircle;
          if (widget.state == _Bio.ok && !_c.isCompleted) {
            final double p = kEntryPopCurve.transform(((v * 620 - 120) / 500).clamp(0.0, 1.0));
            inner = Opacity(
              opacity: p.clamp(0.0, 1.0),
              child: Transform.scale(scale: 0.4 + 0.6 * p, child: coreCircle),
            );
          }
          Widget ringWidget = Container(
            width: 128,
            height: 128,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
            child: inner,
          );
          if (widget.state == _Bio.wait && !context.kvReduceMotion) {
            final double e = KvMotion.ease.transform(v);
            ringWidget = Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                ringWidget,
                Transform.scale(
                  scale: 1 + 0.3 * e,
                  child: Opacity(
                    opacity: 0.55 * (1 - e),
                    child: Container(
                      width: 128,
                      height: 128,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: c.brand, width: 2),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          if (widget.state == _Bio.fail && !_c.isCompleted) {
            ringWidget = Transform.translate(offset: Offset(_shakeAt(v * 630), 0), child: ringWidget);
          }
          return ringWidget;
        },
      ),
    );
    if (widget.onTap == null) {
      return body;
    }
    return KvPressable(
      onTap: widget.onTap,
      shape: BoxShape.circle,
      semanticLabel: widget.state == _Bio.ok ? 'Продолжить' : 'Приложить палец',
      child: body,
    );
  }

  /// Смещение встряхивания bioShake (0 → -8 → 7 → -5 → 3 → 0) через [ms] миллисекунд, с задержкой 180 мс.
  double _shakeAt(double ms) {
    final double p = ((ms - 180) / 450).clamp(0.0, 1.0);
    const List<double> frames = [0, -8, 7, -5, 3, 0];
    final double pos = p * 5;
    final int i = pos.floor().clamp(0, 4);
    final double f = Curves.ease.transform(pos - i);
    return frames[i] + (frames[i + 1] - frames[i]) * f;
  }
}

/// Полоса ожидания перехода (.bio-bar): зелёная заливка растёт за 1,6 с после задержки 0,2 с.
class _BioBar extends StatefulWidget {
  const _BioBar();

  @override
  State<_BioBar> createState() => _BioBarState();
}

class _BioBarState extends State<_BioBar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.kvReduceMotion) {
      _c.value = 1;
    } else if (!_c.isAnimating && _c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Animation<double> t = CurvedAnimation(
      parent: _c,
      curve: const Interval(200 / 1800, 1, curve: KvMotion.ease),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        width: 120,
        height: 4,
        child: ColoredBox(
          color: c.surface3,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: t,
              builder: (BuildContext context, Widget? fill) =>
                  Transform(alignment: Alignment.centerLeft, transform: Matrix4.diagonal3Values(t.value, 1, 1), child: fill),
              child: ColoredBox(color: c.ok, child: const SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
  }
}
