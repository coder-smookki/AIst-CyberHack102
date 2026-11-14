import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../service_common.dart';

/// Очередь отправки (c-queue без связи, c-queue-ok после передачи): связь с сервером цеха, осмотр, отчёт и
/// заметки последнего осмотра, отправленное за день и место на телефоне.
class QueueScreen extends ConsumerWidget {
  /// Создаёт экран; [online] - связь с сервером цеха есть и всё передано.
  const QueueScreen({super.key, required this.online});

  /// Связь есть.
  final bool online;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<InspectionSummary>? today = ref.watch(todaySummariesProvider).value;
    final Site? site = ref.watch(siteProvider).value;
    final int? ping = ref.watch(serverPingProvider).value;
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final String now = KvFormat.time(ref.watch(clockProvider).now());
    String code(String id) => units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id;
    final InspectionSummary? last = today?.firstOrNull;
    final List<InspectionSummary> earlier = today == null || today.isEmpty ? const <InspectionSummary>[] : today.sublist(1);
    final List<Widget> latest = last == null ? const <Widget>[] : _latestRows(context, last, code(last.unitId));
    final List<Widget> sent = [for (final InspectionSummary s in earlier) _inspectionRow(context, s, code(s.unitId), sent: true)];
    final double queuedMb = last == null || online ? 0 : last.sizeMb + last.reportSizeMb;
    return KvScreen(
      header: KvHeader(
        title: 'Очередь отправки',
        subtitle: online ? 'Всё передано · $now' : KvFormat.typo('Нет связи · ${latest.length} в очереди'),
        status: online ? KvStatus.ok : KvStatus.bad,
        onBack: () => context.kvBack(EngineerServicePaths.profile),
      ),
      foot: online ? null : const _RetryButton(),
      children: [
        _Connection(online: online, server: site?.server ?? '', wifi: site?.wifi ?? '', ping: ping),
        if (today == null) const KvSkeleton.card(height: 240),
        if (online) ...[
          KvSectionLabel('Отправлено сегодня · ${latest.length + sent.length}'),
          KvList(children: [...latest, ...sent]),
        ] else ...[
          if (latest.isNotEmpty) ...[KvSectionLabel('Ждут отправки · ${latest.length}'), KvList(children: latest)],
          if (sent.isNotEmpty) ...[const KvSectionLabel('Отправлено сегодня'), KvList(children: sent)],
        ],
        _Storage(usedMb: queuedMb),
      ],
    );
  }

  /// Строки последнего осмотра: сам осмотр, отчёт PDF и заметки.
  List<Widget> _latestRows(BuildContext context, InspectionSummary s, String code) {
    final KvStatus tone = online ? KvStatus.ok : KvStatus.warn;
    return [
      _inspectionRow(context, s, code, sent: online),
      if (s.reportSizeMb > 0)
        KvRow(
          icon: KvIcons.filePdf,
          iconStatus: tone,
          title: KvFormat.typo('Отчёт PDF · ${s.inspectionId}'),
          subtitle: KvFormat.typo('${KvFormat.num(s.reportSizeMb, 1)} МБ · сформирован ${s.reportAt ?? s.end}'),
          trailing: online ? _Time(s.reportAt ?? s.end) : null,
          chevron: true,
          onTap: () => context.kvPush(EngineerServicePaths.cReport),
        ),
      for (final SummaryNote n in s.notes)
        KvRow(
          icon: n.length.isEmpty ? KvIcons.edit : KvIcons.mic,
          iconStatus: tone,
          title: KvFormat.typo('Заметка: ${n.title}'),
          subtitle: KvFormat.typo('$code · ${n.time}${n.length.isEmpty ? ' · текстовая' : ' · голосовая, ${n.length}'}'),
          trailing: online ? _Time(n.sentAt ?? s.sentAt ?? s.end) : null,
          chevron: true,
          onTap: () => showKvToast(
            context,
            kind: online ? KvToastKind.ok : KvToastKind.info,
            icon: KvIcons.mic,
            title: online ? 'Заметка на сервере цеха' : 'Заметка сохранена на телефоне',
            text: KvFormat.typo(online ? 'Прикреплена к осмотру ${s.inspectionId}' : 'Отправится вместе с осмотром'),
          ),
        ),
    ];
  }

  /// Строка осмотра: находки, снимки и объём; касание - итог последнего осмотра или карточка агрегата.
  Widget _inspectionRow(BuildContext context, InspectionSummary s, String code, {required bool sent}) {
    final int f = s.findings.length;
    final bool latest = s.reportSizeMb > 0;
    return KvRow(
      icon: KvIcons.clipboard,
      iconStatus: sent ? KvStatus.ok : KvStatus.warn,
      title: KvFormat.typo('Осмотр $code · ${s.inspectionId}'),
      subtitle: KvFormat.typo(
        '$f ${KvFormat.plural(f, 'находка', 'находки', 'находок')}, ${s.photos} ${KvFormat.plural(s.photos, 'снимок', 'снимка', 'снимков')}'
        ' · ${KvFormat.num(s.sizeMb, 1)} МБ',
      ),
      trailing: sent ? _Time(s.sentAt ?? s.end) : null,
      chevron: true,
      onTap: () => context.kvPush(latest ? EngineerServicePaths.cSummary : EngineerInspectPaths.card(s.unitId)),
    );
  }
}

