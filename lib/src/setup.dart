// Setting up a node: spotting one that's just been flashed, the community's
// radio presets, and applying a chosen setup to the node one command at a
// time. Ported from MeshCore Desktop's setup.py.
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'model.dart';
import 'protocol.dart' as p;
import 'session.dart';

class Preset {
  final String title;
  final double freq; // MHz
  final double bw; // kHz
  final int sf, cr;
  final int hashSize; // bytes per hop in floods
  const Preset(this.title, this.freq, this.bw, this.sf, this.cr, [this.hashSize = 1]);

  bool matches(double f, double b, int s, int c) => (freq - f).abs() < 0.0005 && (bw - b).abs() < 0.05 && sf == s && cr == c;
}

// The suggested settings the MeshCore apps offer, from api.meshcore.nz/api/v1/config
// on 12 Nov 2026. The radio must match the local mesh, so these are a starting point.
const presets = [
  Preset('Australia', 915.800, 250, 10, 5, 2),
  Preset('Australia (Narrow)', 916.575, 62.5, 7, 7, 2),
  Preset('Australia (Mid)', 915.075, 125, 9, 5, 2),
  Preset('Australia: SA, WA', 923.125, 62.5, 8, 8, 2),
  Preset('Australia: QLD', 923.125, 62.5, 8, 5, 2),
  Preset('Brazil', 923.125, 62.5, 8, 8),
  Preset('Canada', 910.525, 62.5, 7, 5, 3),
  Preset('Costa Rica', 910.525, 125, 11, 5),
  Preset('EU/UK (Narrow)', 869.618, 62.5, 8, 8),
  Preset('EU/UK (Deprecated)', 869.525, 250, 11, 5),
  Preset('Czech Republic (Narrow)', 869.432, 62.5, 7, 5, 2),
  Preset('EU 433MHz (Long Range)', 433.650, 250, 11, 5),
  Preset('EU 433MHz (Narrow)', 433.650, 62.5, 8, 8),
  Preset('Hungary', 869.618, 62.5, 7, 5, 2),
  Preset('Netherlands', 869.618, 62.5, 7, 5),
  Preset('Netherlands (Limburg)', 869.618, 62.5, 8, 8, 2),
  Preset('New Zealand (Narrow)', 917.375, 62.5, 7, 5, 2),
  Preset('New Zealand (Gisborne)', 917.375, 250, 11, 5),
  Preset('Portugal 433', 433.375, 62.5, 9, 6),
  Preset('Portugal 868', 869.618, 62.5, 7, 6),
  Preset('Slovakia', 869.618, 62.5, 7, 5, 2),
  Preset('Switzerland', 869.618, 62.5, 8, 8),
  Preset('Thailand', 921.000, 62.5, 7, 5),
  Preset('USA', 910.525, 62.5, 7, 5),
  Preset('USA - Southern California', 927.875, 62.5, 7, 5, 3),
  Preset('Vietnam (Narrow)', 920.250, 62.5, 8, 5),
  Preset('Vietnam (Deprecated)', 920.250, 250, 11, 5),
];

const bandwidths = [7.8, 10.4, 15.6, 20.8, 31.25, 41.7, 62.5, 125.0, 250.0, 500.0]; // kHz, what SX126x radios do

/// The first preset with these settings; several regions share some.
Preset? findPreset(double freq, double bw, int sf, int cr, [int? hashSize]) {
  final hits = presets.where((x) => x.matches(freq, bw, sf, cr)).toList();
  final exact = hits.where((x) => hashSize == null || x.hashSize == hashSize).toList();
  return (exact.isNotEmpty ? exact : hits).firstOrNull;
}

// Who the node answers telemetry requests from, one setting per kind of reading,
// two bits each in the telemetry byte: base (battery) in bits 0-1, location in
// 2-3, environment sensors in 4-5. (TELEM_MODE_* in the companion firmware.)
const telemetryKinds = ['base', 'location', 'environment'];
const telemetryKindNames = {'base': 'Battery', 'location': 'Location', 'environment': 'Environment sensors'};
const telemetryModes = {0: 'Nobody', 1: 'Only contacts I allow', 2: 'Anyone'};

Map<String, int> telemetryModesOf(int byte) => {
      for (final (i, k) in telemetryKinds.indexed) k: (byte >> (2 * i)) & 3,
    };

/// Packs the modes back, keeping the old byte's bits for any kind not given.
int telemetryByte(Map<String, int> modes, [int old = 0]) {
  var out = old & ~0x3F;
  for (final (i, k) in telemetryKinds.indexed) {
    out |= ((modes[k] ?? (old >> (2 * i)) & 3) & 3) << (2 * i);
  }
  return out;
}

