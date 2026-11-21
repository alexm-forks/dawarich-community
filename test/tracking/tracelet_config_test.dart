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
    expect(config.geo.batteryBudgetPerHour, 0.0);
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
      gpsPaused: true,
    );

    // Not passive: the tracker must still get fixes, or Tracelet never fires
    // the heartbeat that notices leaving the place.
    expect(config.geo.desiredAccuracy, tl.DesiredAccuracy.medium);
    expect(config.android.locationUpdateInterval, 15 * 60 * 1000);
    expect(config.android.fastestLocationUpdateInterval, 15 * 60 * 1000);
    expect(config.geo.batteryBudgetPerHour, 0.0);
    expect(config.geo.distanceFilter, 10.0);
  });

  test('battery saver: network fixes, other apps\' fixes at most every 5 min', () {
    final tl.Config config = engine.buildConfigurationForTest(
      settings(frequency: 0),
      gpsPaused: true,
      takeOtherAppsFixes: true,
    );

    expect(config.geo.desiredAccuracy, tl.DesiredAccuracy.medium);
    expect(config.android.locationUpdateInterval, 15 * 60 * 1000);
    expect(config.android.fastestLocationUpdateInterval, 5 * 60 * 1000);
  });

  test('timer mode is unchanged, charging or not', () {
    for (final bool charging in [false, true]) {
      final tl.Config config = engine.buildConfigurationForTest(
        settings(frequency: 10),
        chargingBoost: charging,
      );

      expect(config.android.locationUpdateInterval, 5000);
      expect(config.android.fastestLocationUpdateInterval, 2500);
      expect(config.geo.batteryBudgetPerHour, 0.0);
      expect(config.geo.distanceFilter, 10.0);
    }
  });

  // alex-hack: a drive tracked at the 5-minute interval kept dropping to
  // "stationary": the speed machine's 180 s countdown after a slow fix ran
  // out before the next fix could show it was still moving.
  test('the stationary countdown is at least twice the interval', () {
    int delay(tl.Config config) => config.motion.speedStationaryDelay;

    expect(delay(engine.buildConfigurationForTest(settings(frequency: 0))), 600);
    expect(
      delay(engine.buildConfigurationForTest(settings(frequency: 0), movingIntervalSeconds: 30)),
      180,
    );
    expect(
      delay(engine.buildConfigurationForTest(settings(frequency: 0), chargingBoost: true)),
      180,
    );
  });

  test('vehicle speed: a fix every 15 s, no adaptive gate', () {
    final tl.Config config = engine.buildConfigurationForTest(
      settings(frequency: 0),
      vehicle: true,
    );

    expect(config.android.locationUpdateInterval, 15000);
    expect(config.android.fastestLocationUpdateInterval, 5000);
    expect(config.geo.enableAdaptiveMode, isFalse);
    expect(config.motion.speedStationaryDelay, 180);
  });

  test('vehicle mode gives way to the boost, a pause and a shorter interval', () {
    expect(
      engine.buildConfigurationForTest(settings(frequency: 0), vehicle: true, chargingBoost: true)
          .android.locationUpdateInterval,
      2000,
    );
    expect(
      engine.buildConfigurationForTest(settings(frequency: 0), vehicle: true, gpsPaused: true)
          .android.locationUpdateInterval,
      15 * 60 * 1000,
    );
    expect(
      engine.buildConfigurationForTest(settings(frequency: 0), vehicle: true, movingIntervalSeconds: 5)
          .android.locationUpdateInterval,
      5000,
    );
    expect(
      engine.buildConfigurationForTest(settings(frequency: 10), vehicle: true)
          .android.locationUpdateInterval,
      5000,
    );
  });
}
