// System notifications for DMs, @mentions and newly heard nodes while the app
// is in the background. Tapping one opens its chat.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _asked = false;
  int _id = 1;
  void Function(String payload) onTap = (_) {};
  String? launchPayload; // the notification that opened the app, if any

  static const _android = AndroidNotificationDetails('messages', 'Messages',
      channelDescription: 'Direct messages, mentions and new nodes', importance: Importance.high, priority: Priority.high);
  static const _details = NotificationDetails(
    android: _android,
    iOS: DarwinNotificationDetails(),
    linux: LinuxNotificationDetails(),
  );

  Future<void> init() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS || Platform.isLinux || Platform.isMacOS)) return;
    try {
      const darwin = DarwinInitializationSettings(
          requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false);
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: darwin,
          macOS: darwin,
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        ),
        onDidReceiveNotificationResponse: (r) {
          if (r.payload != null) onTap(r.payload!);
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) launchPayload = launch!.notificationResponse?.payload;
      _ready = true;
    } catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  /// Asks once per run, when there's a node to hear from: not at first launch.
  Future<void> askPermission() async {
    if (!_ready || _asked) return;
    _asked = true;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true, badge: false);
    } catch (e) {
      debugPrint('notification permission: $e');
    }
  }

  Future<void> show(String title, String body, {String? payload}) async {
    if (!_ready) return;
    try {
      await _plugin.show(id: _id++, title: title, body: body, notificationDetails: _details, payload: payload);
    } catch (e) {
      debugPrint('notify: $e');
    }
  }
}
