// Drives a transport: sync on connect, then commands from the UI. The node
// answers one command at a time, with pushes (0x80 and up) mixed in at any
// moment. Ported from MeshCore Desktop's link.py.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'model.dart';
import 'protocol.dart' as p;
import 'transport.dart';

enum LinkState { idle, connecting, syncing, ready, disconnected }

class _Lock {
  Future<void> _last = Future.value();
  Future<T> run<T>(Future<T> Function() fn) {
    final prev = _last;
    final done = Completer<void>();
    _last = done.future;
    return prev.then((_) => fn()).whenComplete(done.complete);
  }
}

class Session extends ChangeNotifier {
  final Model model;
  final Transport t;
  LinkState state = LinkState.idle;
  String detail = '';
  bool connected = false;
  int maxChannels = 8;
  final _lock = _Lock();
  (Set<String>, Completer<p.Frame?>)? _waiter;
  bool _syncWanted = false;
  bool _draining = false;
  bool _backlog = false;
  Timer? _tick;
  int _ticks = 0;
  final _adminLock = _Lock();
  (bool Function(p.Frame), Completer<p.Frame?>)? _adminWaiter;
  double adminMinWait = 6; // seconds; the node's estimate can be tight for a reply

  Session(this.model, this.t) {
    t.onFrame = _frame;
    t.onDisconnect = _dropped;
  }

  void _state(LinkState s, [String d = '']) {
    state = s;
    detail = d;
    notifyListeners();
  }

  // --- frames -----------------------------------------------------------------

  void _frame(Uint8List b) {
    final f = p.decode(b);
    if (f == null) {
      debugPrint('bad frame: code ${b.isEmpty ? -1 : b[0]}, ${b.length} bytes');
      return;
    }
    if (f.kind == 'msg_waiting') {
      _syncWanted = true;
      if (state == LinkState.ready) _drain();
    } else if (f.kind == 'path_updated' && connected) {
      // A flood reached them and the node learned a route: fetch it.
      request(p.getContact(f['key']), {'contact'});
    }
    model.apply(f, live: !_backlog);
    final w = _waiter;
    if (f.code < 0x80 && w != null && (w.$1.contains(f.kind) || f.kind == 'err') && !w.$2.isCompleted) {
      w.$2.complete(f);
    }
    final a = _adminWaiter;
    if (a != null && !a.$2.isCompleted && a.$1(f)) a.$2.complete(f);
  }

  /// Sends a command and waits for its answer: one of [expect], or an error.
  /// null if nothing came.
  Future<p.Frame?> request(Uint8List frame, Set<String> expect, {Duration timeout = const Duration(seconds: 8)}) {
    return _lock.run(() async {
      if (!connected) return null;
      final c = Completer<p.Frame?>();
      _waiter = (expect, c);
      try {
        await t.write(frame);
        return await c.future.timeout(timeout, onTimeout: () {
          debugPrint('no answer to command ${frame[0]}');
          return null;
        });
      } catch (e) {
        debugPrint('write failed: $e');
        return null;
      } finally {
        _waiter = null;
      }
    });
  }

  // --- lifecycle --------------------------------------------------------------

