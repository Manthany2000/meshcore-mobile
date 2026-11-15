// The node's own settings, and the setup wizard for a node that's just been
// flashed. Both fill one NodeForm and send only what differs from the node.
// Ported from MeshCore Desktop's setup_ui.py and node_settings.py.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../../main.dart';
import '../model.dart';
import '../protocol.dart' as p;
import '../session.dart';
import '../setup.dart';
import 'common.dart';

const custom = 'Custom';

String _g(double x) => x == x.roundToDouble() ? '${x.toInt()}' : '$x';

/// The node's settings as form values, and the Plan of what differs from the node.
class NodeForm extends ChangeNotifier {
  final AppState app;
  final bool fresh; // the setup wizard on a just-flashed node
  final bool wizard;
  late SelfInfo si;
  int curHash = 1, curPin = 0;

  final name = TextEditingController();
  final pos = TextEditingController();
  final freq = TextEditingController();
  final pin = TextEditingController();
  final scope = TextEditingController();
  final tags = TextEditingController(); // the wizard's hashtag channels
  String preset = custom;
  double bw = 62.5;
  int sf = 7, cr = 5, hash = 1, tx = 22;
  bool share = false, autoAdd = true, multiAcks = false, pinFixed = false;
  Map<String, int> telem = {};
  bool advert = false, advertTouched = false, shareTouched = false;
  bool reboot = false, rebootTouched = false;
  String? nameErr, posErr, pinErr, scopeErr, freqErr;
  bool running = false;

  NodeForm(this.app, {this.fresh = false, this.wizard = false}) {
    baseline();
    load();
    for (final c in [name, pos, freq, pin, scope, tags]) {
      c.addListener(edited);
    }
  }

  Session? get session => app.session;
  Model get model => app.model;
  bool get ready => session?.state == LinkState.ready;
  bool get scopeShown => (session?.scopes ?? false) && model.defaultScope != null;

  /// What the node has now, to compare the fields with.
  void baseline() {
    si = model.selfInfo!;
    final di = model.deviceInfo;
    curHash = di != null && (di['protocol'] ?? 0) >= 10 ? (di['path_hash_mode'] ?? 0) + 1 : 1;
    curPin = di?['ble_pin'] ?? 0;
  }

  /// Fills the fields from what the node has now.
  void load() {
    name.text = fresh ? '' : si.name;
    _setRadio(si.freq, si.bw, si.sf, si.cr, curHash);
    preset = findPreset(si.freq, si.bw, si.sf, si.cr, curHash)?.title ?? custom;
    tx = si.txPower;
    pos.text = si.lat != 0 || si.lon != 0 ? '${si.lat.toStringAsFixed(6)}, ${si.lon.toStringAsFixed(6)}' : '';
    share = si.locPolicy != 0;
    autoAdd = si.manualAdd & 1 == 0;
    telem = telemetryModesOf(si.telemetry);
    multiAcks = si.multiAcks != 0;
    scope.text = model.defaultScope ?? '';
    pinFixed = curPin != 0;
    pin.text = curPin != 0 ? curPin.toString().padLeft(6, '0') : '';
    nameErr = posErr = pinErr = scopeErr = freqErr = null;
    advertTouched = shareTouched = rebootTouched = false;
    edited();
  }

  void _setRadio(double f, double b, int s, int c, int h) {
    freq.text = f.toStringAsFixed(3);
    bw = bandwidths.reduce((a, x) => (x - b).abs() < (a - b).abs() ? x : a);
    sf = s.clamp(5, 12);
    cr = c.clamp(5, 8);
    hash = h.clamp(1, 3);
  }

  void pickPreset(String title) {
    preset = title;
    final x = presets.where((e) => e.title == title).firstOrNull;
    if (x != null) _setRadio(x.freq, x.bw, x.sf, x.cr, x.hashSize);
    edited();
  }

  /// A radio value changed by hand: still the picked preset, another one, or Custom.
  void radioEdited() {
    final r = radio;
    final cur = presets.where((e) => e.title == preset).firstOrNull;
    if (r == null) {
      preset = custom;
    } else if (!(cur != null && cur.matches(r.$1, r.$2, r.$3, r.$4) && cur.hashSize == hash)) {
      final m = findPreset(r.$1, r.$2, r.$3, r.$4, hash);
      preset = m != null && m.hashSize == hash ? m.title : custom;
    }
    edited();
  }

