import 'package:deckhand_core/deckhand_core.dart';
// ignore: implementation_imports
import 'package:deckhand_core/src/wizard/pending_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PendingInputRegistry', () {
    test('awaitInput emits UserInputRequired and resolves on resolve()',
        () async {
      final r = PendingInputRegistry();
      final emitted = <WizardEvent>[];
      final fut = r.awaitInput('step-1', const {'kind': 'choice'}, emitted.add);
      expect(emitted, hasLength(1));
      expect(emitted.first, isA<UserInputRequired>());
      expect(r.isWaiting('step-1'), isTrue);
      r.resolve('step-1', 'option-a');
      expect(await fut, 'option-a');
      expect(r.isWaiting('step-1'), isFalse);
    });

    test('resolve() before awaitInput is a no-op (no leak, no crash)', () {
      final r = PendingInputRegistry();
      r.resolve('never-registered', 'whatever');
      expect(r.isWaiting('never-registered'), isFalse);
    });

    test('clear() resolves outstanding waiters with null', () async {
      final r = PendingInputRegistry();
      final fut = r.awaitInput('s', const {}, (_) {});
      r.clear();
      expect(await fut, isNull);
      expect(r.isWaiting('s'), isFalse);
    });

    test('re-registering the same id closes the previous wait', () async {
      final r = PendingInputRegistry();
      final first = r.awaitInput('dup', const {}, (_) {});
      final second = r.awaitInput('dup', const {}, (_) {});
      // First completer must have been completed-with-null when the
      // second registration arrived.
      expect(await first, isNull);
      r.resolve('dup', 42);
      expect(await second, 42);
    });
  });
}
