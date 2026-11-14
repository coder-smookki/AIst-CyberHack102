import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/api/api_client.dart';
import '../../data/providers.dart';

/// Лист «Подключение»: адрес цехового сервера, проверка связи и демонстрационный режим.
/// Смена режима или адреса завершает текущий сеанс: данные другого сервера открываются после нового входа.
Future<void> showServerSheet(BuildContext context) => showKvSheet<void>(context, builder: (BuildContext _) => const _ServerSheet());

class _ServerSheet extends ConsumerStatefulWidget {
  const _ServerSheet();

  @override
  ConsumerState<_ServerSheet> createState() => _ServerSheetState();
}

class _ServerSheetState extends ConsumerState<_ServerSheet> {
  late final TextEditingController _url = TextEditingController(text: ref.read(apiConfigProvider).baseUrl);
  late bool _demo = ref.read(apiConfigProvider).demo;
  bool _checking = false;
  String? _result;
  KvStatus _resultStatus = KvStatus.info;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _result = null;
    });
    final ApiClient probe = ApiClient(normalizeServerUrl(_url.text));
    try {
      final int ms = await probe.ping();
      _result = 'Сервер на связи · $ms мс';
      _resultStatus = KvStatus.ok;
    } on KvApiException catch (e) {
      _result = e.message;
      _resultStatus = KvStatus.bad;
    } finally {
      probe.close();
    }
    if (mounted) {
      setState(() => _checking = false);
    }
  }

  Future<void> _save() async {
    final ApiConfig before = ref.read(apiConfigProvider);
    final ApiConfigController ctl = ref.read(apiConfigProvider.notifier);
    await ctl.setBaseUrl(_url.text);
    await ctl.setDemo(_demo);
    final ApiConfig after = ref.read(apiConfigProvider);
    if (after != before && ref.read(sessionProvider) != null) {
      try {
        await ref.read(sessionProvider.notifier).logout();
      } on Object {
        ref.invalidate(sessionProvider);
      }
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return KvSheet(
      title: 'Подключение',
      actions: [
        KvButton('Проверить связь', kind: KvButtonKind.secondary, icon: KvIcons.wifi, loading: _checking, onPressed: _demo ? null : _check),
        KvButton('Сохранить', onPressed: _save),
      ],
      children: [
        KvList(
          noIcons: true,
          children: [
            KvRow(
              title: 'Демо-режим',
              subtitle: 'Данные встроенного примера, без сервера',
              minHeight: 56,
              padding: const EdgeInsets.symmetric(horizontal: KvSpace.s4, vertical: 4),
              trailing: KvToggle(value: _demo, semanticLabel: 'Демо-режим', onChanged: (bool v) => setState(() => _demo = v)),
            ),
          ],
        ),
        const SizedBox(height: KvSpace.s3),
        KvField(
          fieldKey: const Key('server-url'),
          label: 'Адрес цехового сервера',
          placeholder: kDefaultServerUrl,
          controller: _url,
          lead: KvIcons.server,
          enabled: !_demo,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _check(),
        ),
        if (_result != null) ...[
          const SizedBox(height: KvSpace.s2),
          Row(
            children: [
              KvDot(status: _resultStatus),
              const SizedBox(width: KvSpace.s2),
              Expanded(child: Text(_result!, style: context.kvText.caption.copyWith(color: c.text2))),
            ],
          ),
        ],
      ],
    );
  }
}

/// Строка «Сервер» для настроек и профиля: текущий адрес или «Демо-режим», касание открывает [showServerSheet].
class ServerSettingsRow extends ConsumerWidget {
  /// Создаёт строку.
  const ServerSettingsRow({super.key, this.padding = const EdgeInsets.symmetric(horizontal: KvSpace.s4, vertical: 4)});

  /// Внутренние поля строки.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ApiConfig cfg = ref.watch(apiConfigProvider);
    final String value = cfg.demo ? 'Демо-режим' : Uri.tryParse(cfg.baseUrl)?.authority ?? cfg.baseUrl;
    return KvRow(title: 'Сервер', minHeight: 52, padding: padding, value: value, onTap: () => showServerSheet(context));
  }
}
