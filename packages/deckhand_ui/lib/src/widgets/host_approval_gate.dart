import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Bridges [HostNotApprovedException] from the service layer to a
/// user-visible "Allow this host?" dialog. Wizard screens call
/// [HostApprovalGate.runGuarded] around any code that might trigger
/// an outbound network call; the helper catches the typed exception,
/// shows the prompt, persists the decision via
/// [SecurityService.approveHost], and re-runs the action — so a
/// freshly-installed Deckhand still walks the user smoothly through
/// "yes, talk to GitHub" rather than dead-ending on the first fetch.
///
/// Refusal ("Cancel") is sticky for the lifetime of the call: the
/// retry doesn't fire, and the original [HostNotApprovedException]
/// propagates so the calling screen can render its own error UX.
class HostApprovalGate {
  HostApprovalGate._();

  /// Run [action]. If it throws [HostNotApprovedException], prompt the
  /// user via [BuildContext]; on approval, persist + retry once. Any
  /// further [HostNotApprovedException] is rethrown so the caller can
  /// surface the failure (the retry only forgives the *first* miss).
  static Future<T> runGuarded<T>(
    WidgetRef ref,
    BuildContext context, {
    required Future<T> Function() action,
  }) async {
    try {
      return await action();
    } on HostNotApprovedException catch (e) {
      if (!context.mounted) rethrow;
      final approved = await _promptApproval(context, e.host);
      if (!approved) rethrow;
      await ref.read(securityServiceProvider).approveHost(e.host);
      return action();
    }
  }

  static Future<bool> _promptApproval(BuildContext context, String host) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.public),
        title: const Text('Allow network access?'),
        content: Text(
          'Deckhand wants to contact "$host" to fetch profiles or '
          'firmware. Allow this host? You can revoke this later '
          'from Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
