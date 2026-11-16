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
  int protocol = 0; // the node's FIRMWARE_VER_CODE
  final _lock = _Lock();
  final _scopeLock = _Lock();
  String? _scopeNow; // the override set on the node: "", noScope, a region; null: unknown
  Duration writeTimeout = const Duration(seconds: 10); // a write stuck longer means the link is dead
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
  /// null if nothing came, the write failed, or the link is down. Never hangs:
  /// a write that doesn't finish drops the link, so the app reconnects.
  Future<p.Frame?> request(Uint8List frame, Set<String> expect, {Duration timeout = const Duration(seconds: 8)}) {
    return _lock.run(() async {
      if (!connected) return null;
      final c = Completer<p.Frame?>();
      _waiter = (expect, c);
      try {
        try {
          await t.write(frame).timeout(writeTimeout);
        } on TimeoutException {
          debugPrint('write of command ${frame[0]} stuck: dropping the link');
          _linkLost('node stopped responding');
          return null;
        }
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
    await t.connect();
    // Only now: a reconnect can wait a long time for the node, and the last
    // contacts stay on screen meanwhile.
    model.reset();
    connected = true;
    _state(LinkState.syncing, 'node info');
    if (await request(p.appStart(), {'self_info'}) == null) {
      throw StateError("The node didn't answer");
    }
    final di = await request(p.deviceQuery(), {'device_info'});
    if (di != null && di.kind == 'device_info') {
      maxChannels = di['max_channels'] ?? 8;
      protocol = di['protocol'] ?? 0;
    }
    _scopeNow = null;
    if (scopes) {
      // Another app may have left a scope set: start from the node's default.
      await _setScope('');
      await request(p.simple(p.cmdGetDefaultFloodScope), {'default_scope'});
    }
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

  void _dropped([String why = 'link dropped']) {
    if (!connected) return;
    connected = false;
    _tick?.cancel();
    final w = _waiter;
    if (w != null && !w.$2.isCompleted) w.$2.complete(null);
    _state(LinkState.disconnected, why);
  }

  /// The transport still says it's up but has stopped working: drop it
  /// ourselves so pending commands end and the app reconnects.
  void _linkLost(String why) {
    _dropped(why);
    t.close().timeout(const Duration(seconds: 10)).catchError((e) => debugPrint('closing the dead link: $e'));
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
      f = await scoped(model.channelScope(m.channel), p.sendChannel(m.channel, m.wireTime, m.text), {'ok'});
    } else {
      final c = model.contacts[p.hex(m.dmPrefix)];
      if (c != null && model.alwaysFloods(c.prefixHex)) {
        // The last reply will have taught the node a route; forget it so this one floods too.
        await resetPath(c.key);
      }
      f = await scoped('', p.sendDirect(m.dmPrefix, m.wireTime, m.text), {'sent'});
    }
    model.sendResult(m, f);
  }

  // --- flood scopes ---------------------------------------------------------------

  /// The node can scope floods to a region (protocol v8+).
  bool get scopes => protocol >= 8;

  /// It can also send floods with no scope when it has a default (v12+).
  bool get unscoped => protocol >= 12;

  Future<p.Frame?> _setScope(String scope) async {
    final f = await request(p.setFloodScope(scope == noScope ? null : scope), {'ok'});
    _scopeNow = f != null && f.kind == 'ok' ? scope : null;
    return f;
  }

  /// Sends a command whose floods go out with this scope: "" for the node's
  /// default, [noScope] for none, or a region. If the node can't take a scope
  /// we asked for, the command isn't sent: that gives the node's error.
  Future<p.Frame?> scoped(String scope, Uint8List frame, Set<String> expect, {Duration timeout = const Duration(seconds: 8)}) {
    return _scopeLock.run(() async {
      if (scopes && scope != _scopeNow) {
        final f = await _setScope(scope);
        if ((f == null || f.kind != 'ok') && scope.isNotEmpty) return f;
      } else if (scope.isNotEmpty && !scopes) {
        return p.Frame(p.respErr, 'err', {'err': 1}); // unsupported
      }
      return request(frame, expect, timeout: timeout);
    });
  }

  /// Saved on the node. Floods use it unless a channel says otherwise.
  Future<p.Frame?> setDefaultScope(String name) async {
    final f = await request(p.setDefaultScope(name), {'ok'});
    await request(p.simple(p.cmdGetDefaultFloodScope), {'default_scope'});
    return f;
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
        final sent = await scoped('', frame, {'sent'});
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

  /// Makes sure the node has this contact saved. With auto-add off, the node
  /// tells us about adverts it hears without keeping them, so they show here
  /// but anything sent to them fails with "not found". Gives the node's answer
  /// ("contact" if it had it, "ok" once added), or an "err"/null.
  Future<p.Frame?> ensureContact(Uint8List key) async {
    final f = await request(p.getContact(key), {'contact'});
    if (f == null || f.kind == 'contact') return f;
    final c = model.contacts[p.hex(key.sublist(0, p.keyPrefix))];
    if (c == null || c.key.length < 32) return f;
    return request(p.addContact(c), {'ok'});
  }

  Future<p.Frame?> login(Uint8List key, String password) async {
    final prefix = key.sublist(0, p.keyPrefix);
    final have = await ensureContact(key);
    if (have != null && have.kind == 'err') return have;
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

  /// The node restarts straight away and never answers. The link drops and
  /// the usual reconnect picks it up again.
  Future<void> reboot() => _lock.run(() async {
        try {
          await t.write(p.reboot()).timeout(writeTimeout);
        } catch (e) {
          debugPrint('reboot: $e');
        }
      });

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
