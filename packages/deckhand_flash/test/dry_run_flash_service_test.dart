import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/src/sidecar_client.dart';
import 'package:deckhand_flash/src/sidecar_flash_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pin the most important guarantee of dry-run mode: it must NEVER
/// reach the sidecar. A real sidecar call would (a) require a live
/// process, (b) acquire a confirmation token, and (c) potentially
/// flash a disk if the test environment had elevation. None of that
/// can happen when `dryRun: true`.
///
/// Implementation: pass a [SidecarClient] whose binary points at a
/// path that DOES NOT EXIST. If the dry-run flag fails to short-
/// circuit, the underlying `Process.start` would throw — and the
/// test would fail with the wrong error type.
void main() {
  late SidecarClient deadClient;

  setUp(() {
    deadClient = SidecarClient(binaryPath: '/this/path/does/not/exist');
    // Deliberately do NOT call `start()`. A real sidecar call would
    // throw `StateError('SidecarClient not started')` if dry-run
    // forgot to gate.
  });

  group('SidecarFlashService dry-run', () {
    test('writeImage emits a synthetic stream and never touches the client',
        () async {
      final svc = SidecarFlashService(deadClient, dryRun: true);

      final events = await svc
          .writeImage(
            imagePath: '/tmp/img.xz',
            diskId: 'mmcblk0',
            confirmationToken: 'tok',
          )
          .toList();

      expect(events, isNotEmpty);
      expect(events.first.phase, FlashPhase.preparing);
      expect(events.last.phase, FlashPhase.done);
      // The simulated stream announces itself as DRY-RUN in the
      // message so a developer watching the UI knows nothing real
      // happened.
      expect(events.last.message, contains('DRY-RUN'));
    });

    test('readImage emits a synthetic stream', () async {
      final svc = SidecarFlashService(deadClient, dryRun: true);
      final events = await svc
          .readImage(diskId: 'mmcblk0', outputPath: '/tmp/backup.img')
          .toList();
      expect(events.last.phase, FlashPhase.done);
      expect(events.last.message, contains('DRY-RUN'));
    });

    test('sha256 returns a clearly synthetic digest, no RPC', () async {
      final svc = SidecarFlashService(deadClient, dryRun: true);
      final digest = await svc.sha256('/some/path');
      expect(digest, hasLength(64));
      expect(digest, contains('dryrun'));
    });

    test('NOT setting dryRun would actually try to call the sidecar',
        () async {
      // Prove the contract from the other side: with dryRun: false,
      // calling writeImage on a not-started client surfaces a real
      // error. This pins the regression — if someone refactors
      // `dryRun` and accidentally drops the gate, this test starts
      // passing in the dry-run-off path *and* the dry-run-on path
      // returns the synthetic stream (covered above), which is the
      // exact silent-failure mode we're guarding against.
      final svc = SidecarFlashService(deadClient, dryRun: false);
      expect(
        () => svc.writeImage(
          imagePath: '/tmp/img.xz',
          diskId: 'mmcblk0',
          confirmationToken: 'tok',
        ).first,
        throwsA(isA<Object>()),
      );
    });
  });
}
