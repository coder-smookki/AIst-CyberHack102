import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admins_cases.dart';
import 'design_case.dart';
import 'engineer_inspect_cases.dart';
import 'engineer_service_cases.dart';
import 'entry_cases.dart';
import 'harness.dart';
import 'master_operator_cases.dart';

/// Прогон снимков дизайна. Отбор через --dart-define:
/// GROUP=entry|engineer_inspect|engineer_service|master_operator|admins, IDS=login,objects,
/// WIDTH=360|390|430, THEME=light|dark. Снимки - `build/design_shots/<тема>-<ширина>/<id>.png`.
void main() {
  const String groupFilter = String.fromEnvironment('GROUP');
  const String ids = String.fromEnvironment('IDS');
  const String width = String.fromEnvironment('WIDTH');
  const String theme = String.fromEnvironment('THEME');
  final Map<String, List<DesignCase>> groups = {
    'entry': entryCases,
    'engineer_inspect': engineerInspectCases,
    'engineer_service': engineerServiceCases,
    'master_operator': masterOperatorCases,
    'admins': adminsCases,
  };
  final Set<String> wanted = ids.isEmpty ? <String>{} : ids.split(',').map((String s) => s.trim()).toSet();
  final List<int> widths = width.isEmpty ? kPhoneHeights.keys.toList() : [int.parse(width)];
  final List<String> themes = theme.isEmpty ? ['light', 'dark'] : [theme];
  for (final MapEntry<String, List<DesignCase>> g in groups.entries) {
    if (groupFilter.isNotEmpty && g.key != groupFilter) {
      continue;
    }
    group(g.key, () {
      for (final DesignCase c in g.value) {
        if (wanted.isNotEmpty && !wanted.contains(c.id)) {
          continue;
        }
        for (final String t in themes) {
          for (final int w in widths) {
            testWidgets('${c.id} $t-$w', (WidgetTester tester) async {
              await shootCase(tester, c, width: w, theme: t);
            }, skip: c.skip != null, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
          }
        }
      }
    });
  }
}
