import 'package:dawarich/core/network/dio_client.dart';
import 'package:flutter/foundation.dart';

/// A place the user created by hand in Dawarich.
@immutable
final class DawarichPlace {
  final int id;
  final String name;
  final double latitude;
  final double longitude;
  final String note;

  const DawarichPlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.note = '',
  });

  static DawarichPlace? fromJson(Object? item) {
    if (item is! Map) return null;
    final Object? id = item['id'];
    final Object? lat = item['latitude'];
    final Object? lon = item['longitude'];
    if (id is! int || lat == null || lon == null) return null;

    final double? latitude = double.tryParse(lat.toString());
    final double? longitude = double.tryParse(lon.toString());
    if (latitude == null || longitude == null) return null;

    final String name = (item['name'] as String?)?.trim() ?? '';

    return DawarichPlace(
      id: id,
      name: name.isNotEmpty ? name : 'Place $id',
      latitude: latitude,
      longitude: longitude,
      note: item['note'] as String? ?? '',
    );
  }
}

/// alex-hack: manually created places in the Dawarich API
/// (`/api/v1/places`), including their notes, which hold Wi-Fi links.
class AlexPlacesRemoteSource {
  final DioClient _client;

  const AlexPlacesRemoteSource(this._client);

  Future<List<DawarichPlace>> manualPlaces() async {
    final response = await _client.get<List<dynamic>>(
      '/api/v1/places',
      queryParameters: {'filter': 'manual'},
    );

    final List<DawarichPlace> places = (response.data ?? const [])
        .map(DawarichPlace.fromJson)
        .whereType<DawarichPlace>()
        .toList();

    places.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return places;
  }

  Future<DawarichPlace> place(int id) async {
    final response = await _client.get<Map<String, dynamic>>('/api/v1/places/$id');
    final DawarichPlace? place = DawarichPlace.fromJson(response.data);
    if (place == null) {
      throw StateError('Dawarich returned an unreadable place $id');
    }
    return place;
  }

  Future<void> updateNote(int id, String note) async {
    await _client.patch<Map<String, dynamic>>(
      '/api/v1/places/$id',
      data: {
        'place': {'note': note},
      },
    );
  }
}