  (double, double, int, int)? get radio {
    final f = double.tryParse(freq.text.trim());
    if (f == null || f < 150 || f > 2500) return null;
    return ((f * 1000).round() / 1000, bw, sf, cr);
  }

  void edited() {
    if (!advertTouched) {
      // A new name or position only reaches others in an advert.
      final pl = _diff();
      advert = wizard || pl.name != null || pl.location != null || pl.shareLocation != null;
    }
    if (!rebootTouched) reboot = _diff().pin != null;
    notifyListeners();
  }

  // --- checks ---------------------------------------------------------------------

  bool checkName() {
    final n = name.text.trim();
    String? bad;
    if (n.isEmpty) {
      bad = fresh ? 'Give it a name.' : null; // blank on a set-up node: keep its name
    } else if (utf8.encode(n).length > p.nameMax) {
      bad = "That's ${utf8.encode(n).length} bytes; the node keeps ${p.nameMax}.";
    } else if (n.toUpperCase() == p.hex(si.key.sublist(0, 4)).toUpperCase() && fresh) {
      bad = "That's the default name; pick your own.";
    }
    nameErr = bad;
    notifyListeners();
    return bad == null;
  }

  (bool, (double, double)?) checkPos() {
    try {
      final v = parseLatLon(pos.text);
      posErr = null;
      return (true, v);
    } on FormatException catch (e) {
      posErr = e.message;
      return (false, null);
    } finally {
      notifyListeners();
    }
  }

  (bool, int?) checkPin() {
    if (!pinFixed) {
      pinErr = null;
      return (true, 0);
    }
    final t = pin.text.trim();
    final v = int.tryParse(t);
    if (t.length == 6 && v != null && v >= 100000) {
      pinErr = null;
      return (true, v);
    }
    pinErr = 'The PIN needs six digits, not starting with 0.';
    notifyListeners();
    return (false, null);
  }

  bool checkScope() {
    scopeErr = scopeShown && scope.text.trim().isNotEmpty ? p.regionProblem(scope.text) : null;
    notifyListeners();
    return scopeErr == null;
  }

  bool checkRadio() {
    freqErr = radio == null ? 'Frequency must be from 150 to 2500 MHz.' : null;
    notifyListeners();
    return freqErr == null;
  }

  // --- the plan -------------------------------------------------------------------

  /// What differs from the node, without touching the error messages.
  Plan _diff() {
    final pl = Plan()..advert = false;
    final n = name.text.trim();
    if (n.isNotEmpty && n != si.name && utf8.encode(n).length <= p.nameMax) pl.name = n;
    final r = radio;
    if (r != null) {
      if (!((r.$1 - si.freq).abs() < 0.0005 && (r.$2 - si.bw).abs() < 0.05 && r.$3 == si.sf && r.$4 == si.cr)) pl.radio = r;
    }
    if (hash != curHash) pl.hashSize = hash;
    if (tx != si.txPower) pl.txPower = tx;
    (double, double)? where;
    var posOk = true;
    try {
      where = parseLatLon(pos.text);
    } on FormatException {
      posOk = false;
    }
    if (where != null && ((where.$1 - si.lat).abs() > 1e-6 || (where.$2 - si.lon).abs() > 1e-6)) {
      pl.location = where;
    } else if (posOk && where == null && (si.lat != 0 || si.lon != 0)) {
      pl.location = (0.0, 0.0); // cleared
    }
    if (share != (si.locPolicy != 0)) pl.shareLocation = share;
    if (autoAdd != (si.manualAdd & 1 == 0)) pl.autoAdd = autoAdd;
    final t = telemetryByte(telem, si.telemetry);
    if (t != si.telemetry) pl.telemetry = t;
    if (multiAcks != (si.multiAcks != 0)) pl.multiAcks = multiAcks;
    if (scopeShown) {
      final cur = model.defaultScope;
      final next = p.regionName(scope.text);
      if (cur != null && next != cur && p.regionProblem(next.isEmpty ? 'x' : next) == null) pl.defaultScope = next;
    }
    if (!pinFixed) {
      if (curPin != 0) pl.pin = 0;
    } else {
      final v = int.tryParse(pin.text.trim());
      if (pin.text.trim().length == 6 && v != null && v >= 100000 && v != curPin) pl.pin = v;
    }
    final have = {for (final c in model.channels.values) c.name.toLowerCase()};
    pl.channels = [
      for (final tag in parseHashtags(tags.text))
        if (!have.contains(tag)) (tag, hashtagSecret(tag))
    ];
    return pl;
  }

