import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../../main.dart';
import '../model.dart';
import '../protocol.dart' as p;
import '../session.dart';
import 'chat.dart';
import 'common.dart';

class HomeScreen extends StatefulWidget {
  final AppState app;
  const HomeScreen({super.key, required this.app});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int tab = 0;
  StreamSubscription? _newContacts;

  @override
  void initState() {
    super.initState();
    _newContacts = widget.app.model.newContacts.stream.listen((c) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('New ${typeName(c.type).toLowerCase()} heard: ${c.name}'),
        duration: const Duration(seconds: 3),
      ));
    });
  }

  @override
  void dispose() {
    _newContacts?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final m = app.model;
    return ListenableBuilder(
      listenable: Listenable.merge([app, m]),
      builder: (context, _) {
        final s = app.session;
        final unread = [for (final c in m.channels.keys) chanConv(c), ...m.dmConvs()].fold(0, (a, c) => a + m.unread(c));
        return Scaffold(
          appBar: AppBar(
            title: Text(m.selfInfo?.name ?? 'MeshCore'),
            actions: [
              if (m.batteryMv > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(children: [
                    Icon(_battIcon(p.battPercent(m.batteryMv)), size: 20),
                    const SizedBox(width: 2),
                    Text('${p.battPercent(m.batteryMv)}%'),
                  ]),
                ),
            ],
            bottom: s != null && s.state != LinkState.ready
                ? PreferredSize(preferredSize: const Size.fromHeight(32), child: _LinkBanner(app: app))
                : null,
          ),
          body: IndexedStack(index: tab, children: [
            ChatsTab(app: app),
            ContactsTab(app: app),
            NodeTab(app: app),
          ]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: [
              NavigationDestination(
                icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.forum_outlined)),
                selectedIcon: const Icon(Icons.forum),
                label: 'Chats',
              ),
              const NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Contacts'),
              const NavigationDestination(icon: Icon(Icons.router_outlined), selectedIcon: Icon(Icons.router), label: 'Node'),
            ],
          ),
        );
      },
    );
  }
}

IconData _battIcon(int pct) => pct > 80
    ? Icons.battery_full
    : pct > 50
        ? Icons.battery_5_bar
        : pct > 20
            ? Icons.battery_3_bar
            : Icons.battery_1_bar;

class _LinkBanner extends StatelessWidget {
  final AppState app;
  const _LinkBanner({required this.app});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final down = app.session?.state == LinkState.disconnected;
    return Container(
      height: 32,
      color: down ? cs.errorContainer : cs.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Expanded(child: Text(linkStateText(app.session), overflow: TextOverflow.ellipsis)),
        if (down) TextButton(onPressed: app.reconnectNow, child: const Text('Retry now')),
      ]),
    );
  }
}

// --- Chats ----------------------------------------------------------------------

class ChatsTab extends StatelessWidget {
  final AppState app;
  const ChatsTab({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final m = app.model;
    final chans = m.channels.values.toList()..sort((a, b) => a.idx.compareTo(b.idx));
    final dms = m.dmConvs();
    return Scaffold(
      body: ListView(children: [
        const SectionHeader('Channels'),
        for (final c in chans) _ConvTile(app: app, conv: chanConv(c.idx), icon: Icons.tag),
        if (chans.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No channels yet.')),
        const SectionHeader('Direct messages'),
        for (final c in dms) _ConvTile(app: app, conv: c, icon: Icons.person_outline),
        if (dms.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No DMs yet. Open a contact to message them.'),
          ),
        const SizedBox(height: 80),
      ]),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add channel',
        onPressed: () => _addChannel(context, app),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _ConvTile extends StatelessWidget {
  final AppState app;
  final String conv;
  final IconData icon;
  const _ConvTile({required this.app, required this.conv, required this.icon});

  @override
  Widget build(BuildContext context) {
    final m = app.model;
    final last = m.lastIn(conv);
    final n = m.unread(conv);
    return ListTile(
      leading: CircleAvatar(child: Icon(icon)),
      title: Text(m.convTitle(conv), style: n > 0 ? const TextStyle(fontWeight: FontWeight.bold) : null),
      subtitle: last == null
          ? null
          : Text(
              '${last.outgoing ? 'You' : last.sender}: ${last.text}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (last != null) Text(shortTime(last.at), style: Theme.of(context).textTheme.labelSmall),
          if (n > 0) ...[const SizedBox(height: 4), Badge(label: Text('$n'))],
        ],
      ),
      onTap: () => openChat(context, app, conv),
      onLongPress: conv.startsWith('ch:') ? () => _channelMenu(context, app, int.parse(conv.substring(3))) : null,
    );
  }
}

void openChat(BuildContext context, AppState app, String conv) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(app: app, conv: conv)));
}

Uint8List hashtagSecret(String name) =>
    SHA256Digest().process(Uint8List.fromList(utf8.encode(name))).sublist(0, 16);

Future<void> _addChannel(BuildContext context, AppState app) async {
  final s = app.session;
  if (s == null || s.state != LinkState.ready) return;
  final m = app.model;
  final free = [for (var i = 0; i < s.maxChannels; i++) i].where((i) => !m.channels.containsKey(i)).firstOrNull;
  if (free == null) {
    toast(context, 'All ${s.maxChannels} channel slots are in use');
    return;
  }
  final name = TextEditingController();
  final secret = TextEditingController();
  var private = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Add channel'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('#hashtag')),
              ButtonSegment(value: true, label: Text('Private')),
            ],
            selected: {private},
            onSelectionChanged: (v) => set(() => private = v.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: name,
            autofocus: true,
            decoration: InputDecoration(labelText: 'Name', hintText: private ? 'My group' : '#test'),
          ),
          if (private)
            TextField(
              controller: secret,
              decoration: const InputDecoration(labelText: 'Secret', hintText: '32 hex digits, or blank for random'),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  var n = name.text.trim();
  Uint8List key;
  if (private) {
    final h = secret.text.replaceAll(' ', '').toLowerCase();
    if (n.isEmpty || (h.isNotEmpty && !RegExp(r'^[0-9a-f]{32}$').hasMatch(h))) {
      toast(context, 'Give it a name, and a secret of 32 hex digits or blank for a random one');
      return;
    }
    final rnd = Random.secure();
    key = h.isEmpty ? Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256))) : p.unhex(h);
  } else {
    n = n.replaceAll(' ', '');
    if (!n.startsWith('#')) n = '#$n';
    if (n.length < 2) return;
    key = hashtagSecret(n);
  }
  final f = await s.setChannel(free, n, key);
  if (context.mounted) toast(context, f?.kind == 'ok' ? 'Added $n' : 'The node refused it');
}

