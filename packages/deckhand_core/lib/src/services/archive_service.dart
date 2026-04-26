import 'ssh_service.dart';

/// Capture and restore tar.gz archives of remote paths over SSH.
///
/// The S145 stock-config snapshot screen relies on this to copy the
/// user's hand-edited config off the printer before Flow A's install
/// rewrites it. See [docs/WIZARD-FLOW.md] (S145-snapshot) and
/// [docs/STEP-IDEMPOTENCY.md] for the post-install restore step.
abstract class ArchiveService {
  /// Stream `tar -czf - <paths>` over [session] into a host-local
  /// archive at [archivePath]. Yields a [SnapshotProgress] event for
  /// every chunk written so the UI can show a "X MB captured" line.
  ///
  /// On failure the partial archive is deleted before the stream
  /// errors — half-written archives must never look like valid
  /// snapshots.
  Stream<SnapshotProgress> captureRemote({
    required SshSession session,
    required List<String> paths,
    required String archivePath,
  });

  /// Unpack [archivePath] into [destDir] on the printer (over the same
  /// SSH session). Files are unpacked side-by-side — the caller picks
  /// a destDir like `~/printer_data.stock-<date>/` rather than
  /// overwriting the live config.
  ///
  /// Returns the list of files successfully restored. A non-empty
  /// `errors` list does not abort the operation: the wizard treats
  /// snapshot restore as best-effort and surfaces the error list to
  /// the user instead of failing the install.
  Future<RestoreResult> restoreRemote({
    required SshSession session,
    required String archivePath,
    required String destDir,
  });

  /// SHA-256 of a host-local archive. Recorded in the session log so a
  /// later debug bundle can prove which snapshot was used.
  Future<String> archiveSha256(String archivePath);
}

class SnapshotProgress {
  const SnapshotProgress({
    required this.bytesCaptured,
    required this.bytesEstimated,
    this.currentPath,
  });
  final int bytesCaptured;
  final int bytesEstimated;
  final String? currentPath;
  double get fraction =>
      bytesEstimated == 0 ? 0 : bytesCaptured / bytesEstimated;
}

class RestoreResult {
  const RestoreResult({
    required this.restoredFiles,
    required this.errors,
  });
  final List<String> restoredFiles;
  final List<String> errors;
}