  Plan plan() => _diff()
    ..advert = advert
    ..reboot = reboot;

  /// The changes, without the advert and restart.
  List<String> changes() => (_diff()..advert = false).steps();

  @override
  void dispose() {
    for (final c in [name, pos, freq, pin, scope, tags]) {
      c.dispose();
    }
    super.dispose();
  }
}

// --- sections -------------------------------------------------------------------------

Widget _note(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );

InputDecoration _dec(String label, {String? hint, String? error, String? helper, Widget? suffix}) => InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: error,
      helperText: helper,
      helperMaxLines: 3,
      errorMaxLines: 3,
      border: const OutlineInputBorder(),
      isDense: true,
      suffixIcon: suffix,
    );

const _gap = SizedBox(height: 14);

class NameSection extends StatelessWidget {
  final NodeForm f;
  const NameSection(this.f, {super.key});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: f.name,
          enabled: !f.running,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          inputFormatters: [_ByteLimit(p.nameMax)],
          decoration: _dec('Node name',
              hint: 'What others see, like ‘kestrel-mobile’',
              error: f.nameErr,
              helper: 'Shown in adverts, contact lists and channel messages. Up to ${p.nameMax} bytes.'),
          onChanged: (_) => f.checkName(),
        ),
        if (f.fresh) _note(context, 'Now: ${f.si.name} (the first bytes of its key).'),
      ]);
}

class RadioSection extends StatelessWidget {
  final NodeForm f;
  const RadioSection(this.f, {super.key});

  @override
  Widget build(BuildContext context) {
    final on = !f.running;
    final maxTx = f.si.maxTx < 1 ? 1 : f.si.maxTx;
    DropdownButtonFormField<T> dd<T>(String label, T value, List<(T, String)> items, void Function(T) set) =>
        DropdownButtonFormField<T>(
          initialValue: value,
          key: ValueKey('$label-$value'),
          isExpanded: true,
          decoration: _dec(label),
          items: [for (final (v, t) in items) DropdownMenuItem(value: v, child: Text(t))],
          onChanged: on
              ? (v) {
                  if (v != null) set(v);
                }
              : null,
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      dd<String>('Region preset', f.preset, [for (final x in presets) (x.title, x.title), (custom, custom)], f.pickPreset),
      _gap,
      TextField(
        controller: f.freq,
        enabled: on,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: _dec('Frequency', error: f.freqErr, suffix: const Padding(padding: EdgeInsets.all(12), child: Text('MHz'))),
        onChanged: (_) {
          f.checkRadio();
          f.radioEdited();
        },
      ),
      _gap,
      Row(children: [
        Expanded(child: dd<double>('Bandwidth', f.bw, [for (final b in bandwidths) (b, '${_g(b)} kHz')], (v) {
          f.bw = v;
          f.radioEdited();
        })),
        const SizedBox(width: 10),
        Expanded(child: dd<int>('Spreading factor', f.sf, [for (var i = 5; i <= 12; i++) (i, 'SF$i')], (v) {
          f.sf = v;
          f.radioEdited();
        })),
      ]),
      _gap,
      Row(children: [
        Expanded(child: dd<int>('Coding rate', f.cr, [for (var i = 5; i <= 8; i++) (i, '4/$i')], (v) {
          f.cr = v;
          f.radioEdited();
        })),
        const SizedBox(width: 10),
        Expanded(child: dd<int>('Hop hash size', f.hash, [for (var i = 1; i <= 3; i++) (i, '$i byte${i > 1 ? 's' : ''}')], (v) {
          f.hash = v;
          f.radioEdited();
        })),
      ]),
      _note(context, 'Hop hash size: how many bytes of each repeater\'s key a flood carries. Bigger meshes use 2 or 3 '
          'so repeaters don\'t get mixed up.'),
      dd<int>('Transmit power', f.tx.clamp(-9, maxTx), [for (var i = maxTx; i >= -9; i--) (i, '$i dBm')], (v) {
        f.tx = v;
        f.edited();
      }),
      _note(context, 'Stay within your country\'s limits. This radio goes up to ${f.si.maxTx} dBm, and some boards have '
          'an amplifier after the radio.'),
    ]);
  }
}

