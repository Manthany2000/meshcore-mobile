// Walks the app against the simulator and saves a screenshot of each screen.
// Run by .github/workflows/screenshots.yml on an iOS Simulator with
// `flutter test`. Shots go to SHOT_DIR (a host folder: simulator apps can write
// there) and to the app's Documents folder as a fallback.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meshcore_mobile/main.dart';
import 'package:path_provider/path_provider.dart';

const prefix = String.fromEnvironment('SHOT_PREFIX', defaultValue: 'light');
const shotDir = String.fromEnvironment('SHOT_DIR');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screenshots', (tester) async {
    final docs = Directory('${(await getApplicationDocumentsDirectory()).path}/screenshots')..createSync(recursive: true);
    var n = 0;
    var converted = false;

    Future<void> wait(double s) async {
      final end = DateTime.now().add(Duration(milliseconds: (s * 1000).round()));
      while (DateTime.now().isBefore(end)) {
        await Future.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    }

    Future<void> shot(String name) async {
      await wait(1.0);
      n++;
      final file = '$prefix-${n.toString().padLeft(2, '0')}-$name.png';
      if (!converted && Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        converted = true;
      }
      final bytes = await binding.takeScreenshot(file);
      File('${docs.path}/$file').writeAsBytesSync(bytes);
      if (shotDir.isNotEmpty) {
        try {
          File('$shotDir/$file')
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes);
        } catch (e) {
          debugPrint('host write failed: $e');
        }
      }
      debugPrint('SHOT $file ${bytes.length} bytes');
    }

    Future<void> tap(Finder f) async {
      if (f.evaluate().isEmpty) {
        debugPrint('not found: $f');
        return;
      }
      await tester.tap(f.first, warnIfMissed: false);
      await wait(0.8);
    }

    Future<void> back() async {
      await tester.pageBack();
      await wait(0.8);
    }

    Future<void> closeSheet() async {
      await tester.tapAt(const Offset(30, 120));
      await wait(0.8);
    }

    Future<void> say(String text) async {
      await tester.enterText(find.byType(TextField).last, text);
      await wait(0.3);
      await tap(find.byIcon(Icons.send));
      FocusManager.instance.primaryFocus?.unfocus();
    }

    await tester.pumpWidget(const MeshCoreApp());
    await wait(4);
    await shot('connect');

    await tap(find.text('Try the simulator'));
    await wait(25); // sync, then let chatter, adverts and packets come in

    // A DM with delivery ticks.
    await tap(find.text('Contacts'));
    await shot('contacts');
    await tap(find.text('alice'));
    await shot('contact');
    await tap(find.text('Message'));
    await say('hey alice, testing the new phone app');
    await wait(6);
    await shot('dm');
    await back();

    // A channel with repeats, a message's details, then its path on the map.
    await tap(find.text('Chats'));
    await tap(find.text('Public'));
    await say('Hello from MeshCore Mobile on iPhone 👋');
    await wait(12);
    await shot('channel');
    final incoming = find.textContaining(' hop');
    if (incoming.evaluate().isNotEmpty) {
      await tap(incoming.last);
      await shot('message-details');
      await tap(find.text('Trace on map'));
      await wait(3);
      await shot('trace');
    } else {
      await back();
    }

    // The live map.
    await tap(find.byTooltip('Clear'));
    await wait(8);
    await shot('map');
    await tap(find.text('Network'));
    await wait(5);
    await shot('network');
    await tap(find.text('Map'));

    await tap(find.text('Dashboard'));
    await wait(2);
    await shot('dashboard');
    await tap(find.textContaining('tap to expand'));
    await wait(2);
    await shot('waterfall');
    await back();

    // A repeater: log in, status, console.
    await tap(find.text('Contacts'));
    await tap(find.text('Repeaters'));
    await tap(find.text('Ridge Repeater'));
    await tap(find.text('Manage repeater'));
    await tester.enterText(find.byType(TextField).first, 'admin');
    await wait(0.3);
    await tap(find.text('Log in'));
    await wait(4);
    await shot('repeater-status');
    await tap(find.text('Console'));
    await tap(find.text('ver'));
    await wait(3);
    await tap(find.text('neighbors'));
    await wait(3);
    await shot('repeater-console');
    await back();

    await tap(find.text('Chats'));
    await shot('chats');
    await tap(find.text('Node'));
    await shot('node');
    await closeSheet();
  }, timeout: const Timeout(Duration(minutes: 6)));
}
