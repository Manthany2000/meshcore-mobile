// A pretend companion node, speaking the same frames as the real one, for
// running the app with no radio: channel chatter with repeats, DMs with acks.
// Ported from MeshCore Desktop's sim.py.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'model.dart' show nowS;
import 'protocol.dart' as p;
import 'transport.dart';

Uint8List _key(String name) => SHA256Digest().process(Uint8List.fromList(utf8.encode(name)));

final _publicSecret = p.unhex('8b3387e9c5cdea6ac9e5edbaa115cd72');

class SimNode {
  final String name;
  final Uint8List key;
  final int type;
  final double lat, lon;
  int hops;
  SimNode(this.name, this.type, this.lat, this.lon, this.hops) : key = _key(name);
}

const _chatter = [
  'anyone on tonight?',
  'test from the car',
  'good copy here, 3 hops',
  '@[{me}] you\'re coming in clear',
  'new repeater up on the ridge',
  'weather\'s turning, signal is great',
  'ping',
  '73 all',
];

class SimTransport extends Transport {
  final Sim sim;
  /// fresh: a node that's just been flashed. visitor: a node the app hasn't
  /// seen is in its contact list, as if heard while the app was closed.
  SimTransport({bool fresh = false, bool visitor = false}) : sim = Sim(fresh: fresh, visitor: visitor);

  @override
  String get label => 'Simulator';

  @override
  Future<void> connect() async {
    sim.onFrame = (b) => onFrame(b);
    sim.onReboot = () => onDisconnect();
    await Future.delayed(const Duration(milliseconds: 300));
    sim.start();
  }

  @override
  Future<void> write(Uint8List frame) async {
    await Future.delayed(const Duration(milliseconds: 10));
    sim.handle(frame);
  }

  @override
  Future<void> close() async => sim.stop();
}

/// A repeater's region map, answering `region ...` as CommonCLI does.
class SimRegions {
  // name -> (parent, floods allowed); '*' is the root.
  final r = <String, (String?, bool)>{'*': (null, true), 'usa': ('*', true), 'ma': ('usa', true), 'boston': ('ma', true)};
  String? home = 'ma', def;

  String? _find(String prefix) {
    prefix = prefix.replaceFirst(RegExp(r'^#+'), '');
    if (r.containsKey(prefix)) return prefix;
    for (final n in r.keys) {
      if (n.startsWith(prefix)) return n;
    }
    return null;
  }

  String tree() {
    final lines = <String>[];
    void walk(String name, int depth) {
      lines.add('${' ' * depth}$name${name == home ? '^' : ''}${r[name]!.$2 ? ' F' : ''}');
      for (final e in r.entries) {
        if (e.value.$1 == name) walk(e.key, depth + 1);
      }
    }

    walk('*', 0);
    final t = lines.join('\n');
    return t.length > 159 ? t.substring(0, 159) : t;
  }

  String command(String cmd) {
    final p0 = cmd.split(' ').where((x) => x.isNotEmpty).toList();
    if (p0.length == 1) return tree();
    final op = p0[1], arg = p0.length > 2 ? p0[2] : null;
    switch (op) {
      case 'save':
        return 'OK';
      case 'allowf' || 'denyf' when arg != null:
        final n = _find(arg);
        if (n == null) return 'Err - unknown region';
        r[n] = (r[n]!.$1, op == 'allowf');
        return 'OK';
      case 'home':
        if (arg == null) return ' home is ${home ?? '*'}';
        final n = _find(arg);
        if (n == null) return 'Err - unknown region';
        home = n;
        return ' home is now $n';
      case 'default':
        if (arg == null) return ' default scope is ${def ?? '<null>'}';
        if (arg == '<null>') {
          def = null;
          return ' default scope is now <null>';
        }
        final n = _find(arg) ?? p.regionName(arg);
        r[n] = (r[n]?.$1 ?? '*', true);
        def = n;
        return ' default scope is now $n';
      case 'put' when arg != null:
        final parent = p0.length > 3 ? _find(p0[3]) : '*';
        if (parent == null) return 'Err - unknown parent';
        if (p.regionProblem(arg) != null) return 'Err - unable to put';
        r[p.regionName(arg)] = (parent, true);
        return 'OK - (flood allowed)';
      case 'remove' when arg != null:
        final n = p.regionName(arg);
        if (!r.containsKey(n) || n == '*') return 'Err - not found';
        if (r.values.any((v) => v.$1 == n)) return 'Err - not empty';
        r.remove(n);
        if (home == n) home = null;
        return 'OK';
      case 'get' when arg != null:
        final n = _find(arg);
        return n == null ? 'Err - unknown region' : ' $n ${r[n]!.$2 ? 'F' : ''}';
    }
    return 'Err - ??';
  }
}

