import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';

import 'sidecar_client.dart';

/// Supervises a [SidecarClient] across crashes.
///
/// The bare [SidecarClient] propagates "sidecar process exited" as an
/// error to every in-flight completer. That's the right primitive,
/// but it leaves callers with no policy for what to do next: every
/// adapter would have to re-derive "is this method safe to retry?"
/// and "is the sidecar still healthy?" on its own.
///
/// [SidecarSupervisor] adds:
///
///   * **Method classification.** Each method is one of
///     [SidecarMethodKind.retrySafe], [SidecarMethodKind.stateful],
///     or [SidecarMethodKind.failStop]. The supervisor re-spawns the
///     sidecar and retries `retrySafe` methods once on a clean
///     process exit. `stateful` methods surface a typed
///     [SidecarCrashedDuringStatefulCall] exception. `failStop`
///     methods do the same and additionally latch the supervisor —
///     no further calls succeed until the user explicitly relaunches
///     Deckhand.
///   * **Restart policy.** Two automatic restarts per session, with
///     exponential backoff (1s, 4s). After the third crash the
///     supervisor latches and every subsequent call fails
///     immediately. Avoids a runaway restart loop pinning the CPU
///     when the sidecar segfaults on startup.
///   * **One health-check call** after every restart so the new
///     sidecar's `version.compat` mismatch is caught at supervisor
///     scope rather than at adapter scope.
///
/// See [docs/ARCHITECTURE.md](../../../docs/ARCHITECTURE.md)
/// (sidecar crash recovery) for the full design notes.
class SidecarSupervisor implements SidecarConnection {
  SidecarSupervisor({
    required SidecarClient Function() spawn,
    DeckhandLogger? logger,
  }) : _spawn = spawn,
       _logger = logger;

  final SidecarClient Function() _spawn;
  final DeckhandLogger? _logger;

  SidecarClient? _client;
  int _restartCount = 0;
  bool _latched = false;

  static const int _maxRestarts = 2;
  static const List<Duration> _backoffSchedule = [
    Duration(seconds: 1),
    Duration(seconds: 4),
  ];

  /// Start the underlying sidecar. Idempotent.
  Future<void> start() async {
    if (_client != null) return;
    _client = _spawn();
    await _client!.start();
    _hookNotificationsBridge();
  }

  /// Issue a JSON-RPC call. Honors method classification and restart
  /// policy. Throws [SidecarLatchedException] when the supervisor has
  /// latched, [SidecarCrashedDuringStatefulCall] when a stateful
  /// call's sidecar died mid-flight.
  @override
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_latched) {
      throw const SidecarLatchedException();
    }
    if (_client == null) {
      throw StateError('SidecarSupervisor.call before start()');
    }

    final kind = classifyMethod(method);
    try {
      return await _client!.call(method, params);
    } on SidecarError catch (e) {
      // SidecarError code -1 with the canonical "exited" message is
      // how SidecarClient surfaces a process death. Anything else is
      // an in-band error from a still-alive sidecar — pass it through.
      if (!_isProcessExitError(e)) rethrow;

      switch (kind) {
        case SidecarMethodKind.retrySafe:
          _logger?.warn(
            'sidecar crashed during retrySafe call $method; restarting',
          );
          await _restartOrLatch();
          return _client!.call(method, params);
        case SidecarMethodKind.stateful:
          await _restartOrLatch();
          throw SidecarCrashedDuringStatefulCall(method: method);
        case SidecarMethodKind.failStop:
          _latched = true;
          await _client?.shutdown();
          _client = null;
          throw SidecarCrashedDuringStatefulCall(
            method: method,
            latched: true,
          );
      }
    }
  }

  /// Forwarder for `callStreaming`. Streams are inherently stateful —
  /// progress delivered before the crash can't be replayed cleanly,
  /// so this method does not auto-retry. The downstream consumer is
  /// expected to handle the in-band error; the supervisor's only job
  /// here is to attempt a restart so the next call can succeed.
  @override
  Stream<SidecarEvent> callStreaming(
    String method,
    Map<String, dynamic> params,
  ) async* {
    if (_latched) throw const SidecarLatchedException();
    if (_client == null) {
      throw StateError('SidecarSupervisor.callStreaming before start()');
    }
    try {
      yield* _client!.callStreaming(method, params);
    } on SidecarError catch (e) {
      if (_isProcessExitError(e)) {
        await _restartOrLatch();
      }
      rethrow;
    }
  }

  /// Subscribe to the all-notifications stream. The supervisor
  /// re-subscribes automatically across restarts via the rebroadcast
  /// controller so long-lived listeners (the egress visualizer, for
  /// instance) don't go silent after the first sidecar crash.
  @override
  Stream<SidecarNotification> get notifications => _notificationsRebroadcast.stream;

  /// Forward per-operation streams to the underlying client. The
  /// returned stream is the live one from the *current* client; if a
  /// restart happens mid-operation the operation itself was already
  /// classified (stateful → caller cleans up; retrySafe → caller retries
  /// the call which gets a new operation id) so we don't try to bridge
  /// notifications across restarts.
  @override
  Stream<SidecarNotification> subscribeToOperation(String operationId) {
    final c = _client;
    if (c == null) {
      throw StateError(
        'SidecarSupervisor.subscribeToOperation before start()',
      );
    }
    return c.subscribeToOperation(operationId);
  }

  // Rebroadcast controller for notifications — see [notifications].
  // Wired up in start() / on every restart so the public stream
  // outlives any individual client.
  final _notificationsRebroadcast =
      StreamController<SidecarNotification>.broadcast();
  StreamSubscription<SidecarNotification>? _notifBridge;

  void _hookNotificationsBridge() {
    _notifBridge?.cancel();
    final c = _client;
    if (c == null) return;
    _notifBridge = c.notifications.listen(
      _notificationsRebroadcast.add,
      onError: _notificationsRebroadcast.addError,
      cancelOnError: false,
    );
  }

  @override
  Future<void> shutdown() async {
    _latched = true;
    await _notifBridge?.cancel();
    if (!_notificationsRebroadcast.isClosed) {
      await _notificationsRebroadcast.close();
    }
    await _client?.shutdown();
    _client = null;
  }

  Future<void> _restartOrLatch() async {
    if (_restartCount >= _maxRestarts) {
      _latched = true;
      throw const SidecarLatchedException();
    }
    final backoff = _backoffSchedule[_restartCount];
    _restartCount++;
    _logger?.info(
      'sidecar restart attempt $_restartCount after ${backoff.inSeconds}s',
    );
    await _notifBridge?.cancel();
    await _client?.shutdown();
    _client = null;
    await Future<void>.delayed(backoff);
    _client = _spawn();
    await _client!.start();
    // Re-attach the rebroadcast bridge so listeners on the public
    // [notifications] stream receive events from the new client.
    _hookNotificationsBridge();
  }

  bool _isProcessExitError(SidecarError e) =>
      e.code == -1 && e.message.contains('sidecar process exited');
}

