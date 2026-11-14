import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../app/routes/entry_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/server_sheet.dart';
import '../profile/profile_screen.dart';
import '../service_common.dart';

/// Настройки (c-settings, c-settings-end): тема оформления, сканер, вход и данные, справка.
/// Тема переключается сразу на всём приложении и сохраняется на телефоне.
class SettingsScreen extends ConsumerStatefulWidget {
  /// Создаёт экран; [atEnd] - только нижняя часть (c-settings-end): вход и данные, справка.
  const SettingsScreen({super.key, this.atEnd = false});

  /// Показать только нижнюю часть экрана.
  final bool atEnd;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Timer? _themeTimer;
  int? _pendingTheme;

  @override
  void dispose() {
    _themeTimer?.cancel();
    super.dispose();
  }

  /// Тема меняется через 260 мс: сначала доезжает плашка сегмента, затем перекрашивается приложение.
  void _setTheme(int i) {
    setState(() => _pendingTheme = i);
    _themeTimer?.cancel();
    _themeTimer = Timer(context.kvReduceMotion ? Duration.zero : const Duration(milliseconds: 260), () {
      final ThemeMode mode = switch (i) {
        0 => ThemeMode.light,
        1 => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      unawaited(ref.read(deviceSettingsProvider.notifier).setThemeMode(mode));
      if (mounted) {
        setState(() => _pendingTheme = null);
      }
    });
  }

  /// Включает или выключает вход по биометрии: выключение забывает ключ сеанса на телефоне, включение на настоящем
  /// сервере сохраняет ключ текущего сеанса после системной проверки.
  Future<void> _setBiometrics(ServiceSettingsController ctl, bool on) async {
    await ctl.setBiometrics(on);
    final BioVault vault = ref.read(bioVaultProvider);
    if (!on) {
      await vault.clear();
      return;
    }
    final AuthSession? s = ref.read(sessionProvider);
    final String? token = ref.read(apiClientProvider).refreshToken;
    if (!ref.read(serverModeProvider) || s == null || token == null || !await vault.available()) {
      return;
    }
    if (await vault.authenticate('Подтвердите включение входа по биометрии')) {
      await vault.store(SavedAccount(email: s.user.email, name: s.user.name, title: s.user.title, roleCode: s.user.roleCode), token);
    } else {
      await ctl.setBiometrics(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeMode mode = ref.watch(deviceSettingsProvider.select((DeviceSettings s) => s.themeMode));
    final ServiceSettings s = ref.watch(serviceSettingsProvider);
    final ServiceSettingsController ctl = ref.read(serviceSettingsProvider.notifier);
    final int theme =
        _pendingTheme ??
        switch (mode) {
          ThemeMode.light => 0,
          ThemeMode.dark => 1,
          ThemeMode.system => 2,
        };
    const EdgeInsets rowPad = EdgeInsets.symmetric(horizontal: KvSpace.s4, vertical: 4);
    return KvScreen(
      header: KvHeader(title: 'Настройки', onBack: () => context.kvBack(EngineerServicePaths.profile)),
      children: [
        if (!widget.atEnd) ...[
          const KvSectionLabel('Оформление'),
          KvCard(
            padding: const EdgeInsets.all(6),
            child: KvSegment(items: const ['Светлая', 'Тёмная', 'Как в системе'], index: theme, onChanged: _setTheme),
          ),
          const KvSectionLabel('Сканер'),
          KvList(
            noIcons: true,
            children: [
              KvRow(
                title: 'Подписи узлов на экране',
                minHeight: 52,
                padding: rowPad,
                trailing: KvToggle(
                  value: s.labels,
                  semanticLabel: 'Подписи узлов на экране',
                  onChanged: (bool v) => unawaited(ctl.setLabels(v)),
                ),
              ),
              KvRow(
                title: 'Вибрация при находке',
                minHeight: 52,
                padding: rowPad,
                trailing: KvToggle(
                  value: s.haptics,
                  semanticLabel: 'Вибрация при находке',
                  onChanged: (bool v) => unawaited(ctl.setHaptics(v)),
                ),
              ),
              _SensitivityBlock(value: s.sensitivity, onChanged: (KvSensitivity v) => unawaited(ctl.setSensitivity(v))),
            ],
          ),
        ],
        const KvSectionLabel('Вход и данные'),
        KvList(
          noIcons: true,
          children: [
            const ServerSettingsRow(),
            KvRow(
              title: 'Вход по биометрии',
              minHeight: 52,
              padding: rowPad,
              trailing: KvToggle(
                value: s.biometrics,
                semanticLabel: 'Вход по биометрии',
                onChanged: (bool v) => unawaited(_setBiometrics(ctl, v)),
              ),
            ),
            KvRow(
              title: 'Фото в отчётах',
              minHeight: 52,
              padding: rowPad,
              trailing: KvToggle(
                value: s.reportPhotos,
                semanticLabel: 'Фото в отчётах',
                onChanged: (bool v) => unawaited(ctl.setReportPhotos(v)),
              ),
            ),
            KvRow(
              title: 'Очистить кэш снимков',
              minHeight: 52,
              padding: rowPad,
              value: KvFormat.typo(s.cacheLabel),
              onTap: () => showClearCacheDialog(context),
            ),
          ],
        ),
        const KvSectionLabel('Справка'),
        KvList(
          noIcons: true,
          children: [
            KvRow(title: 'Показать знакомство снова', minHeight: 52, padding: rowPad, onTap: () => context.kvUp(EntryPaths.aOnb1)),
            KvRow(
              title: 'О приложении',
              minHeight: 52,
              padding: rowPad,
              value: 'версия $kvAppVersionShort',
              onTap: () => showAboutSheet(context),
            ),
          ],
        ),
        const VersionLine('Настройки хранятся на телефоне и в профиле на сервере цеха'),
      ],
    );
  }
}

/// Блок чувствительности (.c-set-block): подпись, сегмент «Осторожно / Баланс / Максимум» и пояснение выбора.
class _SensitivityBlock extends StatelessWidget {
  const _SensitivityBlock({required this.value, required this.onChanged});

  final KvSensitivity value;
  final ValueChanged<KvSensitivity> onChanged;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.s4, 12, KvSpace.s4, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Чувствительность к дефектам',
            style: t.body.copyWith(fontWeight: FontWeight.w500, height: 1.38, color: context.kv.text),
          ),
          const SizedBox(height: 10),
          KvSegment(
            items: [for (final KvSensitivity v in KvSensitivity.values) v.label],
            index: value.index,
            onChanged: (int i) => onChanged(KvSensitivity.values[i]),
          ),
          const SizedBox(height: 10),
          Text(value.caption, style: t.caption),
        ],
      ),
    );
  }
}

