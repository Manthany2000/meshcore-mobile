// Walks the app against the simulator and saves a screenshot of each screen.
// Run by .github/workflows/screenshots.yml on an iOS Simulator.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:meshcore_mobile/main.dart';

const prefix = String.fromEnvironment('SHOT_PREFIX', defaultValue: 'light');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screenshots', (tester) async {
    var n = 0;
    Future<void> wait(double s) async {
      final end = DateTime.now().add(Duration(milliseconds: (s * 1000).round()));
      while (DateTime.now().isBefore(end)) {
        await Future.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    }

    Future<void> shot(String name) async {
      await wait(0.8);
      n++;
      await binding.takeScreenshot('$prefix-${n.toString().padLeft(2, '0')}-$name');
    }

    Future<void> tap(Finder f) async {
      await tester.tap(f.first);
      await wait(0.8);
    }

    Future<void> back() async {
      await tester.pageBack();
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
    await wait(25); // sync, then let some chatter and adverts come in

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

    // A channel with repeats.
    await tap(find.text('Chats'));
    await tap(find.text('Public'));
    await say('Hello from MeshCore Mobile on iPhone 👋');
    await wait(12);
    await shot('channel');
    final repeated = find.textContaining('↻');
    if (repeated.evaluate().isNotEmpty) {
      await tap(repeated.last);
      await shot('message-details');
      await tester.tapAt(const Offset(20, 80)); // close the sheet
      await wait(0.8);
    }
    await back();
    await shot('chats');

    await tap(find.text('Node'));
    await shot('node');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
