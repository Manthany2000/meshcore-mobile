// Everything we know about a contact, and what can be done with it. The same
// sections as MeshCore Desktop's map card.
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../main.dart';
import '../model.dart';
import '../protocol.dart' as p;
import 'common.dart';
import 'home.dart' show openChatFromAnywhere;
import 'map.dart';
import 'repeater.dart';

const _compass = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];

String bearing(double la1, double lo1, double la2, double lo2) {
  double r(double d) => d * math.pi / 180;
  final a1 = r(la1), a2 = r(la2), d = r(lo2 - lo1);
  final deg = (math.atan2(math.sin(d) * math.cos(a2), math.cos(a1) * math.sin(a2) - math.sin(a1) * math.cos(a2) * math.cos(d)) *
              180 /
              math.pi +
          360) %
      360;
  return '${deg.toStringAsFixed(0)}° ${_compass[((deg + 22.5) ~/ 45) % 8]}';
}

String stamp(num t) {
  if (t < clockSane) return t == 0 ? 'never' : 'clock not set';
  return shortTime(t.toDouble());
}

String agoLong(double? s) {
  if (s == null) return 'unknown';
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) return '${s ~/ 3600} h ago';
  return '${s ~/ 86400} d ago';
}

Future<void> showContact(BuildContext context, AppState app, p.Contact c) {
  final m = app.model;
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => ListenableBuilder(
      listenable: m,
      builder: (ctx, _) {
        final cur = m.contacts[c.prefixHex] ?? c;
        final km = m.distanceKm(cur);
        final s = m.selfInfo;
        final relays = cur.type == p.advRepeater
            ? [1, 2, 3].fold(0, (a, n) => a + (m.relayCounts()[p.hex(cur.key.sublist(0, n))] ?? 0))
            : 0;
        final msgs = m.conversation(dmConv(cur.key));
        final cs = Theme.of(ctx).colorScheme;
        void go(VoidCallback f) {
          Navigator.pop(ctx);
          f();
        }

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 16), children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: typeColor(cur.type, cs),
                  child: Icon(typeIcon(cur.type), color: Colors.white),
                ),
                title: Text(cur.name.isEmpty ? cur.prefixHex : cur.name, style: Theme.of(ctx).textTheme.titleLarge),
                subtitle: Text('${typeName(cur.type)} · heard ${agoLong(m.contactAge(cur))}'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  if (cur.type == p.advChat || cur.type == p.advRoom)
                    FilledButton.icon(
                      onPressed: () => go(() => openChatFromAnywhere(context, app, dmConv(cur.key))),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Message'),
                    ),
                  if (cur.type == p.advRepeater)
                    FilledButton.icon(
                      onPressed: () => go(() => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => RepeaterScreen(app: app, contact: cur)))),
                      icon: const Icon(Icons.settings_remote_outlined),
                      label: const Text('Manage repeater'),
                    ),
                  if (located(cur))
                    FilledButton.tonalIcon(
                      onPressed: () => go(() => app.showOnMap(FocusRequest(cur.prefixHex))),
                      icon: const Icon(Icons.place_outlined),
                      label: const Text('On map'),
                    ),
                  if (cur.hops > 0 && located(cur))
                    FilledButton.tonalIcon(
                      onPressed: () => go(() => app.showOnMap(FocusRequest(cur.prefixHex, route: true))),
                      icon: const Icon(Icons.alt_route),
                      label: const Text('Show route'),
                    ),
                  if (cur.hops >= 0)
                    OutlinedButton.icon(
                      onPressed: () async {
                        final f = await app.session?.resetPath(cur.key);
                        if (ctx.mounted) toast(ctx, f?.kind == 'ok' ? 'Route reset: the next message floods' : 'Couldn\'t reset the route');
                      },
                      icon: const Icon(Icons.waves),
                      label: const Text('Reset route'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: p.hex(cur.key)));
                      toast(ctx, 'Public key copied');
                    },
                    icon: const Icon(Icons.key),
                    label: const Text('Copy key'),
                  ),
                ]),
              ),
              if (cur.type == p.advChat)
                SwitchListTile(
                  secondary: const Icon(Icons.all_inclusive),
                  title: const Text('Always flood messages'),
                  subtitle: const Text('Every DM floods the mesh instead of using the stored route'),
                  value: m.alwaysFloods(cur.prefixHex),
                  onChanged: (v) => m.setAlwaysFlood(cur.prefixHex, v),
                ),
              _Section('Reach', [
                ('Route', cur.hops < 0 ? 'No known route: floods' : cur.hops == 0 ? 'Direct neighbour' : '${cur.hops} hops'),
                ('Last heard', agoLong(m.contactAge(cur))),
                ('Last advert', stamp(cur.lastAdvert)),
                ('Contact updated', stamp(cur.lastMod)),
                if (m.lastSnr[cur.prefixHex] != null) ('Last SNR', '${m.lastSnr[cur.prefixHex]!.toStringAsFixed(1)} dB'),
                if (km != null) ('Distance', '${km.toStringAsFixed(1)} km'),
                if (km != null && s != null) ('Bearing', bearing(s.lat, s.lon, cur.lat, cur.lon)),
              ]),
              if (cur.hops > 0)
                _Section('Path', [
                  for (final (i, h) in cur.path.hops().indexed)
                    ('Hop ${i + 1}', () {
                      final n = m.hopNames(p.hex(h));
                      final who = n.isEmpty ? 'unknown' : n.first + (n.length > 1 ? ' (or ${n.length - 1} other${n.length > 2 ? 's' : ''})' : '');
                      return '${p.hex(h)} · $who';
                    }()),
                ]),
              _Section('Identity', [
                ('Type', typeName(cur.type)),
                if (cur.flags & 1 != 0) ('Favourite', 'Yes'),
                ('Hop hash', p.hex(cur.key.sublist(0, 1))),
                ('Public key', p.hex(cur.key)),
              ]),
              if (located(cur)) _Section('Location', [('Latitude', cur.lat.toStringAsFixed(6)), ('Longitude', cur.lon.toStringAsFixed(6))]),
              _Section('Activity', [
                if (msgs.isNotEmpty) ('Saved messages', '${msgs.length}'),
                if (msgs.isNotEmpty) ('Last message', shortTime(msgs.last.at)),
                if (relays > 0) ('Relayed messages', '$relays (by hop hash, may include others)'),
              ]),
            ]),
          ),
        );
      },
    ),
  );
}

