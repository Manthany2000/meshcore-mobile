// Picking a flood scope: the region a channel's messages, or the node's floods,
// are kept to. Repeaters relay a scoped flood only if they allow its region, so
// a scope keeps local chatter local. Ported from MeshCore Desktop's scope_ui.py.
import 'package:material_ui/material_ui.dart';

import '../model.dart';
import '../protocol.dart' as p;

const scopeAbout = 'Repeaters set up with regions only relay a scoped flood if they allow its region, so a scope keeps '
    'messages inside an area. Ask your local mesh which region names its repeaters use.';

/// How a channel's scope reads in a subtitle or menu.
String scopeText(String scope, [String? nodeDefault]) {
  if (scope == noScope) return 'no scope';
  if (scope.isNotEmpty) return '#$scope';
  return nodeDefault != null && nodeDefault.isNotEmpty ? 'node default (#$nodeDefault)' : 'node default (none)';
}

/// For a channel: the node's default, no scope, or a region. For the node's
/// default: none, or a region. Gives the scope as the model keeps it, or null
/// if cancelled.
Future<String?> pickScope(
  BuildContext context, {
  required String title,
  required String intro,
  required String current,
  String? nodeDefault,
  bool forChannel = true,
  bool unscoped = true,
}) {
  var mode = current == noScope && forChannel ? 1 : (current.isNotEmpty && current != noScope ? 2 : 0);
  final name = TextEditingController(text: mode == 2 ? current : '');
  String? err;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final small = Theme.of(ctx).textTheme.bodySmall;
        return AlertDialog(
          title: Text(title),
          scrollable: true,
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(intro),
            const SizedBox(height: 8),
            Text(scopeAbout, style: small),
            const SizedBox(height: 8),
            RadioGroup<int>(
              groupValue: mode,
              onChanged: (v) => set(() => mode = v ?? 0),
              child: Column(children: [
                RadioListTile(
                  contentPadding: EdgeInsets.zero,
                  value: 0,
                  title: Text(forChannel
                      ? 'The node\'s default scope (${nodeDefault != null && nodeDefault.isNotEmpty ? '#$nodeDefault' : 'none set'})'
                      : 'No default: floods go out unscoped unless a channel has one'),
                ),
                if (forChannel)
                  RadioListTile(
                    contentPadding: EdgeInsets.zero,
                    value: 1,
                    enabled: unscoped,
                    title: const Text('No scope: every repeater may relay it'),
                    subtitle: unscoped ? null : const Text('Needs newer firmware on the node (protocol v12)'),
                  ),
                const RadioListTile(contentPadding: EdgeInsets.zero, value: 2, title: Text('A region')),
              ]),
            ),
            TextField(
              controller: name,
              autocorrect: false,
              maxLength: p.scopeNameMax - 1,
              decoration: InputDecoration(
                hintText: 'e.g. usa, ma, boston',
                prefixText: '#',
                errorText: err,
                errorMaxLines: 3,
                isDense: true,
                counterText: '',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => set(() {
                mode = 2;
                err = null;
              }),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (mode == 2) {
                  final problem = p.regionProblem(name.text);
                  if (problem != null) return set(() => err = problem);
                  Navigator.pop(ctx, p.regionName(name.text));
                } else {
                  Navigator.pop(ctx, mode == 1 ? noScope : '');
                }
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    ),
  );
}
