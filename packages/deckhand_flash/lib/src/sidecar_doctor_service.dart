import 'package:deckhand_core/deckhand_core.dart';

import 'sidecar_client.dart';

/// [DoctorService] backed by the Go sidecar's `doctor.run` RPC.
/// The sidecar's `doctor` package
/// (`sidecar/internal/doctor/doctor.go`) is the source of truth for
/// every check; this adapter only translates the wire shape into the
/// [DoctorReport] the UI binds against. See [docs/DOCTOR.md].
///
/// Takes a [SidecarConnection] (rather than a concrete [SidecarClient])
/// so production wiring can interpose [SidecarSupervisor] and tests
/// can pass an in-memory fake.
class SidecarDoctorService implements DoctorService {
  SidecarDoctorService({required this.sidecar});

  final SidecarConnection sidecar;

  @override
  Future<DoctorReport> run() async {
    final res = await sidecar.call('doctor.run', const {});
    final passed = res['passed'] as bool? ?? false;
    final report = res['report'] as String? ?? '';
    final results = <DoctorResult>[];
    final raw = res['results'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          final m = entry.cast<String, dynamic>();
          results.add(DoctorResult(
            name: m['name'] as String? ?? '',
            status:
                doctorStatusFromString(m['status'] as String? ?? 'unknown'),
            detail: m['detail'] as String? ?? '',
          ));
        }
      }
    }
    return DoctorReport(
      passed: passed,
      results: results,
      report: report,
    );
  }
}
