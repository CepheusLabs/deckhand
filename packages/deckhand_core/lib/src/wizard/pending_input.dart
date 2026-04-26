import 'dart:async';

import 'wizard_events.dart';

/// Tiny helper that wires an `await user input` step inside the
/// wizard controller to a UI-driven `resolveUserInput` callback.
///
/// Lives in its own class so the controller doesn't have to expose
/// the underlying map: callers go through `await(emit, stepId, ...)`
/// to register a wait, and `resolve(stepId, value)` to complete it.
/// `clear()` cancels every outstanding wait — the controller calls
/// it from `dispose()` so a Stream consumer cancellation cleans up
/// the completers properly.
class PendingInputRegistry {
  final _pending = <String, Completer<Object?>>{};

  /// Register a wait keyed by [stepId]. The wizard runs through the
  /// returned future at the next step; the UI must call
  /// [resolve] (or the controller's `resolveUserInput` shim) when
  /// it has a decision. Concurrent waits with the same id replace
  /// each other; the previous completer is closed with null so the
  /// step that registered it doesn't leak.
  Future<Object?> awaitInput(
    String stepId,
    Map<String, dynamic> step,
    void Function(WizardEvent) emit,
  ) {
    final existing = _pending[stepId];
    if (existing != null && !existing.isCompleted) {
      existing.complete(null);
    }
    final completer = Completer<Object?>();
    _pending[stepId] = completer;
    emit(UserInputRequired(stepId: stepId, step: step));
    return completer.future;
  }

  /// Resolve an outstanding wait. No-op if no wait is registered for
  /// [stepId] — the UI may resolve faster than the controller can
  /// register, in which case the next [awaitInput] picks up
  /// immediately.
  void resolve(String stepId, Object? value) {
    final completer = _pending.remove(stepId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(value);
    }
  }

  /// True iff a wait is currently registered for [stepId]. Visible
  /// to tests so they can assert the wizard is paused as expected.
  bool isWaiting(String stepId) => _pending.containsKey(stepId);

  /// Cancel every outstanding wait. Each waiter resolves to null —
  /// the controller treats that as "user dismissed" so the step
  /// fails cleanly rather than hanging the dispose() chain.
  void clear() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
  }
}
