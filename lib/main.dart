import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:material_ui/material_ui.dart';

import 'src/model.dart';
import 'src/notify.dart';
import 'src/prefs.dart';
import 'src/protocol.dart' as p;
import 'src/session.dart';
import 'src/setup.dart' show isFresh;
import 'src/sim.dart';
import 'src/transport.dart';
import 'src/ui/chat.dart';
import 'src/ui/common.dart' show typeName;
import 'src/ui/home.dart';
import 'src/ui/logo.dart';
import 'src/ui/map.dart' show MapRequest;

void main(List<String> args) {
  FlutterBluePlus.setLogLevel(LogLevel.warning);
  final fresh = args.contains('--sim-fresh') || const bool.fromEnvironment('SIM_FRESH');
  final visitor = args.contains('--sim-visitor') || const bool.fromEnvironment('SIM_VISITOR');
  final sim = fresh || visitor || args.contains('--sim') || const bool.fromEnvironment('SIM');
  runApp(MeshCoreApp(autoSim: sim ? (fresh: fresh, visitor: visitor) : null));
}

/// The accent choices: the app's teal, and the ones MeshCore Desktop offers.
const accents = {
  'Teal': Color(0xFF14B8A6),
  'Signal green': Color(0xFF3F7420),
  'Amber': Color(0xFF8A5600),
  'Radio red': Color(0xFFA32B22),
  'Slate blue': Color(0xFF2F5B8A),
};

/// Owns the model and the current session, and reconnects when the link drops.
class AppState extends ChangeNotifier {
  final Model model;
  final Prefs prefs;
  final notifier = Notifier();
  bool foreground = true;
  Session? session;
  Transport Function()? _make;
  Timer? _retry;
  String? error;
  bool get linked => session != null;
  final navigator = GlobalKey<NavigatorState>();
  final tab = ValueNotifier<int>(0);
  final mapRequest = ValueNotifier<MapRequest?>(null);
  /// Nodes the node added while the app wasn't connected; the home screen shows them once.
  final foundAway = ValueNotifier<List<p.Contact>>([]);
  /// Set when a just-flashed node connects: the home screen offers to set it up.
  final offerSetup = ValueNotifier<bool>(false);
  final _offered = <String>{};

  static const mapTab = 1;

  /// [dataDir]: where history and settings live (tests pass a temp folder).
  AppState({Future<Directory> Function()? dataDir})
      : model = Model(dataDir: dataDir),
        prefs = Prefs(dataDir: dataDir) {
    model.incoming.stream.listen(_onMessage);
    model.newContacts.stream.listen(_onNewContact);
    notifier.onTap = openConv;
  }

  /// Settings and notifications; the splash shows until this is done.
  Future<void> init() async {
    await prefs.load();
    await notifier.init();
    final launch = notifier.launchPayload;
    if (launch != null) pendingConv = launch;
  }

  String? pendingConv; // a chat to open once connected (from a notification)

  void openConv(String conv) {
    if (session?.state != LinkState.ready) {
      pendingConv = conv;
      return;
    }
    pendingConv = null;
    final nav = navigator.currentState;
    if (nav == null) return;
    nav.popUntil((r) => r.isFirst);
    tab.value = 0;
    nav.push(MaterialPageRoute(builder: (_) => ChatScreen(app: this, conv: conv)));
  }

  bool get _notify => !foreground && prefs.notifications;

  void _onMessage(Message m) {
    if (m.outgoing || !_notify) return;
    final me = model.selfInfo?.name ?? '';
    final mentioned = me.isNotEmpty && m.text.contains('@[$me]');
    // Channels: only when it's about us.
    if (m.isChannel && !mentioned) return;
    notifier.show(m.isChannel ? '${m.sender} in ${model.convTitle(m.conv)}' : m.sender, m.text, payload: m.conv);
  }

  void _onNewContact(p.Contact c) {
    if (!_notify || session?.state != LinkState.ready) return;
    final name = c.name.isEmpty ? c.prefixHex.substring(0, 6) : c.name;
    final title = c.type == p.advRepeater ? 'New repeater found' : 'New contact found';
    final kind = c.type == p.advRepeater || c.type == p.advChat ? '' : ' (${typeName(c.type)})';
    notifier.show(title, '$name$kind');
  }

