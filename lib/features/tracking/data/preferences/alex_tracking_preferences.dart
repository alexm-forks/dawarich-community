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

  /// Seconds between fixes while moving in automatic mode.
  static const int defaultMovingIntervalSeconds = 300;

  /// Choices offered in the app, in seconds.
  static const List<int> movingIntervalChoices = [5, 30, 60, 120, 300, 600];

  static const bool defaultChargingBoost = true;

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
}