class PositionSection extends StatelessWidget {
  final NodeForm f;
  const PositionSection(this.f, {super.key});

  @override
  Widget build(BuildContext context) {
    final on = !f.running;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: f.pos,
        enabled: on,
        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
        decoration: _dec('Position',
            hint: 'lat, lon  (like 42.3601, -71.0589)',
            error: f.posErr,
            helper: 'Blank: the node isn\'t put on maps.',
            suffix: f.pos.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.clear),
                    onPressed: on ? () => f.pos.clear() : null,
                  )),
        onChanged: (_) => f.checkPos(),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          onPressed: on ? () => _pick(context) : null,
          icon: const Icon(Icons.place_outlined),
          label: const Text('Pick on the map'),
        ),
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Share the position in adverts'),
        subtitle: const Text('Off keeps it on the node only'),
        value: f.share,
        onChanged: on
            ? (v) {
                f.share = v;
                f.shareTouched = true;
                f.edited();
              }
            : null,
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Add contacts automatically'),
        subtitle: const Text('When their adverts are heard. Off: only nodes you add yourself. On is easiest on a new node.'),
        value: f.autoAdd,
        onChanged: on
            ? (v) {
                f.autoAdd = v;
                f.edited();
              }
            : null,
      ),
    ]);
  }

  Future<void> _pick(BuildContext context) async {
    final (ok, cur) = f.checkPos();
    final others = [
      for (final c in f.model.contacts.values)
        if (c.lat != 0 || c.lon != 0) LatLng(c.lat, c.lon)
    ];
    final got = await Navigator.of(context).push<LatLng>(MaterialPageRoute(
      builder: (_) => PositionPicker(start: ok && cur != null ? LatLng(cur.$1, cur.$2) : null, others: others),
    ));
    if (got == null) return;
    f.pos.text = '${got.latitude.toStringAsFixed(6)}, ${got.longitude.toStringAsFixed(6)}';
    f.checkPos();
    if (f.fresh && !f.shareTouched) f.share = true; // picking a spot on a new node means wanting to be on the map
    f.edited();
  }
}

class PrivacySection extends StatelessWidget {
  final NodeForm f;
  const PrivacySection(this.f, {super.key});

  @override
  Widget build(BuildContext context) {
    final on = !f.running;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _note(context, 'Who the node answers when someone asks it for readings.'),
      for (final k in telemetryKinds) ...[
        DropdownButtonFormField<int>(
          initialValue: f.telem[k] ?? 0,
          key: ValueKey('telem-$k-${f.telem[k]}'),
          isExpanded: true,
          decoration: _dec(telemetryKindNames[k]!),
          items: [
            for (final e in telemetryModes.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
            if (!telemetryModes.containsKey(f.telem[k])) DropdownMenuItem(value: f.telem[k], child: Text('Mode ${f.telem[k]}')),
          ],
          onChanged: on
              ? (v) {
                  f.telem = {...f.telem, k: v ?? 0};
                  f.edited();
                }
              : null,
        ),
        _gap,
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Extra acks'),
        subtitle: const Text('Send a second ack for each direct message, for lossy links'),
        value: f.multiAcks,
        onChanged: on
            ? (v) {
                f.multiAcks = v;
                f.edited();
              }
            : null,
      ),
    ]);
  }
}

class ScopeSection extends StatelessWidget {
  final NodeForm f;
  const ScopeSection(this.f, {super.key});

  @override
  Widget build(BuildContext context) {
    if (!f.scopeShown) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: f.scope,
        enabled: !f.running,
        autocorrect: false,
        maxLength: p.scopeNameMax - 1,
        decoration: _dec('Flood scope (region)', hint: 'none: floods go everywhere', error: f.scopeErr).copyWith(counterText: ''),
        onChanged: (_) => f.checkScope(),
      ),
      _note(context, 'Repeaters set up with regions only relay floods for regions they allow, so a scope keeps your '
          'messages local. Ask your mesh which names it uses, like ‘usa’ or ‘boston’. Channels can have their own: '
          'long-press one in Chats.'),
    ]);
  }
}

class PinSection extends StatelessWidget {
  final NodeForm f;
  const PinSection(this.f, {super.key});

