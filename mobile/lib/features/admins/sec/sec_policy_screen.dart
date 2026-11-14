import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/adm_widgets.dart';

/// Политика с изменёнными полями.
SecurityPolicy secPolicyWith(
  SecurityPolicy p, {
  int? pwdMin,
  String? pwdClasses,
  int? lockAfter,
  int? lockMinutes,
  int? sessionHours,
  bool? biometrics,
}) => p.copyWith(
  pwdMin: pwdMin,
  pwdClasses: pwdClasses,
  lockAfter: lockAfter,
  lockMinutes: lockMinutes,
  sessionHours: sessionHours,
  biometrics: biometrics,
);

/// Срок сеанса для людей: 720 ч - «30 дн», 12 ч - «12 ч».
String secSessionText(int hours) => hours % 24 == 0 ? '${hours ~/ 24} дн' : '$hours ч';

/// Политика безопасности (sec-policy): пароли, блокировка входа, сеансы и вход по биометрии.
class SecPolicyScreen extends ConsumerWidget {
  /// Создаёт экран.
  const SecPolicyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SecurityPolicy? p = ref.watch(policyProvider).value;
    return KvScreen(
      header: const KvRootHeader(title: 'Политика', subtitle: 'Для всех учётных записей'),
      children: p == null
          ? const [KvSkeleton.card(height: 400)]
          : [
              const KvSectionLabel('Пароли'),
              KvList(
                children: [
                  KvRow(
                    icon: KvIcons.lock,
                    title: 'Длина и состав',
                    subtitle: 'От ${p.pwdMin} символов: ${p.pwdClasses}',
                    onTap: () => context.kvPush(AdminsPaths.ePolicyPwd),
                  ),
                  KvRow(
                    icon: KvIcons.key,
                    title: 'Временный пароль',
                    value: ty('${p.tempPwdHours} ч'),
                    onTap: () => context.kvPush(AdminsPaths.ePolicyPwd),
                  ),
                ],
              ),
              const KvSectionLabel('Блокировка и сеансы'),
              KvList(
                children: [
                  KvRow(
                    icon: KvIcons.ban,
                    title: 'Блокировка входа',
                    subtitle: ty(
                      'После ${p.lockAfter} ${KvFormat.plural(p.lockAfter, 'ошибки', 'ошибок', 'ошибок')} за ${p.lockMinutes} мин',
                    ),
                    onTap: () => _lockSheet(context, ref, p),
                  ),
                  KvRow(
                    icon: KvIcons.timer,
                    title: 'Сеанс',
                    subtitle: ty('Повторный вход через ${secSessionText(p.sessionHours)}'),
                    onTap: () => _sessionSheet(context, ref, p),
                  ),
                ],
              ),
              const KvSectionLabel('Способы входа'),
              KvList(
                children: [
                  KvRow(
                    icon: KvIcons.finger,
                    title: 'Вход по биометрии',
                    subtitle: 'Отпечаток или лицо',
                    trailing: KvToggle(
                      value: p.biometrics,
                      semanticLabel: 'Вход по биометрии',
                      onChanged: (bool v) => ref.read(securityRepositoryProvider).updatePolicy(secPolicyWith(p, biometrics: v)),
                    ),
                  ),
                ],
              ),
            ],
    );
  }

  void _lockSheet(BuildContext context, WidgetRef ref, SecurityPolicy p) {
    final BuildContext screen = context;
    const List<int> attempts = [5, 10, 20];
    const List<int> minutes = [5, 15, 30];
    int a = attempts.indexOf(p.lockAfter).clamp(0, 2);
    int m = minutes.indexOf(p.lockMinutes).clamp(0, 2);
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Блокировка входа',
        actions: [
          AdmBusyButton(
            'Сохранить',
            work: () =>
                ref.read(securityRepositoryProvider).updatePolicy(secPolicyWith(p, lockAfter: attempts[a], lockMinutes: minutes[m])),
            onDone: () => admCloseThen(sheet, () => _saved(screen)),
          ),
        ],
        children: [
          const AdmSub('Неудачных попыток до блокировки'),
          AdmSegment(items: const ['5', '10', '20'], initial: a, onBackground: true, onChanged: (int i) => a = i),
          const AdmSub('За период'),
          AdmSegment(items: const ['5 мин', '15 мин', '30 мин'], initial: m, onBackground: true, onChanged: (int i) => m = i),
          const AdmCaption('Попытки считает сервер. После блокировки вход снова доступен, когда период закончится.'),
        ],
      ),
    );
  }

  void _sessionSheet(BuildContext context, WidgetRef ref, SecurityPolicy p) {
    final BuildContext screen = context;
    const List<int> hours = [12, 168, 720];
    int h = hours.indexOf(p.sessionHours);
    if (h < 0) {
      h = 2;
    }
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Сеансы',
        actions: [
          AdmBusyButton(
            'Сохранить',
            work: () => ref.read(securityRepositoryProvider).updatePolicy(secPolicyWith(p, sessionHours: hours[h])),
            onDone: () => admCloseThen(sheet, () => _saved(screen)),
          ),
        ],
        children: [
          const AdmSub('Срок сеанса'),
          AdmSegment(items: const ['12 ч', '7 дн', '30 дн'], initial: h, onBackground: true, onChanged: (int i) => h = i),
          const AdmCaption('Через этот срок после входа нужен повторный вход. Несохранённый осмотр остаётся на устройстве.'),
        ],
      ),
    );
  }

  static void _saved(BuildContext screen) {
    if (screen.mounted) {
      showKvToast(screen, title: 'Политика сохранена', text: 'Применится на устройствах при подключении к серверу', kind: KvToastKind.ok);
    }
  }
}

