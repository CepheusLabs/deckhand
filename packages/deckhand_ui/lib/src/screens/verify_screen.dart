import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/profile_text.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class VerifyScreen extends ConsumerWidget {
  const VerifyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.watch(wizardControllerProvider);
    final profile = controller.profile;
    final detections = profile?.stockOs.detections ?? const [];

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Does this look like your printer?',
      helperText:
          'A few quick sanity checks so we can confirm the profile you '
          'picked matches what\'s actually on this machine. Required '
          'checks need to match for the flow to work. Optional ones are '
          'hints that we\'re talking to the right kind of printer.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (detections.isEmpty)
            const Text('No detection rules declared for this profile.')
          else
            for (final d in detections)
              Card(
                child: ListTile(
                  leading: Icon(
                    d.required
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    color: d.required
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(_title(d.kind, d.raw, profile?.manufacturer)),
                  subtitle: Text(_explain(d.kind, d.raw, d.required)),
                  isThreeLine: true,
                ),
              ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Looks right, continue',
        onPressed: () => context.go('/choose-path'),
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/connect')),
      ],
    );
  }

  /// Human-facing title for a detection. Prefers the profile author's
  /// custom `label` field if present, otherwise falls back to a generic
  /// sentence keyed by detection `kind`.
  String _title(String kind, Map<String, dynamic> raw, String? vendor) {
    final custom = raw['label'] as String?;
    if (custom != null && custom.trim().isNotEmpty) return custom.trim();

    switch (kind) {
      case 'file_exists':
        return 'A vendor file we expect to see is present';
      case 'file_contains':
        final pattern = raw['pattern'] as String? ?? '';
        return pattern.isEmpty
            ? 'A file contains an expected marker'
            : 'A file mentions "$pattern"';
      case 'process_running':
        final name = raw['name'] as String? ?? '';
        return name.isEmpty
            ? '${vendor ?? "Vendor"} service is running'
            : '"$name" is running';
      case 'process_pattern':
        return 'A vendor process is running';
      default:
        return 'Custom check';
    }
  }

  /// Secondary line - the "how we check it" detail plus any note from
  /// the profile, kept out of the title so non-technical users aren\'t
  /// confronted with a filesystem path first.
  String _explain(String kind, Map<String, dynamic> raw, bool required) {
    final note = flattenProfileText(raw['note'] as String?);
    final label = required ? 'Needs to be present' : 'Optional hint';
    final detail = switch (kind) {
      'file_exists' => 'Checks: ${raw['path']}',
      'file_contains' =>
        'Checks: ${raw['path']} contains "${raw['pattern']}"',
      'process_running' => 'Checks: process "${raw['name']}"',
      _ => raw.toString(),
    };
    return [
      '$label - $detail',
      if (note.isNotEmpty) note,
    ].join('\n');
  }
}
