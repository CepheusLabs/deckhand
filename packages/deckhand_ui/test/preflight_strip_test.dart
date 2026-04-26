import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_ui/src/providers.dart';
import 'package:deckhand_ui/src/widgets/preflight_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreflightStrip', () {
    testWidgets('renders the ready state when every check passes',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            doctorServiceProvider.overrideWithValue(_FakeDoctor.healthy()),
          ],
          child: const MaterialApp(home: Scaffold(body: PreflightStrip())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Preflight: ready'), findsOneWidget);
      // No failure-only buttons should appear in the happy path.
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('surfaces failure count and offers Retry on FAIL', (tester) async {
      final doctor = _FakeDoctor(report: const DoctorReport(
        passed: false,
        results: [
          DoctorResult(
            name: 'elevated_helper',
            status: DoctorStatus.fail,
            detail: 'missing',
          ),
        ],
        report: '[FAIL] elevated_helper — missing\n',
      ));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [doctorServiceProvider.overrideWithValue(doctor)],
          child: const MaterialApp(home: Scaffold(body: PreflightStrip())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Preflight: 1 issue'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('View report'), findsOneWidget);
    });

    testWidgets('shows warning count when only WARNs are present', (tester) async {
      final doctor = _FakeDoctor(report: const DoctorReport(
        passed: true,
        results: [
          DoctorResult(
            name: 'github_rate_limit',
            status: DoctorStatus.warn,
            detail: 'only 2/60',
          ),
        ],
        report: '[WARN] github_rate_limit — only 2/60\n',
      ));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [doctorServiceProvider.overrideWithValue(doctor)],
          child: const MaterialApp(home: Scaffold(body: PreflightStrip())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1 warning'), findsOneWidget);
      expect(find.text('View report'), findsOneWidget);
    });

    testWidgets('opens the report dialog on View report tap', (tester) async {
      final doctor = _FakeDoctor.healthy();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [doctorServiceProvider.overrideWithValue(doctor)],
          child: const MaterialApp(home: Scaffold(body: PreflightStrip())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('View report'));
      await tester.pumpAndSettle();
      expect(find.text('Preflight report'), findsOneWidget);
    });
  });
}

class _FakeDoctor implements DoctorService {
  _FakeDoctor({required this.report});

  factory _FakeDoctor.healthy() => _FakeDoctor(report: const DoctorReport(
        passed: true,
        results: [
          DoctorResult(name: 'runtime', status: DoctorStatus.pass, detail: 'ok'),
        ],
        report: '[PASS] runtime — ok\n\nall checks passed\n',
      ));

  final DoctorReport report;

  @override
  Future<DoctorReport> run() async => report;
}
