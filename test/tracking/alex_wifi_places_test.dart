// The in-memory preferences store comes with shared_preferences.
// ignore_for_file: depend_on_referenced_packages

import 'package:dawarich/core/network/dio_client.dart';
import 'package:dawarich/features/tracking/data/alex_wifi_places_sync.dart';
import 'package:dawarich/features/tracking/data/preferences/alex_tracking_preferences.dart';
import 'package:dawarich/features/tracking/data/preferences/alex_wifi_places.dart';
import 'package:dawarich/features/tracking/data/sources/alex_places_remote_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Dawarich stand-in: places in memory, notes editable.
class _FakeRemote extends AlexPlacesRemoteSource {
  final Map<int, DawarichPlace> places;
  final List<int> updated = [];

  _FakeRemote(List<DawarichPlace> list)
      : places = {for (final p in list) p.id: p},
        super(DioClient(const []));

  @override
  Future<List<DawarichPlace>> manualPlaces() async =>
      places.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<DawarichPlace> place(int id) async => places[id]!;

  @override
  Future<void> updateNote(int id, String note) async {
    final p = places[id]!;
    updated.add(id);
    places[id] = DawarichPlace(
      id: p.id,
      name: p.name,
      latitude: p.latitude,
      longitude: p.longitude,
      note: note,
    );
  }
}

DawarichPlace place(int id, String name, [String note = '']) => DawarichPlace(
      id: id,
      name: name,
      latitude: 51.5,
      longitude: -0.1,
      note: note,
    );

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('WifiPlaceNote', () {
    test('parses wifi lines, keeps the rest of the note', () {
      const note = 'Front door code is in 1Password\n'
          'wifi: AA:BB:CC:00:00:01 Same Name\n'
          '  wifi:aa:bb:cc:00:00:02\n'
          'wifi: not-a-bssid Nope';

      expect(WifiPlaceNote.parse(note), [
        (bssid: 'aa:bb:cc:00:00:01', ssid: 'Same Name'),
        (bssid: 'aa:bb:cc:00:00:02', ssid: ''),
      ]);
    });

    test('add replaces an existing line and keeps other text', () {
      const note = 'Notes\nwifi: aa:bb:cc:00:00:01 Old';
      expect(
        WifiPlaceNote.add(note, 'AA:BB:CC:00:00:01', 'New'),
        'Notes\nwifi: aa:bb:cc:00:00:01 New',
      );
      expect(WifiPlaceNote.add('', 'aa:bb:cc:00:00:02', ''),
          'wifi: aa:bb:cc:00:00:02');
    });

    test('remove drops only that access point', () {
      const note = 'Notes\nwifi: aa:bb:cc:00:00:01 A\nwifi: aa:bb:cc:00:00:02 B\n';
      expect(
        WifiPlaceNote.remove(note, 'AA:BB:CC:00:00:01'),
        'Notes\nwifi: aa:bb:cc:00:00:02 B',
      );
    });
  });

  group('AlexWifiPlacesSync', () {
    test('refresh builds the phone copy from place notes', () async {
      final remote = _FakeRemote([
        place(1, 'Home', 'wifi: aa:bb:cc:00:00:01 Same Name'),
        place(2, 'Office', 'wifi: AA:BB:CC:00:00:02 Same Name'),
        place(3, 'Park'),
      ]);

      await AlexWifiPlacesSync(remote).refresh();

      expect((await AlexWifiPlaces.linkFor('AA:BB:CC:00:00:01'))?.placeName, 'Home');
      expect((await AlexWifiPlaces.linkFor('aa:bb:cc:00:00:02'))?.placeName, 'Office');
      expect(await AlexWifiPlaces.links(), hasLength(2));
    });

    test('link moves an access point from one place to another', () async {
      final remote = _FakeRemote([
        place(1, 'Home', 'Keep me\nwifi: aa:bb:cc:00:00:01 Net'),
        place(2, 'Flat', 'Flat note'),
      ]);

      await AlexWifiPlacesSync(remote).link(
        const CurrentWifi(ssid: 'Net', bssid: 'aa:bb:cc:00:00:01'),
        remote.places[2]!,
      );

      expect(remote.places[1]!.note, 'Keep me');
      expect(remote.places[2]!.note, 'Flat note\nwifi: aa:bb:cc:00:00:01 Net');
      expect((await AlexWifiPlaces.linkFor('aa:bb:cc:00:00:01'))?.placeName, 'Flat');
    });

    test('unlink removes the line and the phone copy', () async {
      final remote = _FakeRemote([
        place(1, 'Home', 'wifi: aa:bb:cc:00:00:01 Net'),
      ]);
      final sync = AlexWifiPlacesSync(remote);
      final links = await sync.refresh();

      await sync.unlink(links.single);

      expect(remote.places[1]!.note, '');
      expect(await AlexWifiPlaces.links(), isEmpty);
    });
  });

  test('battery saver pause setting', () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    expect(await AlexTrackingPreferences.batterySaverPause(), isTrue);

    // No battery plugin in tests: reading battery saver fails, which must
    // count as "not in battery saver" so tracking carries on.
    expect(await AlexTrackingPreferences.batterySaverPausesGps(), isFalse);

    await AlexTrackingPreferences.setBatterySaverPause(false);
    expect(await AlexTrackingPreferences.batterySaverPause(), isFalse);
    expect(await AlexTrackingPreferences.batterySaverPausesGps(), isFalse);
  });

  test('pause state', () async {
    expect(await AlexWifiPlaces.isPaused(), isFalse);

    await AlexWifiPlaces.setActiveBssid('AA:BB:CC:00:00:01');
    expect(await AlexWifiPlaces.isPaused(), isTrue);

    await AlexWifiPlaces.setEnabled(false);
    expect(await AlexWifiPlaces.isPaused(), isFalse);
  });
}
