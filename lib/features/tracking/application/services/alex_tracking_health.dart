import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tracelet/tracelet.dart' as tl;

/// alex-hack: warns when tracking is on but Android has left the tracker
/// without location.
///
/// If Android kills the app's process, the tracking service it re-creates in
/// the background is denied location for the whole life of that service
/// (Tracelet #405): the tracking notification stays up, but no fix arrives
/// until the app is opened, which re-creates the service from the
/// foreground. Run from a WorkManager job every ~15 minutes, this posts a
/// "tap to resume" notification in that state (and when the service isn't
/// running at all), and removes it once tracking is healthy again.
final class AlexTrackingHealth {
  const AlexTrackingHealth._();

  /// Tracelet's own tracking notification uses 7701.
  static const int _notificationId = 7702;
  static const String _channelId = 'alex_tracking_health';
  static const String _channelName = 'Tracking problems';

  /// Whether the health snapshot says tracking is wanted but can't get fixes.
  @visibleForTesting
  static bool needsResume(Map<String, Object?> health) {
    if (health['desiredEnabled'] != true) return false;
    if (health['foregroundServiceEnabled'] == false) return false;
    return health['locationCapabilityLikelyDenied'] == true ||
        health['serviceRunning'] != true;
  }

  /// Checks Tracelet's foreground-service health and shows or clears the
  /// notification. Never throws.
  static Future<void> checkAndNotify() async {
    try {
      final Map<String, Object?> health =
          await tl.Tracelet.getForegroundServiceHealth();

      if (kDebugMode) {
        debugPrint('[TrackingHealth] $health');
      }

      if (needsResume(health)) {
        await _show();
      } else {
        await clear();
      }
    } catch (error) {
      debugPrint('[TrackingHealth] Check failed: $error');
    }
  }

  /// Removes the notification (e.g. when the app opens). Never throws.
  static Future<void> clear() async {
    try {
      final plugin = await _plugin();
      await plugin.cancel(id: _notificationId);
    } catch (error) {
      debugPrint('[TrackingHealth] Clear failed: $error');
    }
  }

  static Future<void> _show() async {
    final plugin = await _plugin();
    await plugin.show(
      id: _notificationId,
      title: 'Tracking has no location access',
      body: 'Android restarted tracking in the background without location. '
          'Tap to open the app and resume.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription:
              'Shown when tracking is on but Android has cut off location',
          importance: Importance.high,
          priority: Priority.high,
          autoCancel: true,
          onlyAlertOnce: true,
          icon: 'ic_bg_service_small',
        ),
      ),
    );
  }

  static Future<FlutterLocalNotificationsPlugin> _plugin() async {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_bg_service_small'),
      ),
    );
    return plugin;
  }
}
