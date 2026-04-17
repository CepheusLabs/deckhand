/// Marker annotation for entry points in profile-shipped scripts.
class ProfileScript {
  const ProfileScript({required this.kind});
  final String kind;
}

/// Restricted runtime context passed to every profile script.
///
/// No dart:io, no dart:ffi, no filesystem access. All communication with
/// the rest of the world goes through this object's methods, which the
/// host runtime implements (and mocks for tests).
abstract class ScriptContext {
  /// Read a decision previously recorded by the wizard.
  T? decision<T>(String path);

  /// Read a profile field.
  T? profileField<T>(String path);

  /// Structured log line; goes to the session log.
  void log(String message, {Map<String, Object?>? data});

  /// SSH probes (read-only).
  ScriptSshProbe get ssh;
}

/// Narrow SSH interface available to profile scripts — read-only probes
/// against the printer's currently-established SSH session. Scripts can't
/// open new connections or run arbitrary commands.
abstract class ScriptSshProbe {
  Future<bool> fileExists(String path);
  Future<bool> fileContains(String path, RegExp pattern);
  Future<bool> processRunning(RegExp pattern);
  Future<bool> systemdUnitEnabled(String unit);
}

/// Return type for service-decision scripts.
enum ServiceAction { keep, stub, remove, disable }
