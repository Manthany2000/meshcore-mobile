// Renders the app's screens at phone size against the simulator, in light
// and dark. Any layout overflow fails the test. With SHOTS=<folder> in the
// environment it also saves each screen there as a PNG:
//   SHOTS=/tmp/shots flutter test test/screens_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meshcore_mobile/main.dart';

final _shots = Platform.environment['SHOTS'];

Future<void> _fonts() async {
  final dir = '${Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/flutter'}/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      final file = File('$dir/$f');
      if (file.existsSync()) l.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await l.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('screens (${dark ? 'dark' : 'light'})', (tester) async {
      await _fonts();
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('mcm-shots')))!;
      final app = AppState(dataDir: () async => dir);
      // flutter_map keeps its tile cache in the app's cache folder.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), (call) async => dir.path);
      final key = GlobalKey();
      var n = 0;

      /// Lets the simulator's real timers run, pumping frames meanwhile.
      Future<void> settle([double s = 0.6]) async {
        for (var i = 0; i < (s * 10).ceil(); i++) {
          await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> shot(String name) async {
        await tester.pump();
        n++;
        final out = _shots;
        if (out == null) return;
        final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final img = await b.toImage(pixelRatio: 1.5);
          final png = await img.toByteData(format: ui.ImageByteFormat.png);
          Directory(out).createSync(recursive: true);
          File('$out/${dark ? 'dark' : 'light'}-${n.toString().padLeft(2, '0')}-$name.png')
              .writeAsBytesSync(png!.buffer.asUint8List());
        });
      }

      Future<void> tap(Finder f) async {
        await tester.ensureVisible(f.first);
        await tester.tap(f.first);
        await settle(0.5);
      }

      Future<void> back() async {
        app.navigator.currentState!.pop();
        await settle(0.5);
      }

      await tester.pumpWidget(RepaintBoundary(key: key, child: MeshCoreApp(app: app)));
      await tester.pump(const Duration(milliseconds: 700));
      await shot('splash');
      await settle(1.5);
      await shot('connect');

      // A node that's been set up.
      await tester.runAsync(() async {
        app.connect(simMaker());
        await Future.delayed(const Duration(seconds: 2));
      });
      await settle(1);
      await tap(find.text('Node'));
      await shot('node-tab');
      await tester.drag(find.byType(ListView).last, const Offset(0, -600));
      await settle(0.3);
      await shot('node-tab-lower');
      await tester.drag(find.byType(ListView).last, const Offset(0, 600));
      await settle(0.3);

      await tap(find.text('Node settings'));
      await shot('settings-general');
      for (final t in ['Radio', 'Privacy', 'Bluetooth and scope', 'About']) {
        await tap(find.text(t));
        await shot('settings-${t.split(' ').first.toLowerCase()}');
      }
      await back();

      await tap(find.text('Default flood scope'));
      await shot('default-scope');
      await tap(find.text('Cancel'));

      // Chats: a channel's scope.
      await tap(find.text('Chats'));
      await tester.longPress(find.text('#test'));
      await settle(0.5);
      await shot('channel-menu');
      await tap(find.text('Flood scope…'));
      await tester.enterText(find.byType(TextField).last, 'boston');
      await settle(0.3);
      await shot('channel-scope');
      await tap(find.text('OK'));
      await tap(find.text('#test'));
      await shot('chat-scoped');
      await back();
      await settle(1);

      // The map, grouped.
      await tap(find.text('Map'));
      await settle(1);
      await shot('map');

      // A repeater: settings and regions.
      await tap(find.text('Contacts'));
      await tap(find.text('Ridge Repeater'));
      await tap(find.text('Manage repeater'));
      if (find.widgetWithText(TextField, 'Password').evaluate().isNotEmpty) {
        // Still logged in from the light run otherwise: logins last as long as the app.
        await tester.enterText(find.widgetWithText(TextField, 'Password'), 'admin');
        await tap(find.text('Log in'));
        await settle(2);
      }
      await tap(find.text('Settings'));
      await tap(find.text('Read all'));
      await settle(14);
      await shot('repeater-settings');
      await tap(find.text('Regions'));
      await tap(find.widgetWithText(FilledButton, 'Read'));
      await settle(3);
      await shot('repeater-regions');
      await back();

      // A freshly flashed node: the setup offer and the wizard.
      await tester.runAsync(() async {
        await app.disconnect();
        app.connect(simMaker(fresh: true));
        await Future.delayed(const Duration(seconds: 2));
      });
      await settle(1.5);
      await shot('setup-offer');
      await tap(find.text('Set up'));
      await tester.enterText(find.byType(TextField).first, 'kestrel-mobile');
      await settle(0.3);
      await shot('wizard-name');
      await tap(find.text('Next'));
      await shot('wizard-radio');
      await tap(find.text('Next'));
      await tester.enterText(find.byType(TextField).first, '42.3601, -71.0589');
      await settle(0.3);
      await shot('wizard-position');
      await tap(find.text('Next'));
      await tester.enterText(find.byType(TextField).first, '#local, #emergency');
      await settle(0.3);
      await shot('wizard-channels');
      await tap(find.text('Next'));
      await shot('wizard-review');
      await tap(find.text('Apply'));
      await settle(3);
      await shot('wizard-done');
      await tap(find.text('Close'));

      await tester.runAsync(() async {
        await app.disconnect();
        await app.model.flush();
        await Future.delayed(const Duration(milliseconds: 300));
        await dir.delete(recursive: true);
      });
      await tester.pumpWidget(const SizedBox());
      await settle(0.2);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
