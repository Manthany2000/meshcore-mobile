// Who relays through whom, laid out by a small force simulation. Ported from
// MeshCore Desktop's NetworkGraph. Tap a node to light up its links.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_ui/material_ui.dart';

import '../model.dart';
import '../protocol.dart' as p;

const me = 'me';

class NetworkGraph extends StatefulWidget {
  final Model model;
  final void Function(p.Contact) onOpen;
  const NetworkGraph({super.key, required this.model, required this.onOpen});

  @override
  State<NetworkGraph> createState() => _NetworkGraphState();
}

class _NetworkGraphState extends State<NetworkGraph> with SingleTickerProviderStateMixin {
  static const maxNodes = 150;
  final pos = <String, List<double>>{};
  var weight = <String, int>{};
  var links = <(String, String), int>{};
  double heat = 0;
  String? hit;
  late final Ticker _sim;
  Timer? _poll;
  final rnd = math.Random(7);
  Size _size = Size.zero;

  Model get m => widget.model;

  @override
  void initState() {
    super.initState();
    _sim = createTicker((_) => _step());
    _rebuild();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _rebuild());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _sim.dispose();
    super.dispose();
  }

  void _rebuild() {
    final (w, l) = m.meshLinks();
    final top = (w.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(maxNodes - 1).map((e) => e.key).toSet()
      ..add(me);
    final keepW = {for (final e in w.entries) if (top.contains(e.key)) e.key: e.value};
    final keepL = {for (final e in l.entries) if (top.contains(e.key.$1) && top.contains(e.key.$2)) e.key: e.value};
    final fresh = keepW.keys.toSet().difference(pos.keys.toSet()).isNotEmpty || pos.keys.toSet().difference(keepW.keys.toSet()).isNotEmpty;
    weight = keepW;
    links = keepL;
    for (final h in weight.keys) {
      pos.putIfAbsent(h, () => h == me ? [0, 0] : [rnd.nextDouble() * 1.2 - .6, rnd.nextDouble() * 1.2 - .6]);
    }
    pos.removeWhere((h, _) => !weight.containsKey(h));
    if (fresh) heat = 1;
    if (heat >= .02 && !_sim.isActive) _sim.start();
    if (mounted) setState(() {});
  }

  /// Nodes push apart, links pull together, and the whole thing cools.
  void _step() {
    final names = pos.keys.toList();
    if (names.isEmpty || heat < .02) {
      _sim.stop();
      return;
    }
    final k = 1.6 / math.sqrt(names.length);
    final force = {for (final n in names) n: [0.0, 0.0]};
    for (var i = 0; i < names.length; i++) {
      final pa = pos[names[i]]!;
      for (var j = i + 1; j < names.length; j++) {
        final pb = pos[names[j]]!;
        final dx = pa[0] - pb[0], dy = pa[1] - pb[1];
        final f = k * k / (dx * dx + dy * dy + 1e-4);
        force[names[i]]![0] += dx * f;
        force[names[i]]![1] += dy * f;
        force[names[j]]![0] -= dx * f;
        force[names[j]]![1] -= dy * f;
      }
    }
    for (final (a, b) in links.keys) {
      final pa = pos[a]!, pb = pos[b]!;
      final dx = pa[0] - pb[0], dy = pa[1] - pb[1];
      final d = math.sqrt(dx * dx + dy * dy) + 1e-4;
      final f = d / k;
      force[a]![0] -= dx * f;
      force[a]![1] -= dy * f;
      force[b]![0] += dx * f;
      force[b]![1] += dy * f;
    }
    final limit = .07 * heat;
    for (final n in names) {
      final fx = force[n]![0], fy = force[n]![1];
      final size = math.sqrt(fx * fx + fy * fy) + 1e-6;
      final step = math.min(size * .02, limit);
      final q = pos[n]!;
      q[0] = (q[0] + fx / size * step - q[0] * .01).clamp(-1.0, 1.0);
      q[1] = (q[1] + fy / size * step - q[1] * .01).clamp(-1.0, 1.0);
    }
    heat *= .975;
    setState(() {});
  }

  Offset screen(String h, Size s) {
    final q = pos[h]!;
    return Offset(s.width / 2 + q[0] * (s.width / 2 - 50), s.height / 2 + q[1] * (s.height / 2 - 70) + 20);
  }

  double radius(String h) => h == me ? 12 : 5 + math.min(9, math.sqrt(weight[h] ?? 1));

  String name(String h) {
    if (h == me) return m.selfInfo?.name ?? 'You';
    return m.hopNames(h).firstOrNull ?? h;
  }

  Set<String> near(String h) => {h, for (final (a, b) in links.keys) if (a == h) b else if (b == h) a};

  void _tap(Offset at) {
    String? best;
    var bestD = 30.0;
    for (final h in pos.keys) {
      final d = (screen(h, _size) - at).distance - radius(h);
      if (d < bestD) {
        bestD = d;
        best = h;
      }
    }
    setState(() => hit = best == hit ? null : best);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    if (pos.length < 2) {
      return ColoredBox(
        color: cs.surface,
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text('The network appears here as your node learns routes and hears relayed messages.', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final h = hit;
    final c = h == null || h == me ? null : m.hopContact(p.unhex(h));
    return ColoredBox(
      color: cs.surface,
      child: LayoutBuilder(builder: (context, box) {
        _size = box.biggest;
        return Stack(children: [
          GestureDetector(
            onTapUp: (d) => _tap(d.localPosition),
            child: CustomPaint(size: _size, painter: _GraphPainter(this, cs, tt)),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: h == null
                ? Text('Line thickness: how often a link was used. Dot size: how often a repeater appears. Tap a node to trace it.',
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant))
                : Card(
                    child: ListTile(
                      title: Text(name(h)),
                      subtitle: Text('${h == me ? 'Your node' : 'Hop hash $h'} · seen on ${weight[h] ?? 0} paths · '
                          '${near(h).length - 1} link${near(h).length == 2 ? '' : 's'}'),
                      trailing: c == null ? null : const Icon(Icons.chevron_right),
                      onTap: c == null ? null : () => widget.onOpen(c),
                    ),
                  ),
          ),
        ]);
      }),
    );
  }
}

class _GraphPainter extends CustomPainter {
  final _NetworkGraphState g;
  final ColorScheme cs;
  final TextTheme tt;
  _GraphPainter(this.g, this.cs, this.tt);

  @override
  void paint(Canvas canvas, Size size) {
    final near = g.hit == null ? null : g.near(g.hit!);
    final top = g.links.values.fold(1, math.max);
    for (final e in g.links.entries) {
      final (a, b) = e.key;
      final on = near == null || a == g.hit || b == g.hit;
      final color = (on && near != null ? cs.primary : cs.onSurfaceVariant)
          .withValues(alpha: on && near != null ? 0.75 : (on ? 0.35 : 0.1));
      canvas.drawLine(g.screen(a, size), g.screen(b, size), Paint()
        ..color = color
        ..strokeWidth = 1 + 3 * e.value / top);
    }
    final ranked = (g.weight.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(14).map((e) => e.key).toSet()
      ..add(me);
    for (final h in g.pos.keys) {
      final pt = g.screen(h, size), r = g.radius(h);
      var fill = h == me ? const Color(0xFFF59E0B) : cs.primary;
      if (near != null && !near.contains(h)) fill = fill.withValues(alpha: 0.2);
      canvas.drawCircle(pt, r + 2, Paint()..color = cs.surface);
      canvas.drawCircle(pt, r, Paint()..color = fill);
      final show = near == null ? ranked.contains(h) : near.contains(h);
      if (show) {
        final tp = TextPainter(
          text: TextSpan(text: g.name(h), style: tt.labelSmall?.copyWith(color: cs.onSurface)),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 140);
        tp.paint(canvas, pt + Offset(r + 4, -tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}
