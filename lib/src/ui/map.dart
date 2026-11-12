// The Map / Network tab. Map: contacts that advertise a location, and every
// flood the node hears runs its path across it. Trace: one received message's
// path in red. Network: who relays through whom. Ported from MeshCore
// Desktop's mapview.py and map.html.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_ui/material_ui.dart';

import '../../main.dart';
import '../model.dart';
import '../protocol.dart' as p;
import 'common.dart';
import 'contact_sheet.dart';
import 'graph.dart';

const staleS = 3 * 86400; // drawn faded
const freshS = 3600; // drawn with a glow

/// What another screen asked the map to show.
sealed class MapRequest {}

class TraceRequest extends MapRequest {
  final Message msg;
  TraceRequest(this.msg);
}

class FocusRequest extends MapRequest {
  final String prefixHex;
  final bool route;
  FocusRequest(this.prefixHex, {this.route = false});
}

Color typeColor(int t, ColorScheme cs) => switch (t) {
      p.advRepeater => const Color(0xFF16A34A),
      p.advRoom => const Color(0xFF9333EA),
      p.advSensor => const Color(0xFFEA580C),
      _ => const Color(0xFF2563EB),
    };

const selfColor = Color(0xFFF59E0B);

bool located(p.Contact c) => c.lat != 0 || c.lon != 0;

/// A stop on a message's path: its name, and where it is if we know.
typedef Stop = ({String name, LatLng? at});

/// Where a received message went: the sender, each repeater, then us. Hops
/// are short hashes, so each is the likeliest located node.
List<Stop> messagePath(Model m, Message msg) {
  final p.Contact? sender = msg.isChannel
      ? m.contacts.values.where((c) => c.name == msg.sender).firstOrNull
      : m.contacts[msg.conv.substring(3)];
  LatLng? at(p.Contact? c) => c != null && located(c) ? LatLng(c.lat, c.lon) : null;
  final stops = <Stop>[(name: msg.outgoing ? 'You' : msg.sender, at: msg.outgoing ? null : at(sender))];
  List<List<int>> hops;
  if (msg.path != null && msg.path!.isNotEmpty) {
    hops = [for (final h in msg.path!) p.unhex(h)];
  } else if (msg.hops < 0 && sender != null && sender.hops > 0) {
    hops = sender.path.hops().reversed.toList(); // a direct DM: the route we know to them, backwards
  } else {
    hops = [];
  }
  for (final h in hops) {
    final c = m.hopContact(h);
    stops.add((name: c != null && c.name.isNotEmpty ? c.name : p.hex(h), at: at(c)));
  }
  final s = m.selfInfo;
  stops.add((name: 'You', at: s != null && (s.lat != 0 || s.lon != 0) ? LatLng(s.lat, s.lon) : null));
  return stops;
}

class _Pulse {
  final List<LatLng> pts;
  final double start;
  _Pulse(this.pts, this.start);
}