extension _Bytes on BytesBuilder {
  void u32(int v) => add(Uint8List(4)..buffer.asByteData().setUint32(0, v & 0xFFFFFFFF, Endian.little));
  void i32(int v) => add(Uint8List(4)..buffer.asByteData().setInt32(0, v, Endian.little));
  void fixed(String s, int len) {
    final e = utf8.encode(s);
    add(Uint8List(len)..setRange(0, min(e.length, len), e));
  }
}

class Sim {
  final rnd = Random();
  void Function(Uint8List) onFrame = (_) {};
  String name = 'SimNode';
  Uint8List key = _key('sim-self');
  // What the setup commands change, as the firmware keeps them.
  (int, int, int, int) radio = (910525, 62500, 7, 5); // kHz, Hz, sf, cr
  int txPower = 22, maxTx = 22;
  int lat = 42356000, lon = -71100000;
  int multiAcks = 0, locPolicy = 0, telemetry = 0, manualAdd = 0;
  int pin = 0, pathHashMode = 0;
  Uint8List? sendScope = Uint8List(0); // the scope override: empty none, a key, or null for unscoped
  (String, Uint8List) defaultScope = ('', Uint8List(0)); // saved on the node
  final sentScopes = <Uint8List?>[]; // the scope each channel message went out with, for the tests
  int reboots = 0;
  void Function() onReboot = () {};
  final regions = <String, SimRegions>{};
  int clock = nowS().floor() - 3600; // a bit behind, so the app sets it
  double _t0 = nowS();
  final queue = <Uint8List>[];
  final contacts = [
    SimNode('Ridge Repeater', p.advRepeater, 42.36, -71.20, 0),
    SimNode('Hilltop RPT', p.advRepeater, 42.40, -71.10, 1),
    SimNode('Water Tower', p.advRepeater, 42.30, -71.30, 2),
    SimNode('Library Roof', p.advRepeater, 42.33, -71.05, 1),
    SimNode('alice', p.advChat, 42.35, -71.15, 1),
    SimNode('bob-t1000', p.advChat, 42.38, -71.00, 2),
    SimNode('Kestrel', p.advChat, 0, 0, -1),
    SimNode('NHbot', p.advChat, 42.90, -71.40, 3),
    SimNode('Town Room', p.advRoom, 42.34, -71.12, 1),
  ];
  final discovered = [
    SimNode('Harbor Repeater', p.advRepeater, 42.32, -70.98, 1),
    SimNode('carol-mobile', p.advChat, 42.31, -71.08, 1),
  ];
  late Map<int, (String, Uint8List)> channels = {
    0: ('Public', _publicSecret),
    1: ('#test', _key('#test').sublist(0, 16)),
  };
  Timer? _timer;
  final _timers = <Timer>[];
  final admins = <String>{}; // repeaters that have us on their admin list
  final repeaterCfg = <String, Map<String, String>>{};

  List<SimNode> get repeaters => contacts.where((c) => c.type == p.advRepeater).toList();

