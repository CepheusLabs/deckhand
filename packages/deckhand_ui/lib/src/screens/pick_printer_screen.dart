import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../widgets/deckhand_stepper.dart';
import '../widgets/host_approval_gate.dart';
import '../widgets/status_pill.dart';
import '../widgets/wizard_scaffold.dart';

class PickPrinterScreen extends ConsumerStatefulWidget {
  const PickPrinterScreen({super.key});

  @override
  ConsumerState<PickPrinterScreen> createState() => _PickPrinterScreenState();
}

class _PickPrinterScreenState extends ConsumerState<PickPrinterScreen> {
  Future<ProfileRegistry>? _registryFuture;
  String? _selectedId;

  Future<ProfileRegistry> _fetchRegistry(BuildContext context) {
    // The fetch goes through HostApprovalGate so the network allow-
    // list prompt fires before the actual HTTP / git call. The gate
    // either approves + retries, or rethrows HostNotApprovedException
    // for the FutureBuilder to render via _ErrorBox.
    return HostApprovalGate.runGuarded<ProfileRegistry>(
      ref,
      context,
      action: () => ref.read(profileServiceProvider).fetchRegistry(),
    );
  }

  @override
  Widget build(BuildContext context) {
    _registryFuture ??= _fetchRegistry(context);
    return FutureBuilder<ProfileRegistry>(
      future: _registryFuture,
      builder: (context, snap) {
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Center(child: CircularProgressIndicator());
        } else if (snap.hasError) {
          body = _ErrorBox(
            message: 'Failed to load printer registry: ${snap.error}',
            onRetry: () => setState(() {
              _registryFuture = _fetchRegistry(context);
            }),
          );
        } else {
          final entries = snap.data!.entries
              .where((e) => e.status != 'stub')
              .toList();
          body = Wrap(
            spacing: 12,
            runSpacing: 12,
            children: entries
                .map(
                  (e) => _PrinterCard(
                    entry: e,
                    selected: _selectedId == e.id,
                    onTap: () => setState(() => _selectedId = e.id),
                  ),
                )
                .toList(),
          );
        }
        return WizardScaffold(
          stepper: const DeckhandStepper(),
          title: 'Which printer are you setting up?',
          helperText:
              'Deckhand supports these printers. Pick yours - we use that '
              'choice to load the right profile before anything else.',
          body: body,
          primaryAction: WizardAction(
            label: t.common.action_continue,
            onPressed: _selectedId == null
                ? null
                : () async {
                    final controller = ref.read(wizardControllerProvider);
                    await HostApprovalGate.runGuarded<void>(
                      ref,
                      context,
                      action: () => controller.loadProfile(_selectedId!),
                    );
                    if (context.mounted) context.go('/connect');
                  },
          ),
          secondaryActions: [
            WizardAction(label: t.common.action_back, onPressed: () => context.go('/'), isBack: true),
          ],
        );
      },
    );
  }
}

class _PrinterCard extends StatelessWidget {
  const _PrinterCard({
    required this.entry,
    required this.selected,
    required this.onTap,
  });
  final ProfileRegistryEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      width: 280,
      child: Card(
        elevation: selected ? 4 : 1,
        color: selected ? t.colorScheme.primaryContainer : null,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.manufacturer,
                  style: t.textTheme.labelLarge?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(entry.displayName, style: t.textTheme.titleLarge),
                const SizedBox(height: 8),
                StatusPill.fromProfileStatus(context, entry.status),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// _StatusChip removed; callers use widgets/status_pill.dart :: StatusPill.fromProfileStatus.

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