  @override
  Widget build(BuildContext context) {
    final on = !f.running;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RadioGroup<bool>(
        groupValue: f.pinFixed,
        onChanged: (v) {
          if (!on || v == null) return;
          f.pinFixed = v;
          f.checkPin();
          f.edited();
        },
        child: const Column(children: [
          RadioListTile(
            contentPadding: EdgeInsets.zero,
            value: false,
            title: Text('Firmware default'),
            subtitle: Text('A new random PIN on the node\'s screen, or 123456 without one'),
          ),
          RadioListTile(contentPadding: EdgeInsets.zero, value: true, title: Text('Always this PIN')),
        ]),
      ),
      if (f.pinFixed)
        TextField(
          controller: f.pin,
          enabled: on,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: _dec('Bluetooth PIN', hint: '6 digits', error: f.pinErr).copyWith(counterText: ''),
          onChanged: (_) => f.checkPin(),
        ),
      _note(context, 'The node uses a new PIN once it restarts. Your phone may need to forget the node and pair again.'),
    ]);
  }
}

/// Caps a text field at a number of UTF-8 bytes, like the firmware does.
class _ByteLimit extends TextInputFormatter {
  final int max;
  _ByteLimit(this.max);

  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue v) =>
      utf8.encode(v.text).length <= max ? v : old;
}

// --- position picker -----------------------------------------------------------------

class PositionPicker extends StatefulWidget {
  final LatLng? start;
  final List<LatLng> others;
  const PositionPicker({super.key, this.start, this.others = const []});

  @override
  State<PositionPicker> createState() => _PositionPickerState();
}

class _PositionPickerState extends State<PositionPicker> {
  LatLng? at;

  @override
  void initState() {
    super.initState();
    at = widget.start;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final o = widget.others;
    final centre = at ??
        (o.isNotEmpty
            ? LatLng(o.map((e) => e.latitude).reduce((a, b) => a + b) / o.length,
                o.map((e) => e.longitude).reduce((a, b) => a + b) / o.length)
            : const LatLng(20, 0));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Node position'),
        actions: [
          TextButton(onPressed: at == null ? null : () => Navigator.pop(context, at), child: const Text('Use this')),
        ],
      ),
      body: Stack(children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: centre,
            initialZoom: at != null ? 13 : (o.isNotEmpty ? 10 : 2),
            onTap: (_, ll) => setState(() => at = ll),
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'io.github.manthany2000.meshcore_mobile',
              maxZoom: 19,
              tileBuilder: dark ? darkModeTileBuilder : null,
            ),
            MarkerLayer(markers: [
              for (final x in o)
                Marker(
                  point: x,
                  width: 10,
                  height: 10,
                  child: Container(decoration: BoxDecoration(color: cs.outline, shape: BoxShape.circle)),
                ),
              if (at != null)
                Marker(
                  point: at!,
                  width: 40,
                  height: 40,
                  alignment: Alignment.topCenter,
                  child: Icon(Icons.location_on, size: 40, color: cs.error),
                ),
            ]),
            const RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              attributions: [TextSourceAttribution('OpenStreetMap contributors')],
            ),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(at == null
                  ? 'Tap where the node is. It puts you on other people\'s maps, so a rough spot is fine.'
                  : '${at!.latitude.toStringAsFixed(5)}, ${at!.longitude.toStringAsFixed(5)} · tap again to move it'),
            ),
          ),
        ),
      ]),
    );
  }
}

// --- sending ----------------------------------------------------------------------------

class LogLine {
  final String text;
  bool? ok;
  String why;
  LogLine(this.text, [this.ok, this.why = '']);
}

class ApplyLog extends StatelessWidget {
  final List<LogLine> lines;
  const ApplyLog(this.lines, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final l in lines)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: l.ok == null
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(l.ok! ? Icons.check_circle : Icons.error, color: l.ok! ? cs.primary : cs.error),
          title: Text(l.text),
          subtitle: l.why.isEmpty ? null : Text(l.why, style: TextStyle(color: cs.error)),
        ),
    ]);
  }
}

Future<bool> _ask(BuildContext context, String title, String text, String yes, [String no = 'Cancel']) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(no)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
        ],
      ),
    ) ==
    true;