  Future<void> start() async {
    _state(LinkState.connecting);
    model.reset();
    await t.connect();
    connected = true;
    _state(LinkState.syncing, 'node info');
    if (await request(p.appStart(), {'self_info'}) == null) {
      throw StateError("The node didn't answer");
    }
    final di = await request(p.deviceQuery(), {'device_info'});
    if (di != null && di.kind == 'device_info') maxChannels = di['max_channels'] ?? 8;
    await request(p.simple(p.cmdGetDeviceTime), {'time'});
    // Our clock is better than a node that lost power. It can only go forward.
    if (model.nodeNow() < nowS() - 30) {
      if (await request(p.setTime(nowS().floor()), {'ok'}) != null) {
        await request(p.simple(p.cmdGetDeviceTime), {'time'});
      }
    }
    await request(p.simple(p.cmdGetBattAndStorage), {'battery'});
    _state(LinkState.syncing, 'channels');
    for (var i = 0; i < maxChannels; i++) {
      await request(p.getChannel(i), {'channel_info'});
    }
    _state(LinkState.syncing, 'contacts');
    await request(p.simple(p.cmdGetContacts), {'contacts_end'}, timeout: const Duration(seconds: 60));
    _state(LinkState.syncing, 'messages');
    await _drain(backlog: true);
    _state(LinkState.ready);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      model.tick();
      if (++_ticks % 60 == 0) request(p.simple(p.cmdGetBattAndStorage), {'battery'});
    });
  }

  Future<void> _drain({bool backlog = false}) async {
    if (_draining) return;
    _draining = true;
    _backlog = backlog;
    try {
      do {
        _syncWanted = false;
        for (var i = 0; i < 500; i++) {
          final f = await request(p.simple(p.cmdSyncNextMessage), {'message', 'no_more'});
          if (f == null || f.kind != 'message') break;
        }
      } while (_syncWanted && connected);
    } finally {
      _backlog = false;
      _draining = false;
    }
  }

  void _dropped() {
    if (!connected) return;
    connected = false;
    _tick?.cancel();
    final w = _waiter;
    if (w != null && !w.$2.isCompleted) w.$2.complete(null);
    _state(LinkState.disconnected, 'link dropped');
  }

  Future<void> stop() async {
    connected = false;
    _tick?.cancel();
    await t.close();
    _state(LinkState.disconnected);
  }

  // --- commands ---------------------------------------------------------------

  Future<Message> send(String conv, String text) async {
    final m = model.addOutgoing(conv, text);
    await _send(m);
    return m;
  }

  Future<void> resend(Message m) async {
    m.wireTime = model.nodeNow();
    m.status = MsgStatus.sending;
    m.repeats = 0;
    m.repeaters = {};
    m.at = nowS();
    m.live = true;
    m.payloadKey = Uint8List(0);
    model.touch();
    await _send(m);
  }

  Future<void> _send(Message m) async {
    p.Frame? f;
    if (m.isChannel) {
      f = await request(p.sendChannel(m.channel, m.wireTime, m.text), {'ok'});
    } else {
      final c = model.contacts[p.hex(m.dmPrefix)];
      if (c != null && model.alwaysFloods(c.prefixHex)) {
        // The last reply will have taught the node a route; forget it so this one floods too.
        await resetPath(c.key);
      }
      f = await request(p.sendDirect(m.dmPrefix, m.wireTime, m.text), {'sent'});
    }
    model.sendResult(m, f);
  }

  // --- repeater admin -----------------------------------------------------------

  /// Sends a request to a remote node and waits for its answer. The node tracks
  /// one such request at a time, so they run one after another. Gives the
  /// answer, the node's "err" frame, or null if nothing came back in time.
  Future<p.Frame?> _admin(Uint8List frame, bool Function(p.Frame) done) {
    return _adminLock.run(() async {
      // Set before sending, so a fast answer can't slip past.
      final c = Completer<p.Frame?>();
      _adminWaiter = (done, c);
      try {
        final sent = await request(frame, {'sent'});
        if (sent == null || sent.kind == 'err') return sent;
        final ms = (sent['timeout_ms'] as int) + 3000;
        final wait = ms / 1000 > adminMinWait ? ms / 1000 : adminMinWait;
        return await c.future.timeout(Duration(milliseconds: (wait * 1000).round()), onTimeout: () => null);
      } finally {
        _adminWaiter = null;
      }
    });
  }

  bool _from(p.Frame f, Uint8List prefix) => p.bytesEq(f['prefix'] as Uint8List, prefix);

  Future<p.Frame?> login(Uint8List key, String password) {
    final prefix = key.sublist(0, p.keyPrefix);
    return _admin(p.login(key, password), (f) => (f.kind == 'login_ok' || f.kind == 'login_fail') && _from(f, prefix));
  }

  Future<p.Frame?> repeaterStatus(Uint8List key) {
    final prefix = key.sublist(0, p.keyPrefix);
    return _admin(p.statusReq(key), (f) => f.kind == 'status' && _from(f, prefix));
  }

  Future<p.Frame?> cli(Uint8List key, String command) {
    final prefix = key.sublist(0, p.keyPrefix);
    return _admin(p.sendCli(prefix, model.nodeNow(), command), (f) {
      if (f.kind != 'message') return false;
      final m = f['msg'] as p.TextMessage;
      return m.txtType == p.txtCli && !m.isChannel && p.bytesEq(m.key, prefix);
    });
  }

  Future<p.Frame?> advert(bool flood) => request(p.sendAdvert(flood), {'ok'});

  /// Forgets the node's stored route to a contact, so the next message to
  /// them floods and the reply teaches the node a fresh one.
  Future<p.Frame?> resetPath(Uint8List key) async {
    final f = await request(p.resetPath(key), {'ok'});
    if (f != null && f.kind == 'ok') await request(p.getContact(key), {'contact'});
    return f;
  }

  Future<p.Frame?> setChannel(int idx, String name, Uint8List secret) async {
    final f = await request(p.setChannel(idx, name, secret), {'ok'});
    await request(p.getChannel(idx), {'channel_info'});
    return f;
  }
}