/// Диалог очистки кэша снимков (c-cache): после подтверждения кэш очищается и показывается итог.
Future<void> showClearCacheDialog(BuildContext context) {
  final BuildContext screen = context;
  return showKvDialog<void>(context, builder: (BuildContext dialog) => _ClearCacheDialog(screen: screen));
}

class _ClearCacheDialog extends ConsumerStatefulWidget {
  const _ClearCacheDialog({required this.screen});

  final BuildContext screen;

  @override
  ConsumerState<_ClearCacheDialog> createState() => _ClearCacheDialogState();
}

class _ClearCacheDialogState extends ConsumerState<_ClearCacheDialog> {
  bool _busy = false;

  Future<void> _clear(String size) async {
    setState(() => _busy = true);
    if (!context.kvReduceMotion) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    await ref.read(serviceSettingsProvider.notifier).clearCache();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
    if (widget.screen.mounted) {
      showKvToast(widget.screen, kind: KvToastKind.ok, icon: KvIcons.trash, title: 'Кэш очищен', text: KvFormat.typo('Освобождено $size'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final String size = ref.watch(serviceSettingsProvider.select((ServiceSettings s) => s.cacheLabel));
    return KvDialog(
      icon: KvIcons.trash,
      tone: KvStatus.warn,
      title: 'Очистить кэш снимков?',
      text: KvFormat.typo('Будет удалено $size снимков, уже переданных на сервер цеха. Неотправленные осмотры останутся на телефоне.'),
      actions: [
        KvButton('Отмена', kind: KvButtonKind.secondary, onPressed: _busy ? null : () => Navigator.of(context).pop()),
        KvButton('Очистить', kind: KvButtonKind.danger, loading: _busy, onPressed: () => unawaited(_clear(size))),
      ],
    );
  }
}

/// Лист «О приложении» (c-about): логотип, версия, сервер цеха, версии моделей, разработчик и шрифт.
Future<void> showAboutSheet(BuildContext context) {
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => Consumer(
      builder: (BuildContext sheet, WidgetRef ref, Widget? child) {
        final KvTextStyles t = sheet.kvText;
        final Site? site = ref.watch(siteProvider).value;
        final ServerStatus? server = ref.watch(serverStatusProvider).value;
        final List<RecognitionModel> models = ref.watch(modelsProvider).value ?? const <RecognitionModel>[];
        String version(int i) => i < models.length ? 'версия ${models[i].version}' : '';
        return KvSheet(
          title: 'О приложении',
          children: [
            const Align(alignment: Alignment.centerLeft, child: KvLogo(height: 26)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('КСТ Визор', style: t.h2),
                Text(KvFormat.typo('AR-ассистент инженера · $kvAppVersion'), style: t.caption),
              ],
            ),
            KvKeyValues([
              ('Сервер цеха', '${site?.server ?? ''} · ${server?.version ?? ''}'),
              ('Модель дефектов', version(0)),
              ('Чтение манометров', version(1)),
              ('Разработка', 'команда AIst'),
              ('Шрифт', 'Geologica, SIL OFL'),
            ]),
          ],
        );
      },
    ),
  );
}
