/// alex-hack: extra motion information sent with a point, in the fields
/// Dawarich's transportation mode detection reads (`motion_data`).
///
/// - [activity]: Android's activity recognition, in Google's names
///   (`WALKING`, `IN_VEHICLE`, ...). A hint Dawarich weighs against the
///   point's movement.
/// - [action] `stationary_presence`: the point says "at this place", not
///   "travelled here". Dawarich keeps it for visits but leaves it out of
///   distances, tracks and trips.
/// - [motion] with [authoritative]: Overland-style motion that Dawarich takes
///   as fact for the window, rather than as a hint.
final class AlexPointMotion {
  final String? activity;
  final String? action;
  final List<String> motion;
  final bool authoritative;

  const AlexPointMotion({
    this.activity,
    this.action,
    this.motion = const [],
    this.authoritative = false,
  });

  /// Recorded at a linked Wi-Fi place: present there, not moving.
  static const AlexPointMotion atPlace = AlexPointMotion(
    action: 'stationary_presence',
    motion: ['stationary'],
    authoritative: true,
  );

  bool get isEmpty => activity == null && action == null && motion.isEmpty;

  Map<String, dynamic> toJson() => {
        if (activity != null) 'activity': activity,
        if (action != null) 'action': action,
        if (motion.isNotEmpty) 'motion': motion,
        if (motion.isNotEmpty && authoritative) 'motion_authoritative': true,
      };

  @override
  bool operator ==(Object other) =>
      other is AlexPointMotion &&
      other.activity == activity &&
      other.action == action &&
      other.authoritative == authoritative &&
      other.motion.join(',') == motion.join(',');

  @override
  int get hashCode => Object.hash(activity, action, authoritative, motion.join(','));

  @override
  String toString() => 'AlexPointMotion(${toJson()})';
}
