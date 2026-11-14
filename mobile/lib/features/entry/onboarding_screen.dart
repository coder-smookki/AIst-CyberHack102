import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/entry_routes.dart';
import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import 'widgets/entry_blocks.dart';
import 'widgets/entry_motion.dart';
import 'widgets/onboarding_art.dart';

/// Шаг знакомства: заголовок и пояснение под иллюстрацией.
typedef _Step = ({String title, String text});

/// Тексты трёх шагов знакомства (ONB в screens/10_entry.js).
const List<_Step> _steps = [
  (title: 'Наведите камеру на шильдик', text: 'Приложение определит агрегат и откроет его карточку.'),
  (title: 'Обойдите агрегат', text: 'Рамки покажут осмотренные узлы и те, что требуют внимания.'),
  (title: 'Зафиксируйте результат одним касанием', text: 'Находка сохранится в истории оборудования и попадёт в отчёт.'),
];

/// Знакомство с приложением (показывается только при первом запуске): логотип и счётчик шага, иллюстрация,
/// заголовок с пояснением, точки шагов, «Пропустить» и «Далее» / «Начать работу».
class OnboardingScreen extends ConsumerWidget {
  /// Создаёт шаг знакомства [step] (1-3).
  const OnboardingScreen({super.key, required this.step});

  /// Номер шага 1-3.
  final int step;

  /// Пути шагов знакомства.
  static const List<String> _paths = [EntryPaths.aOnb1, EntryPaths.aOnb2, EntryPaths.aOnb3];

  Future<void> _finish(BuildContext context, WidgetRef ref) async {
    context.kvFade(EntryPaths.login);
    await ref.read(deviceSettingsProvider.notifier).completeOnboarding();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool narrow = entryNarrow(context);
    final bool last = step == 3;
    final _Step s = _steps[step - 1];

    final Widget top = SizedBox(
      height: KvLayout.touch,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const KvLogo.themed(height: 30),
          Text(
            '0$step / 03',
            style: t.sm.copyWith(
              fontWeight: FontWeight.w500,
              color: c.text2,
              letterSpacing: 0.56,
              height: KvTextStyles.normalHeight(14),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    final Widget art = ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: Container(
        height: double.infinity,
        padding: const EdgeInsets.all(KvSpace.s3),
        decoration: BoxDecoration(color: c.tint2, borderRadius: BorderRadius.circular(KvRadius.lg)),
        child: OnboardingArt(step: step),
      ),
    );

    final Widget copy = Padding(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            s.title,
            textAlign: TextAlign.center,
            style: t.title.copyWith(fontSize: narrow ? 20 : 22, height: 1.25),
          ),
          const SizedBox(height: KvSpace.s2),
          Text(
            s.text,
            textAlign: TextAlign.center,
            style: t.body.copyWith(fontSize: narrow ? 14 : 15, color: c.text2, height: 1.45),
          ),
        ],
      ),
    );

    final Widget foot = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Dots(active: step),
        const SizedBox(height: KvSpace.s1 + KvSpace.s1),
        if (last)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: KvLayout.touch),
            child: Center(
              child: Text(
                'Показывается только при первом запуске',
                textAlign: TextAlign.center,
                style: t.caption.copyWith(color: c.text3, height: KvTextStyles.normalHeight(13)),
              ),
            ),
          )
        else
          Center(child: KvLink('Пропустить', onPressed: () => _finish(context, ref))),
        const SizedBox(height: KvSpace.s1),
        KvButton(last ? 'Начать работу' : 'Далее', onPressed: last ? () => _finish(context, ref) : () => context.kvPush(_paths[step])),
      ],
    );

    return KvScreen(
      surface: true,
      stagger: KvStagger.none,
      body: EntryStagger(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final Widget column = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 2),
                EntryStaggerItem(index: 0, child: top),
                const SizedBox(height: KvSpace.s5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Flexible(child: EntryStaggerItem(index: 1, child: art)),
                      const SizedBox(height: KvSpace.s6),
                      EntryStaggerItem(index: 2, child: copy),
                    ],
                  ),
                ),
                const SizedBox(height: KvSpace.s5),
                EntryStaggerItem(index: 3, child: foot),
                const SizedBox(height: 34),
              ],
            );
            final double homeGap = MediaQuery.viewPaddingOf(context).bottom - KvLayout.homeIndicator;
            final Widget padded = Padding(
              padding: EdgeInsets.fromLTRB(KvSpace.s5, 0, KvSpace.s5, homeGap > 0 ? homeGap : 0),
              child: column,
            );
            if (box.maxHeight >= 600) {
              return padded;
            }
            return SingleChildScrollView(child: SizedBox(height: 600, child: padded));
          },
        ),
      ),
    );
  }
}

/// Точки шагов (.onb-dots): активная растягивается с 6 до 22 px при появлении экрана.
class _Dots extends StatefulWidget {
  const _Dots({required this.active});

  final int active;

  @override
  State<_Dots> createState() => _DotsState();
}

class _DotsState extends State<_Dots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150 + 500),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (context.kvReduceMotion) {
      _c.value = 1;
    } else {
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
      curve: const Interval(150 / 650, 1, curve: KvMotion.ease),
    );
    return Semantics(
      label: 'Шаг ${widget.active} из 3',
      child: SizedBox(
        height: 10,
        child: AnimatedBuilder(
          animation: t,
          builder: (BuildContext context, Widget? _) => Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (int i = 1; i <= 3; i++) ...[
                if (i > 1) const SizedBox(width: 6),
                Container(
                  width: i == widget.active ? 6 + 16 * t.value : 6,
                  height: 6,
                  decoration: BoxDecoration(color: i == widget.active ? c.brand : c.surface3, borderRadius: BorderRadius.circular(3)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
