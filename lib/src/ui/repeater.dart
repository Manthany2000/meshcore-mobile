// Log in to a repeater over the mesh, read its stats, run its CLI, and change
// its settings. Passwords are only ever in the password box and the login
// frame: not saved or logged. Ported from MeshCore Desktop's admin.py.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../main.dart';
import '../model.dart';
import '../protocol.dart' as p;
import 'common.dart';

const _confirm = [
  'reboot', 'clkreboot', 'poweroff', 'shutdown', 'start ota', 'password ', 'tempradio ', 'set prv.key', 'set guest.password',
  'set name', 'set repeat', 'set radio', 'set tx', 'clear stats', 'neighbor.remove',
];
// Left out of the history, and masked in the console's echo.
const _secret = ['password ', 'set guest.password ', 'set prv.key '];

const readPresets = [
  'ver', 'board', 'clock', 'neighbors', 'powersaving', 'get name', 'get role', 'get radio', 'get tx', 'get repeat',
  'get advert.interval', 'get flood.advert.interval', 'get flood.max', 'get lat', 'get lon', 'get owner.info',
];
const actionPresets = ['clock sync', 'advert', 'advert.zerohop', 'clear stats', 'reboot'];

bool needsConfirm(String c) => _confirm.any(c.startsWith);
String masked(String c) {
  for (final s in _secret) {
    if (c.startsWith(s)) return '$s••••••';
  }
  return c;
}

String uptime(int s) {
  final d = s ~/ 86400, h = s % 86400 ~/ 3600, m = s % 3600 ~/ 60;
  return d > 0 ? '$d d $h h' : (h > 0 ? '$h h $m min' : '$m min');
}

class Setting {
  final String key, label, hint;
  final double? lo, hi;
  final bool whole;
  final List<String> choices;
  final int maxLen;
  final bool mayBeEmpty;
  const Setting(this.key, this.label,
      {this.hint = '', this.lo, this.hi, this.whole = true, this.choices = const [], this.maxLen = 0, this.mayBeEmpty = false});

  /// Why this value can't be sent, or null. The repeater makes the finer checks.
  String? problem(String v) {
    if (v.isEmpty) return mayBeEmpty ? null : "$label can't be empty.";
    if (lo == null) return null;
    final n = whole ? int.tryParse(v) : double.tryParse(v);
    if (n == null) return '$label must be a ${whole ? 'whole ' : ''}number.';
    return n >= lo! && n <= hi! ? null : '$label must be from ${_g(lo!)} to ${_g(hi!)}.';
  }
}

String _g(double x) => x == x.roundToDouble() ? '${x.toInt()}' : '$x';

const settings = [
  Setting('name', 'Name', maxLen: 31),
  Setting('repeat', 'Repeating', hint: 'Off stops this repeater relaying packets', choices: ['on', 'off']),
  Setting('tx', 'TX power (dBm)', hint: "Stay within your radio's and your region's limits", lo: -9, hi: 30),
  Setting('flood.max', 'Max flood hops', hint: "Floods that have gone further aren't relayed", lo: 0, hi: 64),
  Setting('advert.interval', 'Local advert (min)', hint: '0 = off. Otherwise even minutes, up to 240', lo: 0, hi: 240),
  Setting('flood.advert.interval', 'Flood advert (hours)', hint: '0 = off, or 3 to 168', lo: 0, hi: 168),
  Setting('lat', 'Latitude', hint: 'Decimal degrees', lo: -90, hi: 90, whole: false),
  Setting('lon', 'Longitude', hint: 'Decimal degrees', lo: -180, hi: 180, whole: false),
  Setting('owner.info', 'Owner info', hint: '| starts a new line', maxLen: 119, mayBeEmpty: true),
];

/// What this session knows about one repeater, kept while the app runs.
class Remote {
  bool loggedIn = false;
  bool? isAdmin; // null: an old repeater that doesn't say
  Map<String, num>? stats;
  double statsAt = 0;
  final settings = <String, String>{};
  final console = <String>[];
  final history = <String>[];
}

