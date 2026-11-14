import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/entry_routes.dart';
import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'entry_flow.dart';
import 'entry_state.dart';
import 'widgets/entry_blocks.dart';

/// «Сервер недоступен» (a-offline): цепочка «Телефон - Wi-Fi - Сервер» с обрывом, что работает без связи,
/// «Повторить подключение» и «Работать без связи». «Ещё» открывает параметры подключения.
class OfflineScreen extends ConsumerWidget {
  /// Создаёт экран.
  const OfflineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ConnectionInfo? info = ref.watch(entryConnectionProvider).value;
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return KvScreen(
      header: KvHeader(
        title: 'Подключение',
        subtitle: 'Сервер не отвечает',
        status: KvStatus.bad,
        onBack: () => context.kvBack(EntryPaths.login),
        onMore: () => showEntryConnectionSheet(context),
      ),
      children: [
        KvCard(
          padding: const EdgeInsets.fromLTRB(KvSpace.s4, KvSpace.s5, KvSpace.s4, KvSpace.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _NetChain(),
              const SizedBox(height: KvSpace.s3 + KvSpace.s2),
              Text('Цеховой сервер не отвечает', textAlign: TextAlign.center, style: t.h2),
              const SizedBox(height: KvSpace.s2),
              Text(
                info == null
                    ? ''
                    : KvFormat.typo(
                        'Сеть ${info.wifi} работает, но ${info.server} (${info.address}) не отвечает с ${info.unreachableSince}.',
                      ),
                textAlign: TextAlign.center,
                style: t.sm.copyWith(color: c.text2, height: 1.45),
              ),
            ],
          ),
        ),
        const KvSectionLabel('Работа без связи'),
        KvList(
          children: [
            const KvRow(icon: KvIcons.archive, title: 'Осмотры сохранятся на телефоне', subtitle: 'Уйдут на сервер, когда связь появится'),
            KvRow(
              icon: KvIcons.activity,
              iconStatus: KvStatus.unk,
              title: 'Показания датчиков на ${info?.readingsAt ?? ''}',
              subtitle: 'Без сервера не обновляются',
            ),
            KvRow(icon: KvIcons.sync, title: 'Связь проверяется сама', subtitle: 'Последняя попытка в ${info?.lastAttempt ?? ''}'),
          ],
        ),
      ],
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvButton('Повторить подключение', icon: KvIcons.refresh, wait: true, onPressed: () => context.kvFade(EntryPaths.aLoginLoading)),
          const SizedBox(height: KvSpace.s2),
          KvButton(
            'Работать без связи',
            kind: KvButtonKind.secondary,
            icon: KvIcons.wifiOff,
            onPressed: () => showEntryOfflineDialog(context),
          ),
        ],
      ),
    );
  }
}

/// Цепочка связи (.net-chain): телефон и Wi-Fi соединены линией с бегущей точкой, до сервера - красный пунктир
/// с крестом.
class _NetChain extends StatelessWidget {
  const _NetChain();

  @override
  Widget build(BuildContext context) {
    final double node = entryNarrow(context) ? 64 : 72;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _NetNode(icon: KvIcons.phone, label: 'Телефон', width: node),
        const Flexible(child: _NetLink(ok: true)),
        _NetNode(icon: KvIcons.wifi, label: 'Wi-Fi', width: node),
        const Flexible(child: _NetLink(ok: false)),
        _NetNode(icon: KvIcons.server, label: 'Сервер', width: node, bad: true),
      ],
    );
  }
}

/// Узел цепочки (.net-node): круг 52 со значком 24 и подпись 12.
class _NetNode extends StatelessWidget {
  const _NetNode({required this.icon, required this.label, required this.width, this.bad = false});

  final KvIcons icon;
  final String label;
  final double width;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return SizedBox(
      width: width,
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bad ? c.badBg : c.tint2, shape: BoxShape.circle),
            child: KvIcon(icon, size: 24, color: bad ? c.bad : c.brand),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: context.kvText.label.copyWith(color: bad ? c.bad : c.text2, height: KvTextStyles.normalHeight(12)),
          ),
        ],
      ),
    );
  }
}

/// Связь между узлами (.net-link): рабочая - синяя линия с точкой, бегущей за 1,6 с; оборванная - красный
/// пунктир с крестом посередине.
class _NetLink extends StatefulWidget {
  const _NetLink({required this.ok});

  final bool ok;

  @override
  State<_NetLink> createState() => _NetLinkState();
}

class _NetLinkState extends State<_NetLink> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.ok) {
      return;
    }
    if (context.kvReduceMotion) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 18, maxWidth: 64),
      child: SizedBox(
        height: 52,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 25,
              height: 2,
              child: widget.ok
                  ? DecoratedBox(decoration: BoxDecoration(color: c.brand, borderRadius: BorderRadius.circular(1)))
                  : CustomPaint(painter: _DashPainter(c.bad)),
            ),
            if (widget.ok)
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(painter: _FlowDotPainter(_c, c.brand, reduce: context.kvReduceMotion)),
                ),
              )
            else
              Positioned(
                top: 25 - 12,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: c.bad, shape: BoxShape.circle),
                    child: KvIcon(KvIcons.close, size: 14, color: c.onBrand),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Красный пунктир 2 px (border-top: 2px dashed): штрих 6, промежуток 6, как рисует браузер.
