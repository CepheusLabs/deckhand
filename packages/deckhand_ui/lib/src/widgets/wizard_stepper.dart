import 'package:flutter/material.dart';

/// A horizontal breadcrumb-style progress indicator at the top of every
/// wizard screen. Completed steps are clickable; the current step is
/// highlighted; future steps are greyed out.
class WizardStepper extends StatelessWidget {
  const WizardStepper({
    super.key,
    required this.steps,
    required this.currentIndex,
    required this.onStepTap,
  });

  final List<WizardStepperItem> steps;
  final int currentIndex;
  final void Function(int index) onStepTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              _StepDot(
                label: steps[i].label,
                state: _stateFor(i),
                onTap: i < currentIndex ? () => onStepTap(i) : null,
              ),
              if (i < steps.length - 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.outline,
                    size: 18,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  _StepState _stateFor(int i) {
    if (i < currentIndex) return _StepState.done;
    if (i == currentIndex) return _StepState.current;
    return _StepState.future;
  }
}

class WizardStepperItem {
  const WizardStepperItem({required this.label});
  final String label;
}

enum _StepState { done, current, future }

class _StepDot extends StatelessWidget {
  const _StepDot({required this.label, required this.state, required this.onTap});
  final String label;
  final _StepState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (state) {
      _StepState.done => theme.colorScheme.primary,
      _StepState.current => theme.colorScheme.secondary,
      _StepState.future => theme.colorScheme.outline,
    };
    final textStyle = theme.textTheme.labelMedium?.copyWith(
      color: color,
      fontWeight: state == _StepState.current ? FontWeight.w700 : FontWeight.w500,
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state == _StepState.done)
              Icon(Icons.check_circle, color: color, size: 14)
            else
              CircleAvatar(radius: 4, backgroundColor: color),
            const SizedBox(width: 6),
            Text(label, style: textStyle),
          ],
        ),
      ),
    );
  }
}
