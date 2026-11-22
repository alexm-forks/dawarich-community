import 'package:dawarich/features/tracking/application/services/background_tracking_entrypoint.dart';
import 'package:flutter_test/flutter_test.dart';

// alex-hack: fixes handled with the app closed carry the activity hint too.
void main() {
  Map<String, Object?> payload({Object? activity}) => {
        'uuid': 'abc-123',
        'timestamp': '2026-01-01T10:00:00.000Z',
        'coords': {'latitude': 51.5, 'longitude': -0.1, 'accuracy': 8.0},
        'activity': activity,
      };

  test('a headless fix carries the activity hint, like a live one', () {
    final fix = mapTraceletHeadlessLocationPayload(
      payload(activity: {'type': 'in_vehicle', 'confidence': 80}),
    )!;
    expect(fix.activity, 'IN_VEHICLE');

    final unsure = mapTraceletHeadlessLocationPayload(
      payload(activity: {'type': 'in_vehicle', 'confidence': 10}),
    )!;
    expect(unsure.activity, isNull);
  });

  test('a headless fix with no activity has no hint', () {
    expect(mapTraceletHeadlessLocationPayload(payload())!.activity, isNull);
  });
}
