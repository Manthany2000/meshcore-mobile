import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_mobile/src/model.dart';
import 'package:meshcore_mobile/src/protocol.dart' as p;
import 'package:meshcore_mobile/src/session.dart';
import 'package:meshcore_mobile/src/setup.dart';
import 'package:meshcore_mobile/src/sim.dart';

void main() {
  // Vectors from MeshCore Desktop's protocol.py, so both apps agree byte for byte.
  group('protocol matches desktop', () {
    final secret = p.unhex('9cd8fcf22a47333b591d96a2b848b73f');

    test('hashtag secret', () => expect(p.hex(hashtagSecret('#test')), p.hex(secret)));

    test('encrypt group', () {
      expect(p.hex(p.encryptGroup(secret, 1762800000, 'alice', 'hello mesh')),
          '1122334e155a4771570530bad13521a346249f50100a982018ba02b14d314451d481bc');
    });

    test('decrypt group', () {
      final got = p.decryptGroup(secret, p.unhex('1122334e155a4771570530bad13521a346249f50100a982018ba02b14d314451d481bc'));
      expect(got, (1762800000, 'alice: hello mesh'));
    });

    test('send direct', () {
      expect(p.hex(p.sendDirect([0, 1, 2, 3, 4, 5], 1762800000, 'hi')), '020000803112690001020304056869');
    });

    test('set channel', () {
      expect(p.hex(p.setChannel(3, '#test', secret)),
          '200323746573740000000000000000000000000000000000000000000000000000009cd8fcf22a47333b591d96a2b848b73f');
    });

    test('login', () {
      expect(p.hex(p.login(List.generate(32, (i) => i), 'secretpass')),
          '1a000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f73656372657470617373');
    });

    test('cli', () {
      expect(p.hex(p.sendCli([0, 1, 2, 3, 4, 5], 1762800000, 'get name')), '02010080311269000102030405676574206e616d65');
    });

    test('repeater status', () {
      final f = p.decode(Uint8List.fromList([0x87, 0, 0, 1, 2, 3, 4, 5,
        ...p.unhex('930f010090ffb9ff55bc00007555000032070000b94a060050460000250f0000409c00001520000002001a000f00a2030014000003000000')]))!;
      expect(f.kind, 'status');
      expect(f['stats'], {
        'batt_mv': 3987, 'tx_queue': 1, 'noise_floor': -112, 'last_rssi': -71, 'recv': 48213, 'sent': 21877,
        'air_secs': 1842, 'up_secs': 412345, 'sent_flood': 18000, 'sent_direct': 3877, 'recv_flood': 40000,
        'recv_direct': 8213, 'errors': 2, 'last_snr': 6.5, 'direct_dups': 15, 'flood_dups': 930, 'rx_air_secs': 5120,
        'recv_errors': 3,
      });
    });

    test('channel message split', () {
      final f = p.decode(Uint8List.fromList([p.respChannelMsgV3, 26, 0, 0, 1, 2, 0, 0, 0, 0, 0, ...'bob: hi: there'.codeUnits]))!;
      final m = f['msg'] as p.TextMessage;
      expect((m.who, m.text, m.hops, m.snr, m.channel), ('bob', 'hi: there', 2, 6.5, 1));
    });

    test('flood scopes', () {
      expect(p.hex(p.setFloodScope('boston')), '36009587d847a7208da684c89cc1f525bc03');
      expect(p.hex(p.setFloodScope('#boston')), '36009587d847a7208da684c89cc1f525bc03');
      expect((p.hex(p.setFloodScope(null)), p.hex(p.setFloodScope(''))), ('3601', '3600'));
      expect(p.hex(p.setDefaultScope('#boston')),
          '3f626f73746f6e000000000000000000000000000000000000000000000000009587d847a7208da684c89cc1f525bc03');
      expect(p.hex(p.setDefaultScope('')), '3f');
    });

    test('node settings', () {
      expect(p.hex(p.setRadio(910.525, 62.5, 7, 5)), '0bbde40d0024f400000705');
      expect(p.hex(p.setLatLon(42.3601, -71.0589)), '0e245d86022cbac3fb');
      expect(p.hex(p.setPin(123456)), '2540e20100');
      expect(p.hex(p.setOtherParams(1, 0x16, 1, 1)), '2601160101');
      expect(p.hex(p.setTxPower(-3)), '0cfd');
      expect(p.hex(p.setName('kestrel-mobile')), '086b65737472656c2d6d6f62696c65');
      expect(p.hex(p.setPathHashMode(1)), '3d0001');
      expect(p.hex(p.reboot()), '137265626f6f74');
    });

    test('add contact', () {
      final c = p.Contact(
          key: Uint8List.fromList(List.generate(32, (i) => i)),
          type: 2,
          hops: -1,
          path: p.HopList(),
          name: 'Ridge',
          lastAdvert: 1762800000,
          lat: 42.36,
          lon: -71.2,
          lastMod: 0);
      expect(
          p.hex(p.addContact(c)),
          '09000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0200ff${'00' * 64}'
          '526964676500000000000000000000000000000000000000000000000000000080311269c05c86020093c1fb');
    });

    test('region tree', () {
      final r = p.parseRegions('*\n usa F\n  ma^ F\n   boston F\n eu\n');
      expect([for (final x in r) (x.name, x.depth, x.flood, x.home, x.parent)], [
        ('*', 0, false, false, null),
        ('usa', 1, true, false, '*'),
        ('ma', 2, true, true, 'usa'),
        ('boston', 3, true, false, 'ma'),
        ('eu', 1, false, false, '*'),
      ]);
      expect(p.parseRegions('Unknown command'), isEmpty);
    });

    test('region names', () {
      expect([for (final x in ['', 'boston', 'a b', 'x' * 30, '#ok-1\$']) p.regionProblem(x)], [
        'Enter a region name.',
        null,
        "Region names can't have ' '.",
        'Region names can be at most 29 bytes.',
        null,
      ]);
    });

    test('setup helpers', () {
      expect(telemetryByte({'base': 2, 'location': 1}, 0xC0 | (1 << 4)), 214);
      expect(telemetryModesOf(0x16), {'base': 2, 'location': 1, 'environment': 1});
      expect(parseHashtags('#Local, emergency;  #local foo'), ['#local', '#emergency', '#foo']);
      expect(findPreset(910.525, 62.5, 7, 5, 3)!.title, 'Canada');
      expect(findPreset(910.525, 62.5, 7, 5, 1)!.title, 'USA');
      expect(parseLatLon('42.3601, -71.0589'), (42.3601, -71.0589));
      expect(parseLatLon(''), isNull);
      expect(() => parseLatLon('91 0'), throwsFormatException);
    });
  });

  group('session against the simulator', () {
    late Directory dir;
    late Model model;
    late SimTransport t;
    late Session s;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mcm');
      model = Model(dataDir: () async => dir);
      t = SimTransport();
      s = Session(model, t);
      await s.start();
    });

    tearDown(() async {
      await s.stop();
      await model.flush();
      await dir.delete(recursive: true);
    });

    test('syncs node, channels, contacts and backlog', () {
      expect(s.state, LinkState.ready);
      expect(model.selfInfo!.name, 'SimNode');
      expect(model.channels.keys, containsAll([0, 1]));
      expect(model.contacts.length, 9);
      expect(model.batteryMv, greaterThan(3000));
      final backlog = model.messages.where((m) => !m.outgoing).toList();
      expect(backlog.map((m) => m.text), containsAll(['morning all', 'you around later?']));
      // Backdated by the sender's timestamp.
      expect(backlog.first.at, lessThan(nowS() - 600));
      // The clock was behind and got set.
      expect((model.nodeNow() - nowS()).abs(), lessThan(5));
    });

    test('channel send goes out and collects repeats', () async {
      final m = await s.send(chanConv(0), 'hello from the test');
      expect(m.status, MsgStatus.sent);
      await Future.delayed(const Duration(seconds: 12));
      expect(m.repeats, greaterThan(0));
      expect(m.repeaters, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('DM is acked or times out', () async {
      final alice = model.contacts.values.firstWhere((c) => c.name == 'alice');
      final m = await s.send(dmConv(alice.key), 'hi alice');
      expect(m.status, MsgStatus.waiting);
      await Future.delayed(const Duration(seconds: 12));
      expect(m.status, anyOf(MsgStatus.delivered, MsgStatus.noAck));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('repeater login, status and CLI', () async {
      final ridge = model.contacts.values.firstWhere((c) => c.name == 'Ridge Repeater');
      expect((await s.login(ridge.key, 'wrong'))!.kind, 'login_fail');
      final ok = (await s.login(ridge.key, 'admin'))!;
      expect((ok.kind, ok['is_admin']), ('login_ok', true));
      final st = (await s.repeaterStatus(ridge.key))!;
      expect(st['stats']['batt_mv'], greaterThan(3800));
      final r = (await s.cli(ridge.key, 'get name'))!;
      expect((r['msg'] as p.TextMessage).text, '> Ridge Repeater');
      // CLI replies aren't conversation.
      expect(model.messages.where((m) => m.text.contains('Ridge Repeater')), isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('mesh links and stats', () async {
      final (w, l) = model.meshLinks();
      expect(w['me'], greaterThan(0));
      expect(l, isNotEmpty);
    });

    test('history survives a restart', () async {
      await s.send(chanConv(0), 'keep me');
      await model.flush();
      final again = Model(dataDir: () async => dir);
      await again.apply(p.Frame(p.respSelfInfo, 'self_info', {
        'key': model.selfInfo!.key,
        'name': 'SimNode',
        'lat': 0.0,
        'lon': 0.0,
        'freq': 0.0,
        'bw': 0.0,
        'sf': 0,
        'cr': 0,
        'tx_power': 0,
        'max_tx': 0,
      }));
      expect(again.messages.map((m) => m.text), contains('keep me'));
    });

    test('channel and default flood scopes', () async {
      expect(s.scopes, isTrue);
      expect(model.defaultScope, '');
      model.setChannelScope(1, 'boston');
      expect((await s.send(chanConv(1), 'scoped')).status, MsgStatus.sent);
      expect(p.hex(t.sim.sentScopes.last!), p.hex(p.regionKey('boston')));
      expect((await s.setDefaultScope('ma'))!.kind, 'ok');
      expect(model.defaultScope, 'ma');
      await s.send(chanConv(0), 'default');
      expect(p.hex(t.sim.sentScopes.last!), p.hex(p.regionKey('ma')));
      model.setChannelScope(0, noScope);
      await s.send(chanConv(0), 'none');
      expect(t.sim.sentScopes.last, isNull);
      // Kept with the history, by channel name.
      await model.flush();
      final again = Model(dataDir: () async => dir);
      await again.apply(p.Frame(p.respSelfInfo, 'self_info', {
        'key': model.selfInfo!.key, 'name': 'SimNode', 'lat': 0.0, 'lon': 0.0, 'freq': 0.0, 'bw': 0.0,
        'sf': 0, 'cr': 0, 'tx_power': 0, 'max_tx': 0,
      }));
      expect(again.channelScopes[1], ('#test', 'boston'));
    });

    test('node settings go to the node and come back', () async {
      final plan = Plan()
        ..name = 'kestrel'
        ..location = (42.3601, -71.0589)
        ..shareLocation = true
        ..telemetry = telemetryByte({'base': 2})
        ..radio = (869.618, 62.5, 8, 8)
        ..txPower = 14
        ..hashSize = 2
        ..pin = 123456
        ..channels = [('#local', hashtagSecret('#local'))];
      final steps = <String>[];
      final ok = await applyPlan(s, plan, (text, good, why) {
        if (good != null) steps.add('$text:$good');
      });
      expect(ok, isTrue, reason: steps.join(', '));
      final si = model.selfInfo!;
      expect((si.name, si.lat, si.lon, si.locPolicy, si.telemetry & 3, si.sf, si.cr, si.txPower),
          ('kestrel', 42.3601, -71.0589, 1, 2, 8, 8, 14));
      expect(si.freq, closeTo(869.618, 1e-6));
      expect((model.deviceInfo!['ble_pin'], model.deviceInfo!['path_hash_mode']), (123456, 1));
      expect(model.channels.values.map((c) => c.name), contains('#local'));
      expect(isFresh(si), isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('repeater regions over the CLI', () async {
      final ridge = model.contacts.values.firstWhere((c) => c.name == 'Ridge Repeater');
      await s.login(ridge.key, 'admin');
      Future<String> run(String cmd) async => ((await s.cli(ridge.key, cmd))!['msg'] as p.TextMessage).text;
      var tree = p.parseRegions(await run('region'));
      expect(tree.map((x) => x.name), ['*', 'usa', 'ma', 'boston']);
      expect(tree.firstWhere((x) => x.home).name, 'ma');
      expect(await run('region put cambridge ma'), startsWith('OK'));
      expect(await run('region denyf boston'), 'OK');
      expect(await run('region default usa'), ' default scope is now usa');
      tree = p.parseRegions(await run('region'));
      expect(tree.firstWhere((x) => x.name == 'cambridge').parent, 'ma');
      expect(tree.firstWhere((x) => x.name == 'boston').flood, isFalse);
      expect(await run('get flood.max.unscoped'), '> 64');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('other nodes', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('mcm'));
    tearDown(() async => dir.delete(recursive: true));

    test('a freshly flashed node looks fresh', () async {
      final model = Model(dataDir: () async => dir);
      final s = Session(model, SimTransport(fresh: true));
      await s.start();
      expect(isFresh(model.selfInfo), isTrue);
      expect(model.contacts, isEmpty);
      expect(model.selfInfo!.lat, 0);
      await s.stop();
      await model.flush();
    });

    test('nodes the radio added while the app was closed', () async {
      final first = Model(dataDir: () async => dir);
      var s = Session(first, SimTransport());
      await s.start();
      expect(first.takeFoundAway(), isEmpty); // the first sync: everything is new, so nothing is news
      await s.stop();
      await first.flush();
      final model = Model(dataDir: () async => dir);
      s = Session(model, SimTransport(visitor: true));
      await s.start();
      final found = model.takeFoundAway();
      expect(found.map((c) => c.name), [startsWith('Visitor-')]);
      expect(model.takeFoundAway(), isEmpty);
      await s.stop();
    });

    test('a stuck write drops the link instead of hanging', () async {
      final t = _Stuck();
      final model = Model(dataDir: () async => dir);
      final s = Session(model, t)..writeTimeout = const Duration(milliseconds: 200);
      await s.start();
      t.stuck = true;
      final m = await s.send(chanConv(0), 'into the void');
      expect(m.status, MsgStatus.failed);
      expect(s.state, LinkState.disconnected);
      expect(t.closed, isTrue);
    });
  });
}

/// The simulator, but its writes can stop finishing, as a hung BLE write does.
class _Stuck extends SimTransport {
  bool stuck = false, closed = false;

  @override
  Future<void> write(Uint8List frame) => stuck ? Completer<void>().future : super.write(frame);

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}
