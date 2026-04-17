import 'package:flutter/material.dart';

import '../router.dart';
import '../theming/deckhand_theme.dart';

/// Top-level widget for the Deckhand desktop app. Wires GoRouter +
/// Material 3 theme. The bootstrapper (app/lib/main.dart) wraps this in
/// a [ProviderScope] with the concrete service implementations.
class WizardShell extends StatelessWidget {
  const WizardShell({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Deckhand',
      theme: DeckhandTheme.light(),
      darkTheme: DeckhandTheme.dark(),
      routerConfig: buildDeckhandRouter(),
    );
  }
}
