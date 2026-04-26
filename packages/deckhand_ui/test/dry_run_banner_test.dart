import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/widgets/dry_run_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(DeckhandSettings settings) => ProviderScope(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(settings),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DryRunBanner()),
        ),
      );

  testWidgets('renders nothing when dry-run is off', (tester) async {
    final settings = DeckhandSettings(path: '<memory>');
    settings.dryRun = false;
    await tester.pumpWidget(wrap(settings));
    expect(find.byIcon(Icons.science_outlined), findsNothing);
    expect(find.textContaining('Dry-run mode'), findsNothing);
  });

  testWidgets('renders banner with warning icon when dry-run is on', (tester) async {
    final settings = DeckhandSettings(path: '<memory>');
    settings.dryRun = true;
    await tester.pumpWidget(wrap(settings));
    expect(find.byIcon(Icons.science_outlined), findsOneWidget);
    expect(find.textContaining('Dry-run mode'), findsOneWidget);
  });

  testWidgets('exposes a live-region Semantics node for screen readers', (tester) async {
    final settings = DeckhandSettings(path: '<memory>');
    settings.dryRun = true;

    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrap(settings));

    // The banner MUST be a live region so VoiceOver / TalkBack
    // announce the state change when a user toggles dry-run without
    // re-entering the wizard. Look for the semantics node by label.
    final semantics = tester.getSemantics(
      find.byType(DryRunBanner),
    );
    expect(
      semantics.label,
      contains('Dry-run mode enabled'),
      reason: 'DryRunBanner must carry a labeled live region; '
          'otherwise assistive tech will silently render the new '
          'visual banner.',
    );
    handle.dispose();
  });

  testWidgets('is tap-transparent so it does not swallow clicks below',
      (tester) async {
    final settings = DeckhandSettings(path: '<memory>');
    settings.dryRun = true;
    final taps = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(settings),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps.add('below'),
                  ),
                ),
                const Align(
                  alignment: Alignment.topCenter,
                  child: DryRunBanner(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Tap outside the banner — anywhere in the middle of the screen.
    // This proves the banner's Material/Padding stack doesn't extend
    // past its intrinsic height and steal wizard clicks.
    await tester.tapAt(const Offset(100, 400));
    expect(taps, ['below']);
  });
}
