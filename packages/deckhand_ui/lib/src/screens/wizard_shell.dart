import 'package:flutter/material.dart';

import '../router.dart';
import '../theming/deckhand_theme.dart';
import '../widgets/resume_gate.dart';

/// Top-level widget for the Deckhand desktop app. Wires GoRouter +
/// Material 3 theme. The bootstrapper (app/lib/main.dart) wraps this
/// in a [ProviderScope] with the concrete service implementations.
///
/// [ResumeGate] runs once after the first frame and offers to restore
/// a prior wizard session if the on-disk snapshot has progressed past
/// the welcome screen.
class WizardShell extends StatelessWidget {
  const WizardShell({super.key});

  @override
  Widget build(BuildContext context) {
    final router = buildDeckhandRouter();
    return MaterialApp.router(
      title: 'Deckhand',
      theme: DeckhandTheme.light(),
      darkTheme: DeckhandTheme.dark(),
      routerConfig: router,
      builder: (context, child) => ResumeGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
