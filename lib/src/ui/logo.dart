// The mark: three linked nodes, the mesh. The same one MeshCore Desktop draws.
// And the splash that shows it while the app starts.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// The nodes as fractions of the box: top, bottom left, bottom right.
const _nodes = [Offset(0.5, 0.26), Offset(0.25, 0.72), Offset(0.75, 0.72)];

class MeshLogoPainter extends CustomPainter {
  final Color ink;
  final double progress; // 0..1: links draw in, then the nodes pop
  MeshLogoPainter(this.ink, {this.progress = 1});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final o = Offset((size.width - s) / 2, (size.height - s) / 2);
    final pts = [for (final n in _nodes) o + Offset(n.dx * s, n.dy * s)];
    final line = Paint()
      ..color = ink
      ..strokeWidth = s * 0.06
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // Each link takes its share of the first 60%.
    final links = (progress / 0.6).clamp(0.0, 1.0) * 3;
    for (var i = 0; i < 3; i++) {
      final f = (links - i).clamp(0.0, 1.0);
      if (f <= 0) continue;
      final a = pts[i], b = pts[(i + 1) % 3];
      canvas.drawLine(a, Offset.lerp(a, b, f)!, line);
    }
    final dot = Paint()..color = ink;
    for (var i = 0; i < 3; i++) {
      final t = ((progress - 0.45 - i * 0.12) / 0.25).clamp(0.0, 1.0);
      if (t <= 0) continue;
      // A little overshoot as each one lands.
      final r = s * 0.1 * (t < 1 ? Curves.easeOutBack.transform(t) : 1);
      canvas.drawCircle(pts[i], math.max(r, 0), dot);
    }
  }

  @override
  bool shouldRepaint(covariant MeshLogoPainter old) => old.progress != progress || old.ink != ink;
}

/// The splash's colours: a night-time tactical display.
class Tac {
  static const bg = Color(0xFF14180F); // near-black olive: the native splash's background too
  static const grid = Color(0xFF232A19);
  static const olive = Color(0xFF4B5320); // olive drab
  static const khaki = Color(0xFFCBB97F);
  static const phosphor = Color(0xFF9BD45A); // radar green
  static const amber = Color(0xFFD9A21B);
}

/// The radar scope: rings, crosshair and bearing ticks, a sweep, and the mesh
/// as three contacts that ping in and link up. The native launch screen is the
/// same scope without the sweep or the contacts (tool/splash.py draws it).
class RadarPainter extends CustomPainter {
  final double sweep; // radians clockwise from north
  final double reveal; // 0..1: contacts ping in, then link up
  RadarPainter({required this.sweep, required this.reveal});

  // The mesh mark, centred on the scope.
  static const _contacts = [Offset(0.5, 0.2), Offset(0.27, 0.64), Offset(0.73, 0.64)];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    final r = s / 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..color = Tac.phosphor.withValues(alpha: 0.45)
      ..strokeWidth = s * 0.008;
    canvas.drawCircle(c, r * 0.98, Paint()..color = const Color(0xFF0E120A));
    canvas.drawCircle(c, r * 0.98, ring..strokeWidth = s * 0.014);
    ring.strokeWidth = s * 0.006;
    for (final f in [0.33, 0.66]) {
      canvas.drawCircle(c, r * f, ring);
    }
    canvas.drawLine(c - Offset(r * 0.98, 0), c + Offset(r * 0.98, 0), ring);
    canvas.drawLine(c - Offset(0, r * 0.98), c + Offset(0, r * 0.98), ring);
    final tick = Paint()
      ..color = Tac.phosphor.withValues(alpha: 0.6)
      ..strokeWidth = s * 0.007;
    for (var d = 0; d < 360; d += 10) {
      final a = d * math.pi / 180;
      final dir = Offset(math.sin(a), -math.cos(a));
      final len = d % 30 == 0 ? 0.08 : 0.04;
      canvas.drawLine(c + dir * r * 0.98, c + dir * r * (0.98 - len), tick);
    }

