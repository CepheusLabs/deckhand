import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:deckhand_ui/deckhand_ui.dart';

void main() {
  runApp(const ProviderScope(child: DeckhandApp()));
}

class DeckhandApp extends StatelessWidget {
  const DeckhandApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Deckhand',
      theme: DeckhandTheme.light(),
      darkTheme: DeckhandTheme.dark(),
      home: const WizardShell(),
    );
  }
}
