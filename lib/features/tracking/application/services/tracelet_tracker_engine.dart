
import 'dart:async';

import 'package:dawarich/core/constants/notification.dart';
import 'package:dawarich/features/tracking/application/interfaces/tracker_engine_interface.dart';
import 'package:dawarich/features/tracking/data/preferences/alex_tracking_preferences.dart';
import 'package:dawarich/features/tracking/data/preferences/alex_wifi_places.dart';
import 'package:dawarich/features/tracking/domain/enum/location_precision.dart';
import 'package:dawarich/features/tracking/domain/enum/tracking_mode.dart';
import 'package:dawarich/features/tracking/domain/models/location_fix.dart';
import 'package:dawarich/features/tracking/domain/models/tracker_settings.dart';

import 'package:battery_plus/battery_plus.dart' as battery_plus;
import 'package:flutter/foundation.dart';
import 'package:tracelet/tracelet.dart' as tl;

final class TraceletTrackerEngine implements ITrackerEngine {

  late final int _instanceId = identityHashCode(this);
  late String debugPrefix = "[TraceletTrackerEngine#$_instanceId]";

  static const int _streamLocationUpdateIntervalMs = 5000;
  static const int _fastestStreamLocationUpdateIntervalMs = 2500;

  // alex-hack: automatic mode asks for a fix every N seconds while moving
  // (set in the app, default 5 minutes), so GPS can power down between fixes,
  // but accepts fixes up to every 5 s that another app (e.g. navigation) is
  // already paying for.
  static const int _automaticFastestIntervalMs = 5000;

  // alex-hack: while charging, automatic mode tracks densely instead: a fix
  // every 2 s at the best accuracy, at most 5 m apart, no battery budget.
  // Motion detection stays on, so a phone sitting still on a charger still
  // turns GPS off.
  static const int _chargingIntervalMs = 2000;
  static const int _chargingFastestIntervalMs = 1000;
  static const double _chargingMaxDistanceFilterMeters = 5.0;

  // alex-hack: while GPS is paused (at a Wi-Fi place, or in battery saver),
  // don't power GPS: ask for a
  // network (Wi-Fi/cell) fix every 15 minutes instead. Not passive: with
  // passive and no other app using GPS the tracker never gets a fix, and
  // Tracelet only fires the heartbeat (where leaving the place is noticed)
  // once it has one, so the pause could never end. One fix after each
  // tracker restart is enough (the heartbeat reuses it however old), so the
  // interval can be long; the first fix arrives when the request starts.
  static const int _wifiPlaceIntervalMs = 15 * 60 * 1000;

  static TrackerSettings? _lastAppliedSettings;
  static bool _chargingBoostApplied = false;
  static bool _gpsPausedApplied = false;

  // alex-hack: in battery saver, take a fix from another app's GPS at most
  // every 5 minutes. Each one wakes the app to process and store it, so not
  // more often, even when e.g. navigation is running.
  static const int _batterySaverOtherAppsIntervalMs = 5 * 60 * 1000;
  static bool _takeOtherAppsFixesApplied = false;

  static const int _heartbeatIntervalSeconds = 60;
  static const int _automaticStopTimeoutMinutes = 5;
  static const double _automaticStationaryRadiusMeters = 50.0;
  static const double _defaultStationaryRadiusMeters = 25.0;

  static bool _isTraceletLocationCallbackRegistered = false;
  static bool _isTraceletHeartbeatCallbackRegistered = false;
  static String? _lastLocationUuid;
  static LocationFixHandler? _locationFixHandler;
  static HeartbeatHandler? _heartbeatHandler;

