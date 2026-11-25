# tracelet_android (alex-hack copy)

A copy of [tracelet_android](https://pub.dev/packages/tracelet_android) 3.8.10 from pub.dev
(Apache-2.0, [Ikolvi/Tracelet](https://github.com/Ikolvi/Tracelet)), used instead of the
pub.dev package through `dependency_overrides` in the app's pubspecs. The first commit
that adds it is the unchanged package, apart from `pubspec.yaml` (`resolution: workspace`
removed so it resolves outside Tracelet's workspace, `publish_to: none`). Later commits are the
changes listed here, so `git log -p packages/tracelet_android` shows each one.

Only the Android plugin is copied. `tracelet`, `tracelet_platform_interface` and the native
SDK (`com.ikolvi:tracelet-sdk`, from Maven Central) are the published versions, so this
copy's version must match them.

## Changes

### The primary engine only receives events once it has an activity or subscribes

`android/src/main/kotlin/com/ikolvi/tracelet/flutter/TraceletAndroidPlugin.kt`

**Problem:** the first Flutter engine to attach in the process becomes Tracelet's primary,
and the primary joined the event fan-out at once. With the app's UI closed, a WorkManager job
(the expired-batch upload, stats refresh and tracking health check run every 15 minutes)
starts an engine of its own. It becomes primary, so it counts as receiving events, though
its Dart side never listens. Every location then went into that isolate instead of the
headless task that saves points, for as long as the job's engine lived. It's the same
mechanism that stopped points for hours with the old `flutter_background_service` engine
(22 Nov). Secondary engines already had to subscribe first (Tracelet #364); the primary
didn't.

**Change:** the primary still takes the primary role at attach (SDK initialisation, event
sender, headless fallback, sync interceptor), but its dispatcher joins the fan-out only
when:

- an activity attaches to it (the app's own UI engine: right after the engine attach,
  before any Dart runs), or
- its Dart side subscribes to an event stream (the existing `requestStateFlush`
  handshake, as for secondary engines).

Until then the fan-out is empty and events go to the headless task. Tracelet Doctor shows
`engines: primary attach … events go to the headless task until it has an activity or its
Dart side subscribes (alex-hack)`, then `engines: primary engine has an activity — joining
the event fan-out` for the app's UI. A WorkManager engine shows the first line followed by
`routing to the headless task (#371)` if a fix arrives while it runs.

**Tests:** five new cases in `PluginSecondaryEngineGuardTest.kt`. With Tracelet's
unchanged code, the two that reproduce the bug fail; with the change, all 22 tests in that file,
`PluginPermissionCallbackDetachTest` and `EventSenderFactoryTest` pass.

**Remove when:** Tracelet makes the primary wait for a subscription too (worth reporting
upstream with this change).

## Updating to a new Tracelet version

1. Bump `tracelet` and `tracelet_doctor` in the pubspecs.
2. Replace this folder with the new `tracelet_android` from pub.dev
   (`https://pub.dev/api/archives/tracelet_android-<version>.tar.gz`; keep `android/`,
   `lib/`, `LICENSE`, `README.md`, `CHANGELOG.md`, `pubspec.yaml`), remove
   `resolution: workspace` from its pubspec and add `publish_to: none`, and commit that on
   its own.
3. Re-apply the changes above if the new version still needs them (check its
   `onAttachedToEngine`), and keep this file.
4. If Tracelet has fixed it, delete this folder and the `dependency_overrides` entries.
