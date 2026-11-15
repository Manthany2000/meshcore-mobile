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
import '../setup.dart' show presets;
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
  'get flood.max.unscoped', 'region', 'region home', 'region default',
];
const actionPresets = ['clock sync', 'advert', 'advert.zerohop', 'region save', 'clear stats', 'reboot'];

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

const nameBad = r'[]\:,?*'; // isValidName() in the firmware refuses these
const onOff = ['on', 'off'];

const groups = [
  ('Identity', 'How it shows up on maps and in contact lists.'),
  ('Radio', 'These must match the rest of your mesh. Frequency, bandwidth, SF and CR only take effect after a reboot, '
      'and a wrong value cuts the repeater off until someone fixes it by USB.'),
  ('Repeating', 'What it relays, and how far.'),
  ('Adverts', 'How often it announces itself.'),
  ('Timing and airtime', 'Fine tuning. The defaults suit most meshes.'),
  ('Access', 'Who can log in. The admin password can be changed but never read back.'),
];

num? _number(String t, bool whole) => whole ? int.tryParse(t) : double.tryParse(t);

(double, double, int, int)? parseRadio(String t) {
  final x = t.split(',');
  if (x.length != 4) return null;
  final f = double.tryParse(x[0]), b = double.tryParse(x[1]), s = int.tryParse(x[2]), c = int.tryParse(x[3]);
  return f == null || b == null || s == null || c == null ? null : (f, b, s, c);
}

String formatRadio(double f, double bw, int sf, int cr) => '${f.toStringAsFixed(3)},${_g(bw)},$sf,$cr';

String? radioProblem(String v) {
  final r = parseRadio(v);
  if (r == null) return 'Radio must be frequency,bandwidth,SF,CR.';
  final (f, bw, sf, cr) = r;
  if (f < 150 || f > 2500) return 'Frequency must be from 150 to 2500 MHz.';
  if (bw < 7 || bw > 500) return 'Bandwidth must be from 7 to 500 kHz.';
  if (sf < 5 || sf > 12) return 'Spreading factor must be from 5 to 12.';
  if (cr < 5 || cr > 8) return 'Coding rate must be from 5 to 8.';
  return null;
}

/// One value the Settings page edits, read and written with `get key` / `set key value`.
class Setting {
  final String key, label, group, hint, unit, badChars;
  final double? lo, hi;
  final bool whole, mayBeEmpty, orZero, reboot, radio;
  final List<String> choices, labels;
  final int maxLen;
  const Setting(this.key, this.label, this.group,
      {this.hint = '',
      this.lo,
      this.hi,
      this.whole = true,
      this.choices = const [],
      this.labels = const [],
      this.maxLen = 0,
      this.mayBeEmpty = false,
      this.orZero = false,
      this.badChars = '',
      this.reboot = false,
      this.radio = false,
      this.unit = ''});

  /// Why this value can't be sent, or null. The repeater makes the finer checks.
  String? problem(String v) {
    if (radio) return radioProblem(v);
    if (v.isEmpty) return mayBeEmpty ? null : "$label can't be empty.";
    final n = utf8.encode(v).length;
    if (maxLen > 0 && n > maxLen) return '$label is $n bytes, and the repeater keeps at most $maxLen.';
    final bad = {for (final ch in v.split('')) if (badChars.contains(ch)) ch}.toList()..sort();
    if (bad.isNotEmpty) return "$label can't contain ${bad.join(' ')}";
    if (choices.isNotEmpty && !choices.contains(v)) return '$label must be one of ${choices.join(', ')}.';
    if (lo == null) return null;
    final x = _number(v, whole);
    if (x == null) return '$label must be a ${whole ? 'whole ' : ''}number.';
    if (orZero && x == 0) return null;
    if (x >= lo! && x <= hi!) return null;
    return '$label must be ${orZero ? '0 or ' : ''}from ${_g(lo!)} to ${_g(hi!)}.';
  }

  /// Whether a `get` reply looks like this setting. An older repeater that doesn't
  /// know a key may answer for a shorter one that starts the same way.
  bool readable(String v) {
    if (radio) return parseRadio(v) != null;
    if (choices.isNotEmpty) return choices.contains(v);
    if (lo != null) return _number(v, false) != null;
    return true;
  }

