import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// alex-hack: a Wi-Fi access point (by BSSID) linked to a Dawarich place.
@immutable
final class WifiPlaceLink {
  final String bssid;
  final String ssid;
  final int placeId;
  final String placeName;
  final double latitude;
  final double longitude;

  const WifiPlaceLink({
    required this.bssid,
    required this.ssid,
    required this.placeId,
    required this.placeName,
    required this.latitude,
    required this.longitude,
  });

  factory WifiPlaceLink.fromJson(Map<String, dynamic> json) => WifiPlaceLink(
        bssid: json['bssid'] as String,
        ssid: json['ssid'] as String? ?? '',
        placeId: json['placeId'] as int,
        placeName: json['placeName'] as String? ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'bssid': bssid,
        'ssid': ssid,
        'placeId': placeId,
        'placeName': placeName,
        'latitude': latitude,
        'longitude': longitude,
      };
}

/// The Wi-Fi network the phone is connected to right now.
@immutable
final class CurrentWifi {
  final String ssid;
  final String bssid;

  const CurrentWifi({required this.ssid, required this.bssid});
}

/// alex-hack: Wi-Fi places. While the phone is connected to an access point
/// linked to a place, GPS is paused and points are recorded at the place.
///
/// Matching is by BSSID (the access point's hardware address), not network
/// name, because the same name is used in several places. Everything lives in
/// shared preferences (no database changes), via [SharedPreferencesAsync]
/// because the UI and the background tracking isolate both read and write it.
final class AlexWifiPlaces {
  const AlexWifiPlaces._();

  static const String _linksKey = 'alex.wifi_places.links';
  static const String _enabledKey = 'alex.wifi_places.enabled';
  static const String _activeBssidKey = 'alex.wifi_places.active_bssid';
  static const String _lastPresenceKey = 'alex.wifi_places.last_presence_ms';

  /// Android reports this BSSID when the app may not read the real one
  /// (no location permission, or location turned off).
  static const String _redactedBssid = '02:00:00:00:00:00';

  /// How often to record a point at the place while connected.
  static const Duration presenceInterval = Duration(minutes: 15);

  static String normaliseBssid(String bssid) => bssid.trim().toLowerCase();

  static Future<List<WifiPlaceLink>> links() async {
    try {
      final String? raw = await SharedPreferencesAsync().getString(_linksKey);
      if (raw == null || raw.isEmpty) return const [];

      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => WifiPlaceLink.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (error) {
      if (kDebugMode) debugPrint('[AlexWifiPlaces] Read failed: $error');
      return const [];
    }
  }

  static Future<void> _saveLinks(List<WifiPlaceLink> links) =>
      SharedPreferencesAsync().setString(
        _linksKey,
        jsonEncode(links.map((l) => l.toJson()).toList()),
      );

  /// Links [link]'s access point to its place, replacing any earlier link for
  /// the same access point.
  static Future<void> addLink(WifiPlaceLink link) async {
    final String bssid = normaliseBssid(link.bssid);
    final List<WifiPlaceLink> current = await links();
    await _saveLinks([
      ...current.where((l) => normaliseBssid(l.bssid) != bssid),
      WifiPlaceLink(
        bssid: bssid,
        ssid: link.ssid,
        placeId: link.placeId,
        placeName: link.placeName,
        latitude: link.latitude,
        longitude: link.longitude,
      ),
    ]);
  }

  static Future<void> removeLink(String bssid) async {
    final String normalised = normaliseBssid(bssid);
    final List<WifiPlaceLink> current = await links();
    await _saveLinks(
      current.where((l) => normaliseBssid(l.bssid) != normalised).toList(),
    );
  }

  static Future<WifiPlaceLink?> linkFor(String bssid) async {
    final String normalised = normaliseBssid(bssid);
    for (final WifiPlaceLink link in await links()) {
      if (normaliseBssid(link.bssid) == normalised) return link;
    }
    return null;
  }

  static Future<bool> enabled() async {
    try {
      return await SharedPreferencesAsync().getBool(_enabledKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) =>
      SharedPreferencesAsync().setBool(_enabledKey, value);

  /// The linked access point the tracker is currently paused at, if any.
  static Future<String?> activeBssid() async {
    try {
      return await SharedPreferencesAsync().getString(_activeBssidKey);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setActiveBssid(String? bssid) async {
    final prefs = SharedPreferencesAsync();
    if (bssid == null) {
      await prefs.remove(_activeBssidKey);
      await prefs.remove(_lastPresenceKey);
    } else {
      await prefs.setString(_activeBssidKey, normaliseBssid(bssid));
    }
  }

  /// Whether GPS should be paused right now (feature on and at a place).
  static Future<bool> isPaused() async =>
      await enabled() && await activeBssid() != null;

  static Future<DateTime?> lastPresencePointAt() async {
    try {
      final int? ms = await SharedPreferencesAsync().getInt(_lastPresenceKey);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setLastPresencePointAt(DateTime time) =>
      SharedPreferencesAsync()
          .setInt(_lastPresenceKey, time.millisecondsSinceEpoch);

  /// The connected Wi-Fi, or null if not on Wi-Fi or the BSSID can't be read.
  static Future<CurrentWifi?> current() async {
    try {
      final List<ConnectivityResult> connectivity =
          await Connectivity().checkConnectivity();
      if (!connectivity.contains(ConnectivityResult.wifi)) return null;

      final NetworkInfo info = NetworkInfo();
      final String? bssid = await info.getWifiBSSID();
      if (bssid == null ||
          bssid.isEmpty ||
          normaliseBssid(bssid) == _redactedBssid) {
        return null;
      }

      String ssid = await info.getWifiName() ?? '';
      if (ssid.length >= 2 && ssid.startsWith('"') && ssid.endsWith('"')) {
        ssid = ssid.substring(1, ssid.length - 1);
      }

      return CurrentWifi(ssid: ssid, bssid: normaliseBssid(bssid));
    } catch (error) {
      if (kDebugMode) debugPrint('[AlexWifiPlaces] Wi-Fi read failed: $error');
      return null;
    }
  }
}
