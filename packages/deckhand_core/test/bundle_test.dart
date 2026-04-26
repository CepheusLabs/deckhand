import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('BundleBuilder', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('deckhand-bundle-');
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on Object {/* best-effort */}
    });

    test('writes a zip with manifest, session.log, wizard_state.json, host.json',
        () async {
      final redactor = Redactor(sessionValues: const {
        'printer_host': 'p1.local',
      });
      final bundlePath = p.join(tmp.path, 'b.zip');
      final builder = BundleBuilder(
        outputPath: bundlePath,
        redactor: redactor,
      );
      final result = await builder.build(
        sessionLog: redactor.redact('saw 192.168.0.5 talking to p1.local'),
        wizardState: WizardState.initial(),
        host: const HostInfoSnapshot(
          os: 'linux', arch: 'amd64',
          deckhandVersion: '26.4.25-1731', dartVersion: '3.10.0',
        ),
      );

      expect(File(bundlePath).existsSync(), isTrue);
      expect(result.sha256, isNotEmpty);
      // Aggregate stats should reflect the IP + session hit from the
      // session log + the placeholder hit on wizard state's empty
      // sshHost (none).
      expect(result.aggregateStats.ipCount, greaterThanOrEqualTo(1));

      // Inspect the archive's contents.
      final archive = ZipDecoder().decodeBytes(File(bundlePath).readAsBytesSync());
      final names = archive.files.map((f) => f.name).toSet();
      expect(names, contains('manifest.json'));
      expect(names, contains('session.log'));
      expect(names, contains('wizard_state.json'));
      expect(names, contains('host.json'));
    });

    test('includes optional run_state and extra text files when supplied',
        () async {
      final redactor = Redactor(sessionValues: const {});
      final bundlePath = p.join(tmp.path, 'b2.zip');
      final builder = BundleBuilder(
        outputPath: bundlePath,
        redactor: redactor,
      );
      final runState = RunState.empty(
        deckhandVersion: '1', profileId: 'p', profileCommit: 'c',
      );
      final result = await builder.build(
        sessionLog: redactor.redact('plain'),
        wizardState: WizardState.initial(),
        host: const HostInfoSnapshot(
          os: 'linux', arch: 'amd64',
          deckhandVersion: '1', dartVersion: '3.10.0',
        ),
        runState: runState,
        extraTextFiles: const {
          'doctor.txt': '[PASS] runtime ok',
          'sidecar.jsonl': '{"event":"ping"}',
        },
      );
      expect(result.sha256, isNotEmpty);
      final names = ZipDecoder()
          .decodeBytes(File(bundlePath).readAsBytesSync())
          .files
          .map((f) => f.name)
          .toSet();
      expect(names, containsAll(['run_state.json', 'doctor.txt', 'sidecar.jsonl']));
    });

    test('redacts identifiers in session.log via the supplied Redactor',
        () async {
      final redactor = Redactor(sessionValues: const {
        'printer_host': 'mybox.local',
      });
      final bundlePath = p.join(tmp.path, 'b3.zip');
      final builder = BundleBuilder(
        outputPath: bundlePath,
        redactor: redactor,
      );
      await builder.build(
        // Use the host bare so the printer-host placeholder fires;
        // an email like `user@host` would be eaten by the email
        // regex first (which is intentional: emails are
        // unconditionally redacted before host substitution).
        sessionLog:
            redactor.redact('connected to mybox.local; saw 10.0.0.5'),
        wizardState: WizardState.initial(),
        host: const HostInfoSnapshot(
          os: 'linux', arch: 'amd64',
          deckhandVersion: '1', dartVersion: '3.10.0',
        ),
      );
      final logBytes = ZipDecoder()
          .decodeBytes(File(bundlePath).readAsBytesSync())
          .files
          .firstWhere((f) => f.name == 'session.log')
          .content as List<int>;
      final body = String.fromCharCodes(logBytes);
      expect(body, contains('<PRINTER_HOST>'));
      expect(body, contains('<IP>'));
      expect(body, isNot(contains('mybox.local')));
      expect(body, isNot(contains('10.0.0.5')));
    });

    test('manifest.json records HMAC placeholder hashes with a salt',
        () async {
      final redactor = Redactor(sessionValues: const {
        'printer_host': 'secret-host.local',
      });
      final bundlePath = p.join(tmp.path, 'b4.zip');
      final builder = BundleBuilder(
        outputPath: bundlePath,
        redactor: redactor,
      );
      await builder.build(
        sessionLog: redactor.redact('hit secret-host.local'),
        wizardState: WizardState.initial(),
        host: const HostInfoSnapshot(
          os: 'linux', arch: 'amd64',
          deckhandVersion: '1', dartVersion: '3.10.0',
        ),
      );
      final manifestBytes = ZipDecoder()
          .decodeBytes(File(bundlePath).readAsBytesSync())
          .files
          .firstWhere((f) => f.name == 'manifest.json')
          .content as List<int>;
      final manifest =
          jsonDecode(String.fromCharCodes(manifestBytes)) as Map<String, dynamic>;

      // Schema bumped to /2 to reflect the salting change — older
      // tooling that knows how to read /1 won't silently mis-handle
      // a /2 bundle.
      expect(manifest['schema'], 'deckhand.debug_bundle/2');

      // Salt is present and non-empty.
      final salt = manifest['placeholder_salt'] as String;
      expect(salt, isNotEmpty);

      // Placeholder hashes are HMAC-prefixed, not bare sha256.
      final placeholders = manifest['placeholders'] as Map<String, dynamic>;
      expect(placeholders['<PRINTER_HOST>'], startsWith('hmac-sha256:'));

      // Crucial: the raw value never makes it into the manifest.
      final raw = String.fromCharCodes(manifestBytes);
      expect(raw, isNot(contains('secret-host.local')));
    });

    test('two bundles for the same printer produce DIFFERENT placeholder hashes',
        () async {
      final redactor = Redactor(sessionValues: const {
        'printer_host': 'p1.local',
      });
      Future<Map<String, dynamic>> buildOne(String name) async {
        final path = p.join(tmp.path, name);
        await BundleBuilder(outputPath: path, redactor: redactor).build(
          sessionLog: redactor.redact('plain'),
          wizardState: WizardState.initial(),
          host: const HostInfoSnapshot(
            os: 'linux', arch: 'amd64',
            deckhandVersion: '1', dartVersion: '3.10.0',
          ),
        );
        final bytes = ZipDecoder()
            .decodeBytes(File(path).readAsBytesSync())
            .files
            .firstWhere((f) => f.name == 'manifest.json')
            .content as List<int>;
        return jsonDecode(String.fromCharCodes(bytes)) as Map<String, dynamic>;
      }

      final a = await buildOne('a.zip');
      final b = await buildOne('b.zip');
      // Different salts → different HMACs even though the raw
      // value is identical. This is the protection against an
      // attacker rainbow-tabling well-known printer hostnames.
      expect(
        a['placeholder_salt'],
        isNot(equals(b['placeholder_salt'])),
        reason: 'each bundle gets its own random salt',
      );
      expect(
        (a['placeholders'] as Map)['<PRINTER_HOST>'],
        isNot(equals((b['placeholders'] as Map)['<PRINTER_HOST>'])),
      );
    });

    test('a holder of the bundle can verify a known value by '
        're-running HMAC with the manifest salt', () async {
      final redactor = Redactor(sessionValues: const {
        'printer_host': 'verifiable.local',
      });
      final bundlePath = p.join(tmp.path, 'b6.zip');
      await BundleBuilder(outputPath: bundlePath, redactor: redactor).build(
        sessionLog: redactor.redact('plain'),
        wizardState: WizardState.initial(),
        host: const HostInfoSnapshot(
          os: 'linux', arch: 'amd64',
          deckhandVersion: '1', dartVersion: '3.10.0',
        ),
      );
      final manifestBytes = ZipDecoder()
          .decodeBytes(File(bundlePath).readAsBytesSync())
          .files
          .firstWhere((f) => f.name == 'manifest.json')
          .content as List<int>;
      final manifest =
          jsonDecode(String.fromCharCodes(manifestBytes)) as Map<String, dynamic>;
      final saltBytes = base64Decode(manifest['placeholder_salt'] as String);
      final hmac = Hmac(sha256, saltBytes);
      final expected = 'hmac-sha256:${hmac.convert(utf8.encode("verifiable.local"))}';
      expect(
        (manifest['placeholders'] as Map)['<PRINTER_HOST>'],
        equals(expected),
      );
    });
  });
}
