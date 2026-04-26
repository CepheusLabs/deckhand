import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Persistent banner at the top of every wizard screen when the user
/// has dry-run mode enabled. The goal is to make it impossible to
/// forget the setting is on — especially during long flows where a
/// developer might switch tabs and come back expecting a real install.
class DryRunBanner extends ConsumerWidget {
  const DryRunBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(deckhandSettingsProvider);
    if (!settings.dryRun) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      label: 'Dry-run mode enabled. No destructive operations will be executed.',
      child: ExcludeSemantics(
        child: Material(
          color: theme.colorScheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.science_outlined,
                  size: 18,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Dry-run mode — no disk writes or remote mutations will happen.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
