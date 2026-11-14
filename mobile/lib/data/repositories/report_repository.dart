import '../models/workflow.dart';

/// Отчёты PDF и Excel (GET /inspections/{id}/report.pdf|.xlsx).
abstract interface class ReportRepository {
  /// Сформированные отчёты, новые сверху.
  Future<List<Report>> reports();

  /// Отчёт по агрегату в формате pdf или xlsx.
  Future<Report> unitReport(String unitId, String format);

  /// Отчёт по осмотру в формате pdf или xlsx.
  Future<Report> inspectionReport(String inspectionId, String format);

  /// Отчёт смены в формате pdf или xlsx.
  Future<Report> shiftReport(String date, String format);
}