Future<void> showSelfSheet(BuildContext context, AppState app) {
  final m = app.model;
  final s = m.selfInfo;
  if (s == null) return Future.value();
  final d = m.deviceInfo;
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 16), children: [
          ListTile(
            leading: const CircleAvatar(backgroundColor: selfColor, child: Icon(Icons.router, color: Colors.white)),
            title: Text(s.name, style: Theme.of(ctx).textTheme.titleLarge),
            subtitle: const Text('Your node'),
          ),
          _Section('Radio', [
            ('Frequency', '${s.freq.toStringAsFixed(3)} MHz'),
            ('Bandwidth', '${s.bw} kHz'),
            ('Spreading factor', '${s.sf}'),
            ('Coding rate', '${s.cr}'),
            ('TX power', '${s.txPower} dBm (max ${s.maxTx})'),
          ]),
          _Section('Node', [
            if (m.batteryMv > 0) ('Battery', '${(m.batteryMv / 1000).toStringAsFixed(2)} V (${p.battPercent(m.batteryMv)}%)'),
            ('Contacts', '${m.contacts.length}'),
            ('Channels', '${m.channels.length}'),
          ]),
          if (d != null)
            _Section('Device', [
              if ((d['model'] as String).isNotEmpty) ('Model', d['model']),
              if ((d['fw'] as String).isNotEmpty) ('Firmware', d['fw']),
              if ((d['build'] as String).isNotEmpty) ('Build', d['build']),
              ('Protocol', '${d['protocol']}'),
              ('Max contacts', '${d['max_contacts']}'),
              ('Max channels', '${d['max_channels']}'),
            ]),
          _Section('Location', [('Latitude', s.lat.toStringAsFixed(6)), ('Longitude', s.lon.toStringAsFixed(6))]),
          _Section('Identity', [('Hop hash', p.hex(s.key.sublist(0, 1))), ('Public key', p.hex(s.key))]),
        ]),
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;
  const _Section(this.title, this.rows);

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title.toUpperCase(), style: tt.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
        const SizedBox(height: 4),
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 120, child: Text(k, style: tt.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
              Expanded(child: SelectableText(v, style: tt.bodyMedium)),
            ]),
          ),
      ]),
    );
  }
}
