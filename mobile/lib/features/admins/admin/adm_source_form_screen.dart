import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/navigation/kv_page.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Параметры источника (e-src-*-edit) и новый источник (e-src-add): протокол, название, адрес, опрос и защита.
class AdmSourceFormScreen extends ConsumerStatefulWidget {
  /// Создаёт форму; без [sourceId] - новый источник.
  const AdmSourceFormScreen({super.key, this.sourceId});

  /// Код изменяемого источника.
  final String? sourceId;

  @override
  ConsumerState<AdmSourceFormScreen> createState() => _AdmSourceFormScreenState();
}

class _AdmSourceFormScreenState extends ConsumerState<AdmSourceFormScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _addr = TextEditingController();
  int? _proto;
  int? _poll;
  bool _filled = false;

  static const List<String> _polls = ['0,5 с', '1 с', '2 с', '5 с'];

  @override
  void dispose() {
    _name.dispose();
    _addr.dispose();
    super.dispose();
  }

  void _fill(DataSource? s) {
    if (_filled) {
      return;
    }
    _filled = true;
    _name.text = s == null ? 'Сервер ввода-вывода, резерв' : admSourceShort(s);
    _addr.text = s == null ? 'opc.tcp://10.20.1.18:4840' : s.addr;
  }

  @override
  Widget build(BuildContext context) {
    final String? id = widget.sourceId;
    final DataSource? s = id == null
        ? null
        : ref.watch(sourcesProvider.select((AsyncValue<List<DataSource>> a) => a.value?.where((DataSource x) => x.id == id).firstOrNull));
    if (id != null && s == null) {
      return KvScreen(
        header: KvHeader(title: 'Параметры', onBack: () => context.kvBack(AdminsPaths.admSources)),
        children: const [KvSkeleton.card()],
      );
    }
    _fill(s);
    final bool modbus = _proto == null ? (s?.proto.startsWith('Modbus') ?? false) : _proto == 1;
    final int poll = _poll ?? (s == null ? 1 : (s.poll == '2 с' ? 2 : 1));
    return KvScreen(
      header: KvHeader(
        title: s == null ? 'Новый источник' : 'Параметры',
        subtitle: s == null ? 'Подключение только на чтение' : admSourceShort(s),
        onBack: () => context.kvBack(s == null ? AdminsPaths.admSources : AdminsPaths.source(s.id)),
      ),
      foot: s != null
          ? AdmBusyButton(
              'Сохранить',
              onDone: () => showKvToast(
                context,
                title: 'Параметры сохранены',
                text: ty('Опрос перезапущен, отклик ${s.latency}'),
                kind: KvToastKind.ok,
              ),
            )
          : AdmBusyButton(
              'Проверить и подключить',
              wait: const Duration(milliseconds: 1400),
              work: () => ref
                  .read(adminRepositoryProvider)
                  .addSource(name: _name.text.trim(), proto: modbus ? 'Modbus TCP' : 'OPC UA', addr: _addr.text.trim()),
              onDone: () => context.pushReplacement(AdminsPaths.eSrcAddOk, extra: const KvNavExtra(transition: KvTransition.fade)),
            ),
      children: [
        KvSegment(
          items: const ['OPC UA', 'Modbus TCP'],
          index: modbus ? 1 : 0,
          onBackground: true,
          onChanged: (int i) => setState(() => _proto = i),
        ),
        KvField(label: 'Название', controller: _name, fieldKey: const ValueKey<String>('src-name')),
        KvField(label: 'Адрес', controller: _addr, lead: KvIcons.link, autofocus: s == null, fieldKey: const ValueKey<String>('src-addr')),
        const KvSectionLabel('Опрос'),
        KvSegment(items: _polls, index: poll, onBackground: true, onChanged: (int i) => setState(() => _poll = i)),
        KvList(
          children: [
            const KvRow(
              icon: KvIcons.lock,
              title: 'Только чтение',
              subtitle: 'Запись в АСУ ТП запрещена',
              trailing: AdmToggle(initial: true),
            ),
            KvRow(
              icon: KvIcons.shieldCheck,
              title: modbus ? 'Изолированный сегмент' : 'Подпись и шифрование',
              subtitle: modbus ? 'Доступ только из сети КИП' : 'Basic256Sha256 · сертификат принят',
              trailing: const AdmToggle(initial: true),
            ),
          ],
        ),
      ],
    );
  }
}

/// Источник подключён (e-src-add-ok): найденные теги, отклик и переход к привязке тегов.
class AdmSourceAddedScreen extends ConsumerWidget {
  /// Создаёт экран.
  const AdmSourceAddedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return KvScreen(
      surface: true,
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KvButton('Привязать теги', icon: KvIcons.link, onPressed: () => context.kvPush(AdminsPaths.tags('N-101'))),
          const SizedBox(height: KvSpace.s2),
          KvButton('Готово', kind: KvButtonKind.secondary, onPressed: () => context.kvFade(AdminsPaths.admSources)),
        ],
      ),
      children: [
        const AdmDone(
          title: 'Источник подключён',
          text: 'Сервер ввода-вывода, резерв · OPC UA · подпись и шифрование',
          stats: [('46', 'тегов найдено'), ('118 мс', 'отклик')],
        ),
        KvNote(icon: KvIcons.info, text: ty('Теги ещё не привязаны к агрегатам. Без привязки правила их не используют.')),
      ],
    );
  }
}
