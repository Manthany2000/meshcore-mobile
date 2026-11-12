// An SDR-style waterfall of the packets the node hears. Across is SNR (weak on
// the left, strong on the right); down is time, newest at the top. Each packet
// leaves a hot spot that cools and scrolls away. Ported from MeshCore
// Desktop's waterfall.py.
import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../model.dart';
import '../protocol.dart' as p;
import 'common.dart';
import 'dashboard.dart' show packetName;

const snrLo = -20.0, snrHi = 15.0;
const _decay = 0.72; // a packet cools over a few rows: a short streak, like a real burst
const _streak = 12; // rows after which what's left of a packet is invisible

// Classic SDR heat ramp: deep blue, blue, cyan, yellow, red, white.
const _ramp = [
  (0.00, Color(0xFF060A20)),
  (0.18, Color(0xFF0C206E)),
  (0.40, Color(0xFF148CD2)),
  (0.62, Color(0xFFEBE13C)),
  (0.82, Color(0xFFEB461E)),
  (1.00, Color(0xFFFFF5EB)),
];

final List<Color> _lut = [
  for (var i = 0; i < 256; i++)
    () {
      final v = i / 255;
      for (var k = 0; k + 1 < _ramp.length; k++) {
        final (a, ca) = _ramp[k];
        final (b, cb) = _ramp[k + 1];
        if (v <= b) return Color.lerp(ca, cb, (v - a) / (b - a))!;
      }
      return _ramp.last.$2;
    }(),
];

class WaterfallPainter extends CustomPainter {
  final List<(double, p.RawPacket)> packets;
  final double now;
  final double rowS; // seconds per row
  final int cols;
  final (double, p.RawPacket)? picked;
  WaterfallPainter(this.packets, this.now, {this.rowS = 0.5, this.cols = 70, this.picked});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _lut[0]);
    final rowH = 2.0;
    final rows = (size.height / rowH).ceil();
    final heat = List.generate(rows, (_) => List<double>.filled(cols, 0));
    final span = rows * rowS;
    for (final (at, pk) in packets.reversed) {
      final age = now - at;
      if (age > span + _streak * rowS) break;
      final x = ((pk.snr - snrLo) / (snrHi - snrLo)).clamp(0.0, 1.0) * (cols - 1);
      final r0 = (age / rowS).floor();
      for (var k = 0; k < _streak; k++) {
        final row = r0 - k; // the streak trails above, the older part further down
        if (row < 0 || row >= rows) continue;
        final v = math.pow(_decay, k).toDouble();
        for (var dx = -3; dx <= 3; dx++) {
          final c = x.round() + dx;
          if (c < 0 || c >= cols) continue;
          heat[row][c] += v * math.exp(-(dx * dx) / 2.2);
        }
      }
    }
    final cw = size.width / cols;
    final paint = Paint();
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final v = heat[r][c];
        if (v < 0.02) continue;
        paint.color = _lut[(math.min(1.0, v * 0.85) * 255).round()];
        canvas.drawRect(Rect.fromLTWH(c * cw, r * rowH, cw + 0.5, rowH + 0.5), paint);
      }
    }
    final pk = picked;
    if (pk != null) {
      final x = ((pk.$2.snr - snrLo) / (snrHi - snrLo)).clamp(0.0, 1.0) * size.width;
      final y = (now - pk.$1) / rowS * rowH;
      canvas.drawCircle(Offset(x, y), 9, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant WaterfallPainter old) => true;
}

/// The strip on the Dashboard. Tap for the big one.
class WaterfallStrip extends StatefulWidget {
  final Model model;
  final double height;
  const WaterfallStrip({super.key, required this.model, this.height = 90});

  @override
  State<WaterfallStrip> createState() => _WaterfallStripState();
}

