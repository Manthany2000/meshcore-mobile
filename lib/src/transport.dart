// The link to a node: BLE (flutter_blue_plus), or the simulator.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'protocol.dart' as p;

abstract class Transport {
  void Function(Uint8List frame) onFrame = (_) {};
  void Function() onDisconnect = () {};
  String get label;
  Future<void> connect();
  Future<void> write(Uint8List frame);
  Future<void> close();
}

class FoundNode {
  final BluetoothDevice device;
  final String name;
  final int rssi;
  FoundNode(this.device, this.name, this.rssi);
}

/// MeshCore nodes in range, strongest first, updated as the scan finds them.
Stream<List<FoundNode>> scan({Duration timeout = const Duration(seconds: 8)}) async* {
  final found = <String, FoundNode>{};
  final ctl = StreamController<List<FoundNode>>();
  final sub = FlutterBluePlus.onScanResults.listen((results) {
    for (final r in results) {
      final name = r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName;
      final uuids = r.advertisementData.serviceUuids.map((u) => u.str128.toLowerCase());
      if (uuids.contains(p.serviceUuid) || name.startsWith('MeshCore')) {
        found[r.device.remoteId.str] = FoundNode(r.device, name.isEmpty ? r.device.remoteId.str : name, r.rssi);
      }
    }
    ctl.add(found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi)));
  });
  await FlutterBluePlus.startScan(timeout: timeout);
  FlutterBluePlus.isScanning.where((s) => !s).first.then((_) {
    sub.cancel();
    ctl.close();
  });
  yield* ctl.stream;
}

class BleTransport extends Transport {
  final BluetoothDevice device;
  final String name;
  BluetoothCharacteristic? _rx;
  StreamSubscription? _notify, _state;
  BleTransport(this.device, this.name);

  @override
  String get label => name;

  @override
  Future<void> connect() async {
    await FlutterBluePlus.stopScan();
    // On iOS the system shows the PIN prompt itself the first time we touch
    // the encrypted characteristics.
    await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 20), mtu: null);
    _state = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) onDisconnect();
    });
    if (device.mtuNow < 185) {
      try {
        await device.requestMtu(185); // Android only; iOS and Linux negotiate on their own
      } catch (_) {}
    }
    final services = await device.discoverServices();
    final svc = services.firstWhere((s) => s.uuid.str128.toLowerCase() == p.serviceUuid,
        orElse: () => throw StateError('$name has no MeshCore service. Is it running companion firmware?'));
    _rx = svc.characteristics.firstWhere((c) => c.uuid.str128.toLowerCase() == p.rxUuid);
    final tx = svc.characteristics.firstWhere((c) => c.uuid.str128.toLowerCase() == p.txUuid);
    _notify = tx.onValueReceived.listen((v) => onFrame(Uint8List.fromList(v)));
    device.cancelWhenDisconnected(_notify!);
    await tx.setNotifyValue(true);
  }

  @override
  Future<void> write(Uint8List frame) async {
    await _rx!.write(frame, withoutResponse: false);
  }

  @override
  Future<void> close() async {
    await _state?.cancel();
    await _notify?.cancel();
    await device.disconnect();
  }
}
