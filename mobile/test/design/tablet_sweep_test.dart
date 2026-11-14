import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admins_cases.dart';
import 'design_case.dart';
import 'engineer_inspect_cases.dart';
import 'engineer_service_cases.dart';
import 'entry_cases.dart';
import 'harness.dart';
import 'master_operator_cases.dart';

/// Главные экраны инженера и по одному экрану других ролей на планшетах 768 × 1024, 820 × 1180, 1024 × 1366
/// и в альбомной 1180 × 820 в обеих темах. Переполнение раскладки проваливает тест. Отбор: --dart-define=WIDTH=768.
const Set<String> kTabletIds = {
  'login',
  'objects',
  'card',
  'card-charts',
  'card-history',
  'diagnostics',
  'b-route',
  'scanner',
  'b-scan-search',
  'b-defect',
  'c-summary',
  'history',
  'assistant',
  'profile',
  'card-menu',
  'master-shift',
  'd-m-finding',
  'adm-system',
  'sec-users',
};

void main() {
  const String width = String.fromEnvironment('WIDTH');
  const String theme = String.fromEnvironment('THEME');
  final List<int> widths = width.isEmpty ? kTabletHeights.keys.toList() : [int.parse(width)];
  final List<String> themes = theme.isEmpty ? ['light', 'dark'] : [theme];
  final List<DesignCase> cases = [
    ...entryCases,
    ...engineerInspectCases,
    ...engineerServiceCases,
    ...masterOperatorCases,
    ...adminsCases,
  ].where((DesignCase c) => kTabletIds.contains(c.id) && c.skip == null).toList();
  for (final DesignCase c in cases) {
    for (final String t in themes) {
      for (final int w in widths) {
        testWidgets('tablet ${c.id} $t-$w', (WidgetTester tester) async {
          await shootCase(tester, c, width: w, theme: t);
        }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
      }
    }
  }
}