/// Runs the plan, adding to [log] as it goes. Remembers nothing on failure.
Future<bool> sendPlan(NodeForm f, Plan plan, List<LogLine> log, VoidCallback changed) async {
  final s = f.session;
  if (s == null) return false;
  f.running = true;
  f.edited();
  bool ok;
  try {
    ok = await applyPlan(s, plan, (text, good, why) {
      final last = log.lastOrNull;
      if (good != null && last != null && last.text == text && last.ok == null) {
        last
          ..ok = good
          ..why = why;
      } else {
        log.add(LogLine(text, good, why));
      }
      changed();
    });
  } catch (e) {
    log.add(LogLine('Stopped: $e', false));
    ok = false;
  }
  f.running = false;
  if (!plan.reboot && f.model.selfInfo != null) {
    // The node's new settings, read back, are the new starting point.
    f.baseline();
    f.load();
  }
  changed();
  return ok;
}

// --- Node settings -------------------------------------------------------------------------

class NodeSettingsScreen extends StatefulWidget {
  final AppState app;
  const NodeSettingsScreen({super.key, required this.app});

  @override
  State<NodeSettingsScreen> createState() => _NodeSettingsScreenState();
}

class _NodeSettingsScreenState extends State<NodeSettingsScreen> {
  late final f = NodeForm(widget.app);
  final log = <LogLine>[];

  @override
  void dispose() {
    f.dispose();
    super.dispose();
  }

  bool _check(TabController tabs) {
    if (!f.checkName()) return _go(tabs, 0);
    if (!f.checkPos().$1) return _go(tabs, 0);
    if (!f.checkRadio()) return _go(tabs, 1);
    if (!f.checkPin().$1 || !f.checkScope()) return _go(tabs, 3);
    return true;
  }

  bool _go(TabController tabs, int i) {
    tabs.animateTo(i);
    return false;
  }

