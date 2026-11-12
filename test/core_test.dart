import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_mobile/src/model.dart';
import 'package:meshcore_mobile/src/protocol.dart' as p;
import 'package:meshcore_mobile/src/session.dart';
import 'package:meshcore_mobile/src/sim.dart';
import 'package:meshcore_mobile/src/ui/home.dart' show hashtagSecret;

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

    test('channel message split', () {
      final f = p.decode(Uint8List.fromList([p.respChannelMsgV3, 26, 0, 0, 1, 2, 0, 0, 0, 0, 0, ...'bob: hi: there'.codeUnits]))!;
      final m = f['msg'] as p.TextMessage;
      expect((m.who, m.text, m.hops, m.snr, m.channel), ('bob', 'hi: there', 2, 6.5, 1));
    });
  });

  group('session against the simulator', () {
    late Directory dir;
    late Model model;
    late Session s;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mcm');
      model = Model(dataDir: () async => dir);
      s = Session(model, SimTransport());
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
  });
}
