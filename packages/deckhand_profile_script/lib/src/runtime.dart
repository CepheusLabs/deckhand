/// Runtime-execution gate for profile-shipped Dart scripts.
///
/// Deckhand v1 ships this package's *types* so profile authors can
/// compile against a stable API surface, but refuses to actually run
/// any script. Running arbitrary Dart code supplied by a third-party
/// profile needs a capability-scoped isolate sandbox, static analysis
/// pass, and signed-tag gating — none of which is implemented yet.
///
/// Call sites that would otherwise load a script must gate on
/// [ProfileScriptRuntime.enabled]. The [loadScript] entry point here
/// always throws [ProfileScriptDisabledException] so accidental wiring
/// is loud and obvious in tests.
class ProfileScriptRuntime {
  ProfileScriptRuntime._();

  /// Master kill switch. Always `false` in v1; do not flip without
  /// shipping the sandbox and signed-tag enforcement at the same time.
  static bool enabled = false;

  /// Host-side entry point for loading a profile script. Always throws
  /// until [enabled] is `true` AND a concrete host runtime has been
  /// installed via [installHost].
  static Future<void> loadScript({
    required String scriptPath,
    required String profileId,
    required String profileSha,
  }) async {
    if (!enabled || _host == null) {
      throw ProfileScriptDisabledException(
        'profile-script execution is disabled in this build '
        '(scriptPath=$scriptPath, profile=$profileId@$profileSha)',
      );
    }
    await _host!.loadScript(
      scriptPath: scriptPath,
      profileId: profileId,
      profileSha: profileSha,
    );
  }

  static ProfileScriptHost? _host;

  /// Register a concrete host implementation. A release build MUST NOT
  /// call this unless the sandbox is in place. Tests use it to wire a
  /// fake host for coverage.
  static void installHost(ProfileScriptHost host) {
    _host = host;
  }

  /// For tests: clear any host wiring.
  static void resetForTesting() {
    _host = null;
    enabled = false;
  }
}

/// Minimal contract the host has to satisfy.
abstract class ProfileScriptHost {
  Future<void> loadScript({
    required String scriptPath,
    required String profileId,
    required String profileSha,
  });
}

class ProfileScriptDisabledException implements Exception {
  ProfileScriptDisabledException(this.message);
  final String message;

  @override
  String toString() => 'ProfileScriptDisabledException: $message';
}