  void _registerTraceletLocationCallbackOnce() {
    if (_isTraceletLocationCallbackRegistered) {
      return;
    }

    _isTraceletLocationCallbackRegistered = true;

    tl.Tracelet.onLocation((tl.Location location) {
      if (kDebugMode) {
        debugPrint(
          '[TraceletTrackerEngine] Tracelet.onLocation fired: '
              'uuid=${location.uuid}, '
              'lat=${location.coords.latitude}, '
              'lon=${location.coords.longitude}, '
              'accuracy=${location.coords.accuracy}, '
              'speed=${location.coords.speed}, '
              'source=${location.locationSource}, '
              'timestamp=${location.timestamp}',
        );
      }

      if (_lastLocationUuid == location.uuid) {
        if (kDebugMode) {
          debugPrint(
            '[TraceletTrackerEngine] Duplicate Tracelet location ignored: '
                '${location.uuid}',
          );
        }

        return;
      }

      _lastLocationUuid = location.uuid;

      final LocationFix locationFix = _mapLocationFix(location);
      final LocationFixHandler? handler = _locationFixHandler;

      if (handler == null) {
        if (kDebugMode) {
          debugPrint(
            '[TraceletTrackerEngine] Dropping Tracelet location because '
                'no app handler is registered.',
          );
        }

        return;
      }

      unawaited(
        handler(locationFix).catchError((Object error, StackTrace stackTrace) {
          if (kDebugMode) {
            debugPrint('[TraceletTrackerEngine] Location handler failed: $error');
            debugPrint('$stackTrace');
          }
        }),
      );
    });
  }

  void _registerTraceletHeartbeatOnce() {

    if (_isTraceletHeartbeatCallbackRegistered) {
      return;
    }

    _isTraceletHeartbeatCallbackRegistered = true;

    tl.Tracelet.onHeartbeat((tl.HeartbeatEvent heartbeat) {
      if (kDebugMode) {
        debugPrint(
          '[TraceletTrackerEngine] Tracelet.onHeartbeat fired: '
        );
      }

      final HeartbeatHandler? handler = _heartbeatHandler;

      if (handler == null) {
        if (kDebugMode) {
          debugPrint(
            '[TraceletTrackerEngine] Dropping Tracelet heartbeat because '
                'no handler is registered.',
          );
        }

        return;
      }

      unawaited(
        handler().catchError((Object error, StackTrace stackTrace) {
          if (kDebugMode) {
            debugPrint('[TraceletTrackerEngine] Heartbeat handler failed: $error');
            debugPrint('$stackTrace');
          }
        }),
      );
    });
  }

  LocationFix _mapLocationFix(tl.Location location) {

    final tl.Coords coords = location.coords;

    return LocationFix(
      latitude: coords.latitude,
      longitude: coords.longitude,
      timestampUtc: _parseTimestampUtc(location.timestamp),
      hAccuracyMeters: coords.accuracy,
      altitudeMeters: coords.altitude,
      altitudeAccuracyMeters: coords.altitudeAccuracy,
      speedMps: coords.speed,
      speedAccuracyMps: coords.speedAccuracy,
      headingDegrees: coords.heading,
      headingAccuracyDegrees: coords.headingAccuracy,
      provider: location.locationSource,
      isMocked: location.isMock,
    );
  }

  DateTime _parseTimestampUtc(String timestamp) {
    return DateTime.tryParse(timestamp)?.toUtc() ?? DateTime.now().toUtc();
  }

  @override
  void setLocationFixHandler(LocationFixHandler? handler) {
    _locationFixHandler = handler;

    if (kDebugMode) {
      debugPrint(
        '[TraceletTrackerEngine] Location stream handler '
            '${handler == null ? 'cleared' : 'registered'}.',
      );
    }
  }

  @override
  void setHeartbeatHandler(HeartbeatHandler? handler) {

    _heartbeatHandler = handler;

    if (kDebugMode) {
      debugPrint(
        '[TraceletTrackerEngine] Heartbeat handler '
            '${handler == null ? 'cleared' : 'registered'}.',
      );
    }
  }

