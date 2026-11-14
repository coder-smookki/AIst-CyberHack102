import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/llm/local_answer.dart';
import '../../../core/llm/local_model.dart';
import '../../../core/llm/local_pack.dart';
import '../../../core/llm/local_search.dart';
import '../../../data/models/workflow.dart';

/// Состояние модели на устройстве.
enum LocalModelState {
  /// Ещё не запускалась.
  idle,

  /// Веса распаковываются из установщика.
  installing,

  /// Веса загружаются в память.
  loading,

  /// Модель готова.
  ready,

  /// Модель не подходит устройству или не загрузилась: ответы поиском по справке.
  searchOnly,
}

/// Состояние помощника: диалог, ответ в процессе и модель.
class LocalAssistantState {
  /// Создаёт состояние.
  const LocalAssistantState({
    this.dialog = const <AssistantMessage>[],
    this.streaming,
    this.model = LocalModelState.idle,
    this.progress = 0,
    this.tier,
    this.reason,
    this.busy = false,
    this.lastTokensPerSecond,
    this.lastFirstTokenMs,
  });

  /// Законченные сообщения.
  final List<AssistantMessage> dialog;

  /// Ответ, который пишется сейчас.
  final AssistantMessage? streaming;

  /// Состояние модели.
  final LocalModelState model;

  /// Доля распаковки или загрузки, 0..1.
  final double progress;

  /// Название выбранного уровня модели.
  final String? tier;

  /// Почему ответы идут поиском по справке.
  final String? reason;

  /// Идёт ответ.
  final bool busy;

  /// Скорость последнего ответа, токенов в секунду.
  final double? lastTokensPerSecond;

  /// Время до первого токена последнего ответа, мс.
  final int? lastFirstTokenMs;

  /// Сообщения для показа: законченные и пишущийся ответ.
  List<AssistantMessage> get messages => streaming == null ? dialog : <AssistantMessage>[...dialog, streaming!];

  /// Копия с изменёнными полями; [clearStreaming] убирает пишущийся ответ.
  LocalAssistantState copyWith({
    List<AssistantMessage>? dialog,
    AssistantMessage? streaming,
    bool clearStreaming = false,
    LocalModelState? model,
    double? progress,
    String? tier,
    String? reason,
    bool? busy,
    double? lastTokensPerSecond,
    int? lastFirstTokenMs,
  }) =>
      LocalAssistantState(
        dialog: dialog ?? this.dialog,
        streaming: clearStreaming ? null : streaming ?? this.streaming,
        model: model ?? this.model,
        progress: progress ?? this.progress,
        tier: tier ?? this.tier,
        reason: reason ?? this.reason,
        busy: busy ?? this.busy,
        lastTokensPerSecond: lastTokensPerSecond ?? this.lastTokensPerSecond,
        lastFirstTokenMs: lastFirstTokenMs ?? this.lastFirstTokenMs,
      );
}

/// Контекст последнего открытого экрана с агрегатом: из него помощник берёт агрегат по умолчанию.
class AssistantContextNotifier extends Notifier<AskContext> {
  @override
  AskContext build() {
    final GoRouter router = ref.watch(routerProvider);
    void listener() => _seen(router.routerDelegate.currentConfiguration.uri);
    router.routerDelegate.addListener(listener);
    ref.onDispose(() => router.routerDelegate.removeListener(listener));
    return const AskContext();
  }

  void _seen(Uri uri) {
    final List<String> s = uri.pathSegments;
    final int card = s.indexOf('card');
    final int hist = s.indexOf('c-history');
    String? unit = uri.queryParameters['unit'];
    String? screen;
    if (card >= 0 && card + 1 < s.length) {
      unit = s[card + 1];
      screen = s.length > card + 2 ? (s[card + 2] == 'charts' ? 'Графики агрегата' : 'История агрегата') : 'Карточка агрегата';
    } else if (hist >= 0 && hist + 1 < s.length) {
      unit = s[hist + 1];
      screen = 'История агрегата';
    } else if (unit != null) {
      screen = switch (s.isEmpty ? '' : s.last) {
        'scanner' || 'b-scan-defect' || 'b-scan-gauge' => 'Сканер',
        'b-route' => 'Маршрут осмотра',
        'diagnostics' => 'Диагностика',
        'docs' || 'b-doc-view' => 'Документы',
        _ => null,
      };
    }
    if (unit != null && unit.isNotEmpty && (unit != state.unitId || screen != state.screen)) {
      state = AskContext(screen: screen, unitId: unit);
    }
  }
}

