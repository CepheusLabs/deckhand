import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';

/// Pure-logic predicate for whether a saved [WizardState] is worth
/// prompting the user about on next launch. An "initial" snapshot
/// (fresh app, no real progress) is not. Exposed so unit tests can
/// exercise it without a widget harness racing against real file I/O.
@visibleForTesting
bool shouldOfferResume(WizardState? snapshot) {
  if (snapshot == null) return false;
  if (snapshot.currentStep == 'welcome' && snapshot.profileId.isEmpty) {
    return false;
  }
  return true;
}

/// Maps a persisted `currentStep` id to a GoRouter path. Known-unknown
/// steps fall back to welcome rather than guessing — safer for
/// resume.
@visibleForTesting
String? routeForResumeStep(String step) {
  const routes = <String, String>{
    'welcome': '/',
    'pick-printer': '/pick-printer',
    'connect': '/connect',
    'verify': '/verify',
    'choose-path': '/choose-path',
    'choose-os': '/choose-os',
    'flash-target': '/flash-target',
    'flash-confirm': '/flash-confirm',
    'first-boot': '/first-boot',
    'first-boot-setup': '/first-boot-setup',
    'firmware': '/firmware',
    'services': '/services',
    'files': '/files',
    'webui': '/webui',
    'screen-choice': '/screen-choice',
    'kiauh': '/kiauh',
    'hardening': '/hardening',
    'review': '/review',
    'progress': '/progress',
    'done': '/done',
  };
  return routes[step];
}

/// Offers to resume a prior session the first time the app mounts.
///
/// Reads the [WizardStateStore] once; if it found a snapshot past the
/// welcome screen, it prompts the user with "Resume where you left
/// off?" or "Start fresh". Pick-up always re-runs probes (the saved
/// state doesn't include secrets or live SSH session state), so the
/// wizard can never jump past an authentication gate.
///
/// This widget is meant to sit as the root of [WizardShell] so its
/// logic runs once at launch regardless of later navigation.
class ResumeGate extends ConsumerStatefulWidget {
  const ResumeGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ResumeGate> createState() => _ResumeGateState();
}

class _ResumeGateState extends ConsumerState<ResumeGate> {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOfferResume());
  }

  Future<void> _maybeOfferResume() async {
    if (_checked) return;
    _checked = true;
    final store = ref.read(wizardStateStoreProvider);
    if (store == null) return;

    final loaded = await store.load();
    if (!shouldOfferResume(loaded)) return;
    final snapshot = loaded!;
    if (!mounted) return;

    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.restore_outlined),
        title: const Text('Resume previous session?'),
        content: Text(
          'Deckhand found a wizard session in progress for '
          '${snapshot.profileId.isEmpty ? "a printer" : "\"${snapshot.profileId}\""}. '
          'Resuming picks up where you left off; probes of the printer '
          'will re-run so nothing happens without you confirming.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Start fresh'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Resume'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (resume == true) {
      try {
        await ref.read(wizardControllerProvider).restore(snapshot);
      } on ResumeFailedException catch (e) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.error_outline),
            title: const Text("Couldn't restore the previous session"),
            content: Text(
              'Deckhand saved your progress on '
              '"${e.snapshot.profileId}", but the profile could not '
              'be reloaded:\n\n${e.cause}\n\n'
              'You can retry from the Pick Printer screen, or start '
              'fresh; the snapshot is kept on disk so a later launch '
              'can try again.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }
      if (!mounted) return;
      final target = routeForResumeStep(snapshot.currentStep);
      if (target != null) {
        context.go(target);
      }
    } else {
      try {
        await store.clear();
      } on FileSystemException {
        // Best-effort: a locked snapshot file means the user will be
        // re-prompted next launch. Not worth surfacing to the user.
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