  bool same(String a, String b) {
    if (a == b) return true;
    if (radio) {
      final x = parseRadio(a), y = parseRadio(b);
      return x != null && y != null && (x.$1 - y.$1).abs() < 1e-4 && (x.$2 - y.$2).abs() < 1e-4 && x.$3 == y.$3 && x.$4 == y.$4;
    }
    if (lo != null) {
      final x = _number(a, false), y = _number(b, false);
      return x != null && y != null && (x - y).abs() < 1e-6;
    }
    return false;
  }

  /// The value as a person reads it, for the confirm list.
  String shown(String v) {
    if (v.isEmpty) return '(empty)';
    if (labels.isNotEmpty && choices.contains(v)) return labels[choices.indexOf(v)];
    final r = radio ? parseRadio(v) : null;
    if (r != null) return '${r.$1.toStringAsFixed(3)} MHz, ${_g(r.$2)} kHz, SF${r.$3}, CR 4/${r.$4}';
    return '$v $unit'.trim();
  }
}

String _g(double x) => x == x.roundToDouble() ? '${x.toInt()}' : '$x';

const settings = [
  // Identity
  Setting('name', 'Name', 'Identity', hint: 'Up to 31 bytes, without [ ] \\ : , ? *', maxLen: 31, badChars: nameBad),
  Setting('lat', 'Latitude', 'Identity', hint: 'Decimal degrees, 0 to leave it off the map', lo: -90, hi: 90, whole: false),
  Setting('lon', 'Longitude', 'Identity', hint: 'Decimal degrees, 0 to leave it off the map', lo: -180, hi: 180, whole: false),
  Setting('owner.info', 'Owner info', 'Identity',
      hint: 'Shown to people who look it up. | starts a new line', maxLen: 119, mayBeEmpty: true),
  // Radio
  Setting('radio', 'Radio', 'Radio', hint: 'Frequency, bandwidth, spreading factor and coding rate', radio: true, reboot: true),
  Setting('tx', 'TX power', 'Radio',
      hint: "Stay within your radio's and your country's limits. Some boards have an amplifier after the radio",
      lo: -9, hi: 30, unit: 'dBm'),
  Setting('path.hash.mode', 'Path hash size', 'Radio',
      hint: 'How many bytes of each repeater\'s key a flood carries in its path. Bigger meshes use 2 or 3 so repeaters '
          'don\'t get mixed up; nodes on older firmware only understand 1',
      choices: ['0', '1', '2'], labels: ['1 byte', '2 bytes', '3 bytes']),
  Setting('radio.rxgain', 'RX boosted gain', 'Radio', hint: 'Better reception for a little more current (SX126x)', choices: onOff),
  Setting('cad', 'Listen before talk', 'Radio', hint: 'Channel activity detection before each send', choices: onOff),
  // Repeating
  Setting('repeat', 'Repeating', 'Repeating', hint: 'Off stops this repeater relaying packets', choices: onOff),
  Setting('loop.detect', 'Loop detection', 'Repeating',
      hint: 'Drops floods that come back round a loop', choices: ['off', 'minimal', 'moderate', 'strict']),
  Setting('flood.max', 'Max flood hops', 'Repeating', hint: "Floods that have gone further aren't relayed", lo: 0, hi: 64),
  Setting('flood.max.unscoped', 'Max hops, unscoped', 'Repeating',
      hint: "The same for floods with no region scope. A low value like 3 keeps others' unscoped chatter local", lo: 0, hi: 64),
  Setting('flood.max.advert', 'Max hops, adverts', 'Repeating', hint: 'The same for flooded adverts', lo: 0, hi: 64),
  Setting('multi.acks', 'Extra ACKs', 'Repeating', hint: 'Extra copies of each ACK it sends, for lossy links', lo: 0, hi: 3),
  // Adverts
  Setting('advert.interval', 'Local advert', 'Adverts',
      hint: '0 = off, otherwise 60 to 240 minutes (kept in steps of 2)', lo: 60, hi: 240, orZero: true, unit: 'min'),
  Setting('flood.advert.interval', 'Flood advert', 'Adverts',
      hint: '0 = off, otherwise 3 to 168 hours', lo: 3, hi: 168, orZero: true, unit: 'h'),
  // Timing and airtime
  Setting('af', 'Airtime factor', 'Timing and airtime',
      hint: "Waits this many times a packet's airtime after sending it: 1 is about a 50% duty cycle, 9 about 10%",
      lo: 0, hi: 9, whole: false),
  Setting('rxdelay', 'RX delay base', 'Timing and airtime',
      hint: 'Gives stronger copies of a flood a head start. 0 = off', lo: 0, hi: 20, whole: false),
  Setting('txdelay', 'Flood TX delay', 'Timing and airtime',
      hint: 'Random wait before relaying a flood, as a factor of its airtime', lo: 0, hi: 2, whole: false),
  Setting('direct.txdelay', 'Direct TX delay', 'Timing and airtime', hint: 'The same for direct packets', lo: 0, hi: 2, whole: false),
  Setting('agc.reset.interval', 'AGC reset', 'Timing and airtime', hint: '0 = off. Rounded down to a multiple of 4', lo: 0, hi: 1020, unit: 's'),
  Setting('int.thresh', 'Interference threshold', 'Timing and airtime', hint: '0 = off', lo: 0, hi: 255),
  // Access
  Setting('guest.password', 'Guest password', 'Access', hint: 'Up to 15 bytes; empty for no guest login', maxLen: 15, mayBeEmpty: true),
  Setting('allow.read.only', 'Read-only guests', 'Access', hint: 'Room servers: lets guests in without a password', choices: onOff),
];

