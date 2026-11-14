import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/adm_widgets.dart';

/// Установка обновления (e-update-run): прогресс, шаги установки и работа сканеров офлайн.
class AdmUpdateRunScreen extends ConsumerWidget {
  /// Создаёт экран.
  const AdmUpdateRunScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ServerStatus? s = ref.watch(serverStatusProvider).value;
    final String next = s?.updateAvailable ?? s?.version ?? '';
    return KvScreen(
      header: KvHeader(
        title: 'Установка $next',
        subtitle: ty('Идёт установка · 64 %'),
        status: KvStatus.info,
        onBack: () => context.kvBack(AdminsPaths.eAdmMaint),
        onMore: () => _menu(context, next, s?.updateNotes ?? ''),
      ),
      foot: KvButton('Свернуть', kind: KvButtonKind.secondary, onPressed: () => context.kvBack(AdminsPaths.eAdmMaint)),
      children: [
        const KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdmBigNum(value: '64', unit: '%', title: 'Установка служб', text: 'Осталось около 2 мин'),
              KvProgress(value: 0.64),
            ],
          ),
        ),
        KvCard(
          child: KvTimeline(
            items: [
              KvTimelineItem(time: '09:41', title: 'Резервная копия создана', text: ty('1,8 ГБ'), status: KvStatus.ok),
              const KvTimelineItem(time: '09:42', title: 'Пакет проверен', text: 'Подпись разработчика подтверждена', status: KvStatus.ok),
              const KvTimelineItem(time: 'Сейчас', title: 'Установка служб', text: 'Опрос датчиков приостановлен', status: KvStatus.info),
              const KvTimelineItem(time: 'Далее', title: 'Проверка после установки', text: 'Опрос, распознавание, база данных'),
            ],
          ),
        ),
        KvNote(icon: KvIcons.wifiOff, text: ty('Сканеры работают офлайн. Осмотры сохранятся на телефонах и передадутся после установки.')),
      ],
    );
  }

  void _menu(BuildContext context, String next, String notes) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Установка $next',
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.list,
                title: 'Журнал установки',
                subtitle: 'Подробные шаги',
                onTap: () => admCloseThen(sheet, () => screen.kvFade(AdminsPaths.admLog)),
              ),
              KvRow(
                icon: KvIcons.info,
                title: 'Что нового в $next',
                subtitle: notes,
                onTap: () => showKvToast(sheet, title: 'Версия $next', text: notes, kind: KvToastKind.info),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
