import 'dart:async';

import '../repositories/change_feed.dart';

/// Изменения данных на настоящем сервере: репозитории сообщают раздел после успешного изменения.
class ApiFeed implements KvChangeFeed {
  final StreamController<KvDomain> _c = StreamController<KvDomain>.broadcast();

  @override
  Stream<KvDomain> get changes => _c.stream;

  /// Сообщить, что раздел [domain] изменился.
  void notify(KvDomain domain) {
    if (!_c.isClosed) {
      _c.add(domain);
    }
  }

  /// Закрыть поток.
  void dispose() => _c.close();
}

/// Общий поток изменений: демонстрационный сервер (разделы других ролей) и настоящий сервер.
class MergedFeed implements KvChangeFeed {
  /// Объединяет потоки [a] и [b].
  MergedFeed(this.a, this.b);

  /// Первый поток.
  final KvChangeFeed a;

  /// Второй поток.
  final KvChangeFeed b;

  @override
  Stream<KvDomain> get changes {
    late final StreamController<KvDomain> out;
    final List<StreamSubscription<KvDomain>> subs = [];
    out = StreamController<KvDomain>.broadcast(
      onListen: () {
        subs
          ..add(a.changes.listen(out.add))
          ..add(b.changes.listen(out.add));
      },
      onCancel: () {
        for (final StreamSubscription<KvDomain> s in subs) {
          s.cancel();
        }
        subs.clear();
      },
    );
    return out.stream;
  }
}
