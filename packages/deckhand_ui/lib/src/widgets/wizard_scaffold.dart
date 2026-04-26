import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dry_run_banner.dart';
import 'profile_text.dart';

/// Standard layout for a wizard screen. Title + body + footer action row.
class WizardScaffold extends StatelessWidget {
  const WizardScaffold({
    super.key,
    required this.title,
    required this.body,
    this.helperText,
    this.primaryAction,
    this.secondaryActions = const [],
    this.stepper,
  });

  final String title;
  final Widget body;
  final String? helperText;
  final WizardAction? primaryAction;
  final List<WizardAction> secondaryActions;
  final Widget? stepper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keyboard shortcuts: Enter activates the primary action,
    // Esc activates the first "Back"-style secondary action.
    // Skipped entirely when neither is enabled so the shortcut
    // map doesn't swallow Enter inside a text field higher up.
    final primary = primaryAction;
    final back = _firstBackAction();
    final shortcuts = <ShortcutActivator, Intent>{
      if (primary?.onPressed != null && !primary!.destructive)
        LogicalKeySet(LogicalKeyboardKey.enter): const _ActivatePrimaryIntent(),
      if (primary?.onPressed != null && !primary!.destructive)
        LogicalKeySet(LogicalKeyboardKey.numpadEnter): const _ActivatePrimaryIntent(),
      if (back?.onPressed != null)
        LogicalKeySet(LogicalKeyboardKey.escape): const _ActivateBackIntent(),
    };
    final actions = <Type, Action<Intent>>{
      _ActivatePrimaryIntent: CallbackAction<_ActivatePrimaryIntent>(
        onInvoke: (_) {
          primary?.onPressed?.call();
          return null;
        },
      ),
      _ActivateBackIntent: CallbackAction<_ActivateBackIntent>(
        onInvoke: (_) {
          back?.onPressed?.call();
          return null;
        },
      ),
    };
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: actions,
        child: Focus(
          autofocus: true,
          child: _buildScaffold(context, theme),
        ),
      ),
    );
  }

  WizardAction? _firstBackAction() {
    // The locale-dependent label heuristic that used to live here is
    // gone. Callers must opt their back action in via `isBack: true`;
    // a localized "Zurück" or "戻る" would otherwise silently lose Esc.
    for (final a in secondaryActions) {
      if (a.isBack) return a;
    }
    return null;
  }

  Widget _buildScaffold(BuildContext context, ThemeData theme) {
    return Scaffold(
      body: Column(
        children: [
          const DryRunBanner(),
          ?stepper,
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
              // Center the content block so wide displays don't leave a
              // sea of empty space on the right. The 960px cap keeps
              // line lengths readable regardless of window size.
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: theme.textTheme.headlineMedium,
                        ),
                      ),
                      if (helperText != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          flattenProfileText(helperText),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      body,
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (primaryAction != null || secondaryActions.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Row(
                    children: [
                      for (final a in secondaryActions) ...[
                        TextButton(
                          onPressed: a.onPressed,
                          child: Text(a.label),
                        ),
                        const SizedBox(width: 8),
                      ],
                      const Spacer(),
                      if (primaryAction != null)
                        // Destructive actions advertise themselves to
                        // assistive tech so a screen-reader user hears
                        // "flash disk, warning: destructive" before
                        // activating the button.
                        Semantics(
                          button: true,
                          enabled: primaryAction!.onPressed != null,
                          label: primaryAction!.destructive
                              ? '${primaryAction!.label}, destructive'
                              : primaryAction!.label,
                          child: ExcludeSemantics(
                            child: FilledButton(
                              onPressed: primaryAction!.onPressed,
                              style: primaryAction!.destructive
                                  ? FilledButton.styleFrom(
                                      backgroundColor: theme.colorScheme.error,
                                      foregroundColor: theme.colorScheme.onError,
                                    )
                                  : null,
                              child: Text(primaryAction!.label),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class WizardAction {
  const WizardAction({
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.isBack = false,
  });
  final String label;
  final VoidCallback? onPressed;

  /// Destructive actions refuse the Enter-key shortcut; the user must
  /// move focus + press Space or click explicitly. Matches the UI
  /// convention where "Flash disk" stays one deliberate action away
  /// from a stray keystroke.
  final bool destructive;

  /// When true, this action is the screen's "go back" affordance and
  /// Esc will fire it. Prefer this flag over heuristics on [label] —
  /// labels are localized, keyboards aren't.
  final bool isBack;
}

class _ActivatePrimaryIntent extends Intent {
  const _ActivatePrimaryIntent();
}

class _ActivateBackIntent extends Intent {
  const _ActivateBackIntent();
}
