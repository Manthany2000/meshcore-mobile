// MeshCore companion protocol: one binary frame per BLE write or notification,
// first byte is the code. Ported from MeshCore Desktop's protocol.py
// (firmware protocol v14).
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const rxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // we write
const txUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // it notifies

const passwordMax = 15;
const textMax = 160; // MAX_TEXT_LEN; for channels it includes "name: "
const keyPrefix = 6;

// Commands, app to node.
const cmdAppStart = 1;
const cmdSendTxtMsg = 2;
const cmdSendChannelTxtMsg = 3;
const cmdGetContacts = 4;
const cmdGetDeviceTime = 5;
const cmdSetDeviceTime = 6;
const cmdSendSelfAdvert = 7;
const cmdSyncNextMessage = 10;
const cmdResetPath = 13;
const cmdGetBattAndStorage = 20;
const cmdDeviceQuery = 22;
const cmdGetContactByKey = 30;
const cmdGetChannel = 31;
const cmdSetChannel = 32;

// Replies and pushes, node to app.
const respOk = 0;
const respErr = 1;
const respContactsStart = 2;
const respContact = 3;
const respEndOfContacts = 4;
const respSelfInfo = 5;
const respSent = 6;
const respContactMsg = 7;
const respChannelMsg = 8;
const respCurrTime = 9;
const respNoMoreMessages = 10;
const respBatt = 12;
const respDeviceInfo = 13;
const respContactMsgV3 = 16;
const respChannelMsgV3 = 17;
const respChannelInfo = 18;
const pushAdvert = 0x80;
const pushPathUpdated = 0x81;
const pushSendConfirmed = 0x82;
const pushMsgWaiting = 0x83;
const pushLogRx = 0x88;
const pushNewAdvert = 0x8A;

const advChat = 1, advRepeater = 2, advRoom = 3, advSensor = 4;
const txtPlain = 0, txtCli = 1, txtSigned = 2;
const payloadTxtMsg = 2, payloadGrpTxt = 5;

const errNames = {
  1: 'unsupported',
  2: 'not found',
  3: 'table full',
  4: 'bad state',
  5: 'file error',
  6: 'illegal argument',
};