  Future<void> _apply(TabController tabs) async {
    if (f.running || !f.ready || !_check(tabs)) return;
    final plan = f.plan();
    if (plan.radio != null || plan.hashSize != null) {
      if (!await _ask(context, 'Change the radio?',
          'Nodes still on the old settings won\'t hear this one any more, and it won\'t hear them.\n\n'
              'Only do this if your local mesh uses the new settings.',
          'Change radio')) {
        return;
      }
    }
    if (plan.pin != null && mounted) {
      plan.reboot = await _ask(context, 'New Bluetooth PIN',
          'The node only starts using the new PIN after a restart. Restart it once the settings are sent?\n\n'
              'Your phone may ask for the new PIN when it reconnects.',
          'Restart afterwards',
          'Not now');
    }
    log.clear();
    if (!mounted) return;
    final sheet = showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        _sheetSet = set;
        return SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            Text('Sending to the node', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            ApplyLog(log),
            if (!f.running) ...[
              const SizedBox(height: 8),
              if (plan.reboot) const Text('The node is restarting; the app reconnects by itself.'),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
              ),
            ],
          ]),
        );
      }),
    );
    final ok = await sendPlan(f, plan, log, () => _sheetSet?.call(() {}));
    _sheetSet?.call(() {});
    if (mounted) toast(context, ok ? 'Node settings saved' : 'Node settings: some steps failed');
    await sheet;
    _sheetSet = null;
  }

  StateSetter? _sheetSet;

  Future<void> _restart() async {
    if (!f.ready) return;
    if (await _ask(context, 'Restart node?', 'The link drops while it restarts, and the app reconnects by itself.', 'Restart')) {
      await widget.app.session?.reboot();
      if (mounted) toast(context, 'Node restarting');
    }
  }

  Future<bool> _leave() async {
    if (f.running) return false;
    if (f.changes().isEmpty) return true;
    return _ask(context, 'Unsent changes', 'Close without sending your changes to the node?', 'Discard changes', 'Keep editing');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([f, widget.app, widget.app.model]),
      builder: (context, _) {
        final changes = f.changes();
        final pl = f.plan();
        return DefaultTabController(
          length: 5,
          child: Builder(builder: (context) {
            final tabs = DefaultTabController.of(context);
            return PopScope(
              canPop: changes.isEmpty && !f.running,
              onPopInvokedWithResult: (did, _) async {
                if (did) return;
                if (await _leave() && context.mounted) Navigator.of(context).pop();
              },
              child: Scaffold(
                appBar: AppBar(
                  title: const Text('Node settings'),
                  bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
                    Tab(text: 'General'),
                    Tab(text: 'Radio'),
                    Tab(text: 'Privacy'),
                    Tab(text: 'Bluetooth and scope'),
                    Tab(text: 'About'),
                  ]),
                ),
                body: TabBarView(children: [
                  _page([NameSection(f), _gap, PositionSection(f)]),
                  _page([
                    if (pl.radio != null || pl.hashSize != null)
                      Card(
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Nodes on the old settings won\'t hear this one any more.'),
                        ),
                      ),
                    RadioSection(f),
                  ]),
                  _page([PrivacySection(f)]),
                  _page([ScopeSection(f), PinSection(f)]),
                  _about(context),
                ]),
                bottomNavigationBar: SafeArea(
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    shape: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          horizontalTitleGap: 4,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('Send a flood advert afterwards'),
                          value: f.advert,
                          onChanged: f.running
                              ? null
                              : (v) {
                                  f.advert = v ?? false;
                                  f.advertTouched = true;
                                  f.edited();
                                },
                        ),
                        Row(children: [
                          Expanded(
                            child: Tooltip(
                              message: changes.join('\n'),
                              child: Text(
                                (changes.isEmpty ? 'No changes' : '${changes.length} change${changes.length > 1 ? 's' : ''} to send') +
                                    (f.ready ? '' : ' · not connected'),
                              ),
                            ),
                          ),
                          TextButton(onPressed: changes.isEmpty || f.running ? null : f.load, child: const Text('Revert')),
                          const SizedBox(width: 4),
                          FilledButton(
                            onPressed: changes.isEmpty || f.running || !f.ready ? null : () => _apply(tabs),
                            child: const Text('Apply'),
                          ),
                        ]),
                      ]),
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _page(List<Widget> children) => ListView(padding: const EdgeInsets.all(16), children: children);

  Widget _about(BuildContext context) {
    final m = widget.app.model;
    final si = m.selfInfo!;
    final di = m.deviceInfo;
    final s = widget.app.session;
    final rows = [
      ('Model', di?['model'] ?? ''),
      ('Firmware', [di?['fw'] ?? '', di?['build'] ?? ''].where((x) => (x as String).isNotEmpty).join(' · ')),
      ('Protocol', di != null ? 'v${di['protocol']}' : ''),
      ('Public key', p.hex(si.key)),
      ('Contacts', di != null && (di['max_contacts'] ?? 0) > 0 ? '${m.contacts.length} of ${di['max_contacts']}' : '${m.contacts.length}'),
      ('Channel slots', '${m.channels.length} of ${s?.maxChannels ?? 8}'),
      ('Flood scopes', (s?.scopes ?? false) ? ((s?.unscoped ?? false) ? 'yes, and unscoped sends' : 'yes') : 'not on this firmware'),
      if (m.batteryMv > 0) ('Battery', '${(m.batteryMv / 1000).toStringAsFixed(2)} V (${p.battPercent(m.batteryMv)}%)'),
    ];
    return ListView(padding: const EdgeInsets.all(16), children: [
      for (final (k, v) in rows)
        if (v.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 120, child: Text(k, style: Theme.of(context).textTheme.labelLarge)),
              Expanded(child: SelectableText(v)),
            ]),
          ),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: f.ready ? _restart : null,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Restart node'),
        ),
      ),
    ]);
  }
}

// --- Setup wizard -----------------------------------------------------------------------------

class SetupWizard extends StatefulWidget {
  final AppState app;
  const SetupWizard({super.key, required this.app});

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  late final f = NodeForm(widget.app, fresh: isFresh(widget.app.model.selfInfo), wizard: true);
  final log = <LogLine>[];
  Plan? sent;
  int page = 0;
  bool done = false, allOk = false;
  static const titles = ['Name', 'Radio', 'Position and contacts', 'Channels and Bluetooth', 'Review'];

  @override
  void dispose() {
    f.dispose();
    super.dispose();
  }

  void _next() {
    if (page == 0 && !f.checkName()) return;
    if (page == 0 && f.fresh && f.name.text.trim().isEmpty) return;
    if (page == 1 && !f.checkRadio()) return;
    if (page == 2 && !f.checkPos().$1) return;
    if (page == 3 && (!f.checkPin().$1 || !f.checkScope())) return;
    if (page == 4) {
      _apply();
      return;
    }
    setState(() => page++);
  }

