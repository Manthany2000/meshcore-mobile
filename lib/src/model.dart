// What we know about the mesh, saved per node as JSON. Knows nothing of BLE or
// widgets: frames go in through apply(), the UI listens via ChangeNotifier.
// Ported from MeshCore Desktop's model.py.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'protocol.dart' as p;

const clockSane = 1700000000; // late 2023: a node never told the time reads less
const copyClaimS = 30; // how old a logged packet can be and still belong to a new message
const repeatWindowS = 120; // how long a flood can still be going round

enum MsgStatus { incoming, sending, sent, waiting, delivered, noAck, failed }

String chanConv(int idx) => 'ch:$idx';
String dmConv(List<int> prefix) => 'dm:${p.hex(prefix.sublist(0, p.keyPrefix))}';

double nowS() => DateTime.now().millisecondsSinceEpoch / 1000;

class Repeater {
  final String hash;
  bool direct;
  double? snr;
  Repeater(this.hash, {this.direct = false, this.snr});
  Map<String, dynamic> toJson() => {'hash': hash, 'direct': direct, 'snr': snr};
}

class Message {
  int id;
  final String conv;
  final bool outgoing;
  final String sender;
  final String text;
  int wireTime; // the timestamp inside the packet
  double at; // local epoch seconds it arrived or was sent
  MsgStatus status;
  int hops; // -1 = direct route
  double? snr;
  int repeats = 0;
  Map<String, Repeater> repeaters = {};
  List<String>? path;
  int pathSize = 1;
  int ack = 0;
  int tripMs = 0;
  double deadline = 0;
  bool live = false;
  Uint8List payloadKey = Uint8List(0);

  Message(this.id, this.conv, this.outgoing, this.sender, this.text, this.wireTime, this.at,
      {this.status = MsgStatus.incoming, this.hops = -1, this.snr, this.live = false});

  bool get isChannel => conv.startsWith('ch:');
  int get channel => isChannel ? int.parse(conv.substring(3)) : -1;
  Uint8List get dmPrefix => isChannel ? Uint8List(0) : p.unhex(conv.substring(3));

  Map<String, dynamic> toJson() => {
        'id': id,
        'conv': conv,
        'out': outgoing,
        'sender': sender,
        'text': text,
        'wt': wireTime,
        'at': at,
        'status': status.name,
        'hops': hops,
        'snr': snr,
        'repeats': repeats,
        'reps': [for (final r in repeaters.values) r.toJson()],
        'path': path,
        'ps': pathSize,
        'ack': ack,
        'trip': tripMs,
      };

  static Message fromJson(Map<String, dynamic> j) {
    final m = Message(j['id'], j['conv'], j['out'], j['sender'], j['text'], j['wt'], (j['at'] as num).toDouble(),
        status: MsgStatus.values.byName(j['status']), hops: j['hops'], snr: (j['snr'] as num?)?.toDouble());
    m.repeats = j['repeats'] ?? 0;
    for (final r in (j['reps'] as List? ?? [])) {
      m.repeaters[r['hash']] = Repeater(r['hash'], direct: r['direct'], snr: (r['snr'] as num?)?.toDouble());
    }
    m.path = (j['path'] as List?)?.cast<String>();
    m.pathSize = j['ps'] ?? 1;
    m.ack = j['ack'] ?? 0;
    m.tripMs = j['trip'] ?? 0;
    // Whatever was in flight when the app closed won't hear back now.
    if (m.status == MsgStatus.sending) m.status = MsgStatus.failed;
    if (m.status == MsgStatus.waiting) m.status = MsgStatus.noAck;
    return m;
  }
}

class Channel {
  final int idx;
  final String name;
  final Uint8List secret; // never logged or shown
  Channel(this.idx, this.name, [Uint8List? secret]) : secret = secret ?? Uint8List(0);
}

class SelfInfo {
  final Uint8List key;
  final String name;
  final double lat, lon, freq, bw;
  final int sf, cr, txPower, maxTx;
  SelfInfo(p.Frame f)
      : key = f['key'],
        name = f['name'],
        lat = f['lat'],
        lon = f['lon'],
        freq = f['freq'],
        bw = f['bw'],
        sf = f['sf'],
        cr = f['cr'],
        txPower = f['tx_power'],
        maxTx = f['max_tx'];
}

class _LoggedPacket {
  final p.RawPacket packet;
  final double at;
  bool claimed = false;
  _LoggedPacket(this.packet, this.at);
}