/// A node nobody has set up yet still has the name the firmware gave it on
/// first boot: the first four bytes of its key in hex.
bool isFresh(SelfInfo? si) {
  if (si == null) return false;
  final name = si.name.trim();
  return name.toUpperCase() == p.hex(si.key.sublist(0, 4)).toUpperCase() || name == 'NONAME';
}

/// A '#name' channel's key is derived from its name, so typing it joins it.
Uint8List hashtagSecret(String name) => SHA256Digest().process(Uint8List.fromList(utf8.encode(name))).sublist(0, 16);

/// '#local, #emergency foo' -> ['#local', '#emergency', '#foo']
List<String> parseHashtags(String text) {
  final out = <String>[];
  for (var w in text.trim().split(RegExp(r'[\s,;]+'))) {
    w = w.trim();
    if (w.isEmpty) continue;
    w = '#${w.replaceFirst(RegExp(r'^#+'), '').toLowerCase()}';
    if (w.length > 1 && !out.contains(w)) out.add(w.length > 31 ? w.substring(0, 31) : w);
  }
  return out;
}

/// '42.3601, -71.0589' (as copied from most maps). Throws FormatException if
/// it isn't a position; blank gives null.
(double, double)? parseLatLon(String text) {
  text = text.trim();
  if (text.isEmpty) return null;
  final parts = text.split(RegExp(r'[\s,;]+')).where((x) => x.isNotEmpty).toList();
  if (parts.length != 2) throw const FormatException('Enter latitude and longitude, like 42.3601, -71.0589');
  final lat = double.tryParse(parts[0]), lon = double.tryParse(parts[1]);
  if (lat == null || lon == null) throw const FormatException('Enter latitude and longitude, like 42.3601, -71.0589');
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
    throw const FormatException('Latitude must be within ±90 and longitude within ±180');
  }
  return (lat, lon);
}

String _g(double x) => x == x.roundToDouble() ? '${x.toInt()}' : '$x';

/// What the setup wizard or the settings screen collected. null means leave it as it is.
class Plan {
  String? name;
  (double, double, int, int)? radio; // freq MHz, bw kHz, sf, cr
  int? hashSize;
  int? txPower;
  (double, double)? location;
  bool? shareLocation;
  bool? autoAdd;
  int? telemetry; // the packed byte; see telemetryByte()
  bool? multiAcks;
  int? pin; // 0: the firmware's default
  List<(String, Uint8List)> channels = []; // to add
  String? defaultScope; // a region, or "" to clear it
  bool advert = true; // flood an advert when done, so the mesh learns the node
  bool reboot = false;

  bool get isEmpty =>
      name == null &&
      radio == null &&
      hashSize == null &&
      txPower == null &&
      location == null &&
      shareLocation == null &&
      autoAdd == null &&
      telemetry == null &&
      multiAcks == null &&
      pin == null &&
      channels.isEmpty &&
      defaultScope == null;

  /// What will be done, in order, for the review page.
  List<String> steps() {
    final out = <String>[];
    if (name != null) out.add('Name the node “$name”');
    if (location != null) out.add('Set its position to ${location!.$1.toStringAsFixed(5)}, ${location!.$2.toStringAsFixed(5)}');
    if (shareLocation != null || autoAdd != null) {
      final bits = [
        if (shareLocation != null) shareLocation! ? 'share its position in adverts' : 'keep its position out of adverts',
        if (autoAdd != null) autoAdd! ? "add contacts as they're heard" : 'add contacts only by hand',
      ];
      final t = bits.join('; ');
      out.add(t[0].toUpperCase() + t.substring(1));
    }
    if (telemetry != null) {
      final m = telemetryModesOf(telemetry!);
      out.add('Answer requests for readings — ${[
        for (final k in telemetryKinds) '$k: ${(telemetryModes[m[k]] ?? 'mode ${m[k]}').toLowerCase()}'
      ].join(', ')}');
    }
    if (multiAcks != null) out.add(multiAcks! ? 'Send an extra ack for each direct message' : 'Send one ack per direct message');
    for (final (n, _) in channels) {
      out.add('Join channel $n');
    }
    if (defaultScope != null) {
      out.add(defaultScope!.isNotEmpty ? 'Keep its floods to region #$defaultScope' : 'Clear its default flood scope');
    }
    if (txPower != null) out.add('Transmit at $txPower dBm');
    if (hashSize != null) out.add('Use $hashSize-byte hop hashes in floods');
    if (radio != null) {
      final (f, bw, sf, cr) = radio!;
      out.add('Tune the radio to ${f.toStringAsFixed(3)} MHz · BW ${_g(bw)} kHz · SF$sf · CR$cr');
    }
    if (pin != null) out.add(pin == 0 ? 'Use the default Bluetooth PIN' : 'Set the Bluetooth PIN to ${pin.toString().padLeft(6, '0')}');
    if (advert) out.add('Send a flood advert so the mesh hears about the node');
    if (reboot) out.add('Restart the node');
    return out;
  }
}

