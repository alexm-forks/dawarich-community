// The in-memory preferences store comes with shared_preferences.
// ignore_for_file: depend_on_referenced_packages

import 'package:dawarich/features/tracking/data/preferences/alex_wifi_places.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  WifiPlaceLink link(String bssid, String place) => WifiPlaceLink(
        bssid: bssid,
        ssid: 'Same Name',
        placeId: place.hashCode,
        placeName: place,
        latitude: 51.5,
        longitude: -0.1,
      );

  test('links are matched by BSSID, case-insensitively', () async {
    await AlexWifiPlaces.addLink(link('AA:BB:CC:00:00:01', 'Home'));
    await AlexWifiPlaces.addLink(link('aa:bb:cc:00:00:02', 'Office'));

    expect((await AlexWifiPlaces.linkFor('aa:bb:cc:00:00:01'))?.placeName, 'Home');
    expect((await AlexWifiPlaces.linkFor('AA:BB:CC:00:00:02'))?.placeName, 'Office');
    expect(await AlexWifiPlaces.linkFor('aa:bb:cc:00:00:03'), isNull);
  });

  test('re-linking an access point replaces its place', () async {
    await AlexWifiPlaces.addLink(link('aa:bb:cc:00:00:01', 'Home'));
    await AlexWifiPlaces.addLink(link('AA:BB:CC:00:00:01', 'Flat'));

    final links = await AlexWifiPlaces.links();
    expect(links, hasLength(1));
    expect(links.single.placeName, 'Flat');
  });

  test('removing a link and pause state', () async {
    await AlexWifiPlaces.addLink(link('aa:bb:cc:00:00:01', 'Home'));
    expect(await AlexWifiPlaces.isPaused(), isFalse);

    await AlexWifiPlaces.setActiveBssid('AA:BB:CC:00:00:01');
    expect(await AlexWifiPlaces.isPaused(), isTrue);

    await AlexWifiPlaces.setEnabled(false);
    expect(await AlexWifiPlaces.isPaused(), isFalse);

    await AlexWifiPlaces.removeLink('AA:BB:CC:00:00:01');
    expect(await AlexWifiPlaces.links(), isEmpty);
  });
}
