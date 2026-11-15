import 'package:dawarich/core/network/dio_client.dart';
import 'package:flutter/foundation.dart';

/// A place the user created by hand in Dawarich.
@immutable
final class DawarichPlace {
  final int id;
  final String name;
  final double latitude;
  final double longitude;

  const DawarichPlace({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });
}

/// alex-hack: reads manually created places from the Dawarich API
/// (`GET /api/v1/places?filter=manual`).
final class AlexPlacesRemoteSource {
  final DioClient _client;

  const AlexPlacesRemoteSource(this._client);

  Future<List<DawarichPlace>> manualPlaces() async {
    final response = await _client.get<List<dynamic>>(
      '/api/v1/places',
      queryParameters: {'filter': 'manual'},
    );

    final List<dynamic> data = response.data ?? const [];
    final List<DawarichPlace> places = [];

    for (final dynamic item in data) {
      if (item is! Map) continue;
      final Object? id = item['id'];
      final Object? lat = item['latitude'];
      final Object? lon = item['longitude'];
      if (id is! int || lat == null || lon == null) continue;

      final double? latitude = double.tryParse(lat.toString());
      final double? longitude = double.tryParse(lon.toString());
      if (latitude == null || longitude == null) continue;

      places.add(DawarichPlace(
        id: id,
        name: (item['name'] as String?)?.trim().isNotEmpty == true
            ? item['name'] as String
            : 'Place $id',
        latitude: latitude,
        longitude: longitude,
      ));
    }

    places.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return places;
  }
}