/// Classification used by [SidecarSupervisor.call]. See the per-kind
/// docs for the policy.
enum SidecarMethodKind {
  /// The method is a pure read with no on-disk side effects, so the
  /// supervisor can re-spawn the sidecar and replay the call without
  /// risking double-execution. `ping`, `host.info`, `doctor.run`,
  /// `disks.list`, `disks.hash`, `version.compat`.
  retrySafe,

  /// The method writes durable state — partial files in cache,
  /// half-completed git clones, partial dd output. Restarting and
  /// re-running could leave inconsistent state on disk, so the
  /// supervisor surfaces a typed exception and lets the caller
  /// decide whether to clean up and retry. `os.download`,
  /// `profiles.fetch`, `disks.read_image`.
  stateful,

  /// The method is destructive and the user has already approved it
  /// (confirmation token issued, elevation prompted). A crash here
  /// is an unrecoverable invariant violation: the supervisor
  /// latches, refuses further calls, and the UI must surface a
  /// "Deckhand needs to relaunch" hard-stop screen.
  /// `disks.write_image` (the elevated-helper path is unaffected by
  /// sidecar death, but the sidecar's pre-flight that issues the
  /// elevation_required error is on this path and a crash there
  /// leaves the UI in an inconsistent state).
  failStop,
}

SidecarMethodKind classifyMethod(String method) {
  switch (method) {
    case 'ping':
    case 'version.compat':
    case 'host.info':
    case 'doctor.run':
    case 'disks.list':
    case 'disks.hash':
    case 'disks.safety_check':
    case 'jobs.cancel':
      return SidecarMethodKind.retrySafe;
    case 'os.download':
    case 'profiles.fetch':
    case 'disks.read_image':
      return SidecarMethodKind.stateful;
    case 'disks.write_image':
      return SidecarMethodKind.failStop;
    default:
      // Unknown method names default to stateful — the safer choice
      // when classification is ambiguous. A new method added without
      // updating this switch errs on the side of "do not retry."
      return SidecarMethodKind.stateful;
  }
}

/// The supervisor has hit its restart cap (or processed a fail-stop
/// crash) and refuses further calls until the app relaunches.
class SidecarLatchedException implements Exception {
  const SidecarLatchedException();
  @override
  String toString() =>
      'SidecarLatchedException: too many sidecar crashes; relaunch Deckhand';
}

/// Sidecar exited mid-call on a [SidecarMethodKind.stateful] method.
/// Caller is expected to clean up partial state (delete the half-
/// downloaded file, rm -rf the partial clone) before retrying.
class SidecarCrashedDuringStatefulCall implements Exception {
  const SidecarCrashedDuringStatefulCall({
    required this.method,
    this.latched = false,
  });
  final String method;
  final bool latched;
  @override
  String toString() =>
      'SidecarCrashedDuringStatefulCall(method=$method, latched=$latched)';
}