class _WaterfallStripState extends State<WaterfallStrip> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 500), (_) {
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
    final now = nowS();
    final lastMin = widget.model.packets.where((e) => now - e.$1 < 60).toList();
    final snr = lastMin.isEmpty ? null : lastMin.map((e) => e.$2.snr).reduce((a, b) => a + b) / lastMin.length;
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => WaterfallScreen(model: widget.model))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CustomPaint(size: Size.fromHeight(widget.height), painter: WaterfallPainter(widget.model.packets, now, cols: 60)),
        ),
        const SizedBox(height: 4),
        Row(children: [
          Text('−20 dB', style: Theme.of(context).textTheme.labelSmall),
          const Spacer(),
          Text(
            '${lastMin.length} packets last minute${snr == null ? '' : ' · avg ${snr.toStringAsFixed(1)} dB'} · tap to expand',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const Spacer(),
          Text('+15 dB', style: Theme.of(context).textTheme.labelSmall),
        ]),
      ]),
    );
  }
}

/// The big waterfall: axes, minutes of history, and tap a spot for its packet.
class WaterfallScreen extends StatefulWidget {
  final Model model;
  const WaterfallScreen({super.key, required this.model});

  @override
  State<WaterfallScreen> createState() => _WaterfallScreenState();
}

class _WaterfallScreenState extends State<WaterfallScreen> {
  Timer? _t;
  (double, p.RawPacket)? picked;
  static const rowS = 0.5;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  void _pick(Offset at, Size size, double now) {
    (double, p.RawPacket)? best;
    var bestD = 30.0;
    for (final e in widget.model.packets) {
      final x = ((e.$2.snr - snrLo) / (snrHi - snrLo)).clamp(0.0, 1.0) * size.width;
      final y = (now - e.$1) / rowS * 2;
      final d = (Offset(x, y) - at).distance;
      if (d < bestD) {
        bestD = d;
        best = e;
      }
    }
    setState(() => picked = best);
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final now = nowS();
    final pk = picked;
    return Scaffold(
      appBar: AppBar(title: const Text('Packet waterfall')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
          child: Column(children: [
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // Time axis.
                SizedBox(
                  width: 40,
                  child: LayoutBuilder(builder: (context, box) {
                    final secs = box.maxHeight / 2 * rowS;
                    return Stack(children: [
                      for (var s = 0.0; s <= secs; s += 30)
                        Positioned(
                          top: s / rowS * 2 - 6,
                          right: 4,
                          child: Text(s == 0 ? 'now' : '-${s ~/ 60}:${(s % 60).toInt().toString().padLeft(2, '0')}', style: tt.labelSmall),
                        ),
                    ]);
                  }),
                ),
                Expanded(
                  child: LayoutBuilder(builder: (context, box) {
                    return GestureDetector(
                      onTapDown: (d) => _pick(d.localPosition, box.biggest, now),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CustomPaint(
                          size: box.biggest,
                          painter: WaterfallPainter(widget.model.packets, now, rowS: rowS, cols: 90, picked: pk),
                        ),
                      ),
                    );
                  }),
                ),
              ]),
            ),
            // SNR axis.
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 4),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                for (var s = snrLo; s <= snrHi; s += 5) Text('${s.toInt()}', style: tt.labelSmall),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Text('SNR (dB)', style: tt.labelSmall),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: pk == null
                      ? Text('${widget.model.packets.length} packets this session. Tap a spot for its packet.')
                      : Text(
                          '${shortTime(pk.$1, seconds: true)} · ${packetName(pk.$2.payloadType)} · '
                          '${pk.$2.snr.toStringAsFixed(1)} dB SNR · ${pk.$2.rssi} dBm RSSI · '
                          '${pk.$2.flood ? '${pk.$2.hops} hops' : 'direct'}'
                          '${pk.$2.path.data.isEmpty ? '' : '\nPath: ${pk.$2.path.hops().map((h) => widget.model.hopNames(p.hex(h)).firstOrNull ?? p.hex(h)).join(' → ')}'}',
                        ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
