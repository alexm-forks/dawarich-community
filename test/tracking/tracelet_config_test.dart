import 'package:dawarich/features/tracking/application/services/tracelet_tracker_engine.dart';
import 'package:dawarich/features/tracking/domain/enum/location_precision.dart';
import 'package:dawarich/features/tracking/domain/models/tracker_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tracelet/tracelet.dart' as tl;

// alex-hack: automatic-mode intervals and the charging boost.
void main() {
  final engine = TraceletTrackerEngine();

  TrackerSettings settings({
    required int frequency,
    int minimumDistance = 10,
    LocationPrecision precision = LocationPrecision.balanced,
  }) =>
      TrackerSettings(
        userId: 1,
        automaticTracking: true,
        trackingFrequency: frequency,
        locationPrecision: precision,
        minimumPointDistance: minimumDistance,
        pointsPerBatch: 50,
        batchExpirationMinutes: 60,
        deviceId: 'test',
      );

  test('automatic mode, not charging: 5 min interval, free fixes every 5 s', () {
    final tl.Config config = engine.buildConfigurationForTest(settings(frequency: 0));

    expect(config.android.locationUpdateInterval, 5 * 60 * 1000);
    expect(config.android.fastestLocationUpdateInterval, 5000);
    expect(config.geo.batteryBudgetPerHour, 2.0);
    expect(config.geo.enableAdaptiveMode, isTrue);
    expect(config.geo.distanceFilter, 10.0);
    expect(config.geo.desiredAccuracy, tl.DesiredAccuracy.medium);
  });

  test('automatic mode, charging: dense, best accuracy, no budget', () {
    final tl.Config config = engine.buildConfigurationForTest(
      settings(frequency: 0),
      chargingBoost: true,
    );

    expect(config.android.locationUpdateInterval, 2000);
    expect(config.android.fastestLocationUpdateInterval, 1000);
    expect(config.geo.batteryBudgetPerHour, 0.0);
    expect(config.geo.enableAdaptiveMode, isFalse);
    expect(config.geo.disableElasticity, isTrue);
    expect(config.geo.distanceFilter, 5.0);
    expect(config.geo.desiredAccuracy, tl.DesiredAccuracy.high);
  });

  test('charging keeps a smaller configured distance filter', () {
    final tl.Config config = engine.buildConfigurationForTest(
      settings(frequency: 0, minimumDistance: 2),
      chargingBoost: true,
    );

    expect(config.geo.distanceFilter, 2.0);
  });

  test('automatic mode uses the chosen moving interval', () {
    final tl.Config config = engine.buildConfigurationForTest(
      settings(frequency: 0),
      movingIntervalSeconds: 60,
    );

    expect(config.android.locationUpdateInterval, 60 * 1000);
    expect(config.android.fastestLocationUpdateInterval, 5000);
  });

  test('a 5 s moving interval keeps fastest no slower than the interval', () {
    final tl.Config config = engine.buildConfigurationForTest(
      settings(frequency: 0),
      movingIntervalSeconds: 5,
    );

    expect(config.android.locationUpdateInterval, 5000);
    expect(config.android.fastestLocationUpdateInterval, 5000);
  });

  test('at a Wi-Fi place: network fixes only, no charging boost', () {
    final tl.Config config = engine.buildConfigurationForTest(
      settings(frequency: 0),
      chargingBoost: true,
      wifiPaused: true,
    );

    // Not passive: the tracker must still get fixes, or Tracelet never fires
    // the heartbeat that notices leaving the place.
    expect(config.geo.desiredAccuracy, tl.DesiredAccuracy.medium);
    expect(config.android.locationUpdateInterval, 15 * 60 * 1000);
    expect(config.android.fastestLocationUpdateInterval, 15 * 60 * 1000);
    expect(config.geo.batteryBudgetPerHour, 2.0);
    expect(config.geo.distanceFilter, 10.0);
  });

  test('timer mode is unchanged, charging or not', () {
    for (final bool charging in [false, true]) {
      final tl.Config config = engine.buildConfigurationForTest(
        settings(frequency: 10),
        chargingBoost: charging,
      );

      expect(config.android.locationUpdateInterval, 5000);
      expect(config.android.fastestLocationUpdateInterval, 2500);
      expect(config.geo.batteryBudgetPerHour, 2.0);
      expect(config.geo.distanceFilter, 10.0);
    }
  });
}