Future<void> _channelMenu(BuildContext context, AppState app, int idx) async {
  final m = app.model;
  final ch = m.channels[idx];
  if (ch == null) return;
  final remove = await showModalBottomSheet<bool>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(ch.name), subtitle: Text('Slot $idx')),
        ListTile(
          leading: const Icon(Icons.done_all),
          title: const Text('Mark read'),
          onTap: () {
            m.markRead(chanConv(idx));
            Navigator.pop(ctx, false);
          },
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Remove channel'),
          onTap: () => Navigator.pop(ctx, true),
        ),
      ]),
    ),
  );
  if (remove == true) await app.session?.setChannel(idx, '', Uint8List(16));
}

// --- Contacts ---------------------------------------------------------------------

class ContactsTab extends StatefulWidget {
  final AppState app;
  const ContactsTab({super.key, required this.app});

  @override
  State<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<ContactsTab> {
  String filter = '';
  int? type;

  @override
  Widget build(BuildContext context) {
    final m = widget.app.model;
    final all = m.contacts.values
        .where((c) => (type == null || c.type == type) && c.name.toLowerCase().contains(filter.toLowerCase()))
        .toList()
      ..sort((a, b) => (m.contactAge(a) ?? 1e12).compareTo(m.contactAge(b) ?? 1e12));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search contacts',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => filter = v),
        ),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          for (final (t, label) in [(null, 'All'), (p.advChat, 'People'), (p.advRepeater, 'Repeaters'), (p.advRoom, 'Rooms')])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(label), selected: type == t, onSelected: (_) => setState(() => type = t)),
            ),
        ]),
      ),
      Expanded(
        child: all.isEmpty
            ? const Center(child: Text('No contacts'))
            : ListView.builder(
                itemCount: all.length,
                itemBuilder: (context, i) {
                  final c = all[i];
                  final age = m.contactAge(c);
                  final km = m.distanceKm(c);
                  return ListTile(
                    leading: CircleAvatar(child: Icon(typeIcon(c.type))),
                    title: Text(c.name.isEmpty ? c.prefixHex : c.name),
                    subtitle: Text([
                      hopsText(c.hops),
                      if (km != null) '${km.toStringAsFixed(1)} km',
                    ].join(' · ')),
                    trailing: age == null ? null : Text(ago(age), style: Theme.of(context).textTheme.labelSmall),
                    onTap: () => showContact(context, widget.app, c),
                  );
                },
              ),
      ),
    ]);
  }
}

