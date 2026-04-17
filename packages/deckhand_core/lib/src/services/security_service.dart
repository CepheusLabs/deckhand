/// Confirmation tokens for destructive operations, host allow-list
/// management, and known-host fingerprints.
abstract class SecurityService {
  /// Issue a single-use token for [operation] targeting [target].
  /// Caller passes the token back to the adapter; sidecar rejects
  /// expired or reused tokens.
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  });

  /// Batch-prompt the user to allow-list [hosts] before any network
  /// traffic reaches them.
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts);

  /// Returns true if [host] is already in the allow-list.
  Future<bool> isHostAllowed(String host);

  /// Persist [fingerprint] for [host]. Called on first successful SSH
  /// connect once the user accepts the fingerprint.
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  });

  /// Returns the pinned fingerprint for [host], or null if none pinned.
  Future<String?> pinnedHostFingerprint(String host);
}

class ConfirmationToken {
  const ConfirmationToken({
    required this.value,
    required this.expiresAt,
    required this.operation,
  });
  final String value;
  final DateTime expiresAt;
  final String operation;
}
