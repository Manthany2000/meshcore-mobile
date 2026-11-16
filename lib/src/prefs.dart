// App-wide settings that aren't about one node: the accent colour, whether to
// notify, and nodes the user said not to offer setup for. A small JSON file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class Prefs extends ChangeNotifier {
  String accent = 'Teal';
  bool notifications = true;
  bool notifyDms = true, notifyMentions = true, notifyNodes = true;
  String theme = 'System'; // System, Light, Dark
  final noSetup = <String>{}; // node key prefixes (hex)
  File? _file;
  final Future<Directory> Function() dataDir;

  Prefs({Future<Directory> Function()? dataDir}) : dataDir = dataDir ?? getApplicationSupportDirectory;

  Future<void> load() async {
    try {
      _file = File('${(await dataDir()).path}/prefs.json');
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        accent = j['accent'] ?? accent;
        notifications = j['notify'] ?? notifications;
        notifyDms = j['notify_dms'] ?? notifyDms;
        notifyMentions = j['notify_mentions'] ?? notifyMentions;
        notifyNodes = j['notify_nodes'] ?? notifyNodes;
        theme = j['theme'] ?? theme;
        noSetup.addAll((j['no_setup'] as List? ?? []).cast<String>());
      }
    } catch (e) {
      debugPrint('prefs unreadable: $e');
    }
    notifyListeners();
  }

  Future<void> save() async {
    notifyListeners();
    final f = _file;
    if (f == null) return;
    try {
      await f.writeAsString(jsonEncode({
        'accent': accent,
        'theme': theme,
        'notify': notifications,
        'notify_dms': notifyDms,
        'notify_mentions': notifyMentions,
        'notify_nodes': notifyNodes,
        'no_setup': noSetup.toList(),
      }));
    } catch (e) {
      debugPrint('saving prefs: $e');
    }
  }
}
