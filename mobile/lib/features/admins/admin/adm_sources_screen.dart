import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Источники данных (adm-sources): подключения OPC UA и Modbus с откликом, опросом и числом тегов.
class AdmSourcesScreen extends ConsumerWidget {
  /// Создаёт экран.
  const AdmSourcesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DataSource>> async = ref.watch(sourcesProvider);
    final List<DataSource> sources = async.value ?? const <DataSource>[];
    final int tags = sources.fold<int>(0, (int a, DataSource s) => a + s.tags);
    return KvScreen(
      header: KvRootHeader(
        title: 'Источники данных',
        subtitle: async.hasValue
            ? '${sources.length} ${KvFormat.plural(sources.length, 'подключение', 'подключения', 'подключений')} · ${admTagsWord(tags)}'
            : ' ',
      ),
      foot: KvButton('Добавить источник', icon: KvIcons.plus, onPressed: () => context.kvPush(AdminsPaths.eSrcAdd)),
      children: [
        if (!async.hasValue) ...[const KvSkeleton.card(height: 140), const KvSkeleton.card(height: 140)],
        for (final DataSource s in sources) AdmSourceCard(source: s, onTap: () => context.kvPush(AdminsPaths.source(s.id))),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.link,
              title: 'Привязка тегов к агрегатам',
              subtitle: 'Н-101, АМС-1, АМС-2',
              onTap: () => context.kvPush(AdminsPaths.tags('N-101')),
            ),
          ],
        ),
      ],
    );
  }
}

/// Карточка источника данных: название, протокол и адрес, отклик, опрос и число тегов.
class AdmSourceCard extends StatelessWidget {
  /// Создаёт карточку.
  const AdmSourceCard({super.key, required this.source, required this.onTap});

  /// Источник.
  final DataSource source;

  /// Касание.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DataSource s = source;
    final bool warn = s.status == 'warn';
    return KvCard(
      onTap: onTap,
      semanticLabel: admSourceShort(s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdmTop(icon: admSourceIcon(s), status: KvStatus.parse(s.status), title: admSourceShort(s), subtitle: '${s.proto} · ${s.addr}'),
          AdmDividedRow(
            top: 12,
            gap: 10,
            children: [
              AdmKpi(value: s.enabled ? s.latency : 'нет данных', label: 'Отклик', dot: KvStatus.parse(s.status), warn: warn),
              AdmKpi(value: s.poll, label: 'Опрос'),
              AdmKpi(value: '${s.tags}', label: 'Тегов'),
            ],
          ),
        ],
      ),
    );
  }
}
