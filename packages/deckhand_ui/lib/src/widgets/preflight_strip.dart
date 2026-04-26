import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Tiny status row for S10-welcome that runs `doctor.run` once on
/// screen entry and shows a single-line summary with a "View report"
/// expander on tap. See [docs/DOCTOR.md] for the check catalog.
///
/// The strip never blocks navigation. Failures are loud
/// (red icon + count) but the wizard's primary "Start" action stays
/// enabled — the destructive flows have their own preconditions and
/// gate independently. The strip's job is to surface "the boring
/// failures" (helper missing, dir not writable, pkexec absent) before
/// the user has invested 20 minutes.
class PreflightStrip extends ConsumerStatefulWidget {
  const PreflightStrip({super.key});

  @override
  ConsumerState<PreflightStrip> createState() => _PreflightStripState();
}

class _PreflightStripState extends ConsumerState<PreflightStrip> {
  Future<DoctorReport>? _future;

  @override
  void initState() {
    super.initState();
    _runOnce();
  }

  void _runOnce() {
    _future = ref.read(doctorServiceProvider).run();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DoctorReport>(
      future: _future,
      builder: (context, snap) {
        final theme = Theme.of(context);
        if (snap.connectionState != ConnectionState.done) {
          return _Row(
            icon: const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: 'Preflight: running…',
            color: theme.colorScheme.onSurfaceVariant,
          );
        }
        if (snap.hasError) {
          // Sidecar refused to respond. The app's startup gate
          // already would have caught a hard failure; this branch
          // covers a transient hiccup mid-session. Show but don't
          // panic.
          return _Row(
            icon: Icon(Icons.help_outline,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            label: 'Preflight: unavailable (${snap.error})',
            color: theme.colorScheme.onSurfaceVariant,
            onRetry: () => setState(_runOnce),
          );
        }
        final report = snap.data!;
        if (report.passed && report.warnings.isEmpty) {
          return _Row(
            icon: Icon(Icons.check_circle_outline,
                size: 18, color: theme.colorScheme.primary),
            label: 'Preflight: ready',
            color: theme.colorScheme.primary,
            onViewReport: () => _showReport(context, report),
          );
        }
        if (report.passed) {
          // No FAILs, but at least one WARN. Yellow but unbloocking.
          final n = report.warnings.length;
          return _Row(
            icon: const Icon(Icons.info_outline, size: 18, color: Colors.orange),
            label: 'Preflight: ready ($n warning${n == 1 ? '' : 's'})',
            color: Colors.orange,
            onViewReport: () => _showReport(context, report),
          );
        }
        final n = report.failures.length;
        return _Row(
          icon: Icon(Icons.error_outline,
              size: 18, color: theme.colorScheme.error),
          label: 'Preflight: $n issue${n == 1 ? '' : 's'} — '
              '${report.failures.first.name}',
          color: theme.colorScheme.error,
          onViewReport: () => _showReport(context, report),
          onRetry: () => setState(_runOnce),
        );
      },
    );
  }

  void _showReport(BuildContext context, DoctorReport report) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 600),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Preflight report',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      report.report,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
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

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.color,
    this.onViewReport,
    this.onRetry,
  });

  final Widget icon;
  final String label;
  final Color color;
  final VoidCallback? onViewReport;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color),
            ),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          if (onViewReport != null)
            TextButton(
                onPressed: onViewReport, child: const Text('View report')),
        ],
      ),
    );
  }
}