const secretSettings = {'guest.password'};

/// What this session knows about one repeater, kept while the app runs.
class Remote {
  bool loggedIn = false;
  bool? isAdmin; // null: an old repeater that doesn't say
  Map<String, num>? stats;
  double statsAt = 0;
  final settings = <String, String>{};
  final console = <String>[];
  final history = <String>[];
  List<p.Region>? regions; // as last read; null: not read yet
  String? regionDefault; // its default scope, "" for none
  bool regionsUnsaved = false; // changed since the last `region save`
  String regionNote = 'Read the regions first.';
  bool regionBad = false;
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
    // A reply can arrive after the screen closed: keep it for next time.
    if (!mounted) return r.console.add(line);
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
    final v = t.startsWith('> ') ? t.substring(2) : (t == '>' ? '' : null);
    if (v != null && s.readable(v)) {
      r.settings[s.key] = v;
    } else {
      r.settings.remove(s.key);
    }
    if (mounted) setState(() => _fill(s));
    return true;
  }

  Future<void> _readSome(List<Setting> which, [String title = '']) => _run(() async {
        for (final (i, s) in which.indexed) {
          _say('Reading ${i + 1} of ${which.length}: ${s.label}…');
          if (!await _readOne(s)) {
            // Replies carry no tag, so a late one could land on the next field. Stop here.
            return _say('No reply reading ${s.label}. Stopped; try again.', true);
          }
        }
        final missing = [for (final s in which) if (!r.settings.containsKey(s.key)) s.label];
        _say('${title.isEmpty ? 'Up to date.' : '$title read.'}'
            '${missing.isEmpty ? '' : ' Not on this firmware: ${missing.join(', ')}.'} Change what you like, then Apply.');
      });

  List<(Setting, String, String)> _changes() => [
        for (final s in settings)
          if (r.settings.containsKey(s.key) && !s.same(_value(s), r.settings[s.key]!)) (s, r.settings[s.key]!, _value(s)),
      ];

  void _revert() => setState(() {
        for (final s in settings) {
          _fill(s);
        }
      });

  Future<void> _apply() async {
    final changes = _changes();
    if (changes.isEmpty) return _say('Nothing has changed.');
    for (final (s, _, v) in changes) {
      final problem = s.problem(v);
      if (problem != null) return _say(problem, true);
    }
    // The radio last: the rest still go out on the old settings.
    changes.sort((a, b) => (a.$1.reboot ? 1 : 0).compareTo(b.$1.reboot ? 1 : 0));
    final radioChange = changes.any((x) => x.$1.radio);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Apply to the repeater?'),
        scrollable: true,
        content: Text('Change these on ${c.name}?\n\n${[
          for (final (s, o, v) in changes)
            secretSettings.contains(s.key) ? '${s.label}: changed' : '${s.label}: ${s.shown(o)} → ${s.shown(v)}'
        ].join('\n')}${radioChange ? '\n\nThe new radio settings take effect when it reboots. After that it only hears nodes on '
            'the same settings: if your own node and the rest of the mesh aren\'t on them, you won\'t reach it again '
            'without USB.' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true) return;
    var reboot = false;
    await _run(() async {
      final refused = <String>[];
      for (final (s, _, v) in changes) {
        final cmd = 'set ${s.key} $v';
        _say('Setting ${s.label}…');
        _log('> ${secretSettings.contains(s.key) ? 'set ${s.key} ••••••' : cmd}');
        final f = await widget.app.session!.cli(c.key, cmd);
        if (f == null || f.kind != 'message') {
          _log('(no reply: it may or may not have applied)');
          return _say('No reply setting ${s.label}: it may or may not have applied. Stopped; read again to check.', true);
        }
        final t = (f['msg'] as p.TextMessage).text;
        _log(t);
        if (!t.toUpperCase().startsWith('OK')) {
          refused.add('${s.label}: $t');
          continue;
        }
        reboot = reboot || s.reboot;
        if (s.reboot) {
          // It reads back the stored value, which is what a reboot will use.
          r.settings[s.key] = v;
          if (mounted) setState(() => _fill(s));
        } else if (!await _readOne(s)) {
          return _say('${s.label} was set, but reading it back got no reply.', true);
        }
      }
      _say(refused.isEmpty ? 'Applied.' : refused.join('  '), refused.isNotEmpty);
    });
    if (reboot && mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reboot the repeater?'),
          content: Text('The radio change on ${c.name} needs a reboot. Reboot it now?\n\n'
              'It won\'t answer until it\'s back, and then only on the new settings.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reboot')),
          ],
        ),
      );
      if (go == true) {
        await _run(() async {
          _log('> reboot');
          final f = await widget.app.session!.cli(c.key, 'reboot');
          _log(f != null && f.kind == 'message' ? (f['msg'] as p.TextMessage).text : '(no reply: it may be restarting)');
          _say('Rebooting. Log in again once it\'s back.');
          r.loggedIn = false;
        });
      }
    }
  }

  Future<void> _changePassword() async {
    final a = TextEditingController(), b = TextEditingController();
    String? err;
    final pw = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Change admin password'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('The new password for ${c.name}. Up to ${p.passwordMax} bytes. Keep it somewhere: it can\'t be read back.'),
            const SizedBox(height: 12),
            TextField(controller: a, obscureText: true, decoration: const InputDecoration(labelText: 'New password')),
            TextField(
              controller: b,
              obscureText: true,
              decoration: InputDecoration(labelText: 'Again', errorText: err, errorMaxLines: 2),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final x = a.text;
                if (x.isEmpty) return set(() => err = 'Enter a password.');
                if (utf8.encode(x).length > p.passwordMax) return set(() => err = 'At most ${p.passwordMax} bytes.');
                if (x.contains(' ')) return set(() => err = 'No spaces.');
                if (x != b.text) return set(() => err = "They don't match.");
                Navigator.pop(ctx, x);
              },
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );
    if (pw == null) return;
    await _run(() async {
      _log('> password ••••••');
      final f = await widget.app.session!.cli(c.key, 'password $pw');
      if (f == null || f.kind != 'message') {
        _log('(no reply: it may or may not have changed)');
        return _say('No reply, so the password may or may not have changed. ${_failure(f)}', true);
      }
      final t = (f['msg'] as p.TextMessage).text;
      _log(t.replaceAll(pw, '••••••'));
      _say(t.toUpperCase().contains('OK') || t.contains('password now') ? 'Password changed.' : 'The repeater said: $t',
          !(t.toUpperCase().contains('OK') || t.contains('password now')));
    });
  }

  // --- regions ------------------------------------------------------------------

  void _regionNote(String t, [bool isBad = false]) {
    if (mounted) {
      setState(() {
        r.regionNote = t;
        r.regionBad = isBad;
      });
    }
  }

  /// Runs a region command, logged in the console. Its reply, or null.
  Future<String?> _regionRun(String cmd) async {
    _log('> $cmd');
    final f = await widget.app.session!.cli(c.key, cmd);
    if (f == null || f.kind != 'message') {
      _log(f == null ? '(no reply)' : '(failed: ${_failure(f)})');
      _regionNote('No reply to “$cmd”. ${_failure(f)}', true);
      return null;
    }
    final t = (f['msg'] as p.TextMessage).text;
    _log(t);
    return t;
  }

  Future<bool> _readRegionsNow() async {
    _regionNote('Reading regions…');
    final tree = await _regionRun('region');
    if (tree == null) return false;
    final regions = p.parseRegions(tree);
    if (regions.isEmpty) {
      final shortTree = tree.length > 60 ? tree.substring(0, 60) : tree;
      _regionNote('This repeater didn\'t list any regions (it said “$shortTree”). It may need firmware 1.10 or later.', true);
      return false;
    }
    final d = await _regionRun('region default');
    r.regions = regions;
    if (d != null && d.contains('default scope is')) {
      final n = d.trim().split(' ').last;
      r.regionDefault = n == '<null>' ? '' : n.replaceFirst(RegExp(r'^#+'), '');
    }
    _regionNote(tree.length < 150
        ? 'Up to date.'
        : 'Up to date, but the list may be cut short: replies hold 160 characters. Use the console\'s region get <name> for the rest.');
    return true;
  }

  Future<void> _readRegions() => _run(_readRegionsNow);

  Future<void> _changeRegions(String cmd, String done) => _run(() async {
        final reply = await _regionRun(cmd);
        if (reply == null) return;
        final bad = reply.startsWith('Err');
        if (!bad) r.regionsUnsaved = true;
        if (await _readRegionsNow()) {
          _regionNote(bad ? 'The repeater said: $reply' : '$done Save to keep it after a restart.', bad);
        }
      });

  Future<void> _saveRegions() => _run(() async {
        final reply = await _regionRun('region save');
        if (reply == null) return;
        final ok = reply.startsWith('OK');
        if (ok) r.regionsUnsaved = false;
        _regionNote(ok ? 'Saved on the repeater.' : 'The repeater said: $reply', !ok);
      });

  Future<void> _addRegion([p.Region? under]) async {
    final name = TextEditingController();
    var parent = under?.name ?? '*';
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Add region'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              autofocus: true,
              autocorrect: false,
              maxLength: p.scopeNameMax - 1,
              decoration: InputDecoration(labelText: 'Name', hintText: 'e.g. boston', errorText: err, errorMaxLines: 3, counterText: ''),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: parent,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Inside'),
              items: [
                for (final x in r.regions ?? <p.Region>[])
                  DropdownMenuItem(value: x.name, child: Text(x.name == '*' ? '* (top level)' : x.name)),
              ],
              onChanged: (v) => parent = v ?? '*',
            ),
            const SizedBox(height: 8),
            Text('Floods scoped to it are allowed. A region inside another counts as part of it.',
                style: Theme.of(ctx).textTheme.bodySmall),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final problem = p.regionProblem(name.text);
                if (problem != null) return set(() => err = problem);
                if ((r.regions ?? []).any((x) => x.name == p.regionName(name.text))) {
                  return set(() => err = 'It already has that region.');
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final n = p.regionName(name.text);
    await _changeRegions('region put $n${parent != '*' ? ' $parent' : ''}', 'Added $n.');
  }

  Future<void> _regionMenu(p.Region reg) async {
    final root = reg.name == '*';
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(root ? '* (no scope)' : reg.name),
            subtitle: Text(reg.flood ? 'Relays its floods' : 'Doesn\'t relay its floods'),
          ),
          ListTile(
            leading: Icon(reg.flood ? Icons.block : Icons.check_circle_outline),
            title: Text(reg.flood ? 'Deny floods' : 'Allow floods'),
            onTap: () => Navigator.pop(ctx, 'flood'),
          ),
          if (!root) ...[
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Add a region inside it'),
              onTap: () => Navigator.pop(ctx, 'add'),
            ),
            if (!reg.home)
              ListTile(leading: const Icon(Icons.home_outlined), title: const Text('Make it the home region'), onTap: () => Navigator.pop(ctx, 'home')),
            if (reg.name != r.regionDefault)
              ListTile(
                leading: const Icon(Icons.travel_explore),
                title: const Text('Make it the default scope'),
                onTap: () => Navigator.pop(ctx, 'default'),
              ),
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Remove region'), onTap: () => Navigator.pop(ctx, 'remove')),
          ],
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    switch (pick) {
      case 'flood':
        if (reg.flood && root) {
          final go = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Deny unscoped floods?'),
              content: Text('Stop ${c.name} relaying floods that have no scope? Most nodes send those today, so this cuts '
                  'off anyone who hasn\'t set a scope. (Max hops, unscoped in Settings is a gentler way.)'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Deny')),
              ],
            ),
          );
          if (go != true) return;
        }
        await _changeRegions('region ${reg.flood ? 'denyf' : 'allowf'} ${reg.name}',
            '${reg.flood ? 'Denied' : 'Allowed'} floods for ${reg.name}.');
      case 'add':
        await _addRegion(reg);
      case 'home':
        await _changeRegions('region home ${reg.name}', '${reg.name} is now the home region.');
      case 'default':
        await _changeRegions('region default ${reg.name}', '${reg.name} is now the default scope.');
      case 'remove':
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Remove region'),
            content: Text('Remove ${reg.name} from ${c.name}?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
            ],
          ),
        );
        if (go == true) await _changeRegions('region remove ${reg.name}', 'Removed ${reg.name}.');
    }
  }

  // --- layout -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.app, widget.app.model]),
      builder: (context, _) {
        return DefaultTabController(
          length: 5,
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
              bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
                Tab(text: 'Status'),
                Tab(text: 'Console'),
                Tab(text: 'Settings'),
                Tab(text: 'Regions'),
                Tab(text: 'History'),
              ]),
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
                child: TabBarView(children: [_statusPage(), _consolePage(), _settingsPage(), _regionsPage(), _historyPage()]),
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

  Widget _field(Setting s, bool enabled) {
    final have = r.settings.containsKey(s.key);
    final changed = have && !s.same(_value(s), r.settings[s.key]!);
    final label = '${s.label}${s.unit.isNotEmpty ? ' (${s.unit})' : ''}${changed ? ' •' : ''}';
    final style = changed ? TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600) : null;
    InputDecoration dec({Widget? suffix}) => InputDecoration(
          label: Text(label, style: style),
          helperText: s.hint.isEmpty ? null : s.hint,
          helperMaxLines: 4,
          border: const OutlineInputBorder(),
          isDense: true,
          counterText: '',
          suffixIcon: suffix,
        );
    if (s.choices.isNotEmpty) {
      return DropdownButtonFormField<String>(
        initialValue: choice[s.key],
        key: ValueKey('${s.key}-${r.settings[s.key]}'),
        isExpanded: true,
        decoration: dec(),
        items: [
          for (final (i, ch) in s.choices.indexed) DropdownMenuItem(value: ch, child: Text(s.labels.isNotEmpty ? s.labels[i] : ch)),
        ],
        onChanged: enabled && have ? (v) => setState(() => choice[s.key] = v) : null,
      );
    }
    return TextField(
      controller: fields[s.key],
      enabled: enabled && have,
      obscureText: secretSettings.contains(s.key),
      maxLength: s.maxLen > 0 ? s.maxLen : null,
      autocorrect: false,
      keyboardType: s.lo != null ? TextInputType.numberWithOptions(signed: true, decimal: !s.whole) : null,
      onChanged: (_) => setState(() {}),
      decoration: dec(
        suffix: s.radio
            ? PopupMenuButton<String>(
                tooltip: 'Region presets',
                icon: const Icon(Icons.public),
                enabled: enabled && have,
                onSelected: (v) => setState(() => fields[s.key]!.text = v),
                itemBuilder: (_) => [
                  for (final x in presets) PopupMenuItem(value: formatRadio(x.freq, x.bw, x.sf, x.cr), child: Text(x.title)),
                ],
              )
            : null,
      ),
    );
  }

  Widget _settingsPage() {
    final enabled = r.loggedIn && r.isAdmin != false && !busy && ready;
    final changes = _changes();
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.all(12), children: [
          Text('Read the repeater\'s settings, change what you like, then Apply. Each change is checked and read back.',
              style: Theme.of(context).textTheme.bodySmall),
          for (final (title, about) in groups) ...[
            Row(children: [
              Expanded(child: SectionHeader(title)),
              TextButton(
                onPressed: enabled ? () => _readSome([for (final s in settings) if (s.group == title) s], title) : null,
                child: const Text('Read'),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(about, style: Theme.of(context).textTheme.bodySmall),
            ),
            for (final s in settings)
              if (s.group == title) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: _field(s, enabled)),
            if (title == 'Access')
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: enabled ? _changePassword : null,
                  icon: const Icon(Icons.password),
                  label: const Text('Change admin password…'),
                ),
              ),
          ],
        ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Row(children: [
            FilledButton.tonal(onPressed: enabled ? () => _readSome(settings) : null, child: const Text('Read all')),
            const Spacer(),
            TextButton(onPressed: changes.isNotEmpty && !busy ? _revert : null, child: const Text('Revert')),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: enabled && changes.isNotEmpty ? _apply : null,
              child: Text(changes.isEmpty ? 'Apply' : 'Apply ${changes.length}'),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _regionsPage() {
    final enabled = r.loggedIn && r.isAdmin != false && !busy && ready;
    final regs = r.regions;
    final cs = Theme.of(context).colorScheme;
    final home = regs?.where((x) => x.home).firstOrNull?.name;
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.all(12), children: [
          Text('Regions decide which scoped floods this repeater relays: one scoped to a region it allows floods for '
              'goes on, others stop here. * is floods with no scope. Tap a region to change it. Needs repeater firmware 1.10 or later.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Text(r.regionNote, style: TextStyle(color: r.regionBad ? cs.error : null, fontSize: 13)),
          if (regs != null) ...[
            const SizedBox(height: 8),
            Text('Home region: ${home ?? 'none'} · Default scope: ${(r.regionDefault ?? '').isEmpty ? 'none' : r.regionDefault}'
                '${r.regionsUnsaved ? ' · unsaved changes' : ''}',
                style: TextStyle(fontWeight: r.regionsUnsaved ? FontWeight.w600 : null)),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                for (final reg in regs)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.only(left: 12 + 20.0 * reg.depth, right: 12),
                    leading: Icon(reg.name == '*' ? Icons.public : Icons.place_outlined, size: 20),
                    title: Text(reg.name == '*' ? '* (no scope)' : reg.name),
                    subtitle: Text([
                      reg.flood ? 'floods allowed' : 'floods denied',
                      if (reg.home) 'home',
                      if (reg.name == r.regionDefault) 'default scope',
                    ].join(' · ')),
                    trailing: Icon(reg.flood ? Icons.check_circle : Icons.block, color: reg.flood ? cs.primary : cs.outline, size: 20),
                    onTap: enabled ? () => _regionMenu(reg) : null,
                  ),
              ]),
            ),
          ],
        ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Wrap(spacing: 8, runSpacing: 4, alignment: WrapAlignment.end, children: [
            FilledButton.tonal(onPressed: enabled ? _readRegions : null, child: const Text('Read')),
            OutlinedButton(onPressed: enabled && regs != null ? () => _addRegion() : null, child: const Text('Add…')),
            if ((r.regionDefault ?? '').isNotEmpty)
              OutlinedButton(
                onPressed: enabled ? () => _changeRegions('region default <null>', 'Cleared the default scope.') : null,
                child: const Text('Clear default'),
              ),
            FilledButton(onPressed: enabled && regs != null ? _saveRegions : null, child: const Text('Save')),
          ]),
        ),
      ),
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
