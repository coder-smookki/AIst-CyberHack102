import '../../models/workflow.dart';
import '../../repositories/change_feed.dart';
import '../../repositories/report_repository.dart';
import '../mock_backend.dart';

/// Отчёты демонстрационного сервера: формируются мгновенно и сохраняются в списке.
class MockReportRepository implements ReportRepository {
  /// Создаёт репозиторий поверх [backend].
  MockReportRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  Report _make(String title, String format, {String? unitId, String? inspectionId}) {
    final Report r = Report(
      id: backend.db.nextId('R-', 0),
      title: title,
      format: format,
      createdAt: '${backend.dateNow} ${backend.timeNow}',
      size: format == 'pdf' ? '1,2 МБ' : '0,4 МБ',
      unitId: unitId,
      inspectionId: inspectionId,
    );
    backend.db.reports.insert(0, r);
    return r;
  }

  @override
  Future<List<Report>> reports() => backend.read(() => List<Report>.unmodifiable(backend.db.reports));

  @override
  Future<Report> unitReport(String unitId, String format) =>
      backend.write([KvDomain.reports], () => _make('Отчёт по агрегату ${backend.unitOf(unitId).code}', format, unitId: backend.unitOf(unitId).id));

  @override
  Future<Report> inspectionReport(String inspectionId, String format) =>
      backend.write([KvDomain.reports], () => _make('Отчёт по осмотру $inspectionId', format, inspectionId: inspectionId));

  @override
  Future<Report> shiftReport(String date, String format) => backend.write([KvDomain.reports], () => _make('Отчёт смены $date', format));
}
