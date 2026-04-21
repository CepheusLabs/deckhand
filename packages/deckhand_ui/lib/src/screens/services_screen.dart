import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/profile_text.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

/// One card per stock-OS service that declares a `wizard:` block. Each
/// card is collapsible so the whole list fits on one page and the user
/// can see at a glance what they've decided without bouncing between
/// pages. The first un-answered service is expanded by default; the
/// rest stay collapsed until the user opens them.
class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({super.key});

  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends ConsumerState<ServicesScreen> {
  final _expanded = <String>{};
  bool _seeded = false;

  List<StockService> _queue() {
    final all =
        ref.read(wizardControllerProvider).profile?.stockOs.services ??
        const [];
    return all.where((s) {
      final w = s.raw['wizard'];
      return w != null && w != 'none';
    }).toList();
  }

  void _seedDefaults() {
    if (_seeded) return;
    _seeded = true;
    final controller = ref.read(wizardControllerProvider);
    final queue = _queue();
    for (final svc in queue) {
      final key = 'service.${svc.id}';
      if (controller.decision<String>(key) == null) {
        final seeded = controller.resolveServiceDefault(svc);
        controller.setDecision(key, seeded);
      }
    }
    // Expand the first service so the user sees an example of what the
    // card looks like opened; everything else starts collapsed.
    if (queue.isNotEmpty) _expanded.add(queue.first.id);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_seeded) setState(_seedDefaults);
    });

    final controller = ref.watch(wizardControllerProvider);
    final queue = _queue();

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Stock services',
      helperText:
          'Each Phrozen service below is up to you. Click a card to see the '
          'full explanation and pick an action. Every service already has a '
          'sensible default picked based on your other choices; change what '
          'you care about and leave the rest alone.',
      body: queue.isEmpty
          ? const Text('Nothing to configure on this profile.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final svc in queue)
                  _ServiceCard(
                    service: svc,
                    currentDecision:
                        controller.decision<String>('service.${svc.id}'),
                    expanded: _expanded.contains(svc.id),
                    onExpandChange: (v) => setState(() {
                      if (v) {
                        _expanded.add(svc.id);
                      } else {
                        _expanded.remove(svc.id);
                      }
                    }),
                    onChoose: (action) {
                      controller.setDecision('service.${svc.id}', action);
                      setState(() {});
                    },
                  ),
              ],
            ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: () => context.go('/files'),
      ),
      secondaryActions: [
        WizardAction(
          label: 'Back',
          onPressed: () => context.go('/screen-choice'),
        ),
      ],
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.service,
    required this.currentDecision,
    required this.expanded,
    required this.onExpandChange,
    required this.onChoose,
  });

  final StockService service;
  final String? currentDecision;
  final bool expanded;
  final ValueChanged<bool> onExpandChange;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wiz =
        (service.raw['wizard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final options = ((wiz['options'] as List?) ?? const []).cast<Map>();
    final question = wiz['question'] as String?;
    final helper = wiz['helper_text'] as String?;

    final selectedLabel = _labelFor(options, currentDecision);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Theme(
        // Remove ExpansionTile's built-in divider lines so it sits
        // cleanly inside a Card without doubling up borders.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: expanded,
          onExpansionChanged: onExpandChange,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Text(
            service.displayName,
            style: theme.textTheme.titleMedium,
          ),
          subtitle: selectedLabel == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _DecisionChip(label: selectedLabel),
                ),
          children: [
            if (question != null) ...[
              Text(
                flattenProfileText(question),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
            ],
            if (helper != null) ...[
              Text(
                flattenProfileText(helper),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
            ],
            RadioGroup<String>(
              groupValue: currentDecision,
              onChanged: (v) {
                if (v != null) onChoose(v);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final opt in options)
                    _OptionTile(
                      id: opt['id'] as String,
                      label: opt['label'] as String? ?? opt['id'] as String,
                      description: opt['description'] as String?,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _labelFor(List<Map> options, String? id) {
    if (id == null) return null;
    for (final o in options) {
      if (o['id'] == id) return o['label'] as String? ?? id;
    }
    return id;
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.id,
    required this.label,
    this.description,
  });

  final String id;
  final String label;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final desc = description == null ? null : flattenProfileText(description);
    return RadioListTile<String>(
      value: id,
      title: Text(label),
      subtitle: desc == null || desc.isEmpty ? null : Text(desc),
      isThreeLine: desc != null && desc.length > 60,
      contentPadding: EdgeInsets.zero,
    );
  }
}

class _DecisionChip extends StatelessWidget {
  const _DecisionChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