  Sim({bool fresh = false, bool visitor = false}) {
    final now = nowS().floor();
    if (visitor) contacts.add(SimNode('Visitor-${1000 + rnd.nextInt(9000)}', p.advChat, 42.37, -71.22, 1));
    // Queued while no app was connected: the old frame format.
    queue.add(_chanMsg(0, 'alice', 'morning all', now - 1800, v3: false));
    queue.add(_dm(contacts[5].key, 'you around later?', now - 900, v3: false));
    if (fresh) {
      // Just flashed: default name, radio and position, nothing heard yet.
      key = _key('sim-fresh');
      name = p.hex(key.sublist(0, 4)).toUpperCase();
      radio = (869618, 62500, 8, 8);
      lat = lon = 0;
      contacts.clear();
      discovered.clear();
      queue.clear();
      channels = {0: ('Public', _publicSecret)};
    }
  }

  int clockNow() => clock + (nowS() - _t0).floor();

  void start() => _scheduleChatter();

  void stop() {
    _timer?.cancel();
    for (final t in _timers) {
      t.cancel();
    }
  }

  void _push(Uint8List b, [double delay = 0]) {
    _timers.add(Timer(Duration(milliseconds: (delay * 1000).round()), () => onFrame(b)));
  }

  Uint8List _contactFrame(SimNode c, [int code = p.respContact]) {
    final b = BytesBuilder()
      ..addByte(code)
      ..add(c.key)
      ..add([c.type, 0, c.hops < 0 ? 0xFF : c.hops]);
    final path = Uint8List(64);
    final rs = repeaters;
    for (var i = 0; i < max(c.hops, 0) && i < rs.length; i++) {
      path[i] = rs[i].key[0];
    }
    b
      ..add(path)
      ..fixed(c.name, 32)
      ..u32(clock - 600)
      ..i32((c.lat * 1e6).round())
      ..i32((c.lon * 1e6).round())
      ..u32(clock - 300);
    return b.toBytes();
  }

  Uint8List _chanMsg(int ch, String who, String text, int ts, {int hops = 1, double snr = 6.5, bool v3 = true}) {
    final b = BytesBuilder();
    v3 ? b.add([p.respChannelMsgV3, (snr * 4).round() & 255, 0, 0]) : b.addByte(p.respChannelMsg);
    b
      ..add([ch, hops, 0])
      ..u32(ts)
      ..add(utf8.encode('$who: $text'));
    return b.toBytes();
  }

  Uint8List _dm(Uint8List key, String text, int ts, {int hops = 2, double snr = 4.0, bool v3 = true}) {
    final b = BytesBuilder();
    v3 ? b.add([p.respContactMsgV3, (snr * 4).round() & 255, 0, 0]) : b.addByte(p.respContactMsg);
    b
      ..add(key.sublist(0, 6))
      ..add([hops, 0])
      ..u32(ts)
      ..add(utf8.encode(text));
    return b.toBytes();
  }

  Uint8List _logRx(int ptype, List<List<int>> path, Uint8List payload, [double? snr]) {
    snr ??= rnd.nextDouble() * 18 - 8;
    final header = (ptype << 2) | 1; // flood
    return (BytesBuilder()
          ..add([p.pushLogRx, (snr * 4).round() & 255, (-60 - rnd.nextInt(60)) & 255, header, path.length])
          ..add([for (final h in path) ...h])
          ..add(payload))
        .toBytes();
  }

  List<List<int>> _randomPath(int k) {
    final rs = repeaters..shuffle(rnd);
    return [for (final r in rs.take(k)) r.key.sublist(0, 1)];
  }

  void _copies(int ptype, Uint8List payload, {int firstHops = 0, int? n}) {
    n ??= 1 + rnd.nextInt(4);
    var t = 0.0;
    for (var i = 0; i < n; i++) {
      t += 0.4 + rnd.nextDouble() * 2.1;
      final lo = firstHops < 1 ? 1 : firstHops;
      final k = lo + rnd.nextInt(4 - lo);
      _push(_logRx(ptype, _randomPath(k), payload), t);
    }
  }

  void _scheduleChatter() {
    _timer = Timer(Duration(seconds: 10 + rnd.nextInt(10)), () {
      _chatterOnce();
      _scheduleChatter();
    });
  }