final remotes = <String, Remote>{};

class RepeaterScreen extends StatefulWidget {
  final AppState app;
  final p.Contact contact;
  const RepeaterScreen({super.key, required this.app, required this.contact});

  @override
  State<RepeaterScreen> createState() => _RepeaterScreenState();
}

class _RepeaterScreenState extends State<RepeaterScreen> {
  final password = TextEditingController();
  final command = TextEditingController();
  final fields = <String, TextEditingController>{for (final s in settings) s.key: TextEditingController()};
  final choice = <String, String?>{};
  String note = '';
  bool bad = false;
  bool busy = false;
  bool live = false;
  Timer? _live;
  final _scroll = ScrollController();

  p.Contact get c => widget.app.model.contacts[widget.contact.prefixHex] ?? widget.contact;
  Remote get r => remotes.putIfAbsent(c.prefixHex, Remote.new);
  bool get ready => widget.app.session?.state.name == 'ready';

  @override
  void initState() {
    super.initState();
    for (final s in settings) {
      _fill(s);
    }
  }

  @override
  void dispose() {
    _live?.cancel();
    password.dispose();
    command.dispose();
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _say(String t, [bool isBad = false]) {
    if (mounted) {
      setState(() {
        note = t;
        bad = isBad;
      });
    }
  }

  String _failure(p.Frame? f) => f == null
      ? 'No reply. The repeater may be out of range, or its saved route stale: try Reset route.'
      : 'The node refused: ${p.errNames[f['err']] ?? f['err']}.';

  Future<T?> _run<T>(Future<T> Function() fn) async {
    if (busy) return null;
    setState(() => busy = true);
    try {
      return await fn();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _login() => _run(() async {
        final pw = password.text;
        password.clear();
        _say('Logging in…');
        final f = await widget.app.session!.login(c.key, pw);
        if (f == null || f.kind == 'err') return _say(_failure(f), true);
        if (f.kind == 'login_fail') {
          r.loggedIn = false;
          return _say("Wrong password, or a blank login and this node isn't on its admin list.", true);
        }
        r.loggedIn = true;
        r.isAdmin = f['is_admin'];
        _say(r.isAdmin == false ? 'Logged in as a guest: stats only.' : 'Logged in.');
        await _statusNow();
      });

  Future<void> _status() => _run(_statusNow);

  Future<void> _statusNow({bool record = true}) async {
    if (!live) _say('Asking for status…');
    final f = await widget.app.session!.repeaterStatus(c.key);
    if (f == null || f.kind == 'err') return _say(_failure(f), true);
    r.stats = (f['stats'] as Map<String, num>);
    r.statsAt = nowS();
    if (record) widget.app.model.recordRepeater(c.prefixHex, r.stats!);
    _say(live ? 'Live: updated ${shortTime(r.statsAt, seconds: true)}' : 'Up to date.');
  }

  void _toggleLive(bool on) {
    setState(() => live = on);
    _live?.cancel();
    if (!on) return;
    var n = 0;
    Future<void> tick() async {
      if (!mounted || !live || busy) return;
      setState(() => busy = true);
      try {
        await _statusNow(record: n++ % 6 == 0); // one sample in six goes to the history, or it'd swamp it
      } finally {
        if (mounted) setState(() => busy = false);
      }
    }

    tick();
    _live = Timer.periodic(const Duration(seconds: 10), (_) => tick());
  }

  Future<void> _resetRoute() => _run(() async {
        _say('Resetting route…');
        final f = await widget.app.session!.resetPath(c.key);
        _say(f != null && f.kind == 'ok' ? 'Route reset.' : "Couldn't reset the route.", f == null || f.kind != 'ok');
      });

  void _log(String line) {
    setState(() => r.console.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _cli(String cmd) async {
    if (utf8.encode(cmd).length > p.textMax) return _say('Commands can be at most ${p.textMax} bytes.', true);
    if (needsConfirm(cmd)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Run on the repeater?'),
          content: Text('Run “${masked(cmd)}” on ${c.name}?\n\nA remote repeater may be hard to reach if this goes wrong.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Run')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (masked(cmd) == cmd && (r.history.isEmpty || r.history.last != cmd)) r.history.add(cmd);
    await _run(() async {
      _log('> ${masked(cmd)}');
      final f = await widget.app.session!.cli(c.key, cmd);
      _log(f != null && f.kind == 'message'
          ? (f['msg'] as p.TextMessage).text
          : f == null
              ? '(no reply: it may or may not have run)'
              : '(failed: ${_failure(f)})');
    });
  }

  Future<void> _advert(bool flood) async {
    final cmd = flood ? 'advert' : 'advert.zerohop';
    await _run(() async {
      _say('Asking the repeater to send a ${flood ? 'flood' : 'zero-hop'} advert…');
      _log('> $cmd');
      final f = await widget.app.session!.cli(c.key, cmd);
      if (f == null || f.kind != 'message') {
        _log('(no reply: it may or may not have sent one)');
        return _say('No reply, so the advert may or may not have gone out. ${_failure(f)}', true);
      }
      final t = (f['msg'] as p.TextMessage).text;
      _log(t);
      _say(t.startsWith('OK') ? '${flood ? 'Flood' : 'Zero-hop'} advert sent.' : 'The repeater said: $t', !t.startsWith('OK'));
    });
  }

  // --- settings -----------------------------------------------------------------

  void _fill(Setting s) {
    final v = r.settings[s.key] ?? '';
    if (s.choices.isNotEmpty) {
      choice[s.key] = s.choices.contains(v) ? v : null;
    } else {
      fields[s.key]!.text = v;
    }
  }

  String _value(Setting s) => s.choices.isNotEmpty ? (choice[s.key] ?? '') : fields[s.key]!.text.trim();

  /// False if the repeater didn't answer. A key it doesn't know just stays blank.
  Future<bool> _readOne(Setting s) async {
    final f = await widget.app.session!.cli(c.key, 'get ${s.key}');
    if (f == null || f.kind != 'message') return false;
    final t = (f['msg'] as p.TextMessage).text;
    if (t.startsWith('> ') || t == '>') {
      r.settings[s.key] = t.length > 2 ? t.substring(2) : '';
    } else {
      r.settings.remove(s.key);
    }
    if (mounted) setState(() => _fill(s));
    return true;
  }

  Future<void> _readAll() => _run(() async {
        for (final (i, s) in settings.indexed) {
          _say('Reading ${i + 1} of ${settings.length}: ${s.label}…');
          if (!await _readOne(s)) {
            // Replies carry no tag, so a late one could land on the next field. Stop here.
            return _say('No reply reading ${s.label}. Stopped; try again.', true);
          }
        }
        _say('Up to date. Change what you like, then Apply.');
      });

  Future<void> _apply() async {
    final changes = [
      for (final s in settings)
        if (r.settings.containsKey(s.key) && _value(s) != r.settings[s.key]) (s, r.settings[s.key]!, _value(s)),
    ];
    if (changes.isEmpty) return _say('Nothing has changed.');
    for (final (s, _, v) in changes) {
      final problem = s.problem(v);
      if (problem != null) return _say(problem, true);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apply to the repeater?'),
        content: Text('Change these on ${c.name}?\n\n${[
          for (final (s, o, v) in changes) '${s.label}: ${o.isEmpty ? '(empty)' : o} → ${v.isEmpty ? '(empty)' : v}'
        ].join('\n')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      final refused = <String>[];
      for (final (s, _, v) in changes) {
        final cmd = 'set ${s.key} $v';
        _say('Setting ${s.label}…');
        _log('> $cmd');
        final f = await widget.app.session!.cli(c.key, cmd);
        if (f == null || f.kind != 'message') {
          _log('(no reply: it may or may not have applied)');
          return _say('No reply setting ${s.label}: it may or may not have applied. Stopped; read again to check.', true);
        }
        final t = (f['msg'] as p.TextMessage).text;
        _log(t);
        if (!t.startsWith('OK')) {
          refused.add('${s.label}: $t');
        } else if (!await _readOne(s)) {
          return _say('${s.label} was set, but reading it back got no reply.', true);
        }
      }
      _say(refused.isEmpty ? 'Applied.' : refused.join('  '), refused.isNotEmpty);
    });
  }

  // --- layout -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.app, widget.app.model]),
      builder: (context, _) {
        return DefaultTabController(
          length: 4,
          child: Scaffold(
            appBar: AppBar(
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.name),
                Text(
                  '${hopsText(c.hops)}${r.loggedIn ? (r.isAdmin == false ? ' · guest' : ' · logged in') : ''}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ]),
              actions: [
                PopupMenuButton<String>(
                  onSelected: (v) => switch (v) {
                    'zero' => _advert(false),
                    'flood' => _advert(true),
                    'route' => _resetRoute(),
                    _ => null,
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'zero', enabled: r.loggedIn, child: const Text('Zero-hop advert')),
                    PopupMenuItem(value: 'flood', enabled: r.loggedIn, child: const Text('Flood advert')),
                    const PopupMenuItem(value: 'route', child: Text('Reset route')),
                  ],
                ),
              ],
              bottom: const TabBar(tabs: [Tab(text: 'Status'), Tab(text: 'Console'), Tab(text: 'Settings'), Tab(text: 'History')]),
            ),
            body: Column(children: [
              if (!r.loggedIn) _loginRow(),
              if (note.isNotEmpty || busy)
                Container(
                  width: double.infinity,
                  color: bad ? cs.errorContainer : cs.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(children: [
                    if (busy) ...[const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 10)],
                    Expanded(child: Text(note, style: TextStyle(color: bad ? cs.onErrorContainer : null, fontSize: 13))),
                  ]),
                ),
              Expanded(
                child: TabBarView(children: [_statusPage(), _consolePage(), _settingsPage(), _historyPage()]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _loginRow() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: password,
              obscureText: true,
              maxLength: p.passwordMax,
              enabled: ready && !busy,
              decoration: const InputDecoration(
                labelText: 'Password',
                hintText: 'Blank if you\'re already its admin',
                counterText: '',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _login(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: ready && !busy ? _login : null, child: const Text('Log in')),
        ]),
      );

  Widget _statusPage() {
    final s = r.stats;
    final cs = Theme.of(context).colorScheme;
    if (s == null) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        Text(r.loggedIn ? 'No status yet.' : 'Log in to read its battery, uptime, noise floor and packet counters. '
            'The sim\'s repeaters take “admin” or “guest”.'),
        const SizedBox(height: 12),
        if (r.loggedIn) FilledButton.tonal(onPressed: busy ? null : _status, child: const Text('Get status')),
      ]);
    }
    final mv = s['batt_mv']!.toInt();
    final pct = mv > 0 ? p.battPercent(mv) : null;
    final up = s['up_secs']!.toInt();
    final rows = [
      ('Battery', mv > 0 ? '${(mv / 1000).toStringAsFixed(2)} V ($pct%)' : 'no reading'),
      ('Uptime', uptime(up)),
      ('Noise floor', '${s['noise_floor']} dBm'),
      ('Last RSSI / SNR', '${s['last_rssi']} dBm / ${s['last_snr']!.toStringAsFixed(1)} dB'),
      ('TX queue', '${s['tx_queue']}'),
      ('Airtime TX / RX', '${s['air_secs']} s / ${s['rx_air_secs']} s${up > 0 ? ' (${(100 * s['air_secs']! / up).toStringAsFixed(1)}% TX)' : ''}'),
      ('Packets RX / TX', '${s['recv']} / ${s['sent']}'),
      ('Flood RX / TX', '${s['recv_flood']} / ${s['sent_flood']}'),
      ('Direct RX / TX', '${s['recv_direct']} / ${s['sent_direct']}'),
      ('Dups flood / direct', '${s['flood_dups']} / ${s['direct_dups']}'),
      ('Errors / RX errors', '${s['errors']} / ${s['recv_errors']}'),
      ('Updated', shortTime(r.statsAt, seconds: true)),
    ];
    return ListView(padding: const EdgeInsets.all(12), children: [
      if (pct != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Icon(Icons.battery_std, color: pct > 20 ? cs.primary : cs.error, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$pct%', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: pct / 100, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                ]),
              ),
            ]),
          ),
        ),
      Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(children: [
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
                  Text(v, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                ]),
              ),
          ]),
        ),
      ),
      Row(children: [
        FilledButton.tonalIcon(onPressed: busy || live ? null : _status, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
        const Spacer(),
        const Text('Live'),
        Switch(value: live, onChanged: r.loggedIn ? _toggleLive : null),
      ]),
      if (live) Text('Asks for status every 10 seconds while this screen is open.', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }

  Widget _consolePage() {
    final mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: const ['Courier', 'monospace'], fontSize: 12.5,
        color: Theme.of(context).colorScheme.onSurface);
    final enabled = r.loggedIn && r.isAdmin != false && !busy && ready;
    return Column(children: [
      Expanded(
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
          child: r.console.isEmpty
              ? Text(r.loggedIn ? 'Run a command below, or tap a preset.' : 'Log in as admin to use the console.', style: mono)
              : ListView(controller: _scroll, children: [for (final l in r.console) SelectableText(l, style: mono)]),
        ),
      ),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final cmd in [...readPresets, ...actionPresets])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                label: Text(cmd),
                avatar: actionPresets.contains(cmd) ? const Icon(Icons.bolt, size: 16) : null,
                onPressed: enabled ? () => _cli(cmd) : null,
              ),
            ),
        ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(children: [
            if (r.history.isNotEmpty)
              PopupMenuButton<String>(
                icon: const Icon(Icons.history),
                tooltip: 'Earlier commands',
                onSelected: (v) => command.text = v,
                itemBuilder: (_) => [for (final h in r.history.reversed.take(15)) PopupMenuItem(value: h, child: Text(h))],
              ),
            Expanded(
              child: TextField(
                controller: command,
                enabled: enabled,
                autocorrect: false,
                style: mono,
                decoration: const InputDecoration(hintText: 'Command', border: OutlineInputBorder(), isDense: true),
                onSubmitted: (v) {
                  if (v.trim().isEmpty) return;
                  _cli(v.trim());
                  command.clear();
                },
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              onPressed: enabled
                  ? () {
                      if (command.text.trim().isEmpty) return;
                      _cli(command.text.trim());
                      command.clear();
                    }
                  : null,
              icon: const Icon(Icons.send),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _settingsPage() {
    final enabled = r.loggedIn && r.isAdmin != false && !busy && ready;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Text('Read the repeater\'s settings, change what you like, then Apply. Each change is checked and read back.',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      for (final s in settings)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: s.choices.isNotEmpty
              ? DropdownButtonFormField<String>(
                  initialValue: choice[s.key],
                  key: ValueKey('${s.key}-${r.settings[s.key]}'),
                  decoration: InputDecoration(labelText: s.label, helperText: s.hint, border: const OutlineInputBorder(), isDense: true),
                  items: [for (final ch in s.choices) DropdownMenuItem(value: ch, child: Text(ch))],
                  onChanged: enabled && r.settings.containsKey(s.key) ? (v) => setState(() => choice[s.key] = v) : null,
                )
              : TextField(
                  controller: fields[s.key],
                  enabled: enabled && r.settings.containsKey(s.key),
                  maxLength: s.maxLen > 0 ? s.maxLen : null,
                  keyboardType: s.lo != null ? TextInputType.numberWithOptions(signed: true, decimal: !s.whole) : null,
                  decoration: InputDecoration(
                    labelText: s.label,
                    helperText: s.hint.isEmpty ? null : s.hint,
                    border: const OutlineInputBorder(),
                    isDense: true,
                    counterText: '',
                  ),
                ),
        ),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton.tonal(onPressed: enabled ? _readAll : null, child: const Text('Read from repeater')),
        const SizedBox(width: 8),
        FilledButton(onPressed: enabled && r.settings.isNotEmpty ? _apply : null, child: const Text('Apply')),
      ]),
    ]);
  }