class MapTab extends StatefulWidget {
  final AppState app;
  const MapTab({super.key, required this.app});

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> with SingleTickerProviderStateMixin {
  final map = MapController();
  bool network = false;
  bool labels = true;
  final types = {p.advChat, p.advRepeater, p.advRoom, p.advSensor};
  int? maxAge; // seconds
  String query = '';
  final search = TextEditingController();
  String? routeOf; // prefix hex whose stored route is drawn
  Message? trace;
  String? selected;
  final pulses = <_Pulse>[];
  late final Ticker _ticker;
  StreamSubscription? _packets;
  bool _ready = false;
  bool _fitted = false;

  Model get m => widget.app.model;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      final now = nowS();
      pulses.removeWhere((x) => now - x.start > 4);
      if (pulses.isEmpty) _ticker.stop();
      setState(() {});
    });
    _packets = m.packetStream.stream.listen((e) => _pulse(e.$2));
    widget.app.mapRequest.addListener(_request);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _packets?.cancel();
    widget.app.mapRequest.removeListener(_request);
    search.dispose();
    super.dispose();
  }

  void _request() {
    final r = widget.app.mapRequest.value;
    if (r == null) return;
    widget.app.mapRequest.value = null;
    setState(() {
      network = false;
      switch (r) {
        case TraceRequest(:final msg):
          trace = msg;
          routeOf = null;
        case FocusRequest(:final prefixHex, :final route):
          trace = null;
          selected = prefixHex;
          routeOf = route ? prefixHex : null;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _frame(r));
  }

  void _frame(MapRequest r) {
    if (!_ready) return;
    switch (r) {
      case TraceRequest(:final msg):
        final pts = [for (final s in messagePath(m, msg)) if (s.at != null) s.at!];
        _fit(pts);
      case FocusRequest(:final prefixHex, :final route):
        final c = m.contacts[prefixHex];
        if (c == null) return;
        if (route) {
          _fit([LatLng(c.lat, c.lon), ..._routePoints(c).whereType<LatLng>(), ?_self]);
        } else if (located(c)) {
          map.move(LatLng(c.lat, c.lon), math.max(map.camera.zoom, 13));
        }
    }
  }

  void _fit(List<LatLng> pts) {
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      map.move(pts.first, 13);
      return;
    }
    map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.fromLTRB(48, 140, 48, 96), maxZoom: 15));
  }

  LatLng? get _self {
    final s = m.selfInfo;
    return s != null && (s.lat != 0 || s.lon != 0) ? LatLng(s.lat, s.lon) : null;
  }

  /// Runs a flood's path across the map as the packet is heard.
  void _pulse(p.RawPacket pk) {
    final me = _self;
    if (network || trace != null || !pk.flood || pk.hops < 1 || me == null || !mounted) return;
    final pts = <LatLng>[];
    for (final h in pk.path.hops()) {
      final c = m.hopContact(h, located: true);
      if (c != null) pts.add(LatLng(c.lat, c.lon));
    }
    if (pts.isEmpty) return;
    pulses.add(_Pulse([...pts, me], nowS()));
    if (pulses.length > 12) pulses.removeAt(0);
    if (!_ticker.isActive) _ticker.start();
  }

  List<LatLng?> _routePoints(p.Contact c) => [
        for (final h in c.hops > 0 ? c.path.hops() : <List<int>>[])
          switch (m.hopContact(h, located: true)) { final x? => LatLng(x.lat, x.lon), _ => null }
      ];

  bool _matches(p.Contact c) {
    final q = query.trim().toLowerCase();
    return q.isEmpty || c.name.toLowerCase().contains(q) || p.hex(c.key).startsWith(q);
  }

  List<p.Contact> _shown() => m.contacts.values.where((c) {
        if (!located(c) || !_matches(c)) return false;
        if (query.isNotEmpty) return true; // a search finds a node whatever the filters say
        if (!types.contains(c.type)) return false;
        final age = m.contactAge(c);
        return maxAge == null || (age != null && age <= maxAge!);
      }).toList();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListenableBuilder(
      listenable: m,
      builder: (context, _) {
        final shown = _shown();
        final me = _self;
        if (_ready && !_fitted && (shown.isNotEmpty || me != null)) {
          _fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _fit([for (final c in shown) LatLng(c.lat, c.lon), ?me]));
        }
        return Stack(children: [
          Offstage(
            offstage: network,
            child: FlutterMap(
              mapController: map,
              options: MapOptions(
                initialCenter: me ?? const LatLng(20, 0),
                initialZoom: me != null ? 11 : 2,
                onMapReady: () => setState(() => _ready = true),
                onTap: (_, _) => setState(() {
                  selected = null;
                  routeOf = null;
                }),
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'io.github.manthany2000.meshcore_mobile',
                  maxZoom: 19,
                  tileBuilder: dark ? darkModeTileBuilder : null,
                ),
                if (routeOf != null && m.contacts[routeOf] != null) _routeLayer(m.contacts[routeOf]!),
                PolylineLayer(polylines: _pulseLines(cs)),
                if (trace != null) ..._traceLayers(cs),
                MarkerLayer(markers: [
                  for (final c in shown) _marker(c, cs),
                  if (me != null && (query.isEmpty || (m.selfInfo?.name.toLowerCase().contains(query.toLowerCase()) ?? false)))
                    Marker(
                      point: me,
                      width: 120,
                      height: 52,
                      child: _Pin(
                        icon: Icons.router,
                        color: selfColor,
                        label: labels ? m.selfInfo!.name : null,
                        selected: selected == 'self',
                        onTap: () => _showSelf(context),
                      ),
                    ),
                ]),
                RichAttributionWidget(
                  alignment: AttributionAlignment.bottomLeft,
                  attributions: [TextSourceAttribution('OpenStreetMap contributors')],
                ),
              ],
            ),
          ),
          if (network) NetworkGraph(model: m, onOpen: (c) => showContact(context, widget.app, c)),
          Positioned(top: 8, left: 8, right: 8, child: _topBar(context, shown)),
          if (!network)
            Positioned(
              right: 12,
              bottom: 24,
              child: FloatingActionButton.small(
                heroTag: 'fit',
                tooltip: 'Show everything',
                onPressed: () => _fit([for (final c in shown) LatLng(c.lat, c.lon), ?me]),
                child: const Icon(Icons.fit_screen),
              ),
            ),
        ]);
      },
    );
  }

  Widget _topBar(BuildContext context, List<p.Contact> shown) {
    final cs = Theme.of(context).colorScheme;
    final t = trace;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        SegmentedButton<bool>(
          style: SegmentedButton.styleFrom(backgroundColor: cs.surface.withValues(alpha: 0.92), visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.map_outlined), label: Text('Map')),
            ButtonSegment(value: true, icon: Icon(Icons.hub_outlined), label: Text('Network')),
          ],
          selected: {network},
          onSelectionChanged: (v) => setState(() => network = v.first),
        ),
        const Spacer(),
        if (!network)
          IconButton.filledTonal(tooltip: 'Filters', onPressed: () => _filters(context), icon: const Icon(Icons.tune)),
      ]),
      if (!network && t == null) ...[
        const SizedBox(height: 6),
        Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(24),
          color: cs.surface.withValues(alpha: 0.95),
          child: TextField(
            controller: search,
            decoration: InputDecoration(
              hintText: 'Search nodes (name or key)',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        search.clear();
                        query = '';
                      })),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              isDense: true,
            ),
            onChanged: (v) => setState(() => query = v),
            onSubmitted: (_) {
              final hits = _shown();
              _fit([for (final c in hits) LatLng(c.lat, c.lon)]);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 8),
          child: Text(
            query.isEmpty ? '${shown.length} of ${m.contacts.length} shown' : '${shown.length} match${shown.length == 1 ? '' : 'es'}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  shadows: [Shadow(color: cs.surface, blurRadius: 4), Shadow(color: cs.surface, blurRadius: 8)],
                ),
          ),
        ),
      ],
      if (!network && t != null) ...[
        const SizedBox(height: 6),
        _TraceCard(model: m, msg: t, onClose: () => setState(() => trace = null)),
      ],
    ]);
  }

  Marker _marker(p.Contact c, ColorScheme cs) {
    final age = m.contactAge(c);
    return Marker(
      point: LatLng(c.lat, c.lon),
      width: 120,
      height: 52,
      child: _Pin(
        icon: typeIcon(c.type),
        color: typeColor(c.type, cs),
        label: labels ? (c.name.isEmpty ? c.prefixHex.substring(0, 6) : c.name) : null,
        stale: age == null || age > staleS,
        fresh: age != null && age < freshS,
        selected: selected == c.prefixHex,
        onTap: () {
          setState(() => selected = c.prefixHex);
          showContact(context, widget.app, c);
        },
      ),
    );
  }

  Widget _routeLayer(p.Contact c) {
    final pts = _routePoints(c);
    final me = _self;
    final line = [LatLng(c.lat, c.lon), ...pts.whereType<LatLng>(), ?me];
    return PolylineLayer(polylines: [
      Polyline(
        points: line,
        color: const Color(0xFFF0B429),
        strokeWidth: 4,
        pattern: pts.any((x) => x == null) ? StrokePattern.dashed(segments: const [8, 6]) : const StrokePattern.solid(),
      ),
    ]);
  }

  List<Polyline> _pulseLines(ColorScheme cs) {
    final now = nowS();
    final out = <Polyline>[];
    for (final x in pulses) {
      final t = now - x.start;
      final grow = (t / 1.5).clamp(0.0, 1.0);
      final fade = t < 2 ? 1.0 : (1 - (t - 2) / 2).clamp(0.0, 1.0);
      out.add(Polyline(
        points: _partial(x.pts, grow),
        color: cs.primary.withValues(alpha: 0.85 * fade),
        strokeWidth: 3,
        strokeCap: StrokeCap.round,
      ));
    }
    return out;
  }

  /// The first [f] of a path's length, for drawing it as it travels.
  List<LatLng> _partial(List<LatLng> pts, double f) {
    if (f >= 1 || pts.length < 2) return pts;
    final segs = pts.length - 1;
    final at = f * segs;
    final i = at.floor();
    final r = at - i;
    final a = pts[i], b = pts[i + 1];
    return [...pts.sublist(0, i + 1), LatLng(a.latitude + (b.latitude - a.latitude) * r, a.longitude + (b.longitude - a.longitude) * r)];
  }

  List<Widget> _traceLayers(ColorScheme cs) {
    final stops = messagePath(m, trace!);
    final pts = [for (final s in stops) if (s.at != null) s.at!];
    final red = cs.error;
    return [
      PolylineLayer(polylines: [Polyline(points: pts, color: red, strokeWidth: 4.5, strokeCap: StrokeCap.round)]),
      MarkerLayer(markers: [
        for (final (i, s) in stops.indexed)
          if (s.at != null)
            Marker(
              point: s.at!,
              width: 26,
              height: 26,
              child: Container(
                decoration: BoxDecoration(color: red, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                alignment: Alignment.center,
                child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ),
      ]),
    ];
  }

  void _showSelf(BuildContext context) {
    setState(() => selected = 'self');
    showSelfSheet(context, widget.app);
  }

  Future<void> _filters(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          void both(VoidCallback f) {
            set(f);
            setState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Show', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  for (final (t, label) in [(p.advChat, 'Chat'), (p.advRepeater, 'Repeaters'), (p.advRoom, 'Rooms'), (p.advSensor, 'Sensors')])
                    FilterChip(
                      avatar: Icon(typeIcon(t), size: 18, color: typeColor(t, Theme.of(ctx).colorScheme)),
                      label: Text(label),
                      selected: types.contains(t),
                      onSelected: (v) => both(() => v ? types.add(t) : types.remove(t)),
                    ),
                ]),
                const SizedBox(height: 16),
                Text('Heard', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  for (final (a, label) in [(null, 'Any time'), (86400, '24 h'), (7 * 86400, '7 days'), (30 * 86400, '30 days')])
                    ChoiceChip(label: Text(label), selected: maxAge == a, onSelected: (_) => both(() => maxAge = a)),
                ]),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Names on the map'),
                  value: labels,
                  onChanged: (v) => both(() => labels = v),
                ),
                const SizedBox(height: 4),
                Text('Faded: not heard for 3 days. Glowing: heard in the last hour. Blue lines: packets your node hears, as they arrive.',
                    style: Theme.of(ctx).textTheme.bodySmall),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String? label;
  final bool stale, fresh, selected;
  final VoidCallback onTap;
  const _Pin({
    required this.icon,
    required this.color,
    this.label,
    this.stale = false,
    this.fresh = false,
    this.selected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: stale ? 0.45 : 1,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: selected ? cs.primary : Colors.white.withValues(alpha: 0.9), width: selected ? 3 : 2),
              boxShadow: [
                if (fresh) BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 10, spreadRadius: 2),
                const BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
              ],
            ),
            child: Icon(icon, size: 16, color: Colors.white),
          ),
          if (label != null)
            Text(
              label!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: dark ? Colors.white : const Color(0xFF222222),
                shadows: [
                  for (var i = 0; i < 2; i++) Shadow(color: dark ? Colors.black : Colors.white, blurRadius: 3),
                ],
              ),
            ),
        ]),
      ),
    );
  }
}

class _TraceCard extends StatelessWidget {
  final Model model;
  final Message msg;
  final VoidCallback onClose;
  const _TraceCard({required this.model, required this.msg, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final stops = messagePath(model, msg);
    final missing = [for (final s in stops) if (s.at == null) s.name];
    final drawn = stops.length - missing.length;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.route, color: cs.error, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Path of ${msg.outgoing ? 'your message' : 'a message from ${msg.sender}'}',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            IconButton(onPressed: onClose, icon: const Icon(Icons.close), tooltip: 'Clear'),
          ]),
          Text(
            [for (final (i, s) in stops.indexed) '${i + 1}. ${s.name}'].join('  →  '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (drawn < 2)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Not enough of this path has a location to draw it.', style: TextStyle(color: cs.error, fontSize: 12)),
            )
          else if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('No location for: ${missing.join(', ')}', style: Theme.of(context).textTheme.labelSmall),
            ),
        ]),
      ),
    );
  }
}
