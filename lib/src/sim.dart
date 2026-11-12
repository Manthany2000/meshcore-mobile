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
  final sim = Sim();

  @override
  String get label => 'Simulator';

  @override
  Future<void> connect() async {
    sim.onFrame = (b) => onFrame(b);
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
  final name = 'SimNode';
  final key = _key('sim-self');
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
  late final Map<int, (String, Uint8List)> channels = {
    0: ('Public', _publicSecret),
    1: ('#test', _key('#test').sublist(0, 16)),
  };
  Timer? _timer;
  final _timers = <Timer>[];

  List<SimNode> get repeaters => contacts.where((c) => c.type == p.advRepeater).toList();

  Sim() {
    final now = nowS().floor();
    // Queued while no app was connected: the old frame format.
    queue.add(_chanMsg(0, 'alice', 'morning all', now - 1800, v3: false));
    queue.add(_dm(contacts[5].key, 'you around later?', now - 900, v3: false));
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

  void handle(Uint8List b) {
    final bd = ByteData.sublistView(b);
    switch (b[0]) {
      case p.cmdAppStart:
        _push((BytesBuilder()
              ..add([p.respSelfInfo, 1, 22, 22])
              ..add(key)
              ..i32(42356000)
              ..i32(-71100000)
              ..add(Uint8List(4))
              ..u32(910525)
              ..u32(62500)
              ..add([7, 5])
              ..add(utf8.encode(name)))
            .toBytes());
      case p.cmdDeviceQuery:
        _push((BytesBuilder()
              ..add([p.respDeviceInfo, 14, 175, 8])
              ..add(Uint8List(4))
              ..fixed('05 Nov 2026', 12)
              ..fixed('Simulated', 40)
              ..fixed('sim-1.0', 20))
            .toBytes());
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
        _push(_b([p.respOk]));
        _copies(p.payloadGrpTxt, p.encryptGroup(channels[ch]!.$2, ts, name, text));
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