/// Контекст экрана для помощника.
final NotifierProvider<AssistantContextNotifier, AskContext> assistantContextProvider =
    NotifierProvider<AssistantContextNotifier, AskContext>(AssistantContextNotifier.new);

/// Помощник на устройстве: поиск по справке, модель llama.cpp по уровню памяти, ответ поиском без модели.
class LocalAssistantController extends Notifier<LocalAssistantState> {
  LocalPack? _pack;
  LocalSearch? _search;
  LinkValidator? _validator;
  LocalModel? _model;
  ModelTier? _tier;
  Future<void>? _warming;
  bool _wanted = false;

  @override
  LocalAssistantState build() {
    ref.onDispose(() => unawaited(_model?.dispose()));
    return const LocalAssistantState();
  }

  /// Набор знаний (загружается один раз).
  Future<LocalPack> pack() async {
    if (_pack == null) {
      final ByteData data = await rootBundle.load('$kLlmAssets/knowledge_pack.json');
      final LocalPack p = LocalPack.parse(utf8.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)));
      _pack = p;
      _search = LocalSearch(p);
      _validator = LinkValidator(p.screens, p.units.map((PackUnit u) => u.id));
    }
    return _pack!;
  }

  /// Готовит справку и модель при открытии экрана: не блокирует интерфейс, показывает прогресс.
  Future<void> warmUp() {
    _wanted = true;
    return _warming ??= _warm().whenComplete(() => _warming = null);
  }

  Future<void> _warm() async {
    await pack();
    if (_model != null || state.model == LocalModelState.searchOnly) {
      return;
    }
    final DeviceProfile device = await DeviceProfile.detect();
    final ModelManifest manifest = await ModelManifest.load(rootBundle);
    final ModelTier? tier = manifest.pick(device);
    if (tier == null) {
      state = state.copyWith(
        model: LocalModelState.searchOnly,
        reason: !device.supported
            ? 'Модель не поддерживается этим процессором: ответы по справке'
            : manifest.tiers.isEmpty
                ? 'Модель не входит в эту сборку: ответы по справке'
                : 'Мало памяти для модели (${device.ramMb} МБ): ответы по справке',
      );
      return;
    }
    _tier = tier;
    try {
      state = state.copyWith(model: LocalModelState.installing, progress: 0, tier: tier.title);
      final String path = await installModel(rootBundle, tier, onProgress: (double p) {
        state = state.copyWith(progress: p);
      });
      if (!_wanted) {
        state = state.copyWith(model: LocalModelState.idle);
        return;
      }
      state = state.copyWith(model: LocalModelState.loading, progress: 1);
      final LocalModel model = await LocalModel.open(path, tier);
      if (!_wanted) {
        await model.dispose();
        state = state.copyWith(model: LocalModelState.idle);
        return;
      }
      _model = model;
      state = state.copyWith(model: LocalModelState.ready);
    } catch (_) {
      state = state.copyWith(model: LocalModelState.searchOnly, reason: 'Модель не загрузилась: ответы по справке');
    }
  }

  /// Освобождает память модели при уходе с экрана; диалог сохраняется.
  Future<void> release() async {
    _wanted = false;
    final LocalModel? m = _model;
    if (m == null || state.busy) {
      return;
    }
    _model = null;
    if (state.model == LocalModelState.ready) {
      state = state.copyWith(model: LocalModelState.idle);
    }
    await m.dispose();
  }

  static String _now() {
    final DateTime t = DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  static List<AssistantLink> _links(List<AnswerLink> links) =>
      <AssistantLink>[for (final AnswerLink l in links) AssistantLink(title: l.label, deeplink: l.path, kind: l.kind)];

  /// Задаёт вопрос [question]; ответ пишется потоком, ссылки становятся переходами.
  Future<void> ask(String question) async {
    final String q = question.trim();
    if (q.isEmpty || state.busy) {
      return;
    }
    final AskContext ctx = ref.read(assistantContextProvider);
    final List<AssistantMessage> dialog = <AssistantMessage>[
      ...state.dialog,
      AssistantMessage(fromUser: true, text: q, time: _now()),
    ];
    state = state.copyWith(dialog: dialog, busy: true);
    await pack();
    final SearchResult found = _search!.search(q, contextUnit: ctx.unitId);
    final ParsedAnswer quick = fallbackAnswer(found, question: q);
    final LocalModel? model = _model;
    if (model == null || !found.found) {
      _finish(AssistantMessage(
        fromUser: false,
        text: quick.text,
        links: _links(quick.links),
        found: found.found,
        source: 'Справка на устройстве',
      ));
      return;
    }
    final String prompt = buildPrompt(buildUserMessage(q, found.top(_tier?.snippets ?? 3), ctx), thinkPrefix: _tier?.thinkPrefix ?? true);
    state = state.copyWith(
      streaming: AssistantMessage(
        fromUser: false,
        text: quick.text,
        links: _links(quick.links),
        found: found.found,
        source: 'Справка на устройстве · модель уточняет ответ…',
      ),
    );
    final StringBuffer raw = StringBuffer();
    final Stopwatch sw = Stopwatch()..start();
    int first = -1;
    int tokens = 0;
    try {
      await for (final String piece in model.generate(prompt)) {
        if (first < 0) {
          first = sw.elapsedMilliseconds;
        }
        tokens++;
        raw.write(piece);
        final ParsedAnswer partial = parseAnswer(raw.toString(), _validator!, streaming: true);
        state = state.copyWith(
          streaming: AssistantMessage(
            fromUser: false,
            text: partial.text.isEmpty ? quick.text : partial.text,
            links: _links(partial.links.isEmpty ? quick.links : partial.links),
            found: found.found,
            source: 'Пишу ответ на устройстве…',
          ),
        );
      }
    } catch (_) {
      raw.clear();
    }
    final int total = sw.elapsedMilliseconds;
    final double? speed = tokens > 1 && total > first ? (tokens - 1) * 1000 / (total - first) : null;
    final ParsedAnswer done = parseAnswer(raw.toString(), _validator!);
    final bool invented = unsupportedNumbers(done.text, prompt).isNotEmpty;
    if (done.text.replaceAll(kDecisionLine, '').trim().isEmpty || invented) {
      _finish(
        AssistantMessage(
          fromUser: false,
          text: quick.text,
          links: _links(quick.links),
          found: found.found,
          source: invented ? 'Справка на устройстве: ответ модели не прошёл проверку чисел' : 'Справка на устройстве',
        ),
        speed: speed,
        first: first,
      );
      return;
    }
    final bool decision = done.text.contains(kDecisionLine) || found.hits.any((SearchHit h) => h.chunk.needsDecisionLine);
    String text = withReference(done.text.replaceAll(kDecisionLine, '').trim(), found);
    if (decision) {
      text = '$text\n\n$kDecisionLine';
    }
    final List<AnswerLink> links = <AnswerLink>[...done.links];
    for (final AnswerLink l in quick.links) {
      if (links.length >= 5) {
        break;
      }
      if (!links.any((AnswerLink x) => x.path == l.path)) {
        links.add(l);
      }
    }
    _finish(
      AssistantMessage(
        fromUser: false,
        text: text,
        links: _links(links),
        found: found.found,
        source: 'На устройстве · ${_tier?.title ?? 'модель'}${_speed(speed, first)}',
      ),
      speed: speed,
      first: first,
    );
  }

  static String _speed(double? speed, int first) {
    if (speed == null || first < 0) {
      return '';
    }
    final String s = speed.toStringAsFixed(1).replaceAll('.', ',');
    final String f = (first / 1000).toStringAsFixed(1).replaceAll('.', ',');
    return ' · $s ток/с · начало через $f с';
  }

  void _finish(AssistantMessage message, {double? speed, int? first}) {
    debugPrint('KV_ASSISTANT tier=${_tier?.id ?? 'search'} state=${state.model.name} first_ms=${first ?? -1} '
        'tok_s=${speed?.toStringAsFixed(1) ?? '-'} found=${message.found}');
    final AssistantMessage answer = message.found
        ? message
        : AssistantMessage(
            fromUser: false,
            text: message.text,
            links: <AssistantLink>[
              ...message.links,
              const AssistantLink(title: 'Спросить мастера', deeplink: 'ask_master', kind: 'ask_master'),
            ],
            found: false,
            source: message.source,
          );
    state = state.copyWith(
      dialog: <AssistantMessage>[...state.dialog, answer],
      clearStreaming: true,
      busy: false,
      lastTokensPerSecond: speed,
      lastFirstTokenMs: first != null && first >= 0 ? first : null,
    );
    if (!_wanted) {
      unawaited(release());
    }
  }

  /// Останавливает пишущийся ответ.
  void stop() => _model?.cancel();
}

/// Помощник на устройстве (живёт весь сеанс приложения; модель выгружается при уходе с экрана).
final NotifierProvider<LocalAssistantController, LocalAssistantState> localAssistantProvider =
    NotifierProvider<LocalAssistantController, LocalAssistantState>(LocalAssistantController.new);
