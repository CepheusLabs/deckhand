import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../wizard/run_state.dart';
import '../wizard/wizard_state.dart';
import 'redactor.dart';

/// Assembles a debug bundle on disk. See [docs/DEBUG-BUNDLES.md] for
/// the full design — what goes in, what's redacted, what's never
/// included. The bundler is the file-writing companion to the
/// [DebugBundleScreen]'s review step:
///
///   1. UI calls [BundleBuilder.build] with the redacted log + the
///      live wizard state + path hints.
///   2. Builder reads the on-printer run-state file (when an SSH
///      session is reachable), redacts every text artifact through
///      [Redactor], assembles a `.zip`, and returns its path.
///
/// A bundle's contents:
///
///   - `manifest.json` (always)
///   - `session.log` (always — the redacted log the screen showed)
///   - `wizard_state.json` (always — redacted)
///   - `run_state.json` (when present)
///   - `host.json` (always — runtime/arch/version, NO data dirs)
///   - `doctor.txt` (when supplied by caller)
///   - `network.jsonl` (when supplied by caller)
///   - `sidecar.jsonl` (when supplied by caller)
///
/// **Placeholder hash protection.** The manifest's `placeholders`
/// map ties each placeholder (`<PRINTER_HOST>`, `<USER>`, …) to a
/// hash so the same printer's bundles can be correlated without
/// revealing the raw value. A naïve `sha256(value)` would be
/// trivially rainbow-tabled — printer hostnames are low-entropy
/// (`printer.local`, `192.168.1.50`, common defaults). We HMAC the
/// values with a per-bundle 256-bit random salt instead. The salt
/// is included in the bundle itself, so a maintainer who has the
/// bundle can verify a hash; a third party who only has the
/// manifest cannot.
class BundleBuilder {
  BundleBuilder({
    required this.outputPath,
    required this.redactor,
    Random? rng,
  }) : _rng = rng ?? Random.secure();

  final Random _rng;

  /// Where the resulting `.zip` lands.
  final String outputPath;

  /// Redactor used for every text artifact added to the bundle.
  final Redactor redactor;

  /// Build the bundle. Returns the bundle's [BundleResult] including
  /// the SHA-256 of the written zip and aggregated redaction stats
  /// across every text artifact.
  ///
  /// `runState` and `extraTextFiles` are optional — the screen knows
  /// what's available; the bundler doesn't try to fetch them.
  Future<BundleResult> build({
    required RedactedDocument sessionLog,
    required WizardState wizardState,
    required HostInfoSnapshot host,
    RunState? runState,
    Map<String, String>? extraTextFiles,
  }) async {
    final encoder = ZipFileEncoder();
    encoder.create(outputPath);
    final aggregateStats = RedactionStats();

    void addText(String pathInside, RedactedDocument doc) {
      final bytes = utf8.encode(doc.text);
      encoder.addArchiveFile(ArchiveFile(pathInside, bytes.length, bytes));
      _accumulate(aggregateStats, doc.stats);
    }

    void addRaw(String pathInside, String body) {
      // Even "raw" text-like inputs go through the redactor — better
      // a noisy false positive than a missed identifier.
      final r = redactor.redact(body);
      addText(pathInside, r);
    }

    // Use the already-redacted document the screen showed the user.
    // Re-running the redactor on placeholdered text would zero out
    // the stats and double-replace the placeholders, hiding what
    // the user reviewed.
    addText('session.log', sessionLog);
    addText(
      'wizard_state.json',
      redactor.redactJson(wizardState.toJson()),
    );
    addText('host.json', redactor.redactJson(host.toJson()));

    if (runState != null) {
      addText(
        'run_state.json',
        redactor.redactJson(runState.toJson()),
      );
    }
    if (extraTextFiles != null) {
      for (final entry in extraTextFiles.entries) {
        addRaw(entry.key, entry.value);
      }
    }

    // Per-bundle HMAC salt — 32 random bytes, base64-encoded. The
    // salt lives in the manifest so a holder of the bundle can
    // reproduce the hashes (and confirm "yes, that placeholder
    // really did stand in for printer.local"); a third party with
    // only the placeholder name cannot rainbow-table the value.
    final saltBytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    final salt = base64Encode(saltBytes);
    final hmac = Hmac(sha256, saltBytes);
    String? hashFor(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      return 'hmac-sha256:${hmac.convert(utf8.encode(raw))}';
    }

    final manifest = <String, Object?>{
      'schema': 'deckhand.debug_bundle/2',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'redaction_stats': aggregateStats.toJson(),
      'placeholder_salt': salt,
      'placeholders': {
        for (final entry
            in redactor.placeholderForSession.entries)
          entry.value: hashFor(redactor.sessionValues[entry.key]),
      },
    };
    final manifestBytes =
        utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest));
    encoder.addArchiveFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );

    encoder.closeSync();

    final sha = await _sha256OfFile(outputPath);
    return BundleResult(
      path: outputPath,
      sha256: sha,
      aggregateStats: aggregateStats,
    );
  }

  static Future<String> _sha256OfFile(String path) async {
    final f = File(path);
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }

  static void _accumulate(RedactionStats agg, RedactionStats one) {
    agg.sessionHits += one.sessionHits;
    agg.ipCount += one.ipCount;
    agg.macCount += one.macCount;
    agg.emailCount += one.emailCount;
    agg.fprCount += one.fprCount;
    agg.secretCount += one.secretCount;
  }
}

@immutable
class HostInfoSnapshot {
  const HostInfoSnapshot({
    required this.os,
    required this.arch,
    required this.deckhandVersion,
    required this.dartVersion,
  });

  final String os;
  final String arch;
  final String deckhandVersion;
  final String dartVersion;

  Map<String, dynamic> toJson() => {
        'os': os,
        'arch': arch,
        'deckhand_version': deckhandVersion,
        'dart_version': dartVersion,
      };
}

@immutable
class BundleResult {
  const BundleResult({
    required this.path,
    required this.sha256,
    required this.aggregateStats,
  });

  /// Filesystem path the zip was written to.
  final String path;

  /// SHA-256 of the zip — surfaced in the post-write toast so users
  /// can paste it alongside the bundle for integrity correlation.
  final String sha256;

  /// Aggregated redaction stats summed across every text artifact in
  /// the bundle. The review screen showed per-artifact stats; the
  /// post-write summary shows the total.
  final RedactionStats aggregateStats;
}

String defaultBundleName() {
  final ts = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;
  return 'deckhand-debug-$ts.zip';
}

String defaultBundlePath(String bundlesDir) {
  return p.join(bundlesDir, defaultBundleName());
}