Future<void> showContact(BuildContext context, AppState app, p.Contact c) {
  final m = app.model;
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: m,
      builder: (ctx, _) {
        final cur = m.contacts[c.prefixHex] ?? c;
        final route = cur.hops < 0
            ? 'No stored route: messages flood'
            : cur.hops == 0
                ? 'Direct, no repeaters'
                : cur.path.hops().map((h) => m.hopNames(p.hex(h)).firstOrNull ?? p.hex(h)).join(' → ');
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(
              leading: CircleAvatar(child: Icon(typeIcon(cur.type))),
              title: Text(cur.name, style: Theme.of(ctx).textTheme.titleMedium),
              subtitle: Text('${typeName(cur.type)} · ${cur.prefixHex}'),
            ),
            ListTile(dense: true, leading: const Icon(Icons.alt_route), title: Text(hopsText(cur.hops)), subtitle: Text(route)),
            if (cur.lat != 0 || cur.lon != 0)
              ListTile(
                dense: true,
                leading: const Icon(Icons.place_outlined),
                title: Text('${cur.lat.toStringAsFixed(4)}, ${cur.lon.toStringAsFixed(4)}'),
                subtitle: m.distanceKm(cur) != null ? Text('${m.distanceKm(cur)!.toStringAsFixed(1)} km away') : null,
              ),
            const Divider(),
            if (cur.type == p.advChat || cur.type == p.advRoom)
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: const Text('Message'),
                onTap: () {
                  Navigator.pop(ctx);
                  openChat(context, app, dmConv(cur.key));
                },
              ),
            ListTile(
              leading: const Icon(Icons.waves),
              title: const Text('Reset route'),
              subtitle: const Text('The next message floods; their reply sets a fresh route'),
              onTap: () async {
                final f = await app.session?.resetPath(cur.key);
                if (ctx.mounted) toast(ctx, f?.kind == 'ok' ? 'Route reset' : 'Couldn\'t reset the route');
              },
            ),
            if (cur.type == p.advChat)
              SwitchListTile(
                secondary: const Icon(Icons.all_inclusive),
                title: const Text('Always flood messages'),
                value: m.alwaysFloods(cur.prefixHex),
                onChanged: (v) => m.setAlwaysFlood(cur.prefixHex, v),
              ),
          ]),
        );
      },
    ),
  );
}

// --- Node ---------------------------------------------------------------------------

class NodeTab extends StatelessWidget {
  final AppState app;
  const NodeTab({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final m = app.model;
    final s = m.selfInfo;
    final di = m.deviceInfo;
    final pk = m.packets;
    final now = nowS();
    final lastMin = pk.where((e) => now - e.$1 < 60).toList();
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.router),
            title: Text(s?.name ?? ''),
            subtitle: Text(app.session?.t.label ?? ''),
          ),
          if (s != null) ...[
            _kv('Radio', '${s.freq.toStringAsFixed(3)} MHz · BW ${s.bw} kHz · SF${s.sf} · CR${s.cr}'),
            _kv('TX power', '${s.txPower} dBm (max ${s.maxTx})'),
            _kv('Key', p.hex(s.key.sublist(0, 8))),
            if (s.lat != 0 || s.lon != 0) _kv('Position', '${s.lat.toStringAsFixed(4)}, ${s.lon.toStringAsFixed(4)}'),
          ],
          if (m.batteryMv > 0) _kv('Battery', '${(m.batteryMv / 1000).toStringAsFixed(2)} V (${p.battPercent(m.batteryMv)}%)'),
          if (di != null) ...[
            _kv('Firmware', [di['fw'], di['build']].where((x) => (x as String).isNotEmpty).join(' · ')),
            if ((di['model'] as String).isNotEmpty) _kv('Hardware', di['model']),
          ],
          const SizedBox(height: 8),
        ]),
      ),
      Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const ListTile(leading: Icon(Icons.campaign_outlined), title: Text('Advertise')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonal(onPressed: () => _advert(context, false), child: const Text('Zero hop')),
              FilledButton.tonal(onPressed: () => _advert(context, true), child: const Text('Flood')),
            ]),
          ),
        ]),
      ),
      Card(
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.graphic_eq),
            title: const Text('Traffic'),
            subtitle: Text('${pk.length} packets heard this session · ${lastMin.length} in the last minute'),
          ),
          for (final (at, r) in pk.reversed.take(8))
            ListTile(
              dense: true,
              title: Text('${_ptype(r.payloadType)} · ${r.flood ? '${r.hops} hops' : 'direct'}'),
              subtitle: r.path.data.isEmpty ? null : Text(r.path.hops().map(p.hex).join(' → ')),
              trailing: Text('${r.snr.toStringAsFixed(1)} dB\n${shortTime(at, seconds: true)}',
                  textAlign: TextAlign.end, style: Theme.of(context).textTheme.labelSmall),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: app.disconnect,
        icon: const Icon(Icons.link_off),
        label: const Text('Disconnect'),
      ),
    ]);
  }

  Widget _kv(String k, String v) => ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text(k),
        trailing: Text(v),
      );

  Future<void> _advert(BuildContext context, bool flood) async {
    final f = await app.session?.advert(flood);
    if (context.mounted) toast(context, f?.kind == 'ok' ? (flood ? 'Flood advert sent' : 'Zero-hop advert sent') : 'Advert failed');
  }
}

String _ptype(int t) => switch (t) {
      0 => 'Request',
      1 => 'Response',
      2 => 'Direct message',
      3 => 'Ack',
      4 => 'Advert',
      5 => 'Channel message',
      6 => 'Group data',
      7 => 'Anon request',
      8 => 'Path',
      9 => 'Trace',
      _ => 'Type $t',
    };