  // Todo: take ownership of the state model
  @override
  Future<tl.State> startTracking(TrackerSettings settings) async {
    if (kDebugMode) {
      debugPrint(
        '$debugPrefix startTracking called with '
            'mode=${settings.trackingMode}, '
            'frequency=${settings.trackingFrequency}, '
            'precision=${settings.locationPrecision}',
      );
    }

    final tl.State state;

    if (settings.trackingMode == TrackingMode.timer) {
      if (kDebugMode) {
        debugPrint('$debugPrefix Calling Tracelet.startPeriodic()');
      }

      state = await tl.Tracelet.startPeriodic();
    } else {
      if (kDebugMode) {
        debugPrint('$debugPrefix Calling Tracelet.start()');
      }

      state = await tl.Tracelet.start();
    }

    if (kDebugMode) {
      debugPrint('$debugPrefix Tracelet start returned state=$state');
    }

    return state;
  }

  @override
  Future<tl.State> stopTracking() async {

    return await tl.Tracelet.stop();
  }

  @override
  Future<tl.State> configure(TrackerSettings settings) async {
    if (kDebugMode) {
      debugPrint(
        '$debugPrefix configure called with '
            'mode=${settings.trackingMode}, '
            'frequency=${settings.trackingFrequency}',
      );
    }

    final tl.Config config = await _buildConfigurationWithChargingState(settings);

    _registerTraceletLocationCallbackOnce();
    _registerTraceletHeartbeatOnce();

    final tl.State state = await tl.Tracelet.ready(config);

    if (kDebugMode) {
      debugPrint('$debugPrefix Tracelet.ready returned state=$state');
    }

    return state;
  }

  @override
  Future<tl.State> updateConfiguration(TrackerSettings settings) async {

    final tl.Config config = await _buildConfigurationWithChargingState(settings);
    return await tl.Tracelet.setConfig(config);
  }

  @override
  Future<void> refreshPowerState() async {
    final TrackerSettings? settings = _lastAppliedSettings;

    if (settings == null) {
      return;
    }

    final state = await _powerState(settings);

    if (state.boost == _chargingBoostApplied &&
        state.gpsPaused == _gpsPausedApplied &&
        state.takeOtherAppsFixes == _takeOtherAppsFixesApplied) {
      return;
    }

    if (kDebugMode) {
      debugPrint(
        '$debugPrefix Power state changed (boost=${state.boost}, '
        'gpsPaused=${state.gpsPaused}); re-applying config.',
      );
    }

    await updateConfiguration(settings);
  }

  /// alex-hack: what the phone's state asks of the tracker right now.
  /// GPS is paused at a Wi-Fi place or in battery saver. In battery saver
  /// (away from a Wi-Fi place) fixes from other apps' GPS are still taken.
  /// The charging boost applies in automatic mode when plugged in and GPS
  /// isn't paused.
  static Future<({bool gpsPaused, bool takeOtherAppsFixes, bool boost})>
      _powerState(TrackerSettings settings) async {
    final bool wifiPaused = await AlexWifiPlaces.isPaused();
    final bool batterySaver =
        await AlexTrackingPreferences.batterySaverPausesGps();
    final bool gpsPaused = wifiPaused || batterySaver;
    final bool boost = settings.trackingMode == TrackingMode.automatic &&
        !gpsPaused &&
        await AlexTrackingPreferences.chargingBoost() &&
        await _isCharging();
    return (
      gpsPaused: gpsPaused,
      takeOtherAppsFixes: batterySaver && !wifiPaused,
      boost: boost,
    );
  }

  /// Reads the alex-hack preferences and the phone's power state right before
  /// building, so every isolate that applies a configuration applies the same
  /// one.
  Future<tl.Config> _buildConfigurationWithChargingState(
    TrackerSettings settings,
  ) async {
    final state = await _powerState(settings);
    final int movingIntervalSeconds =
        await AlexTrackingPreferences.movingIntervalSeconds();

    _lastAppliedSettings = settings;
    _chargingBoostApplied = state.boost;
    _gpsPausedApplied = state.gpsPaused;
    _takeOtherAppsFixesApplied = state.takeOtherAppsFixes;

    return _buildConfiguration(
      settings,
      chargingBoost: state.boost,
      movingIntervalSeconds: movingIntervalSeconds,
      gpsPaused: state.gpsPaused,
      takeOtherAppsFixes: state.takeOtherAppsFixes,
    );
  }

