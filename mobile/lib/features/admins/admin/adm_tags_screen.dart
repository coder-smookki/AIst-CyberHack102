import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/bridges.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Привязка тегов агрегата (e-tags, e-tags-ams1, e-tags-ams2): показания, ключи и адреса тегов, переход между агрегатами.
class AdmTagsScreen extends ConsumerWidget {
  /// Создаёт экран агрегата [unitId].
  const AdmTagsScreen({super.key, required this.unitId, this.fromSegment});

  /// Агрегат: N-101, AMS-1, AMS-2.
  final String unitId;

  /// С какого пункта сегмента пришли (смена агрегата без смены шапки).
  final int? fromSegment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final Equipment? unit = units.where((Equipment u) => u.id == unitId).firstOrNull;
    final List<TagBinding>? bindings = ref.watch(tagsProvider(unitId)).value;
    final int index = kAdmTagUnits.indexOf(unitId);
    if (unit == null || bindings == null) {
      return KvScreen(
        header: KvHeader(title: 'Привязка тегов', subtitle: ' ', onBack: () => context.kvBack(AdminsPaths.admSources)),
        children: const [
          KvSkeleton(height: 50, radius: KvRadius.btn),
          KvSkeleton.card(height: 400),
        ],
      );
    }
    final List<AdmTag> tags = admTagsOf(unit, bindings);
    final bool segSwap = fromSegment != null;
    return KvScreen(
      key: ValueKey<String>(unitId),
      stagger: segSwap ? KvStagger.seg : KvStagger.appear,
      staggerSkip: segSwap ? 1 : 0,
      header: KvHeader(
        title: 'Привязка тегов',
        subtitle: ty('${unit.code} · ${admTagsWord(tags.length)}'),
        onBack: () => context.kvBack(AdminsPaths.admSources),
        onMore: () => _menu(context, unit, tags.length),
      ),
      foot: KvButton('Добавить тег', kind: KvButtonKind.secondary, icon: KvIcons.plus, onPressed: () => _newTag(context, ref, unit)),
      children: [
        KvSegment(
          items: [for (final String id in kAdmTagUnits) units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id],
          index: index < 0 ? 0 : index,
          animateFrom: fromSegment,
          onBackground: true,
          onChanged: (int i) => context.kvSeg(AdminsPaths.tags(kAdmTagUnits[i]), fromSegment: index),
        ),
        if (unit.mode == 'repair')
          KvNote(icon: KvIcons.info, text: ty('${unit.code} остановлен 06:44. Давление и ток показываются как «нет данных».')),
        KvList(
          noIcons: true,
          children: [for (final AdmTag t in tags) _TagRow(tag: t, onTap: () => showAdmTagSheet(context, ref, t))],
        ),
      ],
    );
  }

  void _menu(BuildContext context, Equipment unit, int n) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Теги ${unit.code}',
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.refresh,
                title: 'Проверить чтение всех тегов',
                subtitle: admTagsWord(n),
                onTap: () => showKvToast(
                  sheet,
                  title: ty('$n из ${admTagsWord(n)} читаются'),
                  text: ty('Самое старое значение - 2,4 с назад'),
                  kind: KvToastKind.ok,
                ),
              ),
              KvRow(
                icon: KvIcons.plug,
                title: 'Источники данных',
                onTap: () => admCloseThen(sheet, () => screen.kvFade(AdminsPaths.admSources)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _newTag(BuildContext context, WidgetRef ref, Equipment unit) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => _NewTagSheet(unit: unit, screen: screen),
    );
  }
}

/// Строка тега: название показания, ключ → адрес и текущее значение с точкой статуса.
class _TagRow extends StatelessWidget {
  const _TagRow({required this.tag, required this.onTap});

  final AdmTag tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final TextStyle key = t.caption.copyWith(height: 1.35, color: c.brand, fontWeight: FontWeight.w500);
    return KvRow(
      title: tag.label,
      subtitleWidget: Text.rich(
        TextSpan(
          style: t.caption.copyWith(height: 1.35),
          children: [
            TextSpan(text: tag.name, style: key),
            const TextSpan(text: ' → '),
            TextSpan(text: tag.addr, style: key),
          ],
        ),
      ),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvDot(status: KvStatus.parse(tag.status)),
          const SizedBox(width: 6),
          Text(
            tag.value == null ? 'нет данных' : KvFormat.withUnit(tag.value, tag.eu, tag.digits),
            maxLines: 1,
            softWrap: false,
            style: t.sm.copyWith(fontWeight: FontWeight.w500, color: c.text, height: KvTextStyles.normalHeight(14)),
          ),
        ],
      ),
    );
  }
}

/// Лист тега (e-tag-*): значение со спарклайном за сутки, источник, адрес и уставки; сохранение привязки.
void showAdmTagSheet(BuildContext context, WidgetRef ref, AdmTag tag) {
  final BuildContext screen = context;
  showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => _TagSheet(tag: tag, screen: screen),
  );
}

/// Лист тега: значение, источник, адрес и уставки; сохраняет привязку.
class _TagSheet extends ConsumerStatefulWidget {
  const _TagSheet({required this.tag, required this.screen});

  final AdmTag tag;
  final BuildContext screen;

  @override
  ConsumerState<_TagSheet> createState() => _TagSheetState();
}

class _TagSheetState extends ConsumerState<_TagSheet> {
  late final TextEditingController _addr = TextEditingController(text: widget.tag.addr);
  final TextEditingController _scale = TextEditingController(text: '× 0,1');
  final TextEditingController _source = TextEditingController();

