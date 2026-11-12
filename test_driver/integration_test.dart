import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
      onScreenshot: (name, bytes, [args]) async {
        final f = File('screenshots/$name.png');
        f.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
        return true;
      },
    );
