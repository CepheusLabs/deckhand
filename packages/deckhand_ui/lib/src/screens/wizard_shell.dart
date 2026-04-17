import 'package:flutter/material.dart';

/// Top-level wizard container — renders the progress stepper along the
/// top and hosts the current screen. Screen-by-screen implementations
/// land in follow-up commits.
class WizardShell extends StatelessWidget {
  const WizardShell({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Deckhand')),
      body: const Center(
        child: Text('Wizard scaffold — screens land in follow-up work.'),
      ),
    );
  }
}
