import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import '../shared/bridges.dart';
import 'inspect_providers.dart';
import 'widgets/inspect_blocks.dart';

/// Отбор поиска по типу агрегата: все, насосы in-line, винтовые.
const List<String> _kinds = ['Все', 'Насосы in-line', 'Винтовые'];

/// Поиск агрегата (search; без результата - b-search-empty): строка поиска с фокусом, отбор по типу,
/// найденные агрегаты с подсветкой совпадения, недавние запросы и поиск по шильдику камерой.
class SearchScreen extends ConsumerStatefulWidget {
  /// Создаёт поиск с запросом [initialQuery].
  const SearchScreen({super.key, this.initialQuery});

  /// Запрос при открытии.
  final String? initialQuery;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _query = TextEditingController(text: widget.initialQuery ?? '');
  int _kind = 0;
  List<Equipment>? _shown;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQuery);
  }

  void _onQuery() => setState(() {});

  @override
  void dispose() {
    _query
      ..removeListener(_onQuery)
      ..dispose();
    super.dispose();
  }

  /// Открыть карточку найденного агрегата и запомнить запрос.
  void _open(Equipment u) {
    ref.read(recentSearchesProvider.notifier).remember(_query.text.trim().isEmpty ? u.code : _query.text, u.id);
    context.kvPush(EngineerInspectPaths.card(u.id));
  }

  @override
  Widget build(BuildContext context) {
    final String q = _query.text.trim();
    final AsyncValue<List<Equipment>> found = q.isEmpty ? const AsyncData<List<Equipment>>(<Equipment>[]) : ref.watch(unitSearchProvider(q));
    if (found.hasValue) {
      _shown = found.value;
    }
    final List<Equipment> all = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final List<Equipment> results = (_shown ?? const <Equipment>[]).where(_kindMatches).toList();
    final bool empty = q.isNotEmpty && found.hasValue && results.isEmpty;
    return KvScreen(
      header: _SearchBar(
        controller: _query,
        autofocus: true,
        onSubmitted: (String text) {
          if (text.trim().isNotEmpty && found.hasValue) {
            ref.read(recentSearchesProvider.notifier).remember(text, results.firstOrNull?.id);
          }
        },
      ),
      children: [
        KvFilterChips(items: [for (final String k in _kinds) KvFilterItem(k)], selected: _kind, onSelected: (int i) => setState(() => _kind = i)),
        if (empty) ...[
          KvEmpty(
            title: 'Агрегат не найден',
            text: 'На станции нет агрегата «$q». Проверьте номер или найдите агрегат по шильдику камерой.',
            action: KvButton('Найти по шильдику', icon: KvIcons.scan, expand: false, onPressed: () => context.kvUp(EngineerInspectPaths.bScanSearch)),
          ),
          Center(child: KvLink('Все агрегаты станции · ${all.length}', onPressed: () => context.kvBack(EngineerInspectPaths.objects))),
        ] else ...[
          if (q.isNotEmpty && results.isNotEmpty) ...[
            KvSectionLabel('Найдено: ${results.length} · ${_matchKind(results, q)}'),
            KvList(children: [for (final Equipment u in results) _ResultRow(unit: u, query: q, onTap: () => _open(u))]),
          ],
          const _Recent(),
          TintedAction(
            icon: KvIcons.scan,
            title: 'Найти по шильдику',
            subtitle: 'Камера считает номер с заводской таблички',
            onTap: () => context.kvUp(EngineerInspectPaths.bScanSearch),
          ),
        ],
      ],
    );
  }

  bool _kindMatches(Equipment u) {
    final bool screw = u.kindShort.contains('винтов');
    return switch (_kind) {
      1 => !screw,
      2 => screw,
      _ => true,
    };
  }

  /// По чему найдено: серийному номеру, номеру агрегата или модели.
  static String _matchKind(List<Equipment> units, String q) {
    final String l = q.toLowerCase();
    if (units.any((Equipment u) => u.serial.toLowerCase().contains(l))) {
      return 'по серийному номеру';
    }
    if (units.any((Equipment u) => u.code.toLowerCase().contains(l) || u.id.toLowerCase().contains(l))) {
      return 'по номеру';
    }
    return 'по модели';
  }
}

/// Строка поиска (.b-sbar): «назад» и поле с фокусом высотой 48.
class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.autofocus, required this.onSubmitted});

  final TextEditingController controller;
  final bool autofocus;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.gutter, 2, KvSpace.gutter, 12),
      child: Row(
        children: [
          KvRoundButton(icon: KvIcons.back, semanticLabel: 'Назад', onPressed: () => context.kvBack(EngineerInspectPaths.objects)),
          const SizedBox(width: KvSpace.s2),
          Expanded(
            child: KvField(
              controller: controller,
              lead: KvIcons.search,
              height: 48,
              autofocus: autofocus,
              placeholder: 'Номер, модель, серийный номер',
              textInputAction: TextInputAction.search,
              onSubmitted: onSubmitted,
              fieldKey: const ValueKey<String>('search-query'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Найденный агрегат: модель и серийный номер с подсветкой совпадения, чип состояния.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.unit, required this.query, required this.onTap});

  final Equipment unit;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final TextStyle sub = context.kvText.caption.copyWith(height: 1.35);
    final String serial = unit.serial;
    final int at = serial.toLowerCase().indexOf(query.toLowerCase());
    final List<InlineSpan> number = at < 0
        ? [TextSpan(text: serial)]
        : [
            TextSpan(text: serial.substring(0, at)),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(color: c.tint, borderRadius: BorderRadius.circular(4)),
                child: Text(serial.substring(at, at + query.length), style: sub.copyWith(color: c.brand, fontWeight: FontWeight.w600)),
              ),
            ),
            TextSpan(text: serial.substring(at + query.length)),
          ];
    return KvRow(
      icon: KvIcons.gauge,
      iconStatus: unit.kvStatus,
      title: unit.code,
      subtitleWidget: Text.rich(TextSpan(children: [TextSpan(text: '${unit.modelShort}\n№ '), ...number]), style: sub),
      trailing: KvChip(unit.statusLabel, status: unit.kvStatus),
      onTap: onTap,
    );
  }
}

/// Недавние запросы: агрегат открывает карточку, запрос без результата - поиск с этим запросом.
class _Recent extends ConsumerWidget {
  const _Recent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<RecentSearch> recent = ref.watch(recentSearchesProvider);
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    if (recent.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const KvSectionLabel('Недавние'),
        const SizedBox(height: KvSpace.s3),
        KvList(
          children: [
            for (final RecentSearch r in recent)
              _recentRow(context, r, units.where((Equipment u) => u.id == r.unitId).firstOrNull),
          ],
        ),
      ],
    );
  }

  Widget _recentRow(BuildContext context, RecentSearch r, Equipment? u) {
    if (u == null) {
      return KvRow(
        icon: KvIcons.history,
        title: r.query,
        subtitle: 'Запрос без результата',
        onTap: () => context.kvPush(EngineerInspectPaths.searchFor(r.query)),
      );
    }
    final String kind = u.kindShort.isEmpty ? '' : '${u.kindShort[0].toUpperCase()}${u.kindShort.substring(1)}';
    return KvRow(
      icon: KvIcons.history,
      title: u.code,
      subtitle: '$kind · ${u.statusLabel.toLowerCase()}',
      onTap: () => context.kvPush(EngineerInspectPaths.card(u.id)),
    );
  }
}
