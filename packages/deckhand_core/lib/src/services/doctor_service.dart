/// Sidecar self-diagnostic. Implementations call the sidecar's
/// `doctor.run` JSON-RPC method and return structured results so the
/// UI can render its own preflight panel rather than parsing CLI text.
///
/// See [docs/DOCTOR.md] for the check catalog and where in the wizard
/// the results are surfaced.
abstract class DoctorService {
  /// Run the diagnostic. Cheap (sub-second on a healthy host) so the
  /// UI calls it on every S10-welcome enter without debouncing.
  Future<DoctorReport> run();
}

class DoctorReport {
  const DoctorReport({
    required this.passed,
    required this.results,
    required this.report,
  });

  /// True when every check returned [DoctorStatus.pass] or [DoctorStatus.warn].
  /// Mirrors the sidecar's contract: only `FAIL` status flips this to false.
  final bool passed;

  /// Ordered diagnostic results, one entry per check.
  final List<DoctorResult> results;

  /// Human-readable report — same string `deckhand-sidecar doctor`
  /// prints to stdout. Surfaced in the "View report" expander so a
  /// user copying-pasting into a support thread gets identical
  /// output to the CLI.
  final String report;

  /// Convenience filter: every result whose status is FAIL.
  Iterable<DoctorResult> get failures =>
      results.where((r) => r.status == DoctorStatus.fail);

  /// Convenience filter: every result whose status is WARN.
  Iterable<DoctorResult> get warnings =>
      results.where((r) => r.status == DoctorStatus.warn);
}

class DoctorResult {
  const DoctorResult({
    required this.name,
    required this.status,
    required this.detail,
  });
  final String name;
  final DoctorStatus status;
  final String detail;
}

enum DoctorStatus { pass, warn, fail, unknown }

/// Parse a sidecar status string into a [DoctorStatus]. Defensive
/// against new statuses introduced by a newer sidecar against an older
/// UI: anything we don't recognise becomes [DoctorStatus.unknown] and
/// the UI shows the raw status name in italics rather than crashing.
DoctorStatus doctorStatusFromString(String s) {
  switch (s.toUpperCase()) {
    case 'PASS':
      return DoctorStatus.pass;
    case 'WARN':
      return DoctorStatus.warn;
    case 'FAIL':
      return DoctorStatus.fail;
    default:
      return DoctorStatus.unknown;
  }
}
