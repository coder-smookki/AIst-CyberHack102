import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Драйвер интеграционных тестов для flutter drive (нужен для iPhone по Wi-Fi): снимки экрана сохраняются в build/iphone_shots.
Future<void> main() => integrationDriver(
      onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
        final File file = File('build/iphone_shots/$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes);
        return true;
      },
    );
