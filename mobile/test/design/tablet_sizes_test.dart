import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admins_cases.dart';
import 'design_case.dart';
import 'engineer_inspect_cases.dart';
import 'engineer_service_cases.dart';
import 'entry_cases.dart';
import 'harness.dart';
import 'master_operator_cases.dart';

/// Размеры Android-планшетов и iPad в портретной и альбомной ориентации и маленький телефон 360 × 640.
const List<(int, double)> kExtraSizes = <(int, double)>[
  (360, 640),
  (600, 960),
  (960, 600),
  (800, 1280),
  (1280, 800),
  (1024, 1366),
  (1366, 1024),
];

/// Экраны для проверки размеров: вход, инструкция, объекты, карточка, сканер и осмотр, находка, итог, отчёт,
/// ассистент, профиль, мастер, оператор, администраторы.
const Set<String> kSizeIds = {
  'login',
  'guide',
  'objects',
  'search',
  'card',
  'card-menu',
  'card-charts',
  'card-history',
  'docs',
  'scanner',
  'b-scan-gauge',
  'b-scan-defect',
  'b-scan-finish',
  'b-route',
  'b-defect',
  'diagnostics',
  'c-summary',
  'c-report',
  'assistant',
  'history',
  'profile',
  'c-settings',
  'master-shift',
  'master-findings',
  'd-m-finding',
  'master-plan',
  'op-objects',
  'd-op-unit',
  'op-report',
  'adm-system',
  'adm-models',
  'sec-users',
  'sec-roles',
  'f-d-senior-home',
};

/// Главные экраны всех ролей на размерах [kExtraSizes] в светлой теме: переполнение раскладки или исключение
/// проваливают тест. Отбор размера: --dart-define=SIZE=800x1280.
void main() {
  const String only = String.fromEnvironment('SIZE');
  final List<DesignCase> cases = [
    ...entryCases,
    ...engineerInspectCases,
    ...engineerServiceCases,
    ...masterOperatorCases,
    ...adminsCases,
  ].where((DesignCase c) => kSizeIds.contains(c.id) && c.skip == null).toList();
  for (final (int w, double h) in kExtraSizes) {
    final String size = '${w}x${h.round()}';
    if (only.isNotEmpty && only != size) {
      continue;
    }
    for (final DesignCase c in cases) {
      testWidgets('size ${c.id} $size', (WidgetTester tester) async {
        await shootCase(tester, c, width: w, height: h, theme: 'light');
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }
  }
}