  void _chatterOnce() {
    if (discovered.isNotEmpty) {
      final node = discovered.removeAt(0);
      contacts.add(node);
      _push(_contactFrame(node, p.pushNewAdvert));
    }
    final chats = contacts.where((c) => c.type == p.advChat).toList();
    if (chats.isEmpty) return; // a fresh node has heard nobody yet
    final sender = chats[rnd.nextInt(chats.length)];
    if (rnd.nextDouble() < 0.75) {
      final ch = channels.keys.elementAt(rnd.nextInt(channels.length));
      final text = _chatter[rnd.nextInt(_chatter.length)].replaceAll('{me}', name);
      final ts = clockNow();
      final payload = p.encryptGroup(channels[ch]!.$2, ts, sender.name, text);
      final hops = 1 + rnd.nextInt(2);
      _push(_logRx(p.payloadGrpTxt, _randomPath(hops), payload, 7.0)); // the copy the node acts on
      queue.add(_chanMsg(ch, sender.name, text, ts, hops: hops));
      _push(Uint8List.fromList([p.pushMsgWaiting]), 0.05);
      _copies(p.payloadGrpTxt, payload, firstHops: hops);
    } else {
      const dms = ['hey', 'got your msg', 'what\'s your antenna?'];
      queue.add(_dm(sender.key, dms[rnd.nextInt(dms.length)], clockNow()));
      _push(Uint8List.fromList([p.pushMsgWaiting]));
    }
    if (rnd.nextDouble() < 0.3) {
      _push(Uint8List.fromList([p.pushAdvert, ...contacts[rnd.nextInt(contacts.length)].key]));
    }
  }

  SimNode? _contact(List<int> keyOrPrefix) {
    for (final c in contacts) {
      if (p.startsWith(c.key, keyOrPrefix)) return c;
    }
    return null;
  }

  Uint8List _b(List<int> l) => Uint8List.fromList(l);

  Uint8List _sent(int ack) => (BytesBuilder()
        ..add([p.respSent, 0])
        ..u32(ack)
        ..u32(500))
      .toBytes();

  /// A repeater that answers. Library Roof never does, as if out of range.
  SimNode? _repeater(List<int> keyOrPrefix) {
    final c = _contact(keyOrPrefix);
    return c == null || c.type != p.advRepeater || c.name == 'Library Roof' ? null : c;
  }

  void _login(Uint8List b) {
    final k = b.sublist(1, 33), pw = utf8.decode(b.sublist(33));
    _push(_sent(1));
    if (_repeater(k) == null) return;
    final px = p.hex(k.sublist(0, 6));
    Uint8List ok(bool admin) => (BytesBuilder()
          ..add([p.pushLoginSuccess, admin ? 1 : 0])
          ..add(k.sublist(0, 6))
          ..u32(clockNow())
          ..add([admin ? 3 : 1, 8]))
        .toBytes();
    if (pw == 'admin' || (pw.isEmpty && admins.contains(px))) {
      admins.add(px);
      _push(ok(true), 0.4);
    } else if (pw == 'guest') {
      _push(ok(false), 0.4);
    } else {
      _push(_b([p.pushLoginFail, 0, ...k.sublist(0, 6)]), 0.4);
    }
  }

  void _status(Uint8List b) {
    final k = b.sublist(1, 33);
    _push(_sent(2));
    if (_repeater(k) == null) return;
    // Counters that climb unevenly, so the history has something to draw.
    final t = nowS() - _t0;
    final rx = max(0, (t * .6 + 5 * sin(t / 20)).round()), tx = max(0, (t * .3 + 3 * sin(t / 13)).round());
    final bd = ByteData(56);
    var at = 0;
    void u16(int v) {
      bd.setUint16(at, v & 0xFFFF, Endian.little);
      at += 2;
    }

    void i16(int v) {
      bd.setInt16(at, v, Endian.little);
      at += 2;
    }

    void u32(int v) {
      bd.setUint32(at, v, Endian.little);
      at += 4;
    }

    u16(3900 + rnd.nextInt(150));
    u16(1);
    i16(-112 + (3 * sin(t / 15)).round() + rnd.nextInt(3));
    i16(-71);
    u32(48213 + rx);
    u32(21877 + tx);
    u32(1842 + (t * .03).round());
    u32(412345 + t.round());
    u32(18000 + tx ~/ 2);
    u32(3877 + tx ~/ 2);
    u32(40000 + rx ~/ 2);
    u32(8213 + rx ~/ 2);
    u16(2);
    i16(26);
    u16(15);
    u16(930 + rx ~/ 8);
    u32(5120 + (t * .08).round());
    u32(3);
    _push(_b([p.pushStatusResponse, 0, ...k.sublist(0, 6), ...bd.buffer.asUint8List()]), 0.4);
  }

