import 'package:dawarich/features/tracking/data/preferences/alex_wifi_places.dart';
import 'package:dawarich/features/tracking/data/sources/alex_places_remote_source.dart';

/// alex-hack: keeps Wi-Fi links in Dawarich place notes and the phone's copy
/// in step. Dawarich is the source of truth.
final class AlexWifiPlacesSync {
  final AlexPlacesRemoteSource _remote;

  const AlexWifiPlacesSync(this._remote);

  /// Reads every manual place's note and replaces the phone's copy.
  Future<List<WifiPlaceLink>> refresh() async {
    final List<DawarichPlace> places = await _remote.manualPlaces();
    final List<WifiPlaceLink> links = linksFromPlaces(places);
    await AlexWifiPlaces.replaceLinks(links);
    return links;
  }

  /// One link per BSSID; if a BSSID appears on several places, the first
  /// (by name) wins.
  static List<WifiPlaceLink> linksFromPlaces(List<DawarichPlace> places) {
    final Map<String, WifiPlaceLink> byBssid = {};
    for (final DawarichPlace place in places) {
      for (final entry in WifiPlaceNote.parse(place.note)) {
        byBssid.putIfAbsent(
          entry.bssid,
          () => WifiPlaceLink(
            bssid: entry.bssid,
            ssid: entry.ssid,
            placeId: place.id,
            placeName: place.name,
            latitude: place.latitude,
            longitude: place.longitude,
          ),
        );
      }
    }
    return byBssid.values.toList();
  }

  /// Links [accessPoints] to [target]: removes their lines from any other
  /// place's note, adds them to [target]'s (read fresh, so other note edits
  /// are kept). One note update per place.
  Future<List<WifiPlaceLink>> link(
    List<CurrentWifi> accessPoints,
    DawarichPlace target,
  ) async {
    final Set<String> bssids = {for (final ap in accessPoints) ap.bssid};

    for (final DawarichPlace place in await _remote.manualPlaces()) {
      if (place.id == target.id) continue;
      if (WifiPlaceNote.parse(place.note).any((e) => bssids.contains(e.bssid))) {
        String note = place.note;
        for (final String bssid in bssids) {
          note = WifiPlaceNote.remove(note, bssid);
        }
        await _remote.updateNote(place.id, note);
      }
    }

    final DawarichPlace fresh = await _remote.place(target.id);
    String note = fresh.note;
    for (final CurrentWifi ap in accessPoints) {
      note = WifiPlaceNote.add(note, ap.bssid, ap.ssid);
    }
    await _remote.updateNote(target.id, note);

    return refresh();
  }

  /// Removes [link]'s line from its place's note.
  Future<List<WifiPlaceLink>> unlink(WifiPlaceLink link) async {
    final DawarichPlace fresh = await _remote.place(link.placeId);
    await _remote.updateNote(
      link.placeId,
      WifiPlaceNote.remove(fresh.note, link.bssid),
    );
    return refresh();
  }
}