/// Время передачи справа в строке очереди.
class _Time extends StatelessWidget {
  const _Time(this.time);

  final String time;

  @override
  Widget build(BuildContext context) => Text(
    time,
    style: context.kvText.caption.copyWith(color: context.kv.text3, height: KvTextStyles.normalHeight(13)),
  );
}

/// Карточка связи (.c-conn): значок Wi-Fi и пояснение.
class _Connection extends StatelessWidget {
  const _Connection({required this.online, required this.server, required this.wifi, required this.ping});

  final bool online;
  final String server;
  final String wifi;
  final int? ping;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return KvCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KvRowIcon(icon: online ? KvIcons.wifi : KvIcons.wifiOff, status: online ? KvStatus.ok : KvStatus.bad),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  online ? 'Связь с сервером цеха есть' : 'Нет связи с сервером цеха',
                  style: t.body.copyWith(fontWeight: FontWeight.w600, color: c.text, height: KvTextStyles.normalHeight(15)),
                ),
                const SizedBox(height: 3),
                Text(
                  KvFormat.typo(
                    online
                        ? '$server · Wi-Fi $wifi · отклик ${ping ?? '-'} мс'
                        : 'Сеть $wifi вне зоны. Данные сохранены на телефоне и уйдут автоматически при подключении.',
                  ),
                  style: t.caption.copyWith(height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Место на телефоне (.c-store): подписи и тонкая полоса заполнения.
class _Storage extends StatelessWidget {
  const _Storage({required this.usedMb});

  final double usedMb;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final TextStyle label = t.label.copyWith(height: KvTextStyles.normalHeight(12));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('На телефоне', style: label),
              Text(KvFormat.typo('${KvFormat.num(usedMb, usedMb == 0 ? 0 : 1)} МБ из 2 ГБ'), style: label),
            ],
          ),
          const SizedBox(height: 6),
          KvProgress(value: usedMb / 2048, status: usedMb == 0 ? null : KvStatus.warn, thin: true),
        ],
      ),
    );
  }
}

/// Кнопка «Повторить отправку»: спиннер 1,2 с, затем очередь передана.
class _RetryButton extends StatefulWidget {
  const _RetryButton();

  @override
  State<_RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends State<_RetryButton> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    await Future<void>.delayed(context.kvReduceMotion ? Duration.zero : const Duration(milliseconds: 1200));
    if (mounted) {
      context.kvFade(EngineerServicePaths.cQueueOk);
    }
  }

  @override
  Widget build(BuildContext context) =>
      KvButton('Повторить отправку', icon: KvIcons.refresh, loading: _busy, onPressed: _busy ? null : () => unawaited(_retry()));
}
