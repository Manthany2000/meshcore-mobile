import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:material_ui/material_ui.dart';

import 'src/model.dart';
import 'src/session.dart';
import 'src/sim.dart';
import 'src/transport.dart';
import 'src/ui/home.dart';

void main(List<String> args) {
  FlutterBluePlus.setLogLevel(LogLevel.warning);
  runApp(MeshCoreApp(autoSim: args.contains('--sim') || const bool.fromEnvironment('SIM')));
}

/// Owns the model and the current session, and reconnects when the link drops.
class AppState extends ChangeNotifier {
  final model = Model();
  Session? session;
  Transport Function()? _make;
  Timer? _retry;
  String? error;
  bool get linked => session != null;

  Future<void> connect(Transport Function() make) async {
    _make = make;
    error = null;
    await _open();
  }

  Future<void> _open() async {
    _retry?.cancel();
    _retry = null;
    session?.removeListener(_onSession);
    final s = Session(model, _make!());
    session = s;
    s.addListener(_onSession);
    notifyListeners();
    try {
      await s.start();
      error = null;
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
      await s.stop().catchError((_) {});
      if (model.selfInfo == null) {
        // Never got in: back to the connect screen with the error.
        _make = null;
        session = null;
      } else {
        _scheduleRetry();
      }
    }
    notifyListeners();
  }

  void _onSession() {
    final s = session;
    if (s != null && s.state == LinkState.disconnected && _make != null && _retry == null) _scheduleRetry();
    notifyListeners();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), () {
      _retry = null;
      if (_make != null) _open();
    });
  }

  void reconnectNow() {
    _retry?.cancel();
    _retry = null;
    if (_make != null) _open();
  }

  Future<void> disconnect() async {
    _make = null;
    _retry?.cancel();
    _retry = null;
    final s = session;
    session = null;
    s?.removeListener(_onSession);
    await s?.stop().catchError((_) {});
    model.reset();
    model.selfInfo = null;
    notifyListeners();
  }
}

class MeshCoreApp extends StatefulWidget {
  final bool autoSim;
  const MeshCoreApp({super.key, this.autoSim = false});

  @override
  State<MeshCoreApp> createState() => _MeshCoreAppState();
}

class _MeshCoreAppState extends State<MeshCoreApp> {
  final app = AppState();
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    // iOS can end a backgrounded app without warning: save on the way out.
    _life = AppLifecycleListener(onPause: app.model.flush, onDetach: app.model.flush, onHide: app.model.flush);
    if (widget.autoSim) app.connect(SimTransport.new);
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF14B8A6), brightness: b),
          useMaterial3: true,
        );
    return MaterialApp(
      title: 'MeshCore Mobile',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: ListenableBuilder(
        listenable: app,
        builder: (context, _) => app.model.selfInfo != null && app.linked ? HomeScreen(app: app) : ConnectScreen(app: app),
      ),
    );
  }
}

class ConnectScreen extends StatefulWidget {
  final AppState app;
  const ConnectScreen({super.key, required this.app});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  List<FoundNode> found = [];
  bool scanning = false;
  String? scanError;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    FlutterBluePlus.stopScan().catchError((_) {});
    super.dispose();
  }

  Future<void> _scan() async {
    if (scanning) return;
    setState(() {
      scanning = true;
      scanError = null;
    });
    try {
      if (!await FlutterBluePlus.isSupported) throw 'Bluetooth LE isn\'t available on this device';
      final st = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3), onTimeout: () => BluetoothAdapterState.unknown);
      if (st == BluetoothAdapterState.unauthorized) throw 'Allow Bluetooth for MeshCore Mobile in Settings';
      if (st == BluetoothAdapterState.off) throw 'Bluetooth is off';
      _sub = scan().listen((l) {
        if (mounted) setState(() => found = l);
      }, onDone: () {
        if (mounted) setState(() => scanning = false);
      }, onError: (e) {
        if (mounted) setState(() => scanError = '$e');
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          scanError = '$e';
          scanning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final cs = Theme.of(context).colorScheme;
    final busy = app.linked;
    return Scaffold(
      appBar: AppBar(title: const Text('MeshCore Mobile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Connect to a node running MeshCore companion firmware over Bluetooth.',
              style: Theme.of(context).textTheme.bodyMedium),
          if (app.error != null && !busy) ...[
            const SizedBox(height: 12),
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(app.error!, style: TextStyle(color: cs.onErrorContainer)),
              ),
            ),
          ],
          if (busy) ...[
            const SizedBox(height: 32),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 12),
            Center(child: Text(linkStateText(app.session))),
            const SizedBox(height: 12),
            Center(child: TextButton(onPressed: app.disconnect, child: const Text('Cancel'))),
          ] else ...[
            const SizedBox(height: 16),
            Row(children: [
              Text('Nodes nearby', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              if (scanning)
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              else
                TextButton.icon(onPressed: _scan, icon: const Icon(Icons.refresh), label: const Text('Scan')),
            ]),
            if (scanError != null) Padding(padding: const EdgeInsets.all(8), child: Text(scanError!)),
            if (found.isEmpty && !scanning && scanError == null)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('None found. Is the node on, and not connected to another phone or computer?'),
              ),
            for (final n in found)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.router_outlined),
                  title: Text(n.name),
                  subtitle: Text('${n.rssi} dBm'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => app.connect(() => BleTransport(n.device, n.name)),
                ),
              ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => app.connect(SimTransport.new),
              icon: const Icon(Icons.science_outlined),
              label: const Text('Try the simulator'),
            ),
          ],
        ],
      ),
    );
  }
}

String linkStateText(Session? s) {
  if (s == null) return '';
  return switch (s.state) {
    LinkState.connecting => 'Connecting to ${s.t.label}…',
    LinkState.syncing => 'Syncing ${s.detail}…',
    LinkState.ready => 'Connected',
    LinkState.disconnected => 'Reconnecting…',
    LinkState.idle => '',
  };
}
