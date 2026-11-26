import 'package:flutter/services.dart';

/// An access point from a Wi-Fi scan.
final class WifiAccessPoint {
  final String bssid;
  final String ssid;

  /// Signal strength in dBm.
  final int level;

  /// Channel frequency in MHz.
  final int frequency;

  /// How long ago this access point was last seen.
  final Duration age;

  const WifiAccessPoint({
    required this.bssid,
    required this.ssid,
    required this.level,
    required this.frequency,
    required this.age,
  });

  /// '2.4 GHz', '5 GHz' or '6 GHz'.
  String get band => frequency >= 5925
      ? '6 GHz'
      : frequency >= 4900
          ? '5 GHz'
          : '2.4 GHz';
}

/// alex-hack: the Wi-Fi access points the phone can see, from Android's Wi-Fi
/// scan. Needs location permission and location turned on, as reading the
/// connected BSSID does.
class AlexWifi {
  const AlexWifi._();

  static const MethodChannel _channel = MethodChannel('uk.a09.alexwifi');

  /// The access points seen by a fresh scan, or by the latest one if Android
  /// throttled the request. Null where it can't be read (another platform,
  /// no permission, or the plugin missing).
  static Future<List<WifiAccessPoint>?> scan() async {
    try {
      final List<Object?>? raw = await _channel.invokeListMethod<Object?>('scan');
      if (raw == null) return null;
      return [
        for (final Object? item in raw)
          if (item is Map)
            WifiAccessPoint(
              bssid: '${item['bssid']}',
              ssid: '${item['ssid'] ?? ''}',
              level: (item['level'] as num?)?.toInt() ?? 0,
              frequency: (item['frequency'] as num?)?.toInt() ?? 0,
              age: Duration(milliseconds: (item['ageMs'] as num?)?.toInt() ?? 0),
            ),
      ];
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
