import 'package:dawarich/features/tracking/domain/models/location_fix.dart';
import 'package:dawarich/features/tracking/domain/models/tracker_settings.dart';
import 'package:tracelet/tracelet.dart' as tl;

typedef LocationFixHandler = Future<void> Function(LocationFix locationFix);
typedef HeartbeatHandler = Future<void> Function();

abstract interface class ITrackerEngine {
  void setLocationFixHandler(LocationFixHandler? handler);
  void setHeartbeatHandler(HeartbeatHandler? handler);
  Future<tl.State> startTracking(TrackerSettings settings);
  Future<tl.State> stopTracking();
  Future<tl.State> configure(TrackerSettings settings);
  Future<tl.State> updateConfiguration(TrackerSettings settings);

  /// alex-hack: re-checks the phone's power state (charging, battery saver,
  /// Wi-Fi place) and, if what it asks of the tracker changed since the
  /// configuration was last applied, re-applies it.
  Future<void> refreshPowerState();

  /// alex-hack: puts automatic mode into its moving state now (GPS on at the
  /// moving interval), instead of waiting for motion detection. Does nothing
  /// in timer mode or while GPS is paused.
  Future<void> startMoving();
  Future<void> updateForegroundNotification({
    String? title,
    String? body,
  });
}