import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dawarich/features/batch/application/usecases/batch_upload_workflow_usecase.dart';
import 'package:dawarich/features/batch/application/usecases/get_current_batch_usecase.dart';
import 'package:dawarich/features/tracking/application/interfaces/tracker_engine_interface.dart';
import 'package:dawarich/features/tracking/application/usecases/get_batch_point_count_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/get_last_point_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/point_creation/create_point_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/point_creation/store_point_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/settings/get_tracker_settings_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/settings/save_tracker_settings_usecase.dart';
import 'package:dawarich/features/tracking/data/preferences/alex_tracking_preferences.dart';
import 'package:dawarich/features/tracking/data/preferences/alex_wifi_places.dart';
import 'package:dawarich/features/tracking/domain/models/location_fix.dart';
import 'package:dawarich/features/tracking/domain/models/tracker_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:option_result/option_result.dart';
import 'package:tracelet/tracelet.dart';

final class PointAutomationService {

  final ITrackerEngine _trackerEngine;
  final CreatePointUseCase _createPoint;
  final StorePointUseCase _storePoint;
  final GetLastPointUseCase _getLastPoint;
  final GetBatchPointCountUseCase _getBatchPointCount;
  final GetCurrentBatchUseCase _getCurrentBatch;
  final BatchUploadWorkflowUseCase _batchUploadWorkflow;
  final GetTrackerSettingsUseCase _getTrackerSettings;
  final SaveTrackerSettingsUseCase _saveTrackerSettings;

  Future<void> _trackingProcessingChain = Future.value();

  // alex-hack: uploads run beside the processing chain, one at a time, so a
  // slow or failing upload (bad signal on a train) never holds up storing
  // new fixes.
  bool _uploadInFlight = false;

  // alex-hack: the Wi-Fi place / power checks can't rely on Tracelet's
  // heartbeat alone: it only fires once the tracker has a cached fix, and in
  // timer (periodic) mode the tracker's fixes never fill that cache. So the
  // checks also run when a fix arrives (at most once a minute) and straight
  // away when the network connection changes.
  static const Duration _stateCheckMinInterval = Duration(minutes: 1);

  /// alex-hack: while paused at a Wi-Fi place, a fix at least this good and
  /// this far from the place means we've left, whatever the Wi-Fi says.
  static const double _leaveFixMaxAccuracyMeters = 100;
  static const double _leaveDistanceMeters = 250;

  /// alex-hack: writes a decision into Tracelet's log, so it shows up in a
  /// Tracelet Doctor report (the app's own debugPrints don't). Never throws.
  static void _alexLog(String message) {
    debugPrint('[alex-hack] $message');
    unawaited(
      Tracelet.log('warn', 'alex-hack: $message')
          .then((_) {}, onError: (Object _) {}),
    );
  }
  DateTime? _lastStateCheck;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// alex-hack: in battery saver, fixes less accurate than this (our own
  /// network fixes) are dropped; GPS fixes from other apps are kept.
  static const double batterySaverMaxAccuracyMeters = 30;
  Future<void>? _headlessRuntimeReadyFuture;

  PointAutomationService(
      this._trackerEngine,
      this._createPoint,
      this._storePoint,
      this._getLastPoint,
      this._getBatchPointCount,
      this._getCurrentBatch,
      this._batchUploadWorkflow,
      this._getTrackerSettings,
      this._saveTrackerSettings,
      );

