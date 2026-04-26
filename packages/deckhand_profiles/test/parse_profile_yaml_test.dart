import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_profiles/src/sidecar_profile_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [parseProfileYaml], the pure-string seam for
/// [SidecarProfileService.load]. We exercise it directly instead of
/// the service so tests don't depend on File I/O or a sidecar process.
void main() {
  const validProfile = '''
schema_version: 1
profile_id: test-printer
profile_version: 0.1.0
display_name: Test Printer
status: alpha
manufacturer: Acme
model: Robo
hardware:
  architecture: aarch64
os:
  fresh_install_options:
    - id: debian
      display_name: Debian 12
      url: https://example.com/img
ssh:
  default_credentials:
    - user: mks
      password: makerbase
firmware:
  choices:
    - id: kalico
      display_name: Kalico
      repo: https://github.com/KalicoCrew/kalico
      ref: main
  default_choice: kalico
flows:
  stock_keep:
    enabled: true
    steps: []
''';

  group('parseProfileYaml happy path', () {
    test('parses a valid minimal profile into the model', () {
      final profile = parseProfileYaml(validProfile);
      expect(profile.id, 'test-printer');
      expect(profile.version, '0.1.0');
      expect(profile.displayName, 'Test Printer');
      expect(profile.status, ProfileStatus.alpha);
      expect(profile.manufacturer, 'Acme');
      expect(profile.model, 'Robo');
      expect(profile.hardware.architecture, 'aarch64');
      expect(profile.os.freshInstallOptions.single.id, 'debian');
      expect(profile.firmware.defaultChoice, 'kalico');
      expect(profile.flows.stockKeep?.enabled, isTrue);
    });

    test('preserves unknown future keys (forward compatibility)', () {
      // A profile from a newer deckhand-profiles release may carry
      // fields this app version doesn't model yet. They must round-
      // trip through `raw` so persisted state, logs, and bug reports
      // don't silently drop the data.
      const withUnknown = '''
schema_version: 99
profile_id: future-printer
profile_version: 9.9.9
display_name: Future Printer
status: alpha
brand_new_key: some-value
nested_future_block:
  color: orange
  thermal_runaway_grace_seconds: 5
''';
      final profile = parseProfileYaml(withUnknown);
      expect(profile.id, 'future-printer');
      expect(profile.raw['brand_new_key'], 'some-value');
      expect(profile.raw['nested_future_block'],
          isA<Map<String, dynamic>>());
      expect(
        (profile.raw['nested_future_block']
            as Map<String, dynamic>)['color'],
        'orange',
      );
    });

    test('status: stub parses to ProfileStatus.stub so the wizard can '
        'refuse to use it', () {
      const stubProfile = '''
schema_version: 1
profile_id: work-in-progress
profile_version: 0.0.1
display_name: WIP
status: stub
''';
      final profile = parseProfileYaml(stubProfile);
      expect(profile.status, ProfileStatus.stub,
          reason: 'status=stub must survive the parse round-trip');
    });
  });

  group('parseProfileYaml rejects malformed profiles with a clean exception',
      () {
    test('missing schema_version throws ProfileFormatException '
        '(not a cast/null error)', () {
      const noSchema = '''
profile_id: test
profile_version: 0.1.0
display_name: Test
status: alpha
''';
      expect(
        () => parseProfileYaml(noSchema),
        throwsA(
          isA<ProfileFormatException>().having(
            (e) => e.message,
            'message',
            contains('schema_version'),
          ),
        ),
      );
    });

    test('missing profile_id throws ProfileFormatException', () {
      const noId = '''
schema_version: 1
profile_version: 0.1.0
display_name: Test
status: alpha
''';
      expect(
        () => parseProfileYaml(noId),
        throwsA(
          isA<ProfileFormatException>().having(
            (e) => e.message,
            'message',
            contains('profile_id'),
          ),
        ),
      );
    });

    test('empty profile_id throws ProfileFormatException', () {
      const emptyId = '''
schema_version: 1
profile_id: ""
profile_version: 0.1.0
display_name: Test
status: alpha
''';
      expect(() => parseProfileYaml(emptyId),
          throwsA(isA<ProfileFormatException>()));
    });

    test('non-mapping root throws ProfileFormatException', () {
      // A YAML list at the root (a common copy-paste mistake when
      // authors paste fragment content) must fail cleanly.
      const listRoot = '''
- one
- two
- three
''';
      expect(() => parseProfileYaml(listRoot),
          throwsA(isA<ProfileFormatException>()));
    });

    test('ProfileFormatException.toString includes the message', () {
      const e = ProfileFormatException('missing field `foo`');
      expect(e.toString(), contains('missing field `foo`'));
    });
  });

  // TODO(test-hardware): end-to-end `SidecarProfileService.load` goes
  // through File I/O + an actual sidecar process for `ensureCached`.
  // That's covered in the wizard-level integration harness. The pure
  // parsing contract is fully covered here.
}
