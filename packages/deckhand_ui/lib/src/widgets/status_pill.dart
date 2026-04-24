import 'package:flutter/material.dart';

/// Small rounded label used across the wizard to indicate state
/// (service running, screen installed, profile status, etc.).
///
/// Consolidates five near-identical private implementations that
/// previously lived in connect_screen, pick_printer_screen,
/// screen_choice_screen (twice), services_screen, and webui_screen.
/// Each variation boiled down to the same `Container(decoration:
/// BoxDecoration(...), child: Text)` shape; the only real axis of
/// variation was whether a border was drawn and how the color was
/// chosen.
///
/// Factories:
///   * [StatusPill.new] - explicit color, no border.
///   * [StatusPill.bordered] - explicit color with a faint border.
///   * [StatusPill.fromKlippyState] - ready/printing/etc mapped to
///     semantic theme colors; adds a Semantics label.
///   * [StatusPill.fromProfileStatus] - stable/beta/alpha/etc mapped
///     to semantic theme colors.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.bordered = false,
    this.semanticsLabel,
  });

  /// Same shape as [StatusPill.new] but with a faint outline.
  const StatusPill.bordered({
    super.key,
    required this.label,
    required this.color,
    this.semanticsLabel,
  }) : bordered = true;

  /// Maps a Klipper/Klippy state string (ready, printing, startup,
  /// error, etc.) to a semantic theme color. Used on the connect
  /// screen to tint each discovered printer card's state chip.
  factory StatusPill.fromKlippyState(
    BuildContext context,
    String state,
  ) {
    final theme = Theme.of(context);
    final normalized = state.toLowerCase();
    final color = switch (normalized) {
      'ready' || 'printing' => theme.colorScheme.tertiary,
      'startup' || 'shutdown' => theme.colorScheme.secondary,
      'error' || 'disconnected' => theme.colorScheme.error,
      _ => theme.colorScheme.outline,
    };
    return StatusPill(
      label: normalized,
      color: color,
      semanticsLabel: 'Klipper state $normalized',
    );
  }

  /// Maps a profile `status` field (stable/beta/alpha/experimental/
  /// deprecated) to a semantic theme color. Used on pick_printer and
  /// screen_choice to tint the status badge on each card.
  factory StatusPill.fromProfileStatus(
    BuildContext context,
    String status,
  ) {
    final theme = Theme.of(context);
    final color = switch (status) {
      'stable' => theme.colorScheme.tertiary,
      'beta' => theme.colorScheme.secondary,
      'alpha' => theme.colorScheme.primary,
      'experimental' || 'deprecated' => theme.colorScheme.error,
      _ => theme.colorScheme.outline,
    };
    return StatusPill(label: status, color: color);
  }

  final String label;
  final Color color;
  final bool bordered;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pill = Container(
      padding: bordered
          ? const EdgeInsets.symmetric(horizontal: 6, vertical: 1)
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: bordered ? 0.18 : 0.15),
        borderRadius: BorderRadius.circular(bordered ? 8 : 10),
        border: bordered
            ? Border.all(color: color.withValues(alpha: 0.4), width: 0.5)
            : null,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (semanticsLabel != null) {
      return Semantics(label: semanticsLabel, child: pill);
    }
    return pill;
  }
}
