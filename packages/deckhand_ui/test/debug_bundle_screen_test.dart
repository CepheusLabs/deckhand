import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/screens/debug_bundle_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('DebugBundleScreen', () {
    testWidgets('renders the redacted preview and the stats summary',
        (tester) async {
      RedactedDocument? saved;
      var cancelled = false;
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: DebugBundleScreen(
            sessionLog:
                'Connected to 192.168.1.50; saw mac aa:bb:cc:dd:ee:ff',
            onSave: (doc) => saved = doc,
            onCancel: () => cancelled = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Review debug bundle'), findsOneWidget);
      expect(find.textContaining('<IP>'), findsWidgets);
      expect(find.textContaining('<MAC>'), findsWidgets);
      expect(find.textContaining('1 IPs'), findsOneWidget);

      // Cancel returns through the callback.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(cancelled, isTrue);
      expect(saved, isNull);
    });

    testWidgets('save passes the redacted document back', (tester) async {
      RedactedDocument? saved;
      final controller = stubWizardController(profileJson: testProfileJson());
      await controller.loadProfile('test-printer');

      await tester.pumpWidget(
        testHarness(
          controller: controller,
          child: DebugBundleScreen(
            sessionLog: 'plain',
            onSave: (doc) => saved = doc,
            onCancel: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save bundle'));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      // No redactions on plain prose.
      expect(saved!.stats.isClean, isTrue);
    });
  });
}
