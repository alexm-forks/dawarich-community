import 'package:flutter/services.dart';

/// alex-hack: whether a charger is connected, from Android's battery
/// broadcast (EXTRA_PLUGGED). Unlike the charge status ("charging",
/// "discharging", ...) this stays true on a car charger that can't keep up
/// with navigation and the screen, where Android reports "discharging".
///
/// A plugin rather than a channel on the activity, so it's registered in the
/// background engines that run tracking too.
class AlexPower {
  const AlexPower._();

  static const MethodChannel _channel = MethodChannel('uk.a09.alexpower');

  /// True or false on Android; null where it can't be told (another
  /// platform, or the plugin missing), so callers can fall back.
  static Future<bool?> isPluggedIn() async {
    try {
      return await _channel.invokeMethod<bool>('isPluggedIn');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