    // The sweep: a fading wedge behind a bright leading edge.
    final rect = Rect.fromCircle(center: c, radius: r * 0.96);
    final start = sweep - math.pi / 2; // canvas angles start east
    const trail = math.pi / 2.2;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(start - trail);
    canvas.translate(-c.dx, -c.dy);
    canvas.drawArc(
      rect,
      0,
      trail,
      true,
      Paint()
        ..shader = SweepGradient(
          center: Alignment.center,
          startAngle: 0,
          endAngle: trail,
          colors: [Tac.phosphor.withValues(alpha: 0), Tac.phosphor.withValues(alpha: 0.38)],
        ).createShader(rect),
    );
    canvas.restore();
    canvas.drawLine(
        c,
        c + Offset(math.cos(start), math.sin(start)) * r * 0.96,
        Paint()
          ..color = Tac.phosphor
          ..strokeWidth = s * 0.01);

    // Contacts and their links.
    final pts = [for (final p in _contacts) Offset(c.dx - r + p.dx * s, c.dy - r + p.dy * s)];
    final link = Paint()
      ..color = Tac.khaki
      ..strokeWidth = s * 0.016
      ..strokeCap = StrokeCap.round;
    final links = ((reveal - 0.55) / 0.35).clamp(0.0, 1.0) * 3;
    for (var i = 0; i < 3; i++) {
      final f = (links - i).clamp(0.0, 1.0);
      if (f <= 0) continue;
      final a = pts[i], b = pts[(i + 1) % 3];
      canvas.drawLine(a, Offset.lerp(a, b, f)!, link);
    }
    for (var i = 0; i < 3; i++) {
      final t = ((reveal - 0.1 - i * 0.14) / 0.2).clamp(0.0, 1.0);
      if (t <= 0) continue;
      // A ping: a ring that spreads and fades, and the contact itself.
      if (t < 1) {
        canvas.drawCircle(
            pts[i],
            s * (0.03 + 0.12 * t),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = s * 0.008
              ..color = Tac.phosphor.withValues(alpha: 1 - t));
      }
      canvas.drawCircle(pts[i], s * 0.05, Paint()..color = Tac.phosphor.withValues(alpha: 0.25 * t));
      canvas.drawCircle(pts[i], s * 0.032 * Curves.easeOutBack.transform(t), Paint()..color = Tac.khaki);
    }
  }

  @override
  bool shouldRepaint(covariant RadarPainter old) => old.sweep != sweep || old.reveal != reveal;
}

