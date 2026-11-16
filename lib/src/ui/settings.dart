// App settings: look, notifications, and about. Things about the node itself
// stay on the Node tab (Node settings).
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../main.dart';
import 'logo.dart';

void openSettings(BuildContext context, AppState app) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsScreen(app: app)));

/// The gear for app bars.
Widget settingsButton(BuildContext context, AppState app) => IconButton(
      tooltip: 'Settings',
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => openSettings(context, app),
    );

class SettingsScreen extends StatelessWidget {
  final AppState app;
  const SettingsScreen({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final prefs = app.prefs;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) => ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          const _Header('Appearance'),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('Theme'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'System', label: Text('System')),
                  ButtonSegment(value: 'Light', label: Text('Light')),
                  ButtonSegment(value: 'Dark', label: Text('Dark')),
                ],
                selected: {prefs.theme},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  prefs.theme = s.first;
                  prefs.save();
                },
              ),
            ),
          ),
          const ListTile(leading: Icon(Icons.palette_outlined), title: Text('Accent colour')),
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in accents.entries)
                ChoiceChip(
                  avatar: CircleAvatar(backgroundColor: e.value, radius: 8),
                  label: Text(e.key),
                  selected: prefs.accent == e.key,
                  onSelected: (_) {
                    prefs.accent = e.key;
                    prefs.save();
                  },
                ),
            ]),
          ),
          const Divider(),
          const _Header('Notifications'),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('Notifications'),
            subtitle: const Text('While the app is in the background or the phone is locked'),
            value: prefs.notifications,
            onChanged: (v) async {
              prefs.notifications = v;
              prefs.save();
              if (!v) return;
              final ok = await app.notifier.enable();
              if (ok == false && context.mounted) notificationsOff(context);
            },
          ),
          _sub(prefs.notifications, 'Direct messages', prefs.notifyDms, (v) => prefs.notifyDms = v),
          _sub(prefs.notifications, '@mentions in channels', prefs.notifyMentions, (v) => prefs.notifyMentions = v),
          _sub(prefs.notifications, 'New nodes found', prefs.notifyNodes, (v) => prefs.notifyNodes = v),
          ListTile(
            enabled: prefs.notifications,
            leading: const SizedBox(width: 24),
            title: const Text('Send a test notification'),
            subtitle: const Text('Arrives in 5 seconds: lock the phone or switch apps to see it as a message would'),
            onTap: () async {
              final ok = await app.notifier.allowed();
              if (!context.mounted) return;
              if (ok == false) return notificationsOff(context);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Test notification in 5 seconds')));
              Timer(const Duration(seconds: 5), () => app.notifier.show(appName, 'Notifications are working'));
            },
          ),
          const Divider(),
          const _Header('About'),
          ListTile(
            leading: SizedBox.square(
              dimension: 24,
              child: CustomPaint(painter: MeshLogoPainter(Theme.of(context).colorScheme.primary)),
            ),
            title: const Text(appName),
            subtitle: const Text('Version $appVersion · a chat app for MeshCore companion nodes'),
          ),
        ]),
      ),
    );
  }

  Widget _sub(bool enabled, String title, bool value, void Function(bool) set) => SwitchListTile(
        secondary: const SizedBox(width: 24),
        title: Text(title),
        value: value,
        onChanged: enabled
            ? (v) {
                set(v);
                app.prefs.save();
              }
            : null,
      );
}

void notificationsOff(BuildContext context) => showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Notifications are off'),
        content: const Text('The phone is blocking notifications from $appName. Turn them on in '
            'Settings › Notifications › $appName (on Android: Settings › Apps › $appName › Notifications).'),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
