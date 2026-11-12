// What the mesh has been doing, from what the node has told us. Packets are
// counted for this session; messages come from the saved history. Ported from
// MeshCore Desktop's dashboard.py.
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../main.dart';
import '../model.dart';
import '../protocol.dart' as p;
import 'common.dart';
import 'waterfall.dart';

String packetName(int t) => switch (t) {
      0 => 'Request',
      1 => 'Response',
      2 => 'Direct msg',
      3 => 'Ack',
      4 => 'Advert',
      5 => 'Channel msg',
      6 => 'Channel data',
      7 => 'Anon request',
      8 => 'Path',
      9 => 'Trace',
      _ => 'Type $t',
    };

class DashboardTab extends StatefulWidget {
  final AppState app;
  const DashboardTab({super.key, required this.app});

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.app.model;
    final now = nowS();
    final ages = m.contacts.values.map(m.contactAge);
    final tiles = [
      ('${ages.where((a) => a != null && a < 86400).length}', 'Nodes heard, 24 h', Icons.sensors),
      ('${m.contacts.values.where((c) => c.type == p.advRepeater).length}', 'Repeaters known', Icons.cell_tower),
      ('${m.messages.where((x) => now - x.at < 86400).length}', 'Messages, 24 h', Icons.forum_outlined),
      ('${m.packets.length}', 'Packets this session', Icons.graphic_eq),
    ];
    return ListView(padding: const EdgeInsets.all(12), children: [
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.1,
        children: [
          for (final (v, label, icon) in tiles)
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Row(children: [
                    Text(v, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Icon(icon, color: Theme.of(context).colorScheme.primary),
                  ]),
                  Text(label, style: Theme.of(context).textTheme.labelSmall),
                ]),
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
      _Card(title: 'Packet waterfall', child: WaterfallStrip(model: m)),
      _Card(
        title: 'Busiest repeaters',
        child: _Bars(rows: m.busiestRepeaters(), empty: 'Repeaters appear here once they relay messages you can hear.', unit: 'relayed'),
      ),
      _Card(
        title: 'Channel activity, 7 days',
        child: _Bars(rows: m.channelActivity(), empty: 'No channel messages in the last week.', unit: 'messages'),
      ),
      _Card(
        title: 'Live packets',
        child: m.packets.isEmpty
            ? const Padding(padding: EdgeInsets.all(8), child: Text('Packets your node hears will scroll by here.'))
            : Column(children: [
                for (final (at, r) in m.packets.reversed.take(25))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        width: 62,
                        child: Text(shortTime(at, seconds: true),
                            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 12)),
                      ),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${packetName(r.payloadType)} · ${r.flood ? '${r.hops} hop${r.hops == 1 ? '' : 's'}' : 'direct'}',
                              style: const TextStyle(fontSize: 13)),
                          if (r.flood && r.path.data.isNotEmpty)
                            Text(
                              r.path.hops().map((h) => m.hopNames(p.hex(h)).firstOrNull ?? p.hex(h)).join(' → '),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                        ]),
                      ),
                      Text('${r.snr.toStringAsFixed(1)} dB', style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
              ]),
      ),
    ]);
  }
}

class _Card extends StatelessWidget {
  final String title;
  final Widget child;
  const _Card({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            child,
          ]),
        ),
      );
}

class _Bars extends StatelessWidget {
  final List<(String, int)> rows;
  final String empty, unit;
  const _Bars({required this.rows, required this.empty, required this.unit});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return Text(empty, style: Theme.of(context).textTheme.bodySmall);
    final top = rows.map((r) => r.$2).reduce((a, b) => a > b ? a : b);
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      for (final (name, n) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 110, child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 14,
                    width: (box.maxWidth * n / top).clamp(4.0, box.maxWidth),
                    decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(4)),
                  ),
                ),
              ),
            ),
            SizedBox(width: 40, child: Text('$n', textAlign: TextAlign.end, style: const TextStyle(fontSize: 13))),
          ]),
        ),
    ]);
  }
}
