import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Модель распознавания (e-model-det, e-model-gauge, e-model-plate, e-model-next): метрики, сравнение тестовой
/// версии с рабочей, порог уверенности, классы; проверка на эталонных кадрах или активация.
class AdmModelScreen extends ConsumerWidget {
  /// Создаёт экран модели [modelId].
  const AdmModelScreen({super.key, required this.modelId});

  /// Код модели.
  final String modelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<RecognitionModel>? models = ref.watch(modelsProvider).value;
    final RecognitionModel? m = models?.where((RecognitionModel x) => x.id == modelId).firstOrNull;
    if (m == null) {
      return KvScreen(
        header: KvHeader(title: 'Модель', onBack: () => context.kvBack(AdminsPaths.admModels)),
        children: const [KvSkeleton.card(height: 200)],
      );
    }
    final AdmModelInfo info = admModelInfo(m);
    final bool test = m.status == 'test';
    final bool det = m.id.startsWith('m-det');
    final String metricLabel = admMetricLabel(m);
    final String metricValue = admMetricValue(m);
    final RecognitionModel? base = test
        ? models!.where((RecognitionModel x) => x.name == m.name && x.id != m.id && x.status == 'active').firstOrNull
        : null;
    List<String> shown = info.classes.take(8).toList();
    if (test) {
      shown = [...info.isNew, ...info.classes.take(6)];
    }
    final int rest = info.classes.length - shown.length;
    final String short = admShortVersion(m.version);
    return KvScreen(
      header: KvHeader(
        title: info.short,
        subtitle: 'Версия ${m.version} · ${test ? 'тестирование' : (m.status == 'active' ? 'активна' : 'архив')}',
        status: test ? KvStatus.info : (m.status == 'active' ? KvStatus.ok : KvStatus.unk),
        onBack: () => context.kvBack(AdminsPaths.admModels),
        onMore: () => _menu(context, m, info),
      ),
      foot: test
          ? KvButton('Активировать версию $short', icon: KvIcons.check, onPressed: () => _activate(context, ref, m, base))
          : AdmBusyButton(
              'Проверить на эталонных кадрах',
              kind: KvButtonKind.secondary,
              icon: KvIcons.target,
              wait: const Duration(milliseconds: 1200),
              onDone: () => showKvToast(context, title: 'Проверка пройдена', text: ty('$metricLabel $metricValue на 1 240 кадрах'), kind: KvToastKind.ok),
            ),
      children: [
        AdmGrid(
          children: [
            KvTile(label: metricLabel, value: metricValue),
            KvTile(label: 'Время кадра', value: info.ms.replaceFirst(' мс', ''), unit: 'мс'),
            KvTile(label: 'Ложные тревоги', value: info.fp.replaceFirst(' %', ''), unit: '%'),
            KvTile(label: 'Скорость', value: m.fps.replaceFirst(' кадр/с', ''), unit: 'кадр/с'),
          ],
        ),
        if (test && base != null)
          KvCard(
            title: 'Сравнение с ${admShortVersion(base.version)}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KvKeyValues([
                  (metricLabel, '${admMetricValue(base)} → $metricValue'),
                  ('Ложные срабатывания', ty('${admModelInfo(base).fp} → ${info.fp}')),
                  ('Классов', '${base.classes} → ${m.classes}'),
                  ('Скорость', ty('${base.fps.replaceFirst(' кадр/с', '')} → ${m.fps}')),
                ]),
                const AdmCaption('Проверено на 1 240 кадрах насосной станции № 2', top: KvSpace.s2),
              ],
            ),
          ),
        if (det)
          const KvCard(
            title: 'Порог уверенности для дефектов',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AdmSegment(items: ['0,25', '0,35', '0,50'], initial: 0),
                AdmCaption('Низкий порог: дефект не будет пропущен, возможны лишние срабатывания.', top: KvSpace.s2),
              ],
            ),
          ),
        KvCard(
          title: '${m.classes} ${KvFormat.plural(m.classes, 'класс', 'класса', 'классов')}',
          child: AdmChips(
            chips: [
              for (final String c in shown)
                if (test && info.isNew.contains(c)) (c, KvStatus.info, true) else (c, null, false),
              if (rest > 0) ('ещё $rest', null, false),
            ],
          ),
        ),
      ],
    );
  }

  void _menu(BuildContext context, RecognitionModel m, AdmModelInfo info) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: info.short,
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.info,
                title: 'Размер и версия',
                subtitle: ty('${m.size} · загружена ${m.date}'),
                onTap: () => showKvToast(sheet, title: 'Модель ${m.version}', text: ty('${m.size} · подпись разработчика подтверждена'), kind: KvToastKind.info),
              ),
              KvRow(
                icon: KvIcons.list,
                title: 'Системный журнал',
                subtitle: 'События распознавания',
                onTap: () => admCloseThen(sheet, () => screen.kvFade(AdminsPaths.admLog)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _activate(BuildContext context, WidgetRef ref, RecognitionModel m, RecognitionModel? base) {
    final BuildContext screen = context;
    final String short = admShortVersion(m.version);
    showKvDialog<void>(
      context,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.cpu,
        title: 'Активировать $short?',
        text: base == null
            ? 'Сканеры получат модель при следующем подключении к серверу.'
            : 'Сканеры получат модель при следующем подключении к серверу. Версия ${admShortVersion(base.version)} останется для отката.',
        actions: [
          AdmDialogActions(
            okText: 'Активировать',
            wait: const Duration(milliseconds: 1200),
            work: () => ref.read(adminRepositoryProvider).activateModel(m.id),
            onDone: () => admCloseThen(
              dialog,
              () => showKvToast(screen, title: 'Версия $short активирована', text: 'Сканеры получат её при подключении к серверу', kind: KvToastKind.ok),
            ),
          ),
        ],
      ),
    );
  }
}
