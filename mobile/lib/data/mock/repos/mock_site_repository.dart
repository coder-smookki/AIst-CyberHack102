import '../../models/people.dart';
import '../../repositories/site_repository.dart';
import '../mock_backend.dart';

/// Площадка и сотрудники демонстрационного сервера.
class MockSiteRepository implements SiteRepository {
  /// Создаёт репозиторий поверх [backend].
  MockSiteRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  @override
  Future<Site> site() => backend.read(() => backend.db.site);

  @override
  Future<Map<String, Person>> people() => backend.read(() => Map<String, Person>.unmodifiable(backend.db.people));

  @override
  Future<List<Person>> engineers() => backend.read(
        () => [
          for (final u in backend.db.users)
            if (u.roleCode == 'engineer' && u.status != 'blocked')
              Person(id: u.id, name: u.name, roleCode: u.roleCode, roleLabel: u.roleLabel, email: u.email, shift: backend.db.site.shift),
        ],
      );

  @override
  Future<int> ping() => backend.read(() => backend.db.pingMs);
}
