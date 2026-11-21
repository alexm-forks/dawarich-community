import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// alex-hack: settings for automatic mode that upstream doesn't have.
///
/// Kept in shared preferences rather than the Drift database, so a plain
/// upstream build can still open the same database. Uses
/// [SharedPreferencesAsync] (no in-memory cache) because the UI isolate writes
/// these and the background tracking isolate reads them.
final class AlexTrackingPreferences {
  const AlexTrackingPreferences._();

  static const String _movingIntervalKey = 'alex.tracking.moving_interval_seconds';
  static const String _chargingBoostKey = 'alex.tracking.charging_boost';
  static const String _batterySaverPauseKey = 'alex.tracking.battery_saver_pause';
  static const String _vehicleUntilKey = 'alex.tracking.vehicle_until_ms';

  /// Seconds between fixes while moving in automatic mode.
  static const int defaultMovingIntervalSeconds = 300;

  /// Choices offered in the app, in seconds.
  static const List<int> movingIntervalChoices = [5, 30, 60, 120, 300, 600];

  static const bool defaultChargingBoost = true;

  static const bool defaultBatterySaverPause = true;

  static Future<int> movingIntervalSeconds() async {
    try {
      final int? value =
          await SharedPreferencesAsync().getInt(_movingIntervalKey);
      return value != null && value > 0 ? value : defaultMovingIntervalSeconds;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[AlexTrackingPreferences] Read failed: $error');
      }
      return defaultMovingIntervalSeconds;
    }
  }

  static Future<void> setMovingIntervalSeconds(int seconds) =>
      SharedPreferencesAsync().setInt(_movingIntervalKey, seconds);

  /// Until when vehicle mode (dense fixes at vehicle speed) lasts. Kept here
  /// rather than in memory, as the fix that starts it and the heartbeat that
  /// ends it may arrive in different parts of the app.
  static Future<DateTime?> vehicleUntil() async {
    try {
      final int? ms = await SharedPreferencesAsync().getInt(_vehicleUntilKey);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[AlexTrackingPreferences] Read failed: $error');
      }
      return null;
    }
  }

  static Future<void> setVehicleUntil(DateTime until) =>
      SharedPreferencesAsync().setInt(_vehicleUntilKey, until.millisecondsSinceEpoch);

  static Future<bool> chargingBoost() async {
    try {
      return await SharedPreferencesAsync().getBool(_chargingBoostKey) ??
          defaultChargingBoost;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[AlexTrackingPreferences] Read failed: $error');
      }
      return defaultChargingBoost;
    }
  }

  static Future<void> setChargingBoost(bool enabled) =>
      SharedPreferencesAsync().setBool(_chargingBoostKey, enabled);

  /// Whether to turn GPS off while the phone's battery saver is on.
  static Future<bool> batterySaverPause() async {
    try {
      return await SharedPreferencesAsync().getBool(_batterySaverPauseKey) ??
          defaultBatterySaverPause;
    } catch (_) {
      return defaultBatterySaverPause;
    }
  }

  static Future<void> setBatterySaverPause(bool enabled) =>
      SharedPreferencesAsync().setBool(_batterySaverPauseKey, enabled);

  /// Whether battery saver is on and the setting says to turn GPS off for it.
  static Future<bool> batterySaverPausesGps() async {
    if (!await batterySaverPause()) return false;
    try {
      return await Battery().isInBatterySaveMode;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[AlexTrackingPreferences] Battery saver state unavailable: $error');
      }
      return false;
    }
  }
}