  /// Exposes [_buildConfiguration] to tests without touching the platform.
  @visibleForTesting
  tl.Config buildConfigurationForTest(
    TrackerSettings settings, {
    bool chargingBoost = false,
    int movingIntervalSeconds =
        AlexTrackingPreferences.defaultMovingIntervalSeconds,
    bool gpsPaused = false,
    bool takeOtherAppsFixes = false,
  }) =>
      _buildConfiguration(
        settings,
        chargingBoost: chargingBoost,
        movingIntervalSeconds: movingIntervalSeconds,
        gpsPaused: gpsPaused,
        takeOtherAppsFixes: takeOtherAppsFixes,
      );

  static Future<bool> _isCharging() async {
    try {
      final battery_plus.BatteryState state =
          await battery_plus.Battery().batteryState;

      return switch (state) {
        battery_plus.BatteryState.charging ||
        battery_plus.BatteryState.full ||
        battery_plus.BatteryState.connectedNotCharging => true,
        _ => false,
      };
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[TraceletTrackerEngine] Battery state unavailable: $error');
      }

      return false;
    }
  }

  @override
  Future<void> updateForegroundNotification({
    String? title,
    String? body,
  }) async {

    if (title != null || body != null) {
      final tl.Config config = tl.Config(
        android: tl.AndroidConfig(
          foregroundService: tl.ForegroundServiceConfig(
            notificationTitle: title,
            notificationText: body,
          ),
        ),
      );

      await tl.Tracelet.setConfig(config);
    }

    await tl.Tracelet.updateNotification();
  }

  tl.Config _buildConfiguration(
    TrackerSettings settings, {
    bool chargingBoost = false,
    int movingIntervalSeconds =
        AlexTrackingPreferences.defaultMovingIntervalSeconds,
    bool gpsPaused = false,
    bool takeOtherAppsFixes = false,
  }) {

    final bool isAutoMode = settings.trackingMode == TrackingMode.automatic;
    final bool boost = isAutoMode && chargingBoost && !gpsPaused;

    final double configuredDistanceFilter = settings
        .effectiveMinimumPointDistanceMeters
        .toDouble();
    final double distanceFilter = boost &&
            configuredDistanceFilter > _chargingMaxDistanceFilterMeters
        ? _chargingMaxDistanceFilterMeters
        : configuredDistanceFilter;

    final tl.GeoConfig geoConfig = tl.GeoConfig(
      desiredAccuracy: gpsPaused
          ? tl.DesiredAccuracy.medium
          : boost
              ? tl.DesiredAccuracy.high
              : _mapDesiredAccuracy(settings.locationPrecision),
      distanceFilter: distanceFilter,
      stationaryRadius: isAutoMode
          ? _automaticStationaryRadiusMeters
          : _defaultStationaryRadiusMeters,
      locationTimeout: 60,
      disableElasticity: boost,
      elasticityMultiplier: 1.0,
      stopAfterElapsedMinutes: -1,
      maxMonitoredGeofences: -1,
      enableTimestampMeta: false,
      enableAdaptiveMode: isAutoMode && !boost,
      periodicLocationInterval: gpsPaused
          ? _wifiPlaceIntervalMs ~/ 1000
          : _resolvePeriodicLocationInterval(settings),
      periodicDesiredAccuracy: gpsPaused
          ? tl.DesiredAccuracy.medium
          : _mapDesiredAccuracy(settings.locationPrecision),
      enableSparseUpdates: false,
      sparseDistanceThreshold: 50.0,
      sparseMaxIdleSeconds: 300,
      batteryBudgetPerHour: boost ? 0.0 : 2.0,
      enableDeadReckoning: false,
      deadReckoningActivationDelay: 0,
      deadReckoningMaxDuration: 0,
      filter: const tl.LocationFilter(),
      resolveAddress: false,

    );

    final tl.AppConfig appConfig = tl.AppConfig(
      stopOnTerminate: false,
      startOnBoot: true,
      heartbeatInterval: _heartbeatIntervalSeconds,
      schedule: const <String>[],
    );

    final tl.ForegroundServiceConfig foregroundServiceConfig = tl.ForegroundServiceConfig(
      enabled: true,
      channelId: NotificationConstants.channelId,
      channelName: NotificationConstants.channelName,
      notificationTitle: NotificationConstants.notificationTitle,
      notificationText: NotificationConstants.notificationContent,
      notificationColor: null,
      notificationSmallIcon: NotificationConstants.notificationIcon,
      notificationLargeIcon: NotificationConstants.notificationIcon,
      notificationPriority: tl.NotificationPriority.low,
      notificationOngoing: true,
      showNotificationOnPauseOnly: false,
      actions: const <String>[],

    );

    final tl.AndroidConfig androidConfig = tl.AndroidConfig(
      locationUpdateInterval: gpsPaused
          ? _wifiPlaceIntervalMs
          : !isAutoMode
          ? _streamLocationUpdateIntervalMs
          : boost
              ? _chargingIntervalMs
              : movingIntervalSeconds * 1000,
      // alex-hack: in battery saver, take other apps' GPS fixes at most every
      // 5 min; at a Wi-Fi place they'd be dropped, so don't wake for them.
      fastestLocationUpdateInterval: gpsPaused
          ? (takeOtherAppsFixes
              ? _batterySaverOtherAppsIntervalMs
              : _wifiPlaceIntervalMs)
          : !isAutoMode
          ? _fastestStreamLocationUpdateIntervalMs
          : boost
              ? _chargingFastestIntervalMs
              : movingIntervalSeconds * 1000 < _automaticFastestIntervalMs
                  ? movingIntervalSeconds * 1000
                  : _automaticFastestIntervalMs,
      deferTime: 0,
      allowIdenticalLocations: false,
      periodicUseForegroundService: true,
      periodicUseExactAlarms: false,
      scheduleUseAlarmManager: false,
      releaseWakelockWhenStationary: isAutoMode,
      foregroundService: foregroundServiceConfig,
    );

    final tl.IosConfig iosConfig = tl.IosConfig(
      activityType: tl.LocationActivityType.other,
      useSignificantChangesOnly: false,
      showsBackgroundLocationIndicator: false,
      pausesLocationUpdatesAutomatically: false,
      locationAuthorizationRequest: tl.LocationAuthorizationRequest.always,
      disableLocationAuthorizationAlert: false,
      preventSuspend: true,
    );


    final tl.LoggerConfig loggerConfig = tl.LoggerConfig(
      logLevel: kDebugMode ? tl.LogLevel.debug : tl.LogLevel.warning,
      logMaxDays: 3,
      debug: kDebugMode
    );

    final tl.MotionConfig motionConfig = isAutoMode
        ? const tl.MotionConfig(
      motionDetectionMode: tl.MotionDetectionMode.smart,
      stationaryTrackingMode: tl.StationaryTrackingMode.geofences,
      stopTimeout: _automaticStopTimeoutMinutes,
    )
        : const tl.MotionConfig();

    final tl.GeofenceConfig geofenceConfig = tl.GeofenceConfig();
    final tl.PersistenceConfig persistenceConfig = tl.PersistenceConfig(
      persistMode: tl.PersistMode.none
    );
    final tl.AuditConfig auditConfig = tl.AuditConfig();
    final tl.PrivacyZoneConfig privacyZoneConfig = tl.PrivacyZoneConfig();
    final tl.SecurityConfig securityConfig = tl.SecurityConfig();
    final tl.AttestationConfig attestationConfig = tl.AttestationConfig();
    final tl.TelematicsConfig telematicsConfig = tl.TelematicsConfig();
    final tl.ClassifierConfig classifierConfig = tl.ClassifierConfig();
    final tl.ImpactConfig impactConfig = tl.ImpactConfig();

    final tl.Config config = tl.Config(
      geo: geoConfig,
      app: appConfig,
      android: androidConfig,
      ios: iosConfig,
      logger: loggerConfig,
      motion: motionConfig,
      geofence: geofenceConfig,
      persistence: persistenceConfig,

      audit: auditConfig,
      privacyZone: privacyZoneConfig,
      security: securityConfig,
      attestation: attestationConfig,
      telematics: telematicsConfig,
      classifier: classifierConfig,
      impact: impactConfig,
    );

    _debugPrintEffectiveTraceletConfig(
      settings: settings,
      config: config,
    );

    return config;
  }

  // A small helper to ensure 0 doesn't get passed
  int _resolvePeriodicLocationInterval(TrackerSettings settings) {

    if (settings.trackingMode == TrackingMode.timer) {
      return settings.trackingFrequency;
    }

    return 60;
  }

  tl.DesiredAccuracy _mapDesiredAccuracy(
      LocationPrecision precision,
      ) {
    return switch (precision) {
      LocationPrecision.lowPower => tl.DesiredAccuracy.low,
      LocationPrecision.balanced => tl.DesiredAccuracy.medium,
      LocationPrecision.high => tl.DesiredAccuracy.high,
      LocationPrecision.best => tl.DesiredAccuracy.high,
    };
  }

  void _debugPrintEffectiveTraceletConfig({
    required TrackerSettings settings,
    required tl.Config config,
  }) {
    if (!kDebugMode) return;

    debugPrint('''
      $debugPrefix Effective Tracelet config
      ────────────────────────────────────
      Dawarich settings:
        trackingMode: ${settings.trackingMode}
        trackingFrequency: ${settings.trackingFrequency}
        locationPrecision: ${settings.locationPrecision}
        minimumPointDistance: ${settings.minimumPointDistance}
        automaticTracking: ${settings.automaticTracking}
        pointsPerBatch: ${settings.pointsPerBatch}
      
      Tracelet geo:
        desiredAccuracy: ${config.geo.desiredAccuracy}
        periodicDesiredAccuracy: ${config.geo.periodicDesiredAccuracy}
        distanceFilter: ${config.geo.distanceFilter}
        periodicLocationInterval: ${config.geo.periodicLocationInterval}
        enableAdaptiveMode: ${config.geo.enableAdaptiveMode}
        enableDeadReckoning: ${config.geo.enableDeadReckoning}
      
      Tracelet Android:
        locationUpdateInterval: ${config.android.locationUpdateInterval}
        fastestLocationUpdateInterval: ${config.android.fastestLocationUpdateInterval}
        periodicUseForegroundService: ${config.android.periodicUseForegroundService}
        periodicUseExactAlarms: ${config.android.periodicUseExactAlarms}
        scheduleUseAlarmManager: ${config.android.scheduleUseAlarmManager}
        releaseWakelockWhenStationary: ${config.android.releaseWakelockWhenStationary}
      
      Tracelet foreground service:
        enabled: ${config.android.foregroundService.enabled}
        channelId: ${config.android.foregroundService.channelId}
        channelName: ${config.android.foregroundService.channelName}
        title: ${config.android.foregroundService.notificationTitle}
        text: ${config.android.foregroundService.notificationText}
        priority: ${config.android.foregroundService.notificationPriority}
        ongoing: ${config.android.foregroundService.notificationOngoing}
        showNotificationOnPauseOnly: ${config.android.foregroundService.showNotificationOnPauseOnly}
      
      Tracelet app:
        stopOnTerminate: ${config.app.stopOnTerminate}
        startOnBoot: ${config.app.startOnBoot}
        heartbeatInterval: ${config.app.heartbeatInterval}
      ────────────────────────────────────
      ''');
  }
}