import 'dart:io';

import 'package:deckhand_profile_lint/deckhand_profile_lint.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('deckhand-profile-lint-');
    _writeSchema(tmp);
  });

  tearDown(() {
    try { tmp.deleteSync(recursive: true); } catch (_) {}
  });

  test('accepts a minimal valid profile', () async {
    _writeRegistry(tmp, ['good-printer']);
    _writeProfile(tmp, 'good-printer', _minimalValidProfile('good-printer'));
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isFalse,
        reason: report.results
            .expand((r) => r.findings.map((f) => '${r.file}: ${f.message}'))
            .join('\n'));
  });

  test('flags http:// urls as an error', () async {
    _writeRegistry(tmp, ['bad-url']);
    final profile = '${_minimalValidProfile('bad-url')}'
        '\nflows:\n  fresh_flash:\n    enabled: true\n    images:\n      - id: test\n        display_name: Test\n        url: "http://insecure.example/img.xz"\n        sha256: "${"a" * 64}"\n';
    _writeProfile(tmp, 'bad-url', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
  });

  test('flags malformed sha256', () async {
    _writeRegistry(tmp, ['bad-hash']);
    final profile = '${_minimalValidProfile('bad-hash')}'
        '\nflows:\n  fresh_flash:\n    images:\n      - id: test\n        display_name: Test\n        url: "https://example/img.xz"\n        sha256: "not-a-hash"\n';
    _writeProfile(tmp, 'bad-hash', profile);
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
  });

  test('flags folder/profile_id mismatch', () async {
    _writeRegistry(tmp, ['right-id']);
    _writeProfile(tmp, 'wrong-folder', _minimalValidProfile('right-id'));
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
  });

  test('flags profile missing from registry', () async {
    _writeRegistry(tmp, ['listed']);
    _writeProfile(tmp, 'unlisted', _minimalValidProfile('unlisted'));
    final report = await runProfileLint(['--root', tmp.path]);
    expect(report.hasErrors, isTrue);
  });

  test('status=stub is a warning that --strict escalates to error', () async {
    _writeRegistry(tmp, ['still-stub']);
    final stub = _minimalValidProfile('still-stub').replaceAll(
      'status: stable',
      'status: stub',
    );
    _writeProfile(tmp, 'still-stub', stub);
    final lenient = await runProfileLint(['--root', tmp.path]);
    expect(lenient.hasErrors, isFalse);
    final strict = await runProfileLint(['--root', tmp.path, '--strict']);
    expect(strict.hasErrors, isTrue);
  });

  group('idempotency contract', () {
    test('warns on a step missing the idempotency block', () async {
      _writeRegistry(tmp, ['missing-idem']);
      final profile = '${_minimalValidProfile('missing-idem')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: install_klipper\n'
          '        kind: install_firmware\n';
      _writeProfile(tmp, 'missing-idem', profile);
      final report = await runProfileLint(['--root', tmp.path]);
      // Lenient: warning only.
      expect(report.hasErrors, isFalse);
      final allMessages = report.results
          .expand((r) => r.findings.map((f) => f.message))
          .join('\n');
      expect(allMessages, contains('idempotency'));
    });

    test('--strict turns the missing-idempotency warning into an error',
        () async {
      _writeRegistry(tmp, ['strict-idem']);
      final profile = '${_minimalValidProfile('strict-idem')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: install_klipper\n'
          '        kind: install_firmware\n';
      _writeProfile(tmp, 'strict-idem', profile);
      final strict = await runProfileLint(['--root', tmp.path, '--strict']);
      expect(strict.hasErrors, isTrue);
    });

    test('safe_to_rerun: true silences the warning', () async {
      _writeRegistry(tmp, ['safe-rerun']);
      final profile = '${_minimalValidProfile('safe-rerun')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: install_klipper\n'
          '        kind: install_firmware\n'
          '        safe_to_rerun: true\n';
      _writeProfile(tmp, 'safe-rerun', profile);
      final strict = await runProfileLint(['--root', tmp.path, '--strict']);
      expect(strict.hasErrors, isFalse);
    });

    test('built-in idempotent kinds (snapshot_archive) need no block',
        () async {
      _writeRegistry(tmp, ['builtin-idem']);
      final profile = '${_minimalValidProfile('builtin-idem')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: snap\n'
          '        kind: snapshot_archive\n';
      _writeProfile(tmp, 'builtin-idem', profile);
      final strict = await runProfileLint(['--root', tmp.path, '--strict']);
      expect(strict.hasErrors, isFalse);
    });

    test('declared idempotency block satisfies the rule', () async {
      _writeRegistry(tmp, ['declared-idem']);
      final profile = '${_minimalValidProfile('declared-idem')}'
          '\nflows:\n  stock_keep:\n    enabled: true\n    steps:\n'
          '      - id: install_klipper\n'
          '        kind: install_firmware\n'
          '        idempotency:\n'
          '          pre_check: "test -d ~/klipper"\n'
          '          resume: cleanup_then_restart\n';
      _writeProfile(tmp, 'declared-idem', profile);
      final strict = await runProfileLint(['--root', tmp.path, '--strict']);
      expect(strict.hasErrors, isFalse);
    });
  });
}

void _writeSchema(Directory root) {
  final schemaDir = Directory(p.join(root.path, 'schema'))..createSync(recursive: true);
  // Minimal subset of the real schema — enough for these tests.
  File(p.join(schemaDir.path, 'profile.schema.json')).writeAsStringSync(r'''
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["schema_version", "profile_id", "profile_version", "display_name", "status"],
  "properties": {
    "schema_version": {"type": "integer", "const": 1},
    "profile_id": {"type": "string", "pattern": "^[a-z0-9-]+$"},
    "profile_version": {"type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$"},
    "display_name": {"type": "string", "minLength": 1},
    "status": {"type": "string", "enum": ["stub", "alpha", "beta", "stable", "deprecated"]}
  }
}
''');
}

void _writeRegistry(Directory root, List<String> profileIds) {
  final entries = profileIds.map((id) => '  - profile_id: $id').join('\n');
  File(p.join(root.path, 'registry.yaml')).writeAsStringSync(
    'profiles:\n$entries\n',
  );
}

void _writeProfile(Directory root, String folder, String contents) {
  final dir = Directory(p.join(root.path, 'printers', folder))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'profile.yaml')).writeAsStringSync(contents);
}

String _minimalValidProfile(String id) => '''
schema_version: 1
profile_id: $id
profile_version: 0.0.1
display_name: "$id"
status: stable
''';
