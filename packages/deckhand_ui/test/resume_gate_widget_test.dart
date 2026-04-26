import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/widgets/resume_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget-level tests for the actual `ResumeGate` flow — dialog
/// rendering, "Start fresh" → snapshot cleared, no-dialog paths.
///
/// Uses [InMemoryWizardStateStore] so load/save resolve on a
/// microtask instead of racing real `File` I/O against the
/// simulated frame clock. The pure-logic predicate tests live next
/// door (`resume_gate_test.dart`); these exercise the widget glue.
void main() {
  late InMemoryWizardStateStore store;

  setUp(() {
    store = InMemoryWizardStateStore();
  });

  Widget buildApp() {
    return ProviderScope(
      overrides: [
        deckhandSettingsProvider.overrideWithValue(
          DeckhandSettings(path: '<memory>'),
        ),
        wizardStateStoreProvider.overrideWithValue(store),
      ],
      child: const MaterialApp(
        home: ResumeGate(
          child: Scaffold(body: Center(child: Text('home'))),
        ),
      ),
    );
  }

  // Drives the post-frame callback to completion. Two pumps (initial
  // + 250ms for the dialog entry animation) is enough because the
  // store resolves synchronously.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('dialog appears for a mid-wizard snapshot', (tester) async {
    await store.save(const WizardState(
      profileId: 'sovol-zero',
      decisions: {'firmware': 'kalico'},
      currentStep: 'verify',
      flow: WizardFlow.stockKeep,
    ));

    await tester.pumpWidget(buildApp());
    await drain(tester);

    expect(find.text('Resume previous session?'), findsOneWidget);
    expect(find.textContaining('sovol-zero'), findsOneWidget);

    // Dismiss the dialog so the pending showDialog Future inside
    // _maybeOfferResume resolves and the test can return cleanly.
    await tester.tap(find.text('Start fresh'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('Start fresh clears the snapshot from disk', (tester) async {
    await store.save(const WizardState(
      profileId: 'sovol-zero',
      decisions: {},
      currentStep: 'verify',
      flow: WizardFlow.stockKeep,
    ));

    await tester.pumpWidget(buildApp());
    await drain(tester);
    await tester.tap(find.text('Start fresh'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(await store.load(), isNull,
        reason: 'Start fresh must wipe the on-disk snapshot.');
  });

  testWidgets('null store → no dialog at all', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(
            DeckhandSettings(path: '<memory>'),
          ),
          wizardStateStoreProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(
          home: ResumeGate(
            child: Scaffold(body: Center(child: Text('home'))),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Resume previous session?'), findsNothing);
  });

  testWidgets('initial snapshot → no dialog (welcome + empty profileId)',
      (tester) async {
    await store.save(WizardState.initial());
    await tester.pumpWidget(buildApp());
    await drain(tester);
    expect(find.text('Resume previous session?'), findsNothing);
  });
}
