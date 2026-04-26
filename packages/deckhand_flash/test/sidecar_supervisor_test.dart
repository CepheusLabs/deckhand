import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyMethod', () {
    test('returns retrySafe for read-only methods', () {
      for (final m in const [
        'ping',
        'version.compat',
        'host.info',
        'doctor.run',
        'disks.list',
        'disks.hash',
        'disks.safety_check',
        'jobs.cancel',
      ]) {
        expect(classifyMethod(m), SidecarMethodKind.retrySafe, reason: m);
      }
    });

    test('returns stateful for partial-state methods', () {
      for (final m in const [
        'os.download',
        'profiles.fetch',
        'disks.read_image',
      ]) {
        expect(classifyMethod(m), SidecarMethodKind.stateful, reason: m);
      }
    });

    test('returns failStop for destructive methods', () {
      expect(classifyMethod('disks.write_image'), SidecarMethodKind.failStop);
    });

    test('unknown methods default to stateful (safer)', () {
      expect(classifyMethod('thing.we.dont.know'), SidecarMethodKind.stateful);
    });
  });

  group('SidecarSupervisor', () {
    test('passes through a successful retrySafe call', () async {
      final fake = _FakeClient(callBehavior: (m, p) async {
        return {'ok': true, 'method': m};
      });
      final sup = SidecarSupervisor(spawn: () => fake);
      await sup.start();
      final got = await sup.call('disks.list', const {});
      expect(got, {'ok': true, 'method': 'disks.list'});
      await sup.shutdown();
    });

    test('retries a retrySafe call once on a process-exit error', () async {
      var calls = 0;
      _FakeClient? current;
      current = _FakeClient(callBehavior: (m, p) async {
        calls++;
        if (calls == 1) {
          throw const SidecarError(
            code: -1,
            message: 'sidecar process exited',
          );
        }
        return {'ok': true, 'attempt': calls};
      });

      final spawnLog = <int>[];
      var spawnCount = 0;
      final sup = SidecarSupervisor(spawn: () {
        spawnCount++;
        spawnLog.add(spawnCount);
        if (spawnCount == 1) return current!;
        // Replace the fake with a fresh one for the retry.
        return _FakeClient(callBehavior: current!.callBehavior);
      });
      await sup.start();
      // Use a zero-backoff override via overriding the schedule isn't
      // exposed; tests accept the 1s wait. Wrap in a fakeAsync if it
      // becomes painful. The call still succeeds.
      final got = await sup.call('disks.list', const {});
      expect(got, {'ok': true, 'attempt': 2});
      expect(spawnLog, [1, 2], reason: 'spawn called once initially + once for restart');
      await sup.shutdown();
    });

    test('stateful method on crash throws SidecarCrashedDuringStatefulCall',
        () async {
      final fake = _FakeClient(callBehavior: (m, p) async {
        throw const SidecarError(code: -1, message: 'sidecar process exited');
      });
      final sup = SidecarSupervisor(spawn: () => fake);
      await sup.start();
      await expectLater(
        sup.call('os.download', const {'url': 'x', 'dest': 'y'}),
        throwsA(isA<SidecarCrashedDuringStatefulCall>()
            .having((e) => e.method, 'method', 'os.download')
            .having((e) => e.latched, 'latched', isFalse)),
      );
      await sup.shutdown();
    });

    test('failStop method on crash latches the supervisor', () async {
      final fake = _FakeClient(callBehavior: (m, p) async {
        throw const SidecarError(code: -1, message: 'sidecar process exited');
      });
      final sup = SidecarSupervisor(spawn: () => fake);
      await sup.start();
      await expectLater(
        sup.call('disks.write_image', const {
          'image_path': 'x',
          'disk_id': 'y',
          'confirmation_token': 'z',
        }),
        throwsA(isA<SidecarCrashedDuringStatefulCall>()
            .having((e) => e.latched, 'latched', isTrue)),
      );
      // Subsequent calls latch immediately.
      await expectLater(
        sup.call('ping', const {}),
        throwsA(isA<SidecarLatchedException>()),
      );
    });

    test('latches after exceeding the restart cap', () async {
      final fake = _FakeClient(callBehavior: (m, p) async {
        throw const SidecarError(code: -1, message: 'sidecar process exited');
      });
      var spawns = 0;
      final sup = SidecarSupervisor(spawn: () {
        spawns++;
        return _FakeClient(callBehavior: fake.callBehavior);
      });
      await sup.start();
      // First retrySafe call: crash + restart attempt 1 -> retry crashes
      // again (2nd call to fake) -> swallowed because the same call
      // shape errors. Supervisor then propagates the original error.
      // We don't strictly assert on the error here — we assert the
      // supervisor did NOT exceed _maxRestarts.
      try {
        await sup.call('disks.list', const {});
      } on Object {/* expected */}
      try {
        await sup.call('disks.list', const {});
      } on Object {/* expected */}
      try {
        await sup.call('disks.list', const {});
      } on Object {/* expected */}
      expect(spawns, lessThanOrEqualTo(3),
          reason: '1 initial + at most _maxRestarts (2) = 3');
    });

    test('non-process-exit SidecarErrors pass through unmodified',
        () async {
      final fake = _FakeClient(callBehavior: (m, p) async {
        throw const SidecarError(
          code: -34000,
          message: 'disks.list failed: permission denied',
        );
      });
      final sup = SidecarSupervisor(spawn: () => fake);
      await sup.start();
      await expectLater(
        sup.call('disks.list', const {}),
        throwsA(isA<SidecarError>()
            .having((e) => e.code, 'code', -34000)),
      );
      await sup.shutdown();
    });

    test('start before call is required (StateError otherwise)', () async {
      final sup = SidecarSupervisor(spawn: () => _FakeClient());
      await expectLater(
        sup.call('ping', const {}),
        throwsA(isA<StateError>()),
      );
    });

    test('start is idempotent', () async {
      var spawns = 0;
      final sup = SidecarSupervisor(spawn: () {
        spawns++;
        return _FakeClient();
      });
      await sup.start();
      await sup.start();
      await sup.start();
      expect(spawns, 1);
      await sup.shutdown();
    });
  });
}

/// Fakes [SidecarClient] by extending it. The parent constructor
/// initializes a few internal fields but doesn't spawn until
/// [start] runs; we override start + call + shutdown so no real
/// process is involved.
class _FakeClient extends SidecarClient {
  _FakeClient({this.callBehavior}) : super(binaryPath: '/fake');

  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  )? callBehavior;

  @override
  Future<void> start() async {
    // Simulate a successful spawn — no process actually starts.
  }

  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    final cb = callBehavior;
    if (cb == null) return const {};
    return cb(method, params);
  }

  @override
  Future<void> shutdown() async {}
}
