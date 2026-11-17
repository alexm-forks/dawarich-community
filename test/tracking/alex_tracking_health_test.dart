import 'package:dawarich/features/tracking/application/services/alex_tracking_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> health({
    bool desired = true,
    bool fgsEnabled = true,
    bool running = true,
    bool denied = false,
  }) =>
      {
        'desiredEnabled': desired,
        'foregroundServiceEnabled': fgsEnabled,
        'serviceRunning': running,
        'locationCapabilityLikelyDenied': denied,
      };

  test('healthy tracking needs nothing', () {
    expect(AlexTrackingHealth.needsResume(health()), isFalse);
  });

  test('service started in the background without location', () {
    expect(AlexTrackingHealth.needsResume(health(denied: true)), isTrue);
  });

  test('tracking on but the service is not running', () {
    expect(AlexTrackingHealth.needsResume(health(running: false)), isTrue);
  });

  test('tracking off, or no foreground service configured: nothing to do', () {
    expect(
      AlexTrackingHealth.needsResume(health(desired: false, denied: true)),
      isFalse,
    );
    expect(
      AlexTrackingHealth.needsResume(health(fgsEnabled: false, running: false)),
      isFalse,
    );
  });
}