  Future<Result<(), String>> startTracking(int userId) async {

    if (kDebugMode) {
      debugPrint('[PointAutomation] Starting automatic tracking...');
    }

    try {
      final TrackerSettings settings = await _getTrackerSettings(userId);
      final TrackerSettings updatedSettings = settings.copyWith(
        automaticTracking: true,
      );

      _attachTrackingHandlers(userId);
      final State state = await _trackerEngine.configure(updatedSettings);

      if (!state.enabled) {
        await _trackerEngine.startTracking(updatedSettings);
      }

      await _refreshNotification(userId);

      await _persistAutomaticTracking(userId, true);

      return const Ok(());
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[PointAutomationService] Failed to start tracking: $e');
        debugPrint('$st');
      }

      await _cleanupAfterFailedStart();

      try {
        await _persistAutomaticTracking(userId, false);
      } catch (rollbackError, rollbackStackTrace) {
        if (kDebugMode) {
          debugPrint(
            '[PointAutomationService] Failed to rollback tracking setting: '
                '$rollbackError',
          );
          debugPrint('$rollbackStackTrace');
        }
      }

      return Err('Failed to start tracking: $e');
    }
  }

  /// Restores the Dart-side Tracelet runtime after the app process starts.
  ///
  /// This does not change the user's persisted tracking preference.
  Future<Result<(), String>> resumeTrackingIfEnabled(int userId) async {
    try {
      final TrackerSettings settings = await _getTrackerSettings(userId);

      if (!settings.automaticTracking) {
        if (kDebugMode) {
          debugPrint(
            '[PointAutomation] Runtime resume skipped; tracking is disabled.',
          );
        }

        return const Ok(());
      }

      if (kDebugMode) {
        debugPrint('[PointAutomation] Restoring Tracelet runtime...');
      }

      _attachTrackingHandlers(userId);

      final state = await _trackerEngine.configure(settings);

      if (!state.enabled) {
        await _trackerEngine.startTracking(settings);
      }

      // alex-hack: opening the app always re-checks the Wi-Fi place, so a
      // pause can't outlive the Wi-Fi even if heartbeats stopped.
      unawaited(checkWifiPlaceNow(userId));

      await _refreshNotification(userId);

      return const Ok(());
    } catch (error, stackTrace) {
      _detachTrackingHandlers();

      if (kDebugMode) {
        debugPrint(
          '[PointAutomation] Failed to restore Tracelet runtime: $error',
        );
        debugPrint('$stackTrace');
      }

      return Err('Failed to restore tracking runtime: $error');
    }
  }

  /// Initializes Tracelet inside the long-lived headless Flutter isolate.
  ///
  /// Native Tracelet can continue tracking while the current Dart runtime has
  /// never called ready(). setConfig() still requires ready() in that runtime.
  Future<bool> ensureHeadlessRuntimeReady(int userId) async {
    final TrackerSettings settings = await _getTrackerSettings(userId);

    if (!settings.automaticTracking) {
      _headlessRuntimeReadyFuture = null;

      if (kDebugMode) {
        debugPrint(
          '[PointAutomation] Ignoring headless event; tracking is disabled.',
        );
      }

      return false;
    }

    await (_headlessRuntimeReadyFuture ??=
        _configureHeadlessRuntime(settings));

    _ensureConnectivityListener(userId);

    return true;
  }

  Future<void> _configureHeadlessRuntime(
      TrackerSettings settings,
      ) async {
    try {
      await _trackerEngine.configure(settings);

      if (kDebugMode) {
        debugPrint(
          '[PointAutomation] Headless Tracelet runtime is ready.',
        );
      }
    } catch (error) {
      _headlessRuntimeReadyFuture = null;
      rethrow;
    }
  }

  Future<Result<(), String>> stopTracking(int userId) async {

    if (kDebugMode) {
      debugPrint('[PointAutomation] Stopping automatic tracking...');
    }

    Object? persistError;
    Object? stopError;
    StackTrace? persistStackTrace;
    StackTrace? stopStackTrace;

    _detachTrackingHandlers();

    // alex-hack: forget any Wi-Fi place, so a later start elsewhere doesn't
    // record a departure from it.
    try {
      await AlexWifiPlaces.setActiveBssid(null);
    } catch (_) {}

    try {
      await _persistAutomaticTracking(userId, false);
    } catch (e, st) {
      persistError = e;
      persistStackTrace = st;

      if (kDebugMode) {
        debugPrint('[PointAutomation] Failed to persist tracking disabled: $e');
        debugPrint('$st');
      }
    }

    try {
      await _trackerEngine.stopTracking().timeout(
        const Duration(seconds: 10),
      );
    } catch (e, st) {
      stopError = e;
      stopStackTrace = st;

      if (kDebugMode) {
        debugPrint('[PointAutomation] Engine stop failed: $e');
        debugPrint('$st');
      }
    }

    if (persistError != null || stopError != null) {
      if (kDebugMode) {
        if (persistStackTrace != null) debugPrint('$persistStackTrace');
        if (stopStackTrace != null) debugPrint('$stopStackTrace');
      }

      return Err(
        'Tracking stop completed with errors. '
            'persistError=$persistError, stopError=$stopError',
      );
    }

    return const Ok(());
  }

  Future<Result<(), String>> restartTracking(int userId) async {

    if (kDebugMode) {
      debugPrint('[PointAutomation] Restarting tracking...');
    }

    final Result<(), String> stopResult = await stopTracking(userId);

    if (stopResult case Err(value: final message)) {
      return Err(message);
    }

    return await startTracking(userId);
  }

  /// alex-hack: applies saved settings to a running tracker. Upstream only
  /// applied them at the next start, so a changed setting did nothing until
  /// tracking was toggled off and on. Switching between timer and automatic
  /// mode needs a restart (they start differently); anything else is applied
  /// in place, falling back to a restart if that fails.
  Future<Result<(), String>> applySettingsIfTracking(
    int userId, {
    required bool modeChanged,
  }) async {
    final TrackerSettings settings = await _getTrackerSettings(userId);

    if (!settings.automaticTracking) {
      return const Ok(());
    }

    if (!modeChanged) {
      try {
        await _trackerEngine.updateConfiguration(settings);
        return const Ok(());
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('[PointAutomation] Live settings update failed: $e');
          debugPrint('$st');
        }
      }
    }

    return await restartTracking(userId);
  }

  Future<void> _cleanupAfterFailedStart() async {
    _detachTrackingHandlers();

    try {
      await _trackerEngine.stopTracking().timeout(
        const Duration(seconds: 10),
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[PointAutomation] Failed-start engine cleanup failed: $e');
        debugPrint('$st');
      }
    }
  }

  Future<void> handleTraceletLocationFix({
    required int userId,
    required LocationFix locationFix,
  }) async {
    await _enqueueLocationFix(
      locationFix: locationFix,
      userId: userId,
    );
  }

  Future<void> handleTraceletHeartbeat({
    required int userId,
  }) async {
    await _enqueueTrackingTask(
          () async {
        await _handleHeartbeat(userId);
      },
    );
  }

  Future<void> _persistAutomaticTracking(int userId, bool value) async {

    final settings = await _getTrackerSettings(userId);
    final updatedSettings = settings.copyWith(automaticTracking: value);
    await _saveTrackerSettings(updatedSettings);
  }

  void _attachTrackingHandlers(int userId) {
    if (kDebugMode) {
      debugPrint('[PointAutomation] Attaching Tracelet tracking handlers.');
    }

    _trackerEngine.setLocationFixHandler(
          (LocationFix locationFix) async {
        await handleTraceletLocationFix(
          userId: userId,
          locationFix: locationFix,
        );
      },
    );

    _trackerEngine.setHeartbeatHandler(
          () async {
        await handleTraceletHeartbeat(
          userId: userId,
        );
      },
    );

    _ensureConnectivityListener(userId);
  }

  /// alex-hack: joining or leaving a Wi-Fi network is checked at once. Set up
  /// in whichever Flutter engine handles tracking: the app's, or the headless
  /// one Tracelet starts when the app's UI isn't running.
  void _ensureConnectivityListener(int userId) {
    if (_connectivitySub != null) return;
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      (_) => unawaited(checkWifiPlaceNow(userId)),
      onError: (Object error) =>
          debugPrint('[PointAutomation] Connectivity listener error: $error'),
    );
  }


  void _detachTrackingHandlers() {
    if (kDebugMode) {
      debugPrint('[PointAutomation] Detaching Tracelet tracking handlers.');
    }

    _trackerEngine.setLocationFixHandler(null);
    _trackerEngine.setHeartbeatHandler(null);
    unawaited(_connectivitySub?.cancel());
    _connectivitySub = null;
  }

  Future<void> _enqueueLocationFix({
    required LocationFix locationFix,
    required int userId,
  }) {
    return _enqueueTrackingTask(
          () async {
        await _handleLocationFix(
          locationFix: locationFix,
          userId: userId,
        );
      },
    );
  }

  Future<void> _enqueueTrackingTask(Future<void> Function() task) {
    _trackingProcessingChain = _trackingProcessingChain
        .then((_) => task())
        .catchError((Object error, StackTrace stackTrace) {
      if (kDebugMode) {
        debugPrint('[PointAutomation] Tracking processing failed: $error');
        debugPrint('$stackTrace');
      }
    });

    return _trackingProcessingChain;
  }

  Future<void> _handleLocationFix({
    required LocationFix locationFix,
    required int userId,
    bool skipValidation = false,
  }) async {

    // alex-hack: a delivered fix is also a chance to run the Wi-Fi place and
    // power checks (before deciding whether to drop it), since the heartbeat
    // may not be firing.
    if (!skipValidation) {
      final DateTime now = DateTime.now();
      final DateTime? last = _lastStateCheck;
      if (last == null || now.difference(last) >= _stateCheckMinInterval) {
        await _runStateChecks(userId, source: 'fix');
      }
    }

    // alex-hack: a good fix far from the paused place means we've left,
    // even if the Wi-Fi reading hasn't caught up (or failed).
    if (!skipValidation &&
        locationFix.hAccuracyMeters <= _leaveFixMaxAccuracyMeters &&
        await AlexWifiPlaces.isPaused()) {
      final String? activeBssid = await AlexWifiPlaces.activeBssid();
      final WifiPlaceLink? place =
          activeBssid == null ? null : await AlexWifiPlaces.linkFor(activeBssid);
      if (place != null) {
        final double meters = const Distance().as(
          LengthUnit.Meter,
          LatLng(place.latitude, place.longitude),
          LatLng(locationFix.latitude, locationFix.longitude),
        );
        final double threshold = locationFix.hAccuracyMeters * 2 >
                _leaveDistanceMeters
            ? locationFix.hAccuracyMeters * 2
            : _leaveDistanceMeters;
        if (meters > threshold) {
          _lastStateCheck = DateTime.now();
          await _checkWifiPlace(
            userId,
            source: 'fix',
            leaveReason: 'fix ${meters.round()} m from the place '
                '(accuracy ${locationFix.hAccuracyMeters.round()} m)',
          );
        }
      }
    }

    // alex-hack: at a Wi-Fi place the place's own points stand in for GPS, so
    // stray fixes (other apps' GPS, indoor drift) are dropped.
    if (!skipValidation && await AlexWifiPlaces.isPaused()) {
      if (kDebugMode) {
        debugPrint('[PointAutomation] At a Wi-Fi place; fix dropped.');
      }
      return;
    }

    // alex-hack: in battery saver our own fixes are coarse network ones (kept
    // only to keep the heartbeat alive); keep precise fixes, which come from
    // other apps using GPS.
    if (!skipValidation &&
        locationFix.hAccuracyMeters > batterySaverMaxAccuracyMeters &&
        await AlexTrackingPreferences.batterySaverPausesGps()) {
      if (kDebugMode) {
        debugPrint('[PointAutomation] Battery saver; coarse fix dropped.');
      }
      return;
    }

    try {
      final pointResult = await _createPoint(
        position: locationFix,
        timestamp: locationFix.timestampUtc,
        userId: userId,
        skipValidation: skipValidation,
      );

      if (pointResult case Ok(value: final point)) {
        final storeResult = await _storePoint(point);

        if (storeResult case Ok()) {
          final int batchCount = await _getBatchPointCount(userId);
          final TrackerSettings settings = await _getTrackerSettings(userId);

          if (batchCount >= settings.pointsPerBatch) {
            _startUploadIfIdle(userId);
          }

          await _refreshNotification(userId);
        } else if (storeResult case Err(value: final message)) {
          debugPrint('[PointAutomation] Failed to store point: $message');
        }
      } else if (pointResult case Err(value: final message)) {
        debugPrint('[PointAutomation] Point creation error: $message');
      }
    } catch (error, stackTrace) {
      debugPrint(
        '[PointAutomation] Error handling location fix: '
            '$error\n$stackTrace',
      );
    }
  }

  Future<void> _handleHeartbeat(int userId) async {
    if (kDebugMode) {
      debugPrint('[PointAutomation] Tracelet heartbeat received.');
    }

    await _runStateChecks(userId, source: 'heartbeat');
    await _refreshNotification(userId);
  }

  /// alex-hack: arriving at or leaving a Wi-Fi place, plugging in or
  /// unplugging, battery saver turning on or off, and an upload postponed by
  /// battery saver. Run from the heartbeat, from delivered fixes (at most once
  /// a minute), when the network connection changes and when the app opens.
  Future<void> _runStateChecks(int userId, {required String source}) async {
    _lastStateCheck = DateTime.now();

    try {
      await _checkWifiPlace(userId, source: source);
    } catch (e, s) {
      _alexLog('Wi-Fi place check ($source) failed: $e');
      debugPrint('$s');
    }

    try {
      await _trackerEngine.refreshPowerState();
    } catch (e, s) {
      debugPrint('[PointAutomation] Power state refresh error: $e\n$s');
    }

    try {
      final TrackerSettings settings = await _getTrackerSettings(userId);
      if (await _getBatchPointCount(userId) >= settings.pointsPerBatch) {
        _startUploadIfIdle(userId);
      }
    } catch (e, s) {
      debugPrint('[PointAutomation] Upload catch-up error: $e\n$s');
    }
  }

  /// alex-hack: runs the Wi-Fi place check now rather than at the next
  /// heartbeat (app opened, Wi-Fi Places switch or links changed). Does
  /// nothing while tracking is off.
  Future<void> checkWifiPlaceNow(int userId) => _enqueueTrackingTask(() async {
        final TrackerSettings settings = await _getTrackerSettings(userId);
        if (!settings.automaticTracking) return;
        await _runStateChecks(userId, source: 'now');
        await _refreshNotification(userId);
      });

  /// alex-hack: pauses GPS while connected to a Wi-Fi access point linked to a
  /// Dawarich place, and records points at the place instead: one on arrival,
  /// one every [AlexWifiPlaces.presenceInterval] while there, and one on
  /// leaving. Normal tracking resumes as soon as the phone is off that Wi-Fi.
  ///
  /// [leaveReason] forces leaving the current place (e.g. a fix far away).
  Future<void> _checkWifiPlace(
    int userId, {
    required String source,
    String? leaveReason,
  }) async {
    final String? activeBssid = await AlexWifiPlaces.activeBssid();
    final WifiPlaceLink? activeLink =
        activeBssid == null ? null : await AlexWifiPlaces.linkFor(activeBssid);

    WifiPlaceLink? currentLink;
    CurrentWifi? wifi;
    final bool enabled = await AlexWifiPlaces.enabled();
    if (enabled) {
      wifi = await AlexWifiPlaces.current();
      if (wifi != null && leaveReason == null) {
        currentLink = await AlexWifiPlaces.linkFor(wifi.bssid);
      }
    }
    final String wifiNow =
        wifi == null ? 'no Wi-Fi' : 'Wi-Fi ${wifi.ssid} ${wifi.bssid}';

    final DateTime now = DateTime.now().toUtc();

    // Still at the same place, possibly on another of its access points
    // (mesh Wi-Fi, or the 2.4/5 GHz radios of one router, have different
    // BSSIDs): carry on rather than leaving and arriving again.
    if (currentLink != null &&
        activeLink != null &&
        currentLink.placeId == activeLink.placeId) {
      if (AlexWifiPlaces.normaliseBssid(currentLink.bssid) !=
          AlexWifiPlaces.normaliseBssid(activeLink.bssid)) {
        await AlexWifiPlaces.setActiveBssid(currentLink.bssid);
        _alexLog('roamed at ${currentLink.placeName} to $wifiNow ($source)');
      }
      final DateTime? last = await AlexWifiPlaces.lastPresencePointAt();
      if (last == null ||
          // A minute's slack: checks driven by 15-minute fixes land just
          // under 15 minutes apart, which would skip every other point.
          now.difference(last.toUtc()) >=
              AlexWifiPlaces.presenceInterval - const Duration(minutes: 1)) {
        await _recordWifiPlacePoint(userId, currentLink, now);
        _alexLog('at ${currentLink.placeName}, place point ($source, $wifiNow)');
      }
      return;
    }

    if (activeBssid != null) {
      // Left the place (or the link was deleted, or the feature turned off).
      // Un-pause first, so a failure recording the departure point can't
      // leave tracking paused.
      await AlexWifiPlaces.setActiveBssid(null);
      if (activeLink != null) {
        await _recordWifiPlacePoint(userId, activeLink, now);
      }
      _alexLog(
        'left ${activeLink?.placeName ?? activeBssid}, resuming GPS: '
        '${leaveReason ?? (enabled ? wifiNow : 'Wi-Fi Places turned off')} '
        '($source)',
      );
    }

    if (currentLink != null) {
      await AlexWifiPlaces.setActiveBssid(currentLink.bssid);
      await _recordWifiPlacePoint(userId, currentLink, now);
      _alexLog('arrived at ${currentLink.placeName}, pausing GPS: '
          '$wifiNow ($source)');
    }

    if (activeBssid != null || currentLink != null) {
      final TrackerSettings settings = await _getTrackerSettings(userId);
      await _trackerEngine.updateConfiguration(settings);
    }

    // Leaving a Wi-Fi place means moving: start GPS now rather than waiting
    // for motion detection to wake from the stationary state it settled into
    // at the place.
    if (activeBssid != null && currentLink == null) {
      try {
        await _trackerEngine.startMoving();
      } catch (e) {
        _alexLog('forcing moving state failed: $e');
      }
    }
  }

  Future<void> _recordWifiPlacePoint(
    int userId,
    WifiPlaceLink link,
    DateTime time,
  ) async {
    // Whole minutes: Tracelet delivers events to every running Flutter engine,
    // so more than one may record the same place point. With the same
    // timestamp and coordinates the database's duplicate key keeps only one.
    final DateTime timestampUtc = DateTime.utc(
      time.toUtc().year,
      time.toUtc().month,
      time.toUtc().day,
      time.toUtc().hour,
      time.toUtc().minute,
    );
    await _handleLocationFix(
      userId: userId,
      skipValidation: true,
      locationFix: LocationFix(
        latitude: link.latitude,
        longitude: link.longitude,
        timestampUtc: timestampUtc,
        hAccuracyMeters: 10,
        altitudeMeters: 0,
        altitudeAccuracyMeters: 0,
        speedMps: 0,
        speedAccuracyMps: 0,
        headingDegrees: 0,
        headingAccuracyDegrees: 0,
        provider: 'alex-wifi-place',
      ),
    );
    await AlexWifiPlaces.setLastPresencePointAt(timestampUtc);
  }

  Future<void> _refreshNotification(int userId) async {
    try {
      final int batchCount = await _getBatchPointCount(userId);
      final lastPointOption = await _getLastPoint(userId);

      final String lastPointTimeStr = switch (lastPointOption) {
        Some(value: final lastPoint) => _formatLastPointTime(
          lastPoint.timestamp,
        ),
        None() => '--:--:--',
      };

      // alex-hack: say why GPS is off, so a pause doesn't look like a stall.
      String status = '';
      final String? activeBssid = await AlexWifiPlaces.activeBssid();
      final WifiPlaceLink? place = activeBssid == null || !await AlexWifiPlaces.enabled()
          ? null
          : await AlexWifiPlaces.linkFor(activeBssid);
      if (place != null) {
        status = ' • At ${place.placeName}';
      } else if (await AlexTrackingPreferences.batterySaverPausesGps()) {
        status = ' • Battery saver: no GPS, no uploads';
      }

      final String body =
          'Last point: $lastPointTimeStr • $batchCount in batch$status';
      await _trackerEngine.updateForegroundNotification(
        title: 'Tracking active',
        body: body,
      );
    } catch (e, s) {
      debugPrint('[PointAutomation] Notification refresh error: $e\n$s');
    }
  }

  String _formatLastPointTime(DateTime timestampUtc) {
    final DateTime local = timestampUtc.toLocal();

    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }

  // ── Upload helper ──────────────────────────────────────────────────────

  /// alex-hack: starts an upload unless one is already running, without
  /// waiting for it.
  void _startUploadIfIdle(int userId) {
    if (_uploadInFlight) return;
    _uploadInFlight = true;
    unawaited(
      _uploadCurrentBatch(userId).whenComplete(() => _uploadInFlight = false),
    );
  }

  /// Fetches the current un-uploaded batch and uploads it.
  Future<void> _uploadCurrentBatch(int userId) async {
    try {
      // alex-hack: no automatic uploads in battery saver; points wait on the
      // phone until it's off.
      if (await AlexTrackingPreferences.batterySaverPausesGps()) {
        if (kDebugMode) {
          debugPrint('[PointAutomation] Battery saver; upload postponed.');
        }
        return;
      }

      final batch = await _getCurrentBatch(userId);
      if (batch.isEmpty) return;

      final result = await _batchUploadWorkflow(batch, userId);
      if (result case Ok()) {
        if (kDebugMode) {
          debugPrint('[PointAutomation] Batch upload successful.');
        }
      } else if (result case Err(value: final err)) {
        debugPrint('[PointAutomation] Batch upload failed: $err');
      }
    } catch (e, s) {
      debugPrint('[PointAutomation] Upload error: $e\n$s');
    }
  }

}
