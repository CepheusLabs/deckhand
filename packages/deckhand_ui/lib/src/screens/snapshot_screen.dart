import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

/// S145-snapshot — capture the user's hand-edited config before Flow A
/// rewrites it. See docs/WIZARD-FLOW.md (S145-snapshot) for the spec.
///
/// The screen runs in two phases:
///   1. Pre-probe: every snapshot path declared by the profile is shown
///      with its checkbox. While the probe runs we display a loader
///      next to the size column instead of "0 B" so the user doesn't
///      misread "doesn't exist" for "we haven't checked yet."
///   2. Probed: each path's checkbox shows a size estimate; missing
///      paths are dimmed with "(not found on this printer)".
///
/// Defaults follow the profile's `default_selected` flag — true for
/// load-bearing config dirs, false for chunky things like Moonraker
/// history. The user can opt out of any path; the post-install
/// restore step uses the same selection.
class SnapshotScreen extends ConsumerStatefulWidget {
  const SnapshotScreen({super.key});

  @override
  ConsumerState<SnapshotScreen> createState() => _SnapshotScreenState();
}

class _SnapshotScreenState extends ConsumerState<SnapshotScreen> {
  final _selected = <String>{};
  bool _seeded = false;
  bool _probing = true;
  Map<String, int> _sizes = const {};
  Object? _probeError;
  String _restoreStrategy = 'side_by_side';

  @override
  void initState() {
    super.initState();
    // Defer the probe to a post-frame callback so the screen renders
    // immediately and the spinner is visible while the SSH round-trip
    // is in flight.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runProbe());
  }

  Future<void> _runProbe() async {
    final controller = ref.read(wizardControllerProvider);
    final paths = controller.profile?.stockOs.snapshotPaths ?? const [];
    if (paths.isEmpty) {
      setState(() => _probing = false);
      return;
    }
    final session = controller.sshSession;
    if (session == null) {
      setState(() {
        _probing = false;
        _probeError = StateError(
          'no SSH session — connect to the printer before reaching '
          'this screen',
        );
      });
      return;
    }
    try {
      final ssh = ref.read(sshServiceProvider);
      final sizes = await ssh.duPaths(session, paths.map((p) => p.path).toList());
      if (!mounted) return;
      setState(() {
        _probing = false;
        _sizes = sizes;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _probing = false;
        _probeError = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(wizardControllerProvider);
    final paths = controller.profile?.stockOs.snapshotPaths ?? const [];
    if (!_seeded) {
      for (final p in paths) {
        if (p.defaultSelected) _selected.add(p.id);
      }
      _seeded = true;
    }
    final selectedSize = _selected.fold<int>(
      0,
      (sum, id) {
        final p = paths.firstWhere(
          (e) => e.id == id,
          orElse: () => const StockSnapshotPath(
            id: '',
            displayName: '',
            path: '',
            defaultSelected: false,
          ),
        );
        return sum + (_sizes[p.path] ?? 0);
      },
    );

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Save your current configuration',
      helperText:
          'Before we install Klipper from upstream, we\'ll archive '
          'these directories. They\'ll be restored side-by-side after '
          'install so you can pull any tweaks you want to keep.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (paths.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'This profile doesn\'t declare any snapshot paths. '
                  'Continue if you have nothing custom to preserve, '
                  'or back out and use the Manage view\'s Backup tab '
                  'for a full eMMC dump.',
                ),
              ),
            ),
          for (final p in paths) _SnapshotRow(
            path: p,
            selected: _selected.contains(p.id),
            sizeBytes: _sizes[p.path],
            probing: _probing,
            missing: !_probing && _sizes[p.path] == 0 && _probeError == null,
            onToggle: (v) => setState(() {
              if (v) {
                _selected.add(p.id);
              } else {
                _selected.remove(p.id);
              }
            }),
          ),
          if (_probeError != null) ...[
            const SizedBox(height: 12),
            Text(
              'Could not probe sizes: $_probeError',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Selected: ${_humanBytes(selectedSize)}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Restore strategy',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  RadioGroup<String>(
                    groupValue: _restoreStrategy,
                    onChanged: (v) =>
                        setState(() => _restoreStrategy = v ?? 'side_by_side'),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RadioListTile<String>(
                          value: 'side_by_side',
                          title: Text('Side-by-side'),
                          subtitle: Text(
                            'Archive is unpacked next to the new install. '
                            'You decide what to merge.',
                          ),
                        ),
                        RadioListTile<String>(
                          value: 'auto_merge',
                          title: Text('Auto-merge non-conflicting files'),
                          subtitle: Text(
                            'Files not present in the new install are '
                            'copied in directly; conflicts go to '
                            'side-by-side for manual review.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Snapshot and continue',
        onPressed: _probing
            ? null
            : () {
                // Persist the user's choices before we leave. The
                // controller stores them under profile-stable decision
                // keys so a later jump-back still finds them.
                final c = ref.read(wizardControllerProvider);
                unawaited(c.setDecision('snapshot.paths', _selected.toList()));
                unawaited(
                  c.setDecision('snapshot.restore_strategy', _restoreStrategy),
                );
                context.go('/hardening');
              },
      ),
      secondaryActions: [
        WizardAction(
          label: 'Back',
          isBack: true,
          onPressed: () => context.go('/files'),
        ),
      ],
    );
  }
}

class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({
    required this.path,
    required this.selected,
    required this.probing,
    required this.missing,
    required this.onToggle,
    this.sizeBytes,
  });

  final StockSnapshotPath path;
  final bool selected;
  final bool probing;
  final bool missing;
  final int? sizeBytes;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = missing;
    return CheckboxListTile(
      value: selected && !disabled,
      onChanged: disabled ? null : (v) => onToggle(v ?? false),
      title: Text(path.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (path.helperText != null)
            Text(path.helperText!, style: theme.textTheme.bodySmall),
          Text(
            path.path,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (probing)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 6),
                  Text('measuring…', style: theme.textTheme.bodySmall),
                ],
              ),
            )
          else if (missing)
            Text(
              'not found on this printer',
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else if (sizeBytes != null)
            Text(
              _humanBytes(sizeBytes!),
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

String _humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  double v = bytes / 1024.0;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024.0;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}
