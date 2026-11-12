import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../main.dart';
import '../model.dart';
import '../protocol.dart' as p;
import '../session.dart';
import 'common.dart';
import 'contact_sheet.dart';
import 'map.dart';

class ChatScreen extends StatefulWidget {
  final AppState app;
  final String conv;
  const ChatScreen({super.key, required this.app, required this.conv});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final text = TextEditingController();
  final focus = FocusNode();

  Model get m => widget.app.model;
  bool get isChannel => widget.conv.startsWith('ch:');

  @override
  void initState() {
    super.initState();
    m.addListener(_read);
    text.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => m.markRead(widget.conv));
  }

  void _read() {
    // Seen as it arrives while the chat is open.
    if (m.unread(widget.conv) > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) m.markRead(widget.conv);
      });
    }
  }

  @override
  void dispose() {
    m.removeListener(_read);
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  /// Bytes left: the node cuts a message at 160, and for channels that
  /// includes "name: ".
  int get _left {
    final used = utf8.encode(text.text).length + (isChannel ? utf8.encode('${m.selfInfo?.name ?? ''}: ').length : 0);
    return p.textMax - used;
  }

  Future<void> _send() async {
    final s = widget.app.session;
    final t = text.text.trim();
    if (t.isEmpty || _left < 0 || s == null || s.state != LinkState.ready) return;
    text.clear();
    await s.send(widget.conv, t);
  }

  void _reply(Message msg) {
    final tag = '@[${msg.sender}] ';
    if (!text.text.startsWith(tag)) text.text = tag + text.text;
    text.selection = TextSelection.collapsed(offset: text.text.length);
    focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: Listenable.merge([app, m]),
      builder: (context, _) {
        final msgs = m.conversation(widget.conv);
        final ready = app.session?.state == LinkState.ready;
        final contact = isChannel ? null : m.contacts[widget.conv.substring(3)];
        return Scaffold(
          appBar: AppBar(
            title: GestureDetector(
              onTap: contact == null ? null : () => showContact(context, app, contact),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.convTitle(widget.conv)),
                if (contact != null)
                  Text(
                    m.alwaysFloods(contact.prefixHex) ? 'Always flood' : hopsText(contact.hops),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ]),
            ),
            actions: [
              if (contact != null)
                IconButton(
                  tooltip: 'Flood the next message',
                  icon: const Icon(Icons.waves),
                  onPressed: () async {
                    final f = await app.session?.resetPath(contact.key);
                    if (context.mounted) toast(context, f?.kind == 'ok' ? 'Next message floods' : 'Couldn\'t reset the route');
                  },
                ),
            ],
          ),
          body: Column(children: [
            Expanded(
              child: msgs.isEmpty
                  ? const Center(child: Text('No messages yet'))
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) {
                        final msg = msgs[msgs.length - 1 - i];
                        final prev = i + 1 < msgs.length ? msgs[msgs.length - 2 - i] : null;
                        final showName = isChannel && !msg.outgoing && (prev == null || prev.sender != msg.sender || prev.outgoing);
                        return _Bubble(
                          msg: msg,
                          showName: showName,
                          me: m.selfInfo?.name ?? '',
                          onTap: () => _details(context, msg),
                          onLongPress: () => _menu(context, msg),
                        );
                      },
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: TextField(
                      controller: text,
                      focusNode: focus,
                      enabled: ready,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: ready ? 'Message' : 'Not connected',
                        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        counterText: '',
                        suffixText: text.text.isEmpty ? null : '$_left',
                        suffixStyle: TextStyle(color: _left < 0 ? Theme.of(context).colorScheme.error : null),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: ready && text.text.trim().isNotEmpty && _left >= 0 ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }

  Future<void> _menu(BuildContext context, Message msg) async {
    final again = msg.outgoing && (msg.status == MsgStatus.failed || msg.status == MsgStatus.noAck);
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!msg.outgoing && isChannel)
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(ctx);
                _reply(msg);
              },
            ),
          if (again)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Send again'),
              onTap: () {
                Navigator.pop(ctx);
                widget.app.session?.resend(msg);
              },
            ),
          if (!msg.outgoing)
            ListTile(
              leading: const Icon(Icons.route),
              title: const Text('Trace on map'),
              onTap: () {
                Navigator.pop(ctx);
                widget.app.showOnMap(TraceRequest(msg));
              },
            ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Details'),
            onTap: () {
              Navigator.pop(ctx);
              _details(context, msg);
            },
          ),
        ]),
      ),
    );
  }

  void _details(BuildContext context, Message msg) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => ListenableBuilder(
        listenable: m,
        builder: (ctx, _) {
          String names(String h) {
            final n = m.hopNames(h);
            return n.isEmpty ? h : '${n.first}${n.length > 1 ? ' (+${n.length - 1})' : ''}';
          }

          final reps = msg.repeaters.values.toList()
            ..sort((a, b) => (b.direct ? 1 : 0).compareTo(a.direct ? 1 : 0));
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
                Text(msg.text, style: Theme.of(ctx).textTheme.bodyLarge),
                const SizedBox(height: 8),
                if (!msg.outgoing)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        widget.app.showOnMap(TraceRequest(msg));
                      },
                      icon: const Icon(Icons.route),
                      label: const Text('Trace on map'),
                    ),
                  ),
                const SizedBox(height: 12),
                _row(ctx, 'From', msg.outgoing ? 'You' : msg.sender),
                _row(ctx, 'Time', shortTime(msg.at, seconds: true)),
                if (msg.outgoing) _row(ctx, 'Status', _statusText(msg)),
                if (!msg.outgoing) _row(ctx, 'Route', msg.hops < 0 ? 'Direct route' : '${hopsText(msg.hops)} (flood)'),
                if (msg.snr != null) _row(ctx, 'SNR', '${msg.snr!.toStringAsFixed(1)} dB'),
                if (msg.path != null && msg.path!.isNotEmpty) _row(ctx, 'Path', msg.path!.map(names).join(' → ')),
                _row(ctx, 'Repeats heard', '${msg.repeats}'),
                if (reps.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Relayed by', style: Theme.of(ctx).textTheme.titleSmall),
                  for (final r in reps)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(r.direct ? Icons.cell_tower : Icons.more_horiz),
                      title: Text(names(r.hash)),
                      subtitle: Text(r.direct ? 'Heard directly' : 'Further along'),
                      trailing: r.snr != null ? Text('${r.snr!.toStringAsFixed(1)} dB') : null,
                    ),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _row(BuildContext ctx, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: Theme.of(ctx).textTheme.labelLarge)),
          Expanded(child: Text(v)),
        ]),
      );
}

