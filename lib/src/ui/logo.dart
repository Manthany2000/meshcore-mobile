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

/// Shown while the app loads its settings, then fades into it. The native
/// launch screen shows the same mark on the same colour, so there's no jump.
class Splash extends StatefulWidget {
  final bool ready;
  final Widget child;
  const Splash({super.key, required this.ready, required this.child});

  static const colour = Color(0xFF0F766E); // teal 700: the native splash's background

  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> with TickerProviderStateMixin {
  late final _draw = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..forward();
  late final _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _draw.addStatusListener((_) => _maybeLeave());
    _fade.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => _gone = true);
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
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return widget.child;
    return Stack(children: [
      if (widget.ready) Positioned.fill(child: widget.child),
      Positioned.fill(
        child: FadeTransition(
          opacity: ReverseAnimation(_fade),
          child: Material(
            color: Splash.colour,
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                AnimatedBuilder(
                  animation: _draw,
                  builder: (context, _) => CustomPaint(
                    size: const Size.square(132),
                    painter: MeshLogoPainter(Colors.white, progress: Curves.easeInOut.transform(_draw.value)),
                  ),
                ),
                const SizedBox(height: 20),
                FadeTransition(
                  opacity: CurvedAnimation(parent: _draw, curve: const Interval(0.5, 1, curve: Curves.easeOut)),
                  child: const Column(children: [
                    Text('MeshCore',
                        style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                    SizedBox(height: 4),
                    Text('MOBILE', style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 13, letterSpacing: 4)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}