  void _cli(Uint8List b) {
    final prefix = b.sublist(7, 13), cmd = utf8.decode(b.sublist(13));
    _push(_sent(0));
    final r = _repeater(prefix);
    final px = p.hex(prefix);
    if (r == null || !admins.contains(px)) return; // a real repeater ignores anyone but an admin
    final cfg = repeaterCfg.putIfAbsent(px, () => {
          'name': r.name,
          'repeat': 'on',
          'tx': '22',
          'advert.interval': '120',
          'flood.advert.interval': '12',
          'flood.max': '64',
          'flood.max.unscoped': '64',
          'flood.max.advert': '64',
          'radio': '910.525,62.5,7,5',
          'path.hash.mode': '0',
          'radio.rxgain': 'on',
          'cad': 'off',
          'loop.detect': 'off',
          'multi.acks': '0',
          'af': '1.0',
          'rxdelay': '0.0',
          'txdelay': '0.5',
          'direct.txdelay': '0.3',
          'agc.reset.interval': '0',
          'int.thresh': '0',
          'guest.password': '',
          'allow.read.only': 'off',
          'lat': '${r.lat}',
          'lon': '${r.lon}',
          'owner.info': '',
        });
    final parts = cmd.split(' ');
    String reply;
    if (parts[0] == 'password' && parts.length == 2) {
      reply = 'password now: ${parts[1]}';
    } else if (parts[0] == 'region') {
      reply = regions.putIfAbsent(px, SimRegions.new).command(cmd);
    } else if (parts.length == 2 && parts[0] == 'get' && cfg.containsKey(parts[1])) {
      reply = '> ${cfg[parts[1]]}';
    } else if (parts.length >= 3 && parts[0] == 'set' && cfg.containsKey(parts[1])) {
      cfg[parts[1]] = parts.sublist(2).join(' ');
      reply = parts[1] == 'repeat' ? 'OK - repeat is now ${cfg['repeat']!.toUpperCase()}' : 'OK';
    } else {
      reply = const {
            'ver': 'v1.11.0 (Build: 05-Nov-2026)',
            'clock': '12:00 - 8/11/2026 UTC',
            'board': 'Heltec V3',
            'neighbors': 'A1B2C3D4:42:26\n99F0E1AA:310:-8',
            'advert': 'OK - Advert sent',
            'advert.zerohop': 'OK - zerohop advert sent',
            'clock sync': 'OK - clock set',
            'reboot': 'OK - rebooting',
          }[cmd] ??
          'Unknown command';
    }
    final m = BytesBuilder()
      ..add([p.respContactMsgV3, 24, 0, 0])
      ..add(prefix)
      ..add([1, p.txtCli])
      ..u32(clockNow())
      ..add(utf8.encode(reply));
    queue.add(m.toBytes());
    _push(_b([p.pushMsgWaiting]), 0.5);
  }

