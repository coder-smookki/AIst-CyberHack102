import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/kv_page.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'widgets/inspect_camera.dart';

/// Идущий осмотр агрегата [unitId]; если его нет - начинает новый.
Future<Inspection> ensureInspection(WidgetRef ref, String unitId) async {
  final InspectionRepository repo = ref.read(inspectionRepositoryProvider);
  return await repo.activeInspection(unitId) ?? await repo.start(unitId);
}

/// Возврат на живое видео: закрывает экраны над сканером, а если сканера в стеке нет - открывает его наплывом.
void backToScanner(BuildContext context, String unitId) {
  final RouteMatchList stack = GoRouter.of(context).routerDelegate.currentConfiguration;
  final bool inStack = stack.matches.any((RouteMatchBase m) => m.route is GoRoute && (m.route as GoRoute).name == 'scanner');
  if (inStack) {
    Navigator.of(context, rootNavigator: true).popUntil((Route<dynamic> r) => r.settings.name == 'scanner' || r.isFirst);
  } else {
    context.go(EngineerInspectPaths.scannerFor(unitId), extra: const KvNavExtra(transition: KvTransition.fade));
  }
}

/// Строка показаний к признаку на панели камеры: вибрация и подшипник у работающего агрегата,
/// уставка, по которой остановлен агрегат, - у остановленного.
EvidenceLine sensorContextLine(Equipment unit, List<HistoryEvent> history) {
  if (unit.stoppedAt != null) {
    final HistoryEvent? stop = history.where((HistoryEvent e) => e.title == 'Аварийная остановка').firstOrNull;
    if (stop != null) {
      final String rule = RegExp(r'[RS]\d{2}').firstMatch(stop.text)?.group(0) ?? '';
      final String what = stop.text.split(' · ').first;
      final String text = what.isEmpty ? what : '${what[0].toLowerCase()}${what.substring(1)}';
      return EvidenceLine(KvIcons.temp, '$rule в ${stop.time}: $text');
    }
  }
  final Reading? vib = unit.readings['vib1x'];
  final Reading? bearing = unit.readings['tBearing'];
  return EvidenceLine(
    KvIcons.activity,
    [
      if (vib != null) 'Вибрация ${KvFormat.withUnit(vib.value, vib.unit, vib.digits)}',
      if (bearing != null) 'подшипник ${KvFormat.withUnit(bearing.value, bearing.unit, bearing.digits)}',
    ].join(' · '),
  );
}

/// Первое слово названия узла строчными: «манометр» из «Манометр на нагнетании».
String nodeShortName(String name) => name.split(' ').first.toLowerCase();