bool _ok(p.Frame? f) => f != null && f.kind != 'err';

String _why(p.Frame? f) {
  if (f == null) return 'no answer';
  return f.kind == 'err' ? (p.errNames[f['err']] ?? 'error ${f['err']}') : '';
}

/// progress(text, ok, why): ok is null when a step starts.
typedef Progress = void Function(String text, bool? ok, String why);

/// Sends the plan to the node. Carries on past a failed step and returns
/// whether they all worked. The radio goes last but for the PIN and the
/// advert, so the advert goes out on the new settings.
Future<bool> applyPlan(Session session, Plan plan, Progress progress) async {
  final model = session.model;
  final si = model.selfInfo;
  var allOk = true;

  Future<void> step(String text, Future<p.Frame?> Function() fn) async {
    progress(text, null, '');
    p.Frame? f;
    try {
      f = await fn();
    } catch (e) {
      allOk = false;
      progress(text, false, '$e');
      return;
    }
    final ok = _ok(f);
    allOk &= ok;
    progress(text, ok, _why(f));
  }

  if (plan.name != null) await step('Naming it “${plan.name}”', () => session.request(p.setName(plan.name!), {'ok'}));
  if (plan.location != null) {
    await step('Setting its position', () => session.request(p.setLatLon(plan.location!.$1, plan.location!.$2), {'ok'}));
  }
  if (plan.shareLocation != null || plan.autoAdd != null || plan.telemetry != null || plan.multiAcks != null) {
    // One command sets all four, so the ones we don't change go back as they were.
    var manual = si?.manualAdd ?? 0;
    if (plan.autoAdd != null) manual = (manual & ~1) | (plan.autoAdd! ? 0 : 1);
    var policy = si?.locPolicy ?? 0;
    if (plan.shareLocation != null) policy = plan.shareLocation! ? 1 : 0;
    final telemetry = plan.telemetry ?? si?.telemetry ?? 0;
    final multi = plan.multiAcks != null ? (plan.multiAcks! ? 1 : 0) : (si?.multiAcks ?? 0);
    await step('Setting contact, position and privacy options',
        () => session.request(p.setOtherParams(manual, telemetry, policy, multi), {'ok'}));
  }
  for (final (n, secret) in plan.channels) {
    final free = [for (var i = 0; i < session.maxChannels; i++) i].where((i) => !model.channels.containsKey(i)).firstOrNull;
    if (free == null) {
      progress('Joining $n', false, 'every channel slot is in use');
      allOk = false;
      continue;
    }
    await step('Joining $n', () => session.setChannel(free, n, secret));
  }
  if (plan.defaultScope != null) {
    await step('Setting the default flood scope', () => session.setDefaultScope(plan.defaultScope!));
  }
  if (plan.txPower != null) {
    await step('Setting transmit power to ${plan.txPower} dBm', () => session.request(p.setTxPower(plan.txPower!), {'ok'}));
  }
  if (plan.hashSize != null) {
    await step('Using ${plan.hashSize}-byte hop hashes', () => session.request(p.setPathHashMode(plan.hashSize! - 1), {'ok'}));
  }
  if (plan.radio != null) {
    final (f, bw, sf, cr) = plan.radio!;
    await step('Tuning the radio', () => session.request(p.setRadio(f, bw, sf, cr), {'ok'}));
  }
  if (plan.pin != null) await step('Setting the Bluetooth PIN', () => session.request(p.setPin(plan.pin!), {'ok'}));
  // Read back what the node now says about itself.
  await session.request(p.appStart(), {'self_info'});
  await session.request(p.deviceQuery(), {'device_info'});
  if (plan.advert) await step('Sending a flood advert', () => session.advert(true));
  if (plan.reboot) {
    progress('Restarting the node', null, '');
    await session.reboot();
    progress('Restarting the node', true, '');
  }
  return allOk;
}
