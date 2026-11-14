import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Модели распознавания (adm-models): рабочие и тестовые версии с точностью, скоростью и числом классов.
class AdmModelsScreen extends ConsumerWidget {
  /// Создаёт экран.
  const AdmModelsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<RecognitionModel>> async = ref.watch(modelsProvider);
    final List<RecognitionModel> models = async.value ?? const <RecognitionModel>[];
    return KvScreen(
      header: KvRootHeader(title: 'Модели', subtitle: ty('Распознавание на цеховом сервере · 42 мс/кадр')),
      children: [
        if (!async.hasValue) ...[const KvSkeleton.card(height: 150), const KvSkeleton.card(height: 150)],
        for (final RecognitionModel m in models) _ModelCard(model: m, onTap: () => context.kvPush(AdminsPaths.model(m.id))),
        KvNote(icon: KvIcons.info, text: ty('Модели работают по живому видео с камеры. Порог для дефектов снижен: пропуск дефекта хуже ложной тревоги.')),
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({required this.model, required this.onTap});

  final RecognitionModel model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final RecognitionModel m = model;
    final AdmModelInfo info = admModelInfo(m);
    final bool active = m.status == 'active';
    final bool test = m.status == 'test';
    return KvCard(
      onTap: onTap,
      semanticLabel: '${info.short} ${m.version}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdmTop(
            icon: admModelIcon(m),
            status: active ? KvStatus.ok : null,
            title: info.short,
            subtitle: 'Версия ${m.version} · ${m.date}',
            trailing: AdmToggle(initial: active, semanticLabel: '${info.short} ${m.version}'),
          ),
          AdmDividedRow(
            top: 12,
            gap: 10,
            children: [
              AdmKpi(value: admMetricValue(m), label: admMetricLabel(m).split(' ').first.toLowerCase()),
              AdmKpi(value: m.fps.replaceFirst(' кадр/с', ''), label: 'кадр/с'),
              AdmKpi(value: '${m.classes}', label: KvFormat.plural(m.classes, 'класс', 'класса', 'классов')),
            ],
          ),
          if (test) ...[
            const SizedBox(height: KvSpace.s2),
            const Align(alignment: Alignment.centerLeft, child: KvChip('Тестирование · не на сканерах', status: KvStatus.info)),
          ] else if (!active) ...[
            const SizedBox(height: KvSpace.s2),
            const Align(alignment: Alignment.centerLeft, child: KvChip('Архив · для отката', dot: false)),
          ],
        ],
      ),
    );
  }
}