  Widget _historyPage() {
    final h = widget.app.model.repeaterHistory[c.prefixHex] ?? [];
    if (h.length < 2) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Battery and noise floor are kept each time you refresh this repeater. Refresh a few times to draw a history.'),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(12), children: [
      _Chart(
        title: 'Battery (V)',
        points: [for (final x in h) if (x[1] > 0) (x[0].toDouble(), x[1] / 1000)],
        color: cs.primary,
      ),
      _Chart(title: 'Noise floor (dBm)', points: [for (final x in h) (x[0].toDouble(), x[2].toDouble())], color: cs.tertiary),
      _Chart(title: 'Last RSSI (dBm)', points: [for (final x in h) (x[0].toDouble(), x[3].toDouble())], color: cs.secondary),
      Text('${h.length} readings since ${shortTime(h.first[0].toDouble())}', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _Chart extends StatelessWidget {
  final String title;
  final List<(double, double)> points;
  final Color color;
  const _Chart({required this.title, required this.points, required this.color});

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) return const SizedBox.shrink();
    final lo = points.map((e) => e.$2).reduce(math.min), hi = points.map((e) => e.$2).reduce(math.max);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            Text('${_fmt(lo)} – ${_fmt(hi)} · now ${_fmt(points.last.$2)}', style: Theme.of(context).textTheme.labelSmall),
          ]),
          const SizedBox(height: 8),
          CustomPaint(size: const Size.fromHeight(110), painter: _LinePainter(points, color, Theme.of(context).colorScheme.outlineVariant)),
          Row(children: [
            Text(shortTime(points.first.$1), style: Theme.of(context).textTheme.labelSmall),
            const Spacer(),
            Text(shortTime(points.last.$1), style: Theme.of(context).textTheme.labelSmall),
          ]),
        ]),
      ),
    );
  }

  String _fmt(double v) => v.abs() < 10 ? v.toStringAsFixed(2) : v.toStringAsFixed(0);
}

class _LinePainter extends CustomPainter {
  final List<(double, double)> pts;
  final Color color, grid;
  _LinePainter(this.pts, this.color, this.grid);

  @override
  void paint(Canvas canvas, Size size) {
    final x0 = pts.first.$1, x1 = pts.last.$1;
    var lo = pts.map((e) => e.$2).reduce(math.min), hi = pts.map((e) => e.$2).reduce(math.max);
    if (hi - lo < 1e-6) {
      lo -= 1;
      hi += 1;
    }
    final pad = (hi - lo) * 0.1;
    lo -= pad;
    hi += pad;
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gp);
    }
    Offset at((double, double) e) =>
        Offset((x1 - x0) < 1e-6 ? 0 : (e.$1 - x0) / (x1 - x0) * size.width, size.height - (e.$2 - lo) / (hi - lo) * size.height);
    final path = Path()..moveTo(at(pts.first).dx, at(pts.first).dy);
    for (final e in pts.skip(1)) {
      path.lineTo(at(e).dx, at(e).dy);
    }
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round);
    canvas.drawCircle(at(pts.last), 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}