  Future<void> _apply() async {
    final plan = sent = f.plan();
    setState(() => page = 5);
    final ok = await sendPlan(f, plan, log, () {
      if (mounted) setState(() {});
    });
    if (!mounted) return;
    setState(() {
      done = true;
      allOk = ok;
    });
    toast(context, ok ? 'Node set up' : 'Node setup: some steps failed');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([f, widget.app]),
      builder: (context, _) {
        final applying = page == 5;
        return PopScope(
          canPop: !f.running,
          child: Scaffold(
            appBar: AppBar(
              title: Text(applying ? 'Setting up' : titles[page]),
              automaticallyImplyLeading: !f.running,
            ),
            body: ListView(padding: const EdgeInsets.all(16), children: [
              if (!applying) ...[
                LinearProgressIndicator(value: (page + 1) / 5, borderRadius: BorderRadius.circular(4)),
                const SizedBox(height: 4),
                Text('Step ${page + 1} of 5', style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 12),
              ],
              ..._body(context, cs),
            ]),
            bottomNavigationBar: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(children: [
                  if (page > 0 && !applying) TextButton(onPressed: () => setState(() => page--), child: const Text('Back')),
                  const Spacer(),
                  if (applying)
                    FilledButton(onPressed: done ? () => Navigator.pop(context) : null, child: const Text('Close'))
                  else
                    FilledButton(
                      onPressed: f.ready && (page < 4 || _anything) ? _next : null,
                      child: Text(page == 4 ? 'Apply' : 'Next'),
                    ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  bool get _anything {
    final pl = f.plan();
    return f.changes().isNotEmpty || pl.advert || pl.reboot;
  }

  List<Widget> _body(BuildContext context, ColorScheme cs) {
    switch (page) {
      case 0:
        return [
          _note(context, f.fresh
              ? 'This node still has the name it got when it was flashed, so it looks new. A few questions and it\'s '
                  'ready for the mesh. Everything here can be changed again later in Node settings.'
              : 'Go through the node\'s settings. Anything you leave alone stays as it is.'),
          NameSection(f),
        ];
      case 1:
        return [
          _note(context, 'Every node in a mesh has to use the same settings, or they can\'t hear each other. Pick your '
              'region\'s preset, or ask your local mesh what they use.'),
          RadioSection(f),
        ];
      case 2:
        return [
          _note(context, 'Where the node is. It puts you on other people\'s maps, so a rough spot is fine.'),
          PositionSection(f),
        ];
      case 3:
        final have = [for (final c in (f.model.channels.values.toList()..sort((a, b) => a.idx.compareTo(b.idx)))) c.name];
        return [
          _note(context, 'On the node now: ${have.isEmpty ? 'none' : have.join(', ')}'),
          TextField(
            controller: f.tags,
            autocorrect: false,
            enabled: !f.running,
            decoration: _dec('Join hashtag channels', hint: '#local, #emergency'),
          ),
          _note(context, 'A #channel\'s key comes from its name, so everyone who joins the same name talks together. '
              'Private channels: + in Chats once you\'re set up.'),
          _gap,
          ScopeSection(f),
          PinSection(f),
        ];
      case 4:
        final pl = f.plan();
        final steps = pl.steps();
        if (f.changes().isEmpty) steps.insert(0, 'Nothing to change on the node');
        return [
          _note(context, 'These are sent to the node when you press Apply.'),
          for (final s in steps)
            ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.arrow_right), title: Text(s)),
          const Divider(),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Send a flood advert when done, so the mesh hears about the node'),
            value: f.advert,
            onChanged: (v) {
              f.advert = v ?? false;
              f.advertTouched = true;
              f.edited();
            },
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Restart the node afterwards (needed for a new Bluetooth PIN)'),
            value: f.reboot,
            onChanged: (v) {
              f.reboot = v ?? false;
              f.rebootTouched = true;
              f.edited();
            },
          ),
          if (pl.radio != null && !f.fresh)
            Card(
              color: cs.tertiaryContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('The radio settings change. Nodes on the old settings won\'t hear this one any more.'),
              ),
            ),
        ];
      default:
        return [
          ApplyLog(log),
          if (done) ...[
            const SizedBox(height: 12),
            Text(allOk
                ? 'Done. ${sent?.reboot ?? false ? 'The node is restarting; the app reconnects by itself.' : 'The node is ready.'}'
                : 'Some steps didn\'t work; the rest were sent. Open Node settings to try again.'),
          ],
        ];
    }
  }
}
