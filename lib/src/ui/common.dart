import 'package:material_ui/material_ui.dart';

import '../protocol.dart' as p;

class SectionHeader extends StatelessWidget {
  final String text;
  const SectionHeader(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

void toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));

IconData typeIcon(int t) => switch (t) {
      p.advRepeater => Icons.cell_tower,
      p.advRoom => Icons.meeting_room_outlined,
      p.advSensor => Icons.sensors,
      _ => Icons.person_outline,
    };

String typeName(int t) => switch (t) {
      p.advRepeater => 'Repeater',
      p.advRoom => 'Room',
      p.advSensor => 'Sensor',
      _ => 'Contact',
    };

String hopsText(int h) => h < 0
    ? 'No route'
    : h == 0
        ? 'Direct'
        : h == 1
            ? '1 hop'
            : '$h hops';

String _two(int n) => n.toString().padLeft(2, '0');

String shortTime(double at, {bool seconds = false}) {
  final t = DateTime.fromMillisecondsSinceEpoch((at * 1000).round());
  final now = DateTime.now();
  final hm = '${_two(t.hour)}:${_two(t.minute)}${seconds ? ':${_two(t.second)}' : ''}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
  if (now.difference(t).inDays < 7) {
    return '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1]} $hm';
  }
  return '${t.day}/${t.month} $hm';
}

String ago(double s) {
  if (s < 60) return 'now';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}