/// The scale the node's own screen uses: straight line, 3.0 V to 4.2 V.
int battPercent(int mv) => ((mv - 3000) * 100 ~/ 1200).clamp(0, 100);

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) =>
    Uint8List.fromList([for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

bool bytesEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool startsWith(List<int> a, List<int> prefix) =>
    a.length >= prefix.length && bytesEq(a.sublist(0, prefix.length), prefix);

int _u32(Uint8List b, int at) => ByteData.sublistView(b).getUint32(at, Endian.little);
int _i32(Uint8List b, int at) => ByteData.sublistView(b).getInt32(at, Endian.little);
int _i8(Uint8List b, int at) => ByteData.sublistView(b).getInt8(at);

String cstr(List<int> b) {
  final z = b.indexOf(0);
  return utf8.decode(z < 0 ? b : b.sublist(0, z), allowMalformed: true);
}

Uint8List _sub(Uint8List b, int start, [int? end]) {
  final e = end == null ? b.length : (end > b.length ? b.length : end);
  return start >= e ? Uint8List(0) : Uint8List.fromList(b.sublist(start, e));
}

/// Each hop is the first hashSize bytes of a repeater's key.
class HopList {
  final int hashSize;
  final Uint8List data;
  HopList([this.hashSize = 1, Uint8List? data]) : data = data ?? Uint8List(0);

  List<Uint8List> hops() => [
        for (var i = 0; i + hashSize <= data.length; i += hashSize) _sub(data, i, i + hashSize),
      ];
}

/// Low 6 bits count the hops, top 2 give the hash size. 0xFF: direct/unknown.
int hopsFromPathLen(int pathLen) => pathLen == 0xFF ? -1 : pathLen & 63;

HopList _path(int pathLen, Uint8List src) {
  final size = (pathLen >> 6) + 1;
  return HopList(size, _sub(src, 0, (pathLen & 63) * size));
}

/// One packet the node's radio heard, from PUSH_LOG_RX.
class RawPacket {
  final int payloadType;
  final bool flood;
  final int hops;
  final HopList path;
  final Uint8List payload;
  final double snr;
  final int rssi;
  RawPacket(this.payloadType, this.flood, this.hops, this.path, this.payload, this.snr, this.rssi);
}

class Contact {
  final Uint8List key; // full 32-byte public key
  final int type;
  final int hops; // -1 = no known path
  final HopList path;
  final String name;
  final int lastAdvert;
  final double lat, lon;
  final int lastMod;
  final int flags;
  Contact({
    required this.key,
    required this.type,
    required this.hops,
    required this.path,
    required this.name,
    required this.lastAdvert,
    required this.lat,
    required this.lon,
    required this.lastMod,
    this.flags = 0,
  });

  String get prefixHex => hex(key.sublist(0, keyPrefix));
  Uint8List get prefix => _sub(key, 0, keyPrefix);
}

class TextMessage {
  final bool isChannel;
  final int channel;
  final Uint8List key; // DMs: sender's 6-byte prefix
  final int txtType;
  final int hops;
  final double? snr;
  final int timestamp; // by the sender's clock
  final String who; // channel messages: the name the text started with
  final String text;
  TextMessage({
    required this.isChannel,
    this.channel = 0,
    Uint8List? key,
    this.txtType = txtPlain,
    this.hops = -1,
    this.snr,
    this.timestamp = 0,
    this.who = '',
    this.text = '',
  }) : key = key ?? Uint8List(0);
}

/// A decoded frame. [kind] names it; [d] holds its fields.
class Frame {
  final int code;
  final String kind;
  final Map<String, dynamic> d;
  Frame(this.code, this.kind, [Map<String, dynamic>? d]) : d = d ?? {};
  dynamic operator [](String k) => d[k];
}

RawPacket? _decodeLogRx(Uint8List b) {
  if (b.length < 5) return null;
  final snr = _i8(b, 1) / 4.0;
  final rssi = _i8(b, 2);
  final header = b[3];
  final route = header & 3;
  final ptype = (header >> 2) & 15;
  var at = 4 + ((route == 0 || route == 3) ? 4 : 0);
  if (at >= b.length) return null;
  final pathLen = b[at++];
  if (pathLen >> 6 == 3) return null;
  final n = (pathLen & 63) * ((pathLen >> 6) + 1);
  if (at + n >= b.length) return null;
  return RawPacket(ptype, route == 0 || route == 1, pathLen & 63, _path(pathLen, _sub(b, at, at + n)),
      _sub(b, at + n), snr, rssi);
}

const contactLen = 148;

Contact _decodeContact(Uint8List b) {
  final pl = b[35];
  return Contact(
    key: _sub(b, 1, 33),
    type: b[33],
    flags: b[34],
    hops: hopsFromPathLen(pl),
    path: pl != 0xFF ? _path(pl, _sub(b, 36, 100)) : HopList(),
    name: cstr(_sub(b, 100, 132)),
    lastAdvert: _u32(b, 132),
    lat: _i32(b, 136) / 1e6,
    lon: _i32(b, 140) / 1e6,
    lastMod: _u32(b, 144),
  );
}

TextMessage? _decodeContactMsg(Uint8List b, double? snr) {
  if (b.length < 12) return null;
  final t = b[7];
  final at = t == txtSigned ? 16 : 12;
  if (b.length < at) return null;
  return TextMessage(
      isChannel: false,
      key: _sub(b, 0, 6),
      hops: hopsFromPathLen(b[6]),
      txtType: t,
      timestamp: _u32(b, 8),
      text: cstr(_sub(b, at)),
      snr: snr);
}

TextMessage? _decodeChannelMsg(Uint8List b, double? snr) {
  if (b.length < 7) return null;
  final whole = cstr(_sub(b, 7));
  var who = '', text = whole;
  final i = whole.indexOf(': ');
  if (i >= 0 && i <= 31) {
    who = whole.substring(0, i);
    text = whole.substring(i + 2);
  }
  return TextMessage(
      isChannel: true,
      channel: b[0],
      hops: hopsFromPathLen(b[1]),
      txtType: b[2],
      timestamp: _u32(b, 3),
      who: who,
      text: text,
      snr: snr);
}

/// null if it's too short for its code. Unknown codes give kind 'other'.
Frame? decode(Uint8List b) {
  if (b.isEmpty) return null;
  final c = b[0];
  final n = b.length;
  Frame f(String kind, [Map<String, dynamic>? d]) => Frame(c, kind, d);
  switch (c) {
    case respOk:
      return f('ok', {'value': n >= 5 ? _u32(b, 1) : 0});
    case respErr:
      return f('err', {'err': n > 1 ? b[1] : 0});
    case respContactsStart:
      return n >= 5 ? f('contacts_start', {'count': _u32(b, 1)}) : null;
    case respContact:
    case pushNewAdvert:
      return n >= contactLen ? f('contact', {'contact': _decodeContact(b), 'is_new': c == pushNewAdvert}) : null;
    case respEndOfContacts:
      return f('contacts_end', {'since': n >= 5 ? _u32(b, 1) : 0});
    case respSelfInfo:
      if (n < 58) return null;
      return f('self_info', {
        'key': _sub(b, 4, 36),
        'tx_power': b[2],
        'max_tx': b[3],
        'lat': _i32(b, 36) / 1e6,
        'lon': _i32(b, 40) / 1e6,
        'freq': _u32(b, 48) / 1000,
        'bw': _u32(b, 52) / 1000,
        'sf': b[56],
        'cr': b[57],
        'name': cstr(_sub(b, 58)),
      });
    case respCurrTime:
      return n >= 5 ? f('time', {'time': _u32(b, 1)}) : null;
    case respNoMoreMessages:
      return f('no_more');
    case respBatt:
      return n >= 3 ? f('battery', {'mv': b[1] | b[2] << 8}) : null;
    case respDeviceInfo:
      if (n < 2) return null;
      return f('device_info', {
        'protocol': b[1],
        'max_contacts': n > 2 ? b[2] * 2 : 0,
        'max_channels': n > 3 ? b[3] : 8,
        'build': n >= 20 ? cstr(_sub(b, 8, 20)) : '',
        'model': n >= 60 ? cstr(_sub(b, 20, 60)) : '',
        'fw': n >= 61 ? cstr(_sub(b, 60, 80)) : '',
      });
    case respContactMsg:
    case respChannelMsg:
    case respContactMsgV3:
    case respChannelMsgV3:
      // V3 adds snr*4 and 2 reserved bytes. Messages the node queued while no
      // app was connected stay in the old format.
      final v3 = c == respContactMsgV3 || c == respChannelMsgV3;
      if (v3 && n < 4) return null;
      final snr = v3 ? _i8(b, 1) / 4.0 : null;
      final body = _sub(b, v3 ? 4 : 1);
      final isChan = c == respChannelMsg || c == respChannelMsgV3;
      final m = isChan ? _decodeChannelMsg(body, snr) : _decodeContactMsg(body, snr);
      return m == null ? null : f('message', {'msg': m});
    case respChannelInfo:
      if (n < 34) return null;
      final secret = n >= 50 ? _sub(b, 34, 50) : Uint8List(0);
      return f('channel_info', {
        'idx': b[1],
        'name': cstr(_sub(b, 2, 34)),
        'secret': secret.any((x) => x != 0) ? secret : Uint8List(0),
      });
    case respSent:
      return n >= 10 ? f('sent', {'flood': b[1] != 0, 'ack': _u32(b, 2), 'timeout_ms': _u32(b, 6)}) : null;
    case pushSendConfirmed:
      return n >= 9 ? f('confirmed', {'ack': _u32(b, 1), 'trip_ms': _u32(b, 5)}) : null;
    case pushMsgWaiting:
      return f('msg_waiting');
    case pushAdvert:
      return n >= 7 ? f('advert', {'key': _sub(b, 1, 33)}) : null;
    case pushPathUpdated:
      return n >= 33 ? f('path_updated', {'key': _sub(b, 1, 33)}) : null;
    case pushLogRx:
      final r = _decodeLogRx(b);
      return r != null ? f('log_rx', {'raw': r}) : f('other'); // odd packets on the air aren't an error
  }
  return f('other');
}

// --- encoders -----------------------------------------------------------------

Uint8List _cat(List<List<int>> parts) => Uint8List.fromList([for (final p in parts) ...p]);

Uint8List _le32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v & 0xFFFFFFFF, Endian.little);

Uint8List _fixed(String s, int len) {
  final e = utf8.encode(s);
  final out = Uint8List(len);
  out.setRange(0, e.length > len - 1 ? len - 1 : e.length, e);
  return out;
}

Uint8List appStart([String name = 'MeshCore Mobile']) => _cat([
      [cmdAppStart],
      List.filled(7, 0),
      utf8.encode(name)
    ]);

Uint8List deviceQuery() => Uint8List.fromList([cmdDeviceQuery, 3]); // asks for V3 message frames

Uint8List getChannel(int idx) => Uint8List.fromList([cmdGetChannel, idx]);

Uint8List setChannel(int idx, String name, List<int> secret) {
  final s = Uint8List(16)..setRange(0, secret.length.clamp(0, 16), secret);
  return _cat([
    [cmdSetChannel, idx],
    _fixed(name, 32),
    s
  ]);
}

Uint8List sendChannel(int channel, int ts, String text) => _cat([
      [cmdSendChannelTxtMsg, txtPlain, channel],
      _le32(ts),
      utf8.encode(text)
    ]);

Uint8List sendDirect(List<int> prefix, int ts, String text, [int attempt = 0]) => _cat([
      [cmdSendTxtMsg, txtPlain, attempt],
      _le32(ts),
      prefix.sublist(0, keyPrefix),
      utf8.encode(text)
    ]);

Uint8List setTime(int ts) => _cat([
      [cmdSetDeviceTime],
      _le32(ts)
    ]);

Uint8List sendAdvert(bool flood) => Uint8List.fromList([cmdSendSelfAdvert, flood ? 1 : 0]);

Uint8List resetPath(List<int> key) => _cat([
      [cmdResetPath],
      key.sublist(0, 32)
    ]);

Uint8List getContact(List<int> key) => _cat([
      [cmdGetContactByKey],
      key.sublist(0, 32)
    ]);

Uint8List simple(int cmd) => Uint8List.fromList([cmd]);

// --- channel packets ------------------------------------------------------------

Uint8List _aes(Uint8List secret, Uint8List data, bool encrypt) {
  final c = ECBBlockCipher(AESEngine())..init(encrypt, KeyParameter(_sub(secret, 0, 16)));
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i += 16) {
    c.processBlock(data, i, out, i);
  }
  return out;
}

/// A GRP_TXT payload: channel hash, 2-byte MAC, AES-128-ECB blocks of
/// timestamp, type byte, "sender: text". null if it isn't whole blocks.
(int, String)? decryptGroup(Uint8List secret, Uint8List payload) {
  if (secret.isEmpty || payload.length <= 3) return null;
  final cipher = _sub(payload, 3);
  if (cipher.length % 16 != 0) return null;
  final plain = _aes(secret, cipher, false);
  return (_u32(plain, 0), cstr(_sub(plain, 5)));
}

/// The inverse, for the simulator and tests. Channel hash and MAC are fake.
Uint8List encryptGroup(Uint8List secret, int ts, String who, String text) {
  var plain = _cat([_le32(ts), [0], utf8.encode('$who: $text')]);
  final pad = (16 - plain.length % 16) % 16;
  plain = _cat([plain, List.filled(pad, 0)]);
  return _cat([
    [0x11, 0x22, 0x33],
    _aes(secret, plain, true)
  ]);
}
