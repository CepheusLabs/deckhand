import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

/// JSON-RPC 2.0 client that spawns the Go sidecar binary and talks to it
/// over newline-delimited stdin/stdout.
///
/// Supports:
///   - request/response with id correlation
///   - notifications (sidecar → UI) delivered via [notifications]
///   - per-operation notification streams via [subscribeToOperation]
///   - error responses surfaced as [SidecarError] exceptions
class SidecarClient {
  SidecarClient({required this.binaryPath});

  final String binaryPath;

  final _uuid = const Uuid();
  Process? _process;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _notificationsController =
      StreamController<SidecarNotification>.broadcast();
  final _operationSubscribers =
      <String, StreamController<SidecarNotification>>{};
  StreamSubscription<String>? _stdoutSub;
  bool _started = false;

  /// All notifications from the sidecar. Each one carries an
  /// `operation_id` that correlates it to the request that spawned it.
  Stream<SidecarNotification> get notifications =>
      _notificationsController.stream;

  /// Start the sidecar process. Call once before making any calls.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _process = await Process.start(
      binaryPath,
      const [],
      mode: ProcessStartMode.normal,
      runInShell: false,
    );

    _stdoutSub = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (e, st) {
            _failAll(e.toString());
          },
          onDone: _onProcessDone,
        );

    // stderr → consume so the pipe doesn't fill; one-shot listener that
    // forwards to the current process for debugging.
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          // ignore: avoid_print
          print('[sidecar] $line');
        });

    // Smoke test that the process responded. Timeout after 5s.
    await call('ping', const {}).timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        throw SidecarError(
          code: -1,
          message: 'Sidecar did not respond to ping within 5s',
        );
      },
    );
  }

  /// Make a JSON-RPC call and await the response.
  Future<Map<String, dynamic>> call(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (!_started) {
      throw StateError('SidecarClient not started');
    }
    final id = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final msg = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    _process!.stdin.writeln(msg);
    await _process!.stdin.flush();
    return completer.future;
  }

  /// Subscribe to progress notifications for a specific operation. The
  /// returned stream closes when the matching request completes.
  Stream<SidecarNotification> subscribeToOperation(String operationId) {
    final c = _operationSubscribers.putIfAbsent(
      operationId,
      () => StreamController<SidecarNotification>.broadcast(),
    );
    return c.stream;
  }

  /// Convenience: issue a call whose progress updates you want to stream
  /// as [SidecarNotification]s along with the final response.
  ///
  /// Returns a stream that emits notifications then completes with a
  /// single [SidecarResult] event (or errors with [SidecarError]).
  Stream<SidecarEvent> callStreaming(
    String method,
    Map<String, dynamic> params,
  ) {
    final id = _uuid.v4();
    final controller = StreamController<SidecarEvent>();
    final opSub = _operationSubscribers.putIfAbsent(
      id,
      () => StreamController<SidecarNotification>.broadcast(),
    );
    opSub.stream.listen((n) => controller.add(SidecarProgress(n)));

    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final msg = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    _process!.stdin.writeln(msg);
    _process!.stdin.flush();

    completer.future
        .then((res) {
          controller.add(SidecarResult(res));
          controller.close();
          opSub.close();
          _operationSubscribers.remove(id);
        })
        .catchError((e, st) {
          controller.addError(e, st);
          controller.close();
          opSub.close();
          _operationSubscribers.remove(id);
        });
    return controller.stream;
  }

  /// Cleanly shut the sidecar down.
  Future<void> shutdown() async {
    if (_process == null) return;
    try {
      await call('shutdown', const {}).timeout(const Duration(seconds: 2));
    } catch (_) {
      // ignore - we're shutting down anyway
    }
    _process?.kill();
    await _stdoutSub?.cancel();
    await _notificationsController.close();
    for (final c in _operationSubscribers.values) {
      await c.close();
    }
    _operationSubscribers.clear();
    _process = null;
    _started = false;
  }

  // -----------------------------------------------------------------

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return; // malformed line, ignore
    }

    // Notification (no id)
    if (!obj.containsKey('id')) {
      final params =
          (obj['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      final opId = params['operation_id'] as String?;
      final note = SidecarNotification(
        method: obj['method'] as String? ?? '',
        params: params,
        operationId: opId,
      );
      _notificationsController.add(note);
      if (opId != null) {
        _operationSubscribers[opId]?.add(note);
      }
      return;
    }

    // Response with id
    final id = obj['id'].toString();
    final completer = _pending.remove(id);
    if (completer == null) return;

    if (obj.containsKey('error')) {
      final err = (obj['error'] as Map).cast<String, dynamic>();
      completer.completeError(
        SidecarError(
          code: (err['code'] as num).toInt(),
          message: err['message'] as String? ?? '',
          data: err['data'],
        ),
      );
    } else {
      final result = obj['result'];
      completer.complete(
        result is Map<String, dynamic> ? result : {'value': result},
      );
    }
  }

  void _onProcessDone() {
    _failAll('sidecar process exited');
  }

  void _failAll(String msg) {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(SidecarError(code: -1, message: msg));
      }
    }
    _pending.clear();
  }
}

/// A notification emitted by the sidecar (no response expected).
class SidecarNotification {
  const SidecarNotification({
    required this.method,
    required this.params,
    this.operationId,
  });
  final String method;
  final Map<String, dynamic> params;
  final String? operationId;
}

/// Error shape for failed JSON-RPC calls.
class SidecarError implements Exception {
  const SidecarError({required this.code, required this.message, this.data});
  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'SidecarError($code): $message';
}

/// Event kinds emitted by [SidecarClient.callStreaming].
sealed class SidecarEvent {
  const SidecarEvent();
}

class SidecarProgress extends SidecarEvent {
  const SidecarProgress(this.notification);
  final SidecarNotification notification;
}

class SidecarResult extends SidecarEvent {
  const SidecarResult(this.result);
  final Map<String, dynamic> result;
}