class _DashPainter extends CustomPainter {
  _DashPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()..color = color;
    const double dash = 6;
    final int n = ((size.width + dash) / (dash * 2)).floor().clamp(1, 1000);
    final double gap = n > 1 ? (size.width - n * dash) / (n - 1) : 0;
    for (int i = 0; i < n; i++) {
      canvas.drawRect(Rect.fromLTWH(i * (dash + gap), 0, dash, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => oldDelegate.color != color;
}

/// Точка 6 px, бегущая по линии связи (netFlow): проявляется к 20 %, гаснет после 80 %.
class _FlowDotPainter extends CustomPainter {
  _FlowDotPainter(this.t, this.color, {required this.reduce}) : super(repaint: t);

  final Animation<double> t;
  final Color color;
  final bool reduce;

  @override
  void paint(Canvas canvas, Size size) {
    final double v = reduce ? 0 : t.value;
    final double opacity = v < 0.2 ? v / 0.2 : (v > 0.8 ? (1 - v) / 0.2 : 1);
    final double x = (size.width - 6) * v;
    canvas.drawCircle(Offset(x + 3, 26), 3, Paint()..color = color.withValues(alpha: color.a * (reduce ? 1 : opacity)));
  }

  @override
  bool shouldRepaint(_FlowDotPainter oldDelegate) => oldDelegate.color != color || oldDelegate.reduce != reduce;
}

/// Лист «Подключение» (a-offline-info): сеть, сервер, адрес, последний обмен, очередь, версия приложения,
/// кто обслуживает сервер и копирование этих данных для администратора системы.
Future<void> showEntryConnectionSheet(BuildContext context) => showKvSheet<void>(context, builder: (_) => const _ConnectionSheet());

class _ConnectionSheet extends ConsumerWidget {
  const _ConnectionSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ConnectionInfo? info = ref.watch(entryConnectionProvider).value;
    if (info == null) {
      return const KvSheet(title: 'Подключение', children: [KvSkeleton.card(height: 280)]);
    }
    final String queue = info.queue == 0 ? 'пусто' : '${info.queue} ${KvFormat.plural(info.queue, 'запись', 'записи', 'записей')}';
    final List<(String, String)> pairs = [
      ('Сеть Wi-Fi', info.wifi),
      ('Цеховой сервер', info.server),
      ('Адрес', info.address),
      ('Последний обмен', info.lastExchange),
      ('Очередь отправки', queue),
      ('Версия приложения', info.appVersion),
    ];
    final String phone = info.admin.phone.replaceAll(' ', KvFormat.nbsp).replaceAll('-', '-⁠');
    return KvSheet(
      title: 'Подключение',
      children: [
        EntryKeyValueCard(pairs, outline: true),
        KvNote(icon: KvIcons.info, text: 'Сервер обслуживает администратор системы: ${info.admin.name}, $phone'),
      ],
      actions: [
        KvButton(
          'Скопировать для администратора',
          kind: KvButtonKind.tonal,
          icon: KvIcons.copy,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: pairs.map(((String, String) p) => '${p.$1}: ${p.$2}').join('\n')));
            showKvToast(context, kind: KvToastKind.ok, icon: KvIcons.copy, title: 'Данные скопированы', text: 'Передайте их администратору системы');
          },
        ),
      ],
    );
  }
}

/// Диалог «Работать без связи?» (a-offline-confirm): вход по учётной записи, сохранённой на телефоне.
Future<void> showEntryOfflineDialog(BuildContext screen) => showKvDialog<void>(screen, builder: (_) => _OfflineDialog(screen: screen));

class _OfflineDialog extends ConsumerStatefulWidget {
  const _OfflineDialog({required this.screen});

  final BuildContext screen;

  @override
  ConsumerState<_OfflineDialog> createState() => _OfflineDialogState();
}

class _OfflineDialogState extends ConsumerState<_OfflineDialog> {
  bool _busy = false;

  Future<void> _continue() async {
    setState(() => _busy = true);
    final NavigatorState navigator = Navigator.of(context);
    final BuildContext screen = widget.screen;
    try {
      final SavedAccount? account = await ref.read(entrySavedAccountProvider.future);
      if (account == null) {
        throw const KvApiException(KvFailure.invalidCredentials, 'На этом телефоне нет сохранённой учётной записи - войдите с паролем');
      }
      final AuthSession session = await ref.read(authRepositoryProvider).loginOffline(account.email);
      navigator.pop();
      ref.read(sessionProvider.notifier).restore(session);
      if (screen.mounted) {
        entryOpenHome(screen, session);
      }
    } on KvApiException catch (e) {
      if (navigator.mounted) {
        navigator.pop();
      }
      if (screen.mounted) {
        showKvToast(screen, title: 'Не удалось войти', text: e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return KvDialog(
      icon: KvIcons.wifiOff,
      tone: KvStatus.warn,
      title: 'Работать без связи?',
      text: 'Вход по учётной записи, сохранённой на этом телефоне. Осмотры встанут в очередь и отправятся, когда сервер станет доступен.',
      actions: [
        KvButton('Отмена', kind: KvButtonKind.secondary, onPressed: _busy ? null : () => Navigator.of(context).pop()),
        KvButton('Продолжить', loading: _busy, onPressed: _continue),
      ],
    );
  }
}
