import 'package:deckhand_profile_script/deckhand_profile_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(ProfileScriptRuntime.resetForTesting);

  group('ProfileScriptRuntime (v1 gate)', () {
    test('is disabled by default', () {
      expect(ProfileScriptRuntime.enabled, isFalse);
    });

    test('loadScript throws when disabled even if host is installed', () async {
      ProfileScriptRuntime.installHost(_CountingHost());
      expect(
        ProfileScriptRuntime.loadScript(
          scriptPath: 'scripts/example.dart',
          profileId: 'test-printer',
          profileSha: 'deadbeef',
        ),
        throwsA(isA<ProfileScriptDisabledException>()),
      );
    });

    test('loadScript throws when enabled but no host installed', () async {
      ProfileScriptRuntime.enabled = true;
      expect(
        ProfileScriptRuntime.loadScript(
          scriptPath: 'scripts/example.dart',
          profileId: 'test-printer',
          profileSha: 'deadbeef',
        ),
        throwsA(isA<ProfileScriptDisabledException>()),
      );
    });

    test('loadScript delegates to host only when enabled + installed', () async {
      final host = _CountingHost();
      ProfileScriptRuntime.installHost(host);
      ProfileScriptRuntime.enabled = true;
      await ProfileScriptRuntime.loadScript(
        scriptPath: 'scripts/example.dart',
        profileId: 'test-printer',
        profileSha: 'deadbeef',
      );
      expect(host.calls, 1);
    });
  });

  group('ProfileScript annotation', () {
    test('exposes kind as a const field', () {
      const ann = ProfileScript(kind: 'service-decision');
      expect(ann.kind, 'service-decision');
    });
  });

  group('ServiceAction enum', () {
    test('has the canonical v1 values', () {
      expect(
        ServiceAction.values,
        containsAll([
          ServiceAction.keep,
          ServiceAction.stub,
          ServiceAction.remove,
          ServiceAction.disable,
        ]),
      );
    });
  });
}

class _CountingHost implements ProfileScriptHost {
  int calls = 0;

  @override
  Future<void> loadScript({
    required String scriptPath,
    required String profileId,
    required String profileSha,
  }) async {
    calls++;
  }
}