/// The map grid and the corner brackets of a HUD.
class _HudPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final g = Paint()
      ..color = Tac.grid
      ..strokeWidth = 1;
    const step = 32.0;
    for (var x = (size.width / 2) % step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), g);
    }
    for (var y = (size.height / 2) % step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
    final b = Paint()
      ..color = Tac.olive
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    const m = 18.0, l = 28.0;
    final w = size.width, h = size.height;
    for (final (o, dx, dy) in [
      (const Offset(m, m), 1.0, 1.0),
      (Offset(w - m, m), -1.0, 1.0),
      (Offset(m, h - m), 1.0, -1.0),
      (Offset(w - m, h - m), -1.0, -1.0),
    ]) {
      canvas.drawPath(
          Path()
            ..moveTo(o.dx, o.dy + dy * l)
            ..lineTo(o.dx, o.dy)
            ..lineTo(o.dx + dx * l, o.dy),
          b);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// Shown while the app loads its settings, then fades into it. The native
/// launch screen shows the same scope on the same colour, so there's no jump.
class Splash extends StatefulWidget {
  final bool ready;
  final Widget child;
  final String version;
  const Splash({super.key, required this.ready, required this.child, this.version = ''});

  static const colour = Tac.bg;
  static const scope = 200.0; // the scope's size; the native image is 4x this

  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> with TickerProviderStateMixin {
  late final _draw = AnimationController(vsync: this, duration: const Duration(milliseconds: 1900))..forward();
  late final _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _draw.addStatusListener((_) => _maybeLeave());
    _fade.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        _spin.stop();
        setState(() => _gone = true);
      }
    });
  }

  @override
  void didUpdateWidget(covariant Splash old) {
    super.didUpdateWidget(old);
    _maybeLeave();
  }

  void _maybeLeave() {
    if (widget.ready && _draw.isCompleted && !_fade.isAnimating && !_fade.isCompleted) _fade.forward();
  }

  @override
  void dispose() {
    _draw.dispose();
    _spin.dispose();
    _fade.dispose();
    super.dispose();
  }

  Animation<double> _at(double a, double b) =>
      CurvedAnimation(parent: _draw, curve: Interval(a, b, curve: Curves.easeOut));

  static const _mono = TextStyle(fontFamily: 'ShareTechMono', color: Tac.khaki, fontSize: 12, letterSpacing: 2.5);

  @override
  Widget build(BuildContext context) {
    if (_gone) return widget.child;
    const half = Splash.scope / 2;
    return Stack(children: [
      if (widget.ready) Positioned.fill(child: widget.child),
      Positioned.fill(
        child: FadeTransition(
          opacity: ReverseAnimation(_fade),
          child: Material(
            color: Splash.colour,
            child: LayoutBuilder(builder: (context, box) {
              final mid = box.maxHeight / 2;
              return Stack(children: [
                Positioned.fill(child: FadeTransition(opacity: _at(0, 0.3), child: CustomPaint(painter: _HudPainter()))),
                // The scope sits dead centre, where the native splash put it.
                Positioned(
                  left: box.maxWidth / 2 - half,
                  top: mid - half,
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_draw, _spin]),
                    builder: (context, _) => CustomPaint(
                      size: const Size.square(Splash.scope),
                      painter: RadarPainter(sweep: _spin.value * 2 * math.pi, reveal: _draw.value),
                    ),
                  ),
                ),
                Positioned(
                  left: 24,
                  right: 24,
                  top: mid + half + 28,
                  child: Column(children: [
                    FadeTransition(
                      opacity: _at(0.45, 0.75),
                      child: SlideTransition(
                        position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(_at(0.45, 0.75)),
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('FULL METAL MESH',
                              style: TextStyle(fontFamily: 'BlackOpsOne', color: Tac.khaki, fontSize: 34, letterSpacing: 1.5)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FadeTransition(
                      opacity: _at(0.6, 0.85),
                      child: const Text('TACTICAL MESH COMMS // MESHCORE',
                          textAlign: TextAlign.center, style: TextStyle(fontFamily: 'ShareTechMono', color: Tac.phosphor, fontSize: 12, letterSpacing: 2.5)),
                    ),
                  ]),
                ),
                // Readouts in the corners.
                Positioned(
                  left: 28,
                  top: MediaQuery.paddingOf(context).top + 28,
                  child: FadeTransition(opacity: _at(0.2, 0.5), child: const Text('FMM-01', style: _mono)),
                ),
                Positioned(
                  right: 28,
                  top: MediaQuery.paddingOf(context).top + 28,
                  child: FadeTransition(
                    opacity: _at(0.2, 0.5),
                    child: Row(children: [
                      Container(width: 8, height: 8, decoration: const BoxDecoration(color: Tac.amber, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      const Text('LORA', style: _mono),
                    ]),
                  ),
                ),
                Positioned(
                  left: 28,
                  right: 28,
                  bottom: MediaQuery.paddingOf(context).bottom + 30,
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_draw, _spin]),
                    builder: (context, _) {
                      const msg = '> INITIALIZING LINK';
                      final n = (((_draw.value - 0.5) / 0.4).clamp(0.0, 1.0) * msg.length).round();
                      final cursor = _spin.value < 0.5 ? '_' : ' ';
                      return Row(children: [
                        Text(_draw.value < 0.5 ? '' : msg.substring(0, n) + cursor,
                            style: _mono.copyWith(color: Tac.phosphor)),
                        const Spacer(),
                        if (widget.version.isNotEmpty)
                          Opacity(opacity: _at(0.2, 0.5).value, child: Text('V${widget.version}', style: _mono)),
                      ]);
                    },
                  ),
                ),
              ]);
            }),
          ),
        ),
      ),
    ]);
  }
}