  void handle(Uint8List b) {
    final bd = ByteData.sublistView(b);
    switch (b[0]) {
      case p.cmdAppStart:
        _push((BytesBuilder()
              ..add([p.respSelfInfo, 1, txPower & 255, maxTx])
              ..add(key)
              ..i32(lat)
              ..i32(lon)
              ..add([multiAcks, locPolicy, telemetry, manualAdd])
              ..u32(radio.$1)
              ..u32(radio.$2)
              ..add([radio.$3, radio.$4])
              ..add(utf8.encode(name)))
            .toBytes());
      case p.cmdDeviceQuery:
        _push((BytesBuilder()
              ..add([p.respDeviceInfo, 14, 175, 8])
              ..u32(pin)
              ..fixed('05 Nov 2026', 12)
              ..fixed('Simulated', 40)
              ..fixed('sim-1.0', 20)
              ..add([0, pathHashMode]))
            .toBytes());
      case p.cmdSetAdvertName when b.length >= 2:
        name = utf8.decode(b.sublist(1, min(b.length, 32)), allowMalformed: true);
        _push(_b([p.respOk]));
      case p.cmdSetRadioParams when b.length >= 11:
        final f = bd.getUint32(1, Endian.little), bw = bd.getUint32(5, Endian.little), sf = b[9], cr = b[10];
        if (f >= 150000 && f <= 2500000 && sf >= 5 && sf <= 12 && cr >= 5 && cr <= 8 && bw >= 7000 && bw <= 500000) {
          radio = (f, bw, sf, cr);
          _push(_b([p.respOk]));
        } else {
          _push(_b([p.respErr, 6]));
        }
      case p.cmdSetRadioTxPower when b.length >= 2:
        final dbm = bd.getInt8(1);
        if (dbm >= -9 && dbm <= maxTx) {
          txPower = dbm;
          _push(_b([p.respOk]));
        } else {
          _push(_b([p.respErr, 6]));
        }
      case p.cmdSetAdvertLatLon when b.length >= 9:
        lat = bd.getInt32(1, Endian.little);
        lon = bd.getInt32(5, Endian.little);
        _push(_b([p.respOk]));
      case p.cmdSetOtherParams when b.length >= 2:
        manualAdd = b[1];
        if (b.length >= 5) {
          telemetry = b[2];
          locPolicy = b[3];
          multiAcks = b[4];
        }
        _push(_b([p.respOk]));
      case p.cmdSetDevicePin when b.length >= 5:
        final v = bd.getUint32(1, Endian.little);
        if (v == 0 || (v >= 100000 && v <= 999999)) {
          pin = v;
          _push(_b([p.respOk]));
        } else {
          _push(_b([p.respErr, 6]));
        }
      case p.cmdSetFloodScope when b.length >= 2:
        sendScope = b[1] == 1 ? null : (b.length >= 18 ? b.sublist(2, 18) : Uint8List(0));
        _push(_b([p.respOk]));
      case p.cmdSetDefaultFloodScope:
        if (b.length >= 1 + 31 + 16) {
          final n = p.cstr(b.sublist(1, 32));
          if (n.isEmpty || n.length >= 31) return _push(_b([p.respErr, 6]));
          defaultScope = (n, b.sublist(32, 48));
        } else {
          defaultScope = ('', Uint8List(0));
        }
        _push(_b([p.respOk]));
      case p.cmdGetDefaultFloodScope:
        final (n, k) = defaultScope;
        final o = BytesBuilder()..addByte(p.respDefaultFloodScope);
        if (n.isNotEmpty) {
          o
            ..fixed(n, 31)
            ..add(k);
        }
        _push(o.toBytes());
      case p.cmdSetPathHashMode when b.length >= 3 && b[1] == 0:
        if (b[2] < 3) {
          pathHashMode = b[2];
          _push(_b([p.respOk]));
        } else {
          _push(_b([p.respErr, 6]));
        }
      case p.cmdReboot:
        reboots++;
        _timers.add(Timer(const Duration(milliseconds: 200), onReboot));
      case p.cmdAddUpdateContact when b.length >= 1 + 32 + 3 + 64 + 32 + 4:
        if (_contact(b.sublist(1, 33)) == null) {
          contacts.add(SimNode(p.cstr(b.sublist(100, 132)), b[33], 0, 0, -1));
        }
        _push(_b([p.respOk]));
      case p.cmdGetDeviceTime:
        _push((BytesBuilder()
              ..addByte(p.respCurrTime)
              ..u32(clockNow()))
            .toBytes());
      case p.cmdSetDeviceTime:
        clock = bd.getUint32(1, Endian.little);
        _t0 = nowS();
        _push(_b([p.respOk]));
      case p.cmdGetBattAndStorage:
        final mv = 3900 + rnd.nextInt(200);
        _push(_b([p.respBatt, mv & 255, mv >> 8, ...List.filled(8, 0)]));
      case p.cmdGetChannel:
        final i = b[1];
        final c = channels[i];
        _push((BytesBuilder()
              ..add([p.respChannelInfo, i])
              ..fixed(c?.$1 ?? '', 32)
              ..add(c?.$2 ?? Uint8List(16)))
            .toBytes());
      case p.cmdSetChannel:
        final n = p.cstr(b.sublist(2, 34));
        n.isNotEmpty ? channels[b[1]] = (n, b.sublist(34, 50)) : channels.remove(b[1]);
        _push(_b([p.respOk]));
      case p.cmdGetContacts:
        _push((BytesBuilder()
              ..addByte(p.respContactsStart)
              ..u32(contacts.length))
            .toBytes());
        for (var i = 0; i < contacts.length; i++) {
          _push(_contactFrame(contacts[i]), 0.005 * i);
        }
        _push((BytesBuilder()
              ..addByte(p.respEndOfContacts)
              ..u32(clockNow()))
            .toBytes(), 0.005 * contacts.length + 0.01);
      case p.cmdSyncNextMessage:
        _push(queue.isNotEmpty ? queue.removeAt(0) : _b([p.respNoMoreMessages]));
      case p.cmdSendChannelTxtMsg:
        final ch = b[2], ts = bd.getUint32(3, Endian.little);
        final text = utf8.decode(b.sublist(7));
        if (!channels.containsKey(ch)) return _push(_b([p.respErr, 2]));
        sentScopes.add(sendScope != null && sendScope!.isEmpty ? defaultScope.$2 : sendScope);
        _push(_b([p.respOk]));
        _copies(p.payloadGrpTxt, p.encryptGroup(channels[ch]!.$2, ts, name, text));
      case p.cmdSendLogin:
        _login(b);
      case p.cmdSendStatusReq:
        _status(b);
      case p.cmdSendTxtMsg when b[1] == p.txtCli:
        _cli(b);
      case p.cmdSendTxtMsg:
        final dest = b.sublist(7, 13);
        final ack = rnd.nextInt(1 << 32);
        final ct = _contact(dest);
        final flood = ct == null || ct.hops < 0;
        _push((BytesBuilder()
              ..add([p.respSent, flood ? 1 : 0])
              ..u32(ack)
              ..u32(6000))
            .toBytes());
        if (flood && ct != null) {
          ct.hops = rnd.nextInt(3);
          _push(_b([p.pushPathUpdated, ...ct.key]), 1 + rnd.nextDouble() * 2);
        }
        final payload = _b([dest[0], key[0], for (var i = 0; i < 20; i++) rnd.nextInt(256)]);
        _copies(p.payloadTxtMsg, payload, n: rnd.nextInt(3));
        if (rnd.nextDouble() < 0.8) {
          _push((BytesBuilder()
                ..addByte(p.pushSendConfirmed)
                ..u32(ack)
                ..u32(900 + rnd.nextInt(3100)))
              .toBytes(), 1 + rnd.nextDouble() * 3);
          if (rnd.nextDouble() < 0.5) {
            queue.add(_dm(dest, 'copy that 👍', clockNow()));
            _push(_b([p.pushMsgWaiting]), 5);
          }
        }
      case p.cmdResetPath:
        final ct = _contact(b.sublist(1, 33));
        if (ct == null) return _push(_b([p.respErr, 2]));
        ct.hops = -1;
        _push(_b([p.respOk]));
      case p.cmdGetContactByKey:
        final ct = _contact(b.sublist(1, 33));
        _push(ct != null ? _contactFrame(ct) : _b([p.respErr, 2]));
      case p.cmdSendSelfAdvert:
        _push(_b([p.respOk]));
      default:
        _push(_b([p.respErr, 1]));
    }
  }
}