  @override
  void dispose() {
    _addr.dispose();
    _scale.dispose();
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AdmTag t = widget.tag;
    final DataSource? s = ref.watch(
      sourcesProvider.select((AsyncValue<List<DataSource>> a) => a.value?.where((DataSource x) => x.id == t.sourceId).firstOrNull),
    );
    final bool modbus = t.sourceId != 'src-opc';
    final TelemetrySeries? series = t.value == null
        ? null
        : ref.watch(seriesProvider((unitId: t.unit.id, key: t.key, period: TelemetryPeriod.day))).value;
    if (s != null && _source.text.isEmpty) {
      _source.text = '${admSourceShort(s)} · ${s.proto.split(' ').first}';
    }
    final String setpoints = t.warn != null
        ? 'Уставки ${KvFormat.num(t.warn, t.digits)}${t.alarm != null ? ' / ${KvFormat.num(t.alarm, t.digits)}' : ''} ${t.eu} заданы правилами заказчика'
        : 'Уставок нет, значение используется в правилах как дополнительное';
    return KvSheet(
      title: t.label.length > 20 ? t.label.replaceFirst('Температура', 'Темп.') : t.label,
      actions: [
        AdmBusyButton(
          'Сохранить привязку',
          work: () => ref
              .read(adminRepositoryProvider)
              .saveTag(
                TagBinding(
                  tag: t.tag,
                  unitId: t.unit.id,
                  param: t.label,
                  eu: t.eu,
                  value: t.value == null ? '' : KvFormat.num(t.value, t.digits),
                  sourceId: t.sourceId,
                  addr: _addr.text.trim(),
                ),
              ),
          onDone: () => admCloseThen(context, () => _savedToast(widget.screen)),
        ),
      ],
      children: [
        KvCard(
          style: KvCardStyle.outline,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdmBigNum(
                value: t.value == null ? '-' : KvFormat.num(t.value, t.digits),
                unit: t.eu,
                warn: t.status == 'warn',
                title: t.status == 'unk' ? 'Нет данных' : 'Обновлено 09:41:12',
                text: '${t.unit.code} · ${t.name}',
              ),
              if (series != null && series.values.length > 2)
                KvSparkline(
                  height: 40,
                  data: KvSeriesData(
                    values: series.values,
                    warn: t.warn,
                    alarm: t.alarm,
                    unit: t.eu,
                    digits: t.digits,
                    labels: series.chart.labels,
                  ),
                ),
            ],
          ),
        ),
        KvField(label: 'Источник', controller: _source, lead: KvIcons.plug, readOnly: true),
        if (modbus)
          AdmGrid(
            children: [
              KvField(label: 'Регистр', controller: _addr, keyboardType: TextInputType.number),
              KvField(label: 'Масштаб', controller: _scale),
            ],
          )
        else
          KvField(label: 'Узел OPC UA', controller: _addr),
        AdmCaption(setpoints),
      ],
    );
  }
}

/// Уведомление о сохранённой привязке поверх экрана [screen], если он ещё открыт.
void _savedToast(BuildContext screen) {
  if (screen.mounted) {
    showKvToast(screen, title: 'Привязка сохранена', text: 'Правила используют новое значение со следующего опроса', kind: KvToastKind.ok);
  }
}

/// Лист нового тега агрегата (e-tags-*-new).
class _NewTagSheet extends ConsumerStatefulWidget {
  const _NewTagSheet({required this.unit, required this.screen});

  final Equipment unit;
  final BuildContext screen;

  @override
  ConsumerState<_NewTagSheet> createState() => _NewTagSheetState();
}

class _NewTagSheetState extends ConsumerState<_NewTagSheet> {
  late final bool _n101 = widget.unit.id == 'N-101';
  final TextEditingController _key = TextEditingController(text: 'p_seal');
  final TextEditingController _eu = TextEditingController(text: 'бар');
  final TextEditingController _param = TextEditingController(text: 'Давление в камере уплотнения');
  late final TextEditingController _source = TextEditingController(
    text: _n101 ? 'Сервер ввода-вывода · OPC UA' : 'ПЛК узла откачки · Modbus TCP',
  );
  late final TextEditingController _addr = TextEditingController(text: _n101 ? 'ns=2;s=N101.PSEAL' : '30031');

  @override
  void dispose() {
    for (final TextEditingController c in [_key, _eu, _param, _source, _addr]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Equipment u = widget.unit;
    return KvSheet(
      title: 'Новый тег',
      actions: [
        AdmBusyButton(
          'Добавить тег',
          work: () => ref
              .read(adminRepositoryProvider)
              .saveTag(
                TagBinding(
                  tag: 'NS2.${u.id.replaceAll('-', '')}.${_key.text.trim().toUpperCase()}',
                  unitId: u.id,
                  param: _param.text.trim(),
                  eu: _eu.text.trim(),
                  value: '',
                  sourceId: _n101 ? 'src-opc' : 'src-plc',
                  addr: _addr.text.trim(),
                ),
              ),
          onDone: () => admCloseThen(context, () => _savedToast(widget.screen)),
        ),
      ],
      children: [
        AdmGrid(
          children: [
            KvField(label: 'Ключ', controller: _key, autofocus: true, fieldKey: const ValueKey<String>('tag-key')),
            KvField(label: 'Единица', controller: _eu),
          ],
        ),
        KvField(label: 'Параметр', controller: _param),
        KvField(label: 'Источник', controller: _source, lead: KvIcons.plug, readOnly: true),
        KvField(label: _n101 ? 'Узел OPC UA' : 'Регистр', controller: _addr),
      ],
    );
  }
}
