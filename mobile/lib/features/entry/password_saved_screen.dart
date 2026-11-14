import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../app/shell/role_tabs.dart';
import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'entry_state.dart';
import 'widgets/entry_blocks.dart';
import 'widgets/entry_motion.dart';

/// Что доступно роли: подпись под рядом значков вкладок на экране «Пароль сохранён».
const Map<KvRole, String> _roleAbout = {
  KvRole.engineer: 'Объекты и карточки агрегатов, осмотр со сканером, находки и диагностика, история, ассистент, свои отчёты.',
  KvRole.senior: 'Инженер, который подтверждает замечания коллег и видит отчёты участка.',
  KvRole.master: 'Подтверждает замечания, меняет режим агрегатов, назначает осмотры и видит все отчёты.',
  KvRole.operator: 'Наблюдает за оборудованием и сообщает о признаках неисправности.',
  KvRole.admin: 'Системный программист: обслуживает сервер, базу и модели, управляет стендом демонстрации.',
  KvRole.sec: 'Ведёт учётные записи и роли, настраивает политику безопасности, просматривает журнал.',
};

/// Кнопка перехода к работе по роли.
const Map<KvRole, String> _roleGo = {
  KvRole.engineer: 'Перейти к объектам',
  KvRole.senior: 'Перейти к объектам',
  KvRole.master: 'Перейти к смене',
  KvRole.operator: 'Перейти к агрегатам',
  KvRole.admin: 'Перейти к системе',
  KvRole.sec: 'Перейти к пользователям',
};

/// «Пароль сохранён» (a-pass-ok): зелёная галочка, роль сотрудника с рядом значков её вкладок, переключатель
/// входа по отпечатку и переход к работе.
class PasswordSavedScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const PasswordSavedScreen({super.key});

  @override
  ConsumerState<PasswordSavedScreen> createState() => _PasswordSavedScreenState();
}

class _PasswordSavedScreenState extends ConsumerState<PasswordSavedScreen> {
  bool _bio = false;

  void _go(KvRole role) {
    if (role == KvRole.engineer) {
      context.kvFade(EngineerInspectPaths.fCErshovHome);
    } else {
      context.kvFade(kvRoleHome(role));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthSession? session = ref.watch(sessionProvider);
    final SupportContact? sec = ref.watch(entrySecurityContactProvider).value;
    final KvRole role = session?.user.role ?? KvRole.engineer;
    final KvTextStyles t = context.kvText;
    final List<KvTabSpec> tabs = kvRoleTabs[role] ?? const <KvTabSpec>[];
    return KvScreen(
      padding: const EdgeInsets.fromLTRB(KvSpace.gutter, KvSpace.s5, KvSpace.gutter, 0),
      children: [
        const EntryStateHero(
          icon: KvIcons.check,
          tone: EntryHeroTone.ok,
          title: 'Пароль сохранён',
          text: TextSpan(text: 'Временный пароль больше не действует. Другие сеансы этой учётной записи закрыты.'),
        ),
        KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Роль: ${session?.user.roleTitle ?? role.label}', style: t.h2),
              if (sec != null) Text(KvFormat.typo('Назначил администратор ИБ ${sec.short}'), style: t.caption),
              const SizedBox(height: KvSpace.s3),
              EntryStagger(child: _RolePill(tabs: tabs)),
              const SizedBox(height: KvSpace.s3),
              Text(_roleAbout[role] ?? '', style: t.caption),
            ],
          ),
        ),
        if (session?.biometricsAllowed ?? true)
          KvCard(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: KvLayout.touch),
              child: Row(
                children: [
                  const KvRowIcon(icon: KvIcons.finger),
                  const SizedBox(width: KvSpace.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Входить по отпечатку', style: t.bodyM),
                        Text('Меняется в профиле', style: t.caption),
                      ],
                    ),
                  ),
                  const SizedBox(width: KvSpace.s3),
                  KvToggle(value: _bio, semanticLabel: 'Входить по отпечатку', onChanged: (bool v) => setState(() => _bio = v)),
                ],
              ),
            ),
          ),
      ],
      foot: KvButton(_roleGo[role] ?? 'Перейти к работе', iconRight: KvIcons.arrowRight, onPressed: () => _go(role)),
    );
  }
}

/// Ряд значков вкладок роли (.role-pill): первая вкладка подсвечена, центральная кнопка - синий круг.
class _RolePill extends StatelessWidget {
  const _RolePill({required this.tabs});

  final List<KvTabSpec> tabs;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s2, vertical: 6),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(KvRadius.pill)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (int i = 0; i < tabs.length; i++)
            EntryStaggerItem(
              index: i + 1,
              duration: 360,
              child: Semantics(
                label: tabs[i].label,
                child: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tabs[i].center ? c.btnPrimary : (i == 0 ? c.tint : null),
                  ),
                  child: KvIcon(tabs[i].icon, size: 22, color: tabs[i].center ? c.onBrand : (i == 0 ? c.brand : c.text2)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