  /// Once the link is up: what happened while we were away, and a fresh node.
  void _afterSync() {
    // A real node: ask to notify. Not for the simulator, where the prompt would
    // only get in the way of trying the app (the switch on the Node tab asks).
    if (session?.t is! SimTransport) notifier.askPermission();
    final found = model.takeFoundAway();
    if (found.isNotEmpty) {
      foundAway.value = found;
      if (_notify) {
        final names = [for (final c in found.take(5)) c.name.isEmpty ? c.prefixHex.substring(0, 6) : c.name].join(', ');
        notifier.show('Found while you were away', names + (found.length > 5 ? ' and ${found.length - 5} more' : ''));
      }
    }
    final si = model.selfInfo;
    if (si != null && isFresh(si)) {
      final k = p.hex(si.key.sublist(0, 4));
      if (!prefs.noSetup.contains(k) && _offered.add(k)) offerSetup.value = true;
    }
    final conv = pendingConv;
    if (conv != null) openConv(conv);
  }

  /// Back to the tabs, on the Map, showing what was asked for.
  void showOnMap(MapRequest r) {
    navigator.currentState?.popUntil((route) => route.isFirst);
    tab.value = mapTab;
    mapRequest.value = r;
  }

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
      _afterSync();
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
    tab.value = 0;
    notifyListeners();
  }
}

class MeshCoreApp extends StatefulWidget {
  final ({bool fresh, bool visitor})? autoSim;
  final AppState? app; // tests bring their own
  const MeshCoreApp({super.key, this.autoSim, this.app});

  @override
  State<MeshCoreApp> createState() => _MeshCoreAppState();
}

class _MeshCoreAppState extends State<MeshCoreApp> {
  late final app = widget.app ?? AppState();
  late final AppLifecycleListener _life;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    // iOS can end a backgrounded app without warning: save on the way out.
    _life = AppLifecycleListener(
      onPause: app.model.flush,
      onDetach: app.model.flush,
      onHide: app.model.flush,
      onStateChange: (s) => app.foreground = s == AppLifecycleState.resumed,
    );
    app.init().whenComplete(() {
      if (mounted) setState(() => _loaded = true);
    });
    final sim = widget.autoSim;
    if (sim != null) app.connect(simMaker(fresh: sim.fresh, visitor: sim.visitor));
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.prefs,
      builder: (context, _) {
        final seed = accents[app.prefs.accent] ?? accents['Teal']!;
        ThemeData theme(Brightness b) => ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: b),
              useMaterial3: true,
            );
        return MaterialApp(
          navigatorKey: app.navigator,
          title: 'MeshCore Mobile',
          debugShowCheckedModeBanner: false,
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          home: Splash(
            ready: _loaded,
            child: ListenableBuilder(
              listenable: app,
              builder: (context, _) =>
                  app.model.selfInfo != null && app.linked ? HomeScreen(app: app) : ConnectScreen(app: app),
            ),
          ),
        );
      },
    );
  }
}

/// One simulated node for the whole run, so what it's told (a new name, a PIN)
/// is still there when the app reconnects after a restart.
Transport Function() simMaker({bool fresh = false, bool visitor = false}) {
  final t = SimTransport(fresh: fresh, visitor: visitor);
  return () => t;
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
        if (mounted) setState(() => scanError = _bleProblem(e));
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          scanError = _bleProblem(e);
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
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => app.connect(simMaker()),
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('Try the simulator'),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Other simulations',
                onSelected: (v) => app.connect(simMaker(fresh: v == 'fresh', visitor: v == 'visitor')),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'fresh', child: Text('A freshly flashed node')),
                  PopupMenuItem(value: 'visitor', child: Text('A node that heard someone new')),
                ],
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

/// A scan failure in words, not a platform exception.
String _bleProblem(Object e) {
  final t = '$e';
  if (t.contains('Unsupported')) return "This device has no Bluetooth LE (a simulator?). Try the simulator below.";
  if (t.contains('Unauthorized') || t.contains('unauthorized')) return 'Allow Bluetooth for MeshCore Mobile in Settings.';
  if (t.contains('turned on') || t.contains('PoweredOff')) return 'Bluetooth is off. Turn it on and scan again.';
  return t.startsWith('PlatformException(') ? 'Couldn\'t scan: ${t.split(', ').skip(1).first}' : t;
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