class Model extends ChangeNotifier {
  SelfInfo? selfInfo;
  p.Frame? deviceInfo;
  int batteryMv = 0;
  int clockOffset = 0; // node clock minus ours, seconds
  final contacts = <String, p.Contact>{}; // by 6-byte prefix hex
  final heard = <String, double>{}; // prefix hex -> local time heard live
  final channels = <int, Channel>{};
  final messages = <Message>[];
  final lastRead = <String, double>{};
  final _rawLog = <_LoggedPacket>[];
  final packets = <(double, p.RawPacket)>[]; // this session only
  final savedNames = <String, String>{};
  final floodAlways = <String>{};
  final newContacts = StreamController<p.Contact>.broadcast();
  int _nextId = 1;
  File? _file;
  final Future<Directory> Function() dataDir;

  Model({Future<Directory> Function()? dataDir}) : dataDir = dataDir ?? getApplicationSupportDirectory;
  Timer? _saveTimer;

  /// A new link: forget what's live, keep the node and its history.
  void reset() {
    deviceInfo = null;
    batteryMv = 0;
    contacts.clear();
    heard.clear();
    packets.clear();
    _rawLog.clear();
    notifyListeners();
  }

  // --- persistence ------------------------------------------------------------

  Future<void> _openForNode(Uint8List key) async {
    final dir = await dataDir();
    _file = File('${dir.path}/node-${p.hex(key.sublist(0, 4))}.json');
    messages.clear();
    channels.clear();
    savedNames.clear();
    lastRead.clear();
    floodAlways.clear();
    if (await _file!.exists()) {
      try {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        for (final m in (j['messages'] as List)) {
          messages.add(Message.fromJson(m));
        }
        (j['names'] as Map? ?? {}).forEach((k, v) => savedNames[k] = v);
        (j['reads'] as Map? ?? {}).forEach((k, v) => lastRead[k] = (v as num).toDouble());
        floodAlways.addAll((j['flood'] as List? ?? []).cast<String>());
        (j['channels'] as Map? ?? {}).forEach((k, v) => channels.putIfAbsent(int.parse(k), () => Channel(int.parse(k), v)));
      } catch (e) {
        debugPrint('history unreadable: $e');
      }
    }
    _nextId = messages.fold(0, (a, m) => math.max(a, m.id)) + 1;
    notifyListeners();
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), flush);
  }

  /// Writes the history now. The app calls it when it goes to the background.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final f = _file;
    if (f == null) return;
    final j = {
      'messages': [for (final m in messages.length > 5000 ? messages.sublist(messages.length - 5000) : messages) m.toJson()],
      'names': savedNames,
      'reads': lastRead,
      'flood': floodAlways.toList(),
      'channels': {for (final c in channels.values) '${c.idx}': c.name},
    };
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(j));
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('saving history: $e');
    }
  }

  void _changed() {
    _save();
    notifyListeners();
  }

  // --- queries ----------------------------------------------------------------

  int nodeNow() => nowS().floor() + clockOffset;

  List<Message> conversation(String conv) => messages.where((m) => m.conv == conv).toList();

  int unread(String conv) {
    final since = lastRead[conv] ?? 0;
    return messages.where((m) => m.conv == conv && !m.outgoing && m.at > since).length;
  }

  void markRead(String conv) {
    lastRead[conv] = nowS();
    _changed();
  }

  bool alwaysFloods(String prefixHex) => floodAlways.contains(prefixHex);

  void setAlwaysFlood(String prefixHex, bool on) {
    on ? floodAlways.add(prefixHex) : floodAlways.remove(prefixHex);
    _changed();
  }

  /// DM conversations, most recent first.
  List<String> dmConvs() {
    final last = <String, double>{};
    for (final m in messages) {
      if (!m.isChannel) last[m.conv] = m.at;
    }
    return last.keys.toList()..sort((a, b) => last[b]!.compareTo(last[a]!));
  }

  Message? lastIn(String conv) {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].conv == conv) return messages[i];
    }
    return null;
  }

  String contactName(String prefixHex) {
    final c = contacts[prefixHex];
    if (c != null && c.name.isNotEmpty) return c.name;
    return savedNames[prefixHex] ?? prefixHex.substring(0, 6);
  }

  String convTitle(String conv) {
    if (conv.startsWith('ch:')) {
      final ch = channels[int.parse(conv.substring(3))];
      return ch != null && ch.name.isNotEmpty ? ch.name : 'Channel ${conv.substring(3)}';
    }
    return contactName(conv.substring(3));
  }

  /// Who a hop hash might be. Repeaters first: they're the ones that relay.
  List<String> hopNames(String h) {
    final hb = p.unhex(h);
    final cs = contacts.values.where((c) => p.startsWith(c.key, hb)).toList()
      ..sort((a, b) => (a.type == p.advRepeater ? 0 : 1).compareTo(b.type == p.advRepeater ? 0 : 1));
    return [for (final c in cs) c.name.isNotEmpty ? c.name : p.hex(c.key.sublist(0, 3))];
  }

  double? distanceKm(p.Contact c) {
    final s = selfInfo;
    if (s == null || (s.lat == 0 && s.lon == 0) || (c.lat == 0 && c.lon == 0)) return null;
    double rad(double d) => d * math.pi / 180;
    final la1 = rad(s.lat), la2 = rad(c.lat);
    final dla = la2 - la1, dlo = rad(c.lon - s.lon);
    final a = math.pow(math.sin(dla / 2), 2) + math.cos(la1) * math.cos(la2) * math.pow(math.sin(dlo / 2), 2);
    return 6371 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  double? contactAge(p.Contact c) {
    final h = heard[c.prefixHex];
    if (h != null) return nowS() - h;
    if (c.lastMod != 0) return math.max(0, nodeNow() - c.lastMod).toDouble();
    return null;
  }

  // --- repeats ----------------------------------------------------------------

  /// Is this logged packet a copy of this message? A channel packet is
  /// decrypted and compared, which is exact. A DM can't be decrypted here, but
  /// names its two ends, and its copies share a payload.
  bool _packetIs(p.RawPacket pk, Message m) {
    if (m.isChannel) {
      if (pk.payloadType != p.payloadGrpTxt) return false;
      final ch = channels[m.channel];
      if (ch == null || ch.secret.isEmpty) return false;
      final got = p.decryptGroup(ch.secret, pk.payload);
      return got != null && got.$1 == m.wireTime && got.$2 == '${m.sender}: ${m.text}';
    }
    if (pk.payloadType != p.payloadTxtMsg || pk.payload.length < 2) return false;
    if (m.payloadKey.isNotEmpty) return p.bytesEq(pk.payload, m.payloadKey);
    final me = selfInfo?.key[0] ?? -1;
    final them = m.dmPrefix[0];
    final (dest, src) = m.outgoing ? (them, me) : (me, them);
    return pk.payload[0] == dest && pk.payload[1] == src;
  }

  /// A flood's path lists every repeater so far, in order. A direct route's
  /// lists those still to come, which says nothing about who relayed it.
  void _addCopy(Message m, p.RawPacket pk) {
    if (m.payloadKey.isEmpty) m.payloadKey = pk.payload;
    if (pk.flood && pk.hops == 0) return; // the sender's own transmission
    m.repeats++;
    if (!pk.flood) return;
    final hops = pk.path.hops();
    for (var i = 0; i < hops.length; i++) {
      final h = p.hex(hops[i]);
      final r = m.repeaters.putIfAbsent(h, () => Repeater(h));
      if (i == hops.length - 1 && (!r.direct || (r.snr != null && pk.snr > r.snr!))) {
        r.direct = true;
        r.snr = pk.snr;
      }
    }
  }

  void _claimCopies(Message m) {
    final now = nowS();
    for (final e in _rawLog) {
      if (e.claimed || now - e.at > copyClaimS || !_packetIs(e.packet, m)) continue;
      e.claimed = true;
      final pk = e.packet;
      if (m.path == null && (m.hops < 0 ? !pk.flood : (pk.flood && pk.hops == m.hops))) {
        m.path = [for (final h in pk.path.hops()) p.hex(h)];
        m.pathSize = pk.path.hashSize;
      }
      _addCopy(m, pk);
    }
  }

  void _onRaw(p.RawPacket pk) {
    final now = nowS();
    packets.add((now, pk));
    if (packets.length > 2000) packets.removeAt(0);
    for (final m in messages.reversed) {
      if (now - m.at > repeatWindowS) break;
      if (!m.live) continue;
      if (_packetIs(pk, m)) {
        _addCopy(m, pk);
        _changed();
        return;
      }
    }
    _rawLog.add(_LoggedPacket(pk, now));
    if (_rawLog.length > 64) _rawLog.removeAt(0);
    notifyListeners();
  }

  // --- frames in --------------------------------------------------------------

  Future<void> apply(p.Frame f, {bool live = true}) async {
    switch (f.kind) {
      case 'self_info':
        final newNode = selfInfo == null || !p.bytesEq(selfInfo!.key, f['key']);
        selfInfo = SelfInfo(f);
        if (newNode) await _openForNode(f['key']);
        notifyListeners();
      case 'device_info':
        deviceInfo = f;
        notifyListeners();
      case 'time':
        clockOffset = (f['time'] as int) - nowS().floor();
      case 'battery':
        batteryMv = f['mv'];
        notifyListeners();
      case 'contact':
        final p.Contact c = f['contact'];
        final known = contacts.containsKey(c.prefixHex) || savedNames.containsKey(c.prefixHex);
        contacts[c.prefixHex] = c;
        savedNames[c.prefixHex] = c.name;
        if (f['is_new'] == true) {
          heard[c.prefixHex] = nowS();
          if (!known) newContacts.add(c);
          _changed();
        } else {
          notifyListeners();
        }
      case 'contacts_end':
        _changed();
      case 'advert':
        final px = p.hex((f['key'] as Uint8List).sublist(0, p.keyPrefix));
        if (contacts.containsKey(px)) {
          heard[px] = nowS();
          notifyListeners();
        }
      case 'channel_info':
        if ((f['name'] as String).isNotEmpty || (f['secret'] as Uint8List).isNotEmpty) {
          channels[f['idx']] = Channel(f['idx'], f['name'], f['secret']);
        } else {
          channels.remove(f['idx']);
        }
        _changed();
      case 'log_rx':
        _onRaw(f['raw']);
      case 'confirmed':
        for (final m in messages) {
          // A late ack still counts, and the same ack can come more than once.
          if (m.outgoing && m.ack == f['ack'] && (m.status == MsgStatus.waiting || m.status == MsgStatus.noAck)) {
            m.status = MsgStatus.delivered;
            m.tripMs = f['trip_ms'];
            _changed();
          }
        }
      case 'message':
        _addIncoming(f['msg'], live);
    }
  }

  void _addIncoming(p.TextMessage t, bool live) {
    if (t.txtType != p.txtPlain && t.txtType != p.txtSigned) return;
    final conv = t.isChannel ? chanConv(t.channel) : dmConv(t.key);
    final sender = t.isChannel ? t.who : contactName(p.hex(t.key));
    var at = nowS();
    // Backlog: the sender's timestamp says when it really happened, if their
    // clock is anywhere near right.
    final now = nodeNow();
    if (!live && t.timestamp > clockSane && now - t.timestamp > 0 && now - t.timestamp < 30 * 86400) {
      at -= now - t.timestamp;
    }
    final m = Message(_nextId++, conv, false, sender, t.text, t.timestamp, at, hops: t.hops, snr: t.snr, live: live);
    if (live) _claimCopies(m);
    messages.add(m);
    if (!live) messages.sort((a, b) => a.at.compareTo(b.at));
    if (!t.isChannel) {
      heard[p.hex(t.key)] = at;
    } else {
      for (final c in contacts.values) {
        if (c.name == t.who) {
          heard[c.prefixHex] = at;
          break;
        }
      }
    }
    _changed();
    if (live) incoming.add(m);
  }

  final incoming = StreamController<Message>.broadcast();

  // --- outgoing ---------------------------------------------------------------

  Message addOutgoing(String conv, String text) {
    final m = Message(_nextId++, conv, true, selfInfo?.name ?? 'me', text, nodeNow(), nowS(),
        status: MsgStatus.sending, live: true);
    messages.add(m);
    _changed();
    return m;
  }

  void touch() => _changed();

  /// The node's reply to the send command.
  void sendResult(Message m, p.Frame? f) {
    if (f == null || f.kind == 'err') {
      m.status = MsgStatus.failed;
    } else if (f.kind == 'sent') {
      m.status = MsgStatus.waiting;
      m.ack = f['ack'];
      m.deadline = nowS() + (f['timeout_ms'] as int) / 1000 + 5;
    } else {
      m.status = MsgStatus.sent; // all a channel message ever gets
    }
    _changed();
  }

  void tick() {
    final now = nowS();
    var any = false;
    for (final m in messages) {
      if (m.status == MsgStatus.waiting && now > m.deadline) {
        m.status = MsgStatus.noAck;
        any = true;
      }
    }
    if (any) _changed();
  }
}