String _statusText(Message m) => switch (m.status) {
      MsgStatus.sending => 'Sending…',
      MsgStatus.sent => 'Sent',
      MsgStatus.waiting => 'On air, waiting for an ack',
      MsgStatus.delivered => 'Delivered in ${(m.tripMs / 1000).toStringAsFixed(1)} s',
      MsgStatus.noAck => 'No ack (it may still have arrived)',
      MsgStatus.failed => 'Failed: the node didn\'t take it',
      MsgStatus.incoming => '',
    };

class _Bubble extends StatelessWidget {
  final Message msg;
  final bool showName;
  final String me;
  final VoidCallback onTap, onLongPress;
  const _Bubble({required this.msg, required this.showName, required this.me, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final out = msg.outgoing;
    final mentioned = !out && me.isNotEmpty && msg.text.contains('@[$me]');
    final bg = out ? cs.primaryContainer : (mentioned ? cs.tertiaryContainer : cs.surfaceContainerHighest);
    final fg = out ? cs.onPrimaryContainer : (mentioned ? cs.onTertiaryContainer : cs.onSurface);
    final meta = [
      shortTime(msg.at),
      if (!out && msg.hops >= 0) hopsText(msg.hops),
      if (msg.repeats > 0) '↻${msg.repeats}',
    ].join(' · ');
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        child: Padding(
          padding: EdgeInsets.only(top: showName ? 10 : 3),
          child: Material(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(out ? 16 : 4),
              bottomRight: Radius.circular(out ? 4 : 16),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  if (showName) Text(msg.sender, style: tt.labelMedium?.copyWith(color: cs.primary, fontWeight: FontWeight.bold)),
                  _MentionText(msg.text, style: tt.bodyMedium?.copyWith(color: fg), mention: cs.primary),
                  const SizedBox(height: 2),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(meta, style: tt.labelSmall?.copyWith(color: fg.withValues(alpha: 0.7))),
                    if (out) ...[const SizedBox(width: 4), _StatusIcon(msg, color: fg.withValues(alpha: 0.7))],
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final Message msg;
  final Color color;
  const _StatusIcon(this.msg, {required this.color});

  @override
  Widget build(BuildContext context) {
    final err = Theme.of(context).colorScheme.error;
    return switch (msg.status) {
      MsgStatus.sending => SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: color)),
      MsgStatus.sent || MsgStatus.waiting => Icon(Icons.check, size: 14, color: color),
      MsgStatus.delivered => Icon(Icons.done_all, size: 14, color: Theme.of(context).colorScheme.primary),
      MsgStatus.noAck => Icon(Icons.close, size: 14, color: err),
      MsgStatus.failed => Icon(Icons.error_outline, size: 14, color: err),
      MsgStatus.incoming => const SizedBox.shrink(),
    };
  }
}

/// Text with @[Name] mentions drawn bold in the accent colour.
class _MentionText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final Color mention;
  const _MentionText(this.text, {this.style, required this.mention});

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var at = 0;
    for (final mm in RegExp(r'@\[([^\]]+)\]').allMatches(text)) {
      if (mm.start > at) spans.add(TextSpan(text: text.substring(at, mm.start)));
      spans.add(TextSpan(text: '@${mm.group(1)}', style: TextStyle(color: mention, fontWeight: FontWeight.bold)));
      at = mm.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}
