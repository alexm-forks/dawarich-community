import 'package:tracelet/tracelet.dart' as tl;

/// alex-hack: Android's activity recognition, as the Google activity names
/// Dawarich's transportation mode detection understands. Low-confidence and
/// unknown activities give null: no hint is better than a wrong one.
String? alexGoogleActivity(tl.LocationActivity activity) {
  if (activity.confidence == tl.ActivityConfidence.low) return null;
  return switch (activity.type) {
    tl.ActivityType.still => 'STILL',
    tl.ActivityType.walking => 'WALKING',
    tl.ActivityType.running => 'RUNNING',
    tl.ActivityType.onFoot => 'ON_FOOT',
    tl.ActivityType.inVehicle => 'IN_VEHICLE',
    tl.ActivityType.onBicycle => 'ON_BICYCLE',
    tl.ActivityType.unknown => null,
  };
}