/// Требования к паролю (e-policy-pwd): минимальная длина, буквы и цифры, срок временного пароля.
class SecPolicyPwdScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const SecPolicyPwdScreen({super.key});

  @override
  ConsumerState<SecPolicyPwdScreen> createState() => _SecPolicyPwdScreenState();
}

class _SecPolicyPwdScreenState extends ConsumerState<SecPolicyPwdScreen> {
  static const List<int> _lengths = [8, 10, 12, 14];
  int? _len;
  bool? _mixed;

  @override
  Widget build(BuildContext context) {
    final SecurityPolicy? p = ref.watch(policyProvider).value;
    if (p == null) {
      return KvScreen(
        header: KvHeader(title: 'Пароли', onBack: () => context.kvBack(AdminsPaths.secPolicy)),
        children: const [KvSkeleton.card()],
      );
    }
    final int len = _len ?? _lengths.indexOf(p.pwdMin).clamp(0, 3);
    final bool mixed = _mixed ?? p.pwdClasses.contains('цифр');
    return KvScreen(
      header: KvHeader(title: 'Пароли', subtitle: 'Требования для всех ролей', onBack: () => context.kvBack(AdminsPaths.secPolicy)),
      foot: AdmBusyButton(
        'Сохранить',
        work: () => ref
            .read(securityRepositoryProvider)
            .updatePolicy(secPolicyWith(p, pwdMin: _lengths[len], pwdClasses: mixed ? 'буквы и цифры' : 'любые')),
        onDone: () =>
            showKvToast(context, title: 'Политика сохранена', text: 'Новые требования - при следующей смене пароля', kind: KvToastKind.ok),
      ),
      children: [
        KvCard(
          title: 'Минимальная длина',
          child: KvSegment(items: const ['8', '10', '12', '14'], index: len, onChanged: (int i) => setState(() => _len = i)),
        ),
        KvList(
          noIcons: true,
          children: [
            KvRow(
              title: 'Буквы и цифры',
              subtitle: 'В пароле должны быть и те, и другие',
              trailing: KvToggle(value: mixed, semanticLabel: 'Буквы и цифры', onChanged: (bool v) => setState(() => _mixed = v)),
            ),
            KvRow(
              title: 'Временный пароль',
              subtitle: ty('Действует ${p.tempPwdHours} ч, затем обязательная смена'),
              trailing: const AdmToggle(initial: true, semanticLabel: 'Временный пароль'),
            ),
          ],
        ),
      ],
    );
  }
}
