import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Default [SecurityService] - in-memory single-use confirmation tokens
/// backed by flutter_secure_storage for persistent fingerprints + host
/// allow-list state.
class DefaultSecurityService implements SecurityService {
  DefaultSecurityService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final _uuid = const Uuid();
  final _tokens = <String, ConfirmationToken>{};
  final _egressController = StreamController<EgressEvent>.broadcast();

  @override
  Stream<EgressEvent> get egressEvents => _egressController.stream;

  @override
  void recordEgress(EgressEvent event) {
    if (_egressController.isClosed) return;
    _egressController.add(event);
  }

  /// Tear down the egress stream — production wiring keeps the
  /// service alive for the session, but tests and shutdown paths
  /// need a deterministic close to avoid pending-broadcast warnings.
  Future<void> dispose() async {
    if (!_egressController.isClosed) {
      await _egressController.close();
    }
  }

  @override
  Future<ConfirmationToken> issueConfirmationToken({
    required String operation,
    required String target,
    Duration ttl = const Duration(seconds: 60),
  }) async {
    final token = ConfirmationToken(
      value: _uuid.v4(),
      expiresAt: DateTime.now().add(ttl),
      operation: operation,
    );
    _tokens[token.value] = token;
    // Expire proactively so the map doesn't grow unbounded.
    Timer(ttl, () => _tokens.remove(token.value));
    return token;
  }

  /// Validate + consume a token. Returns true if the token is live;
  /// removes it so subsequent attempts fail.
  bool consumeToken(String value, String operation) {
    final t = _tokens.remove(value);
    if (t == null) return false;
    if (t.operation != operation) return false;
    if (DateTime.now().isAfter(t.expiresAt)) return false;
    return true;
  }

  @override
  Future<Map<String, bool>> requestHostApprovals(List<String> hosts) async {
    // Actual UI prompt happens in the app's router; this method only
    // records the outcome. The app layer calls [approveHost] after the
    // user accepts each one.
    final current = <String, bool>{};
    for (final h in hosts) {
      current[h] = await isHostAllowed(h);
    }
    return current;
  }

  /// Persistently allow-list [host]. Called by the UI after the user
  /// approves a network-egress prompt.
  @override
  Future<void> approveHost(String host) async {
    await _storage.write(key: _hostAllowKey(host), value: '1');
  }

  @override
  Future<void> revokeHost(String host) async {
    await _storage.delete(key: _hostAllowKey(host));
  }

  @override
  Future<bool> isHostAllowed(String host) async {
    return (await _storage.read(key: _hostAllowKey(host))) == '1';
  }

  @override
  Future<void> pinHostFingerprint({
    required String host,
    required String fingerprint,
  }) async {
    await _storage.write(key: _hostFpKey(host), value: fingerprint);
  }

  @override
  Future<String?> pinnedHostFingerprint(String host) async {
    return _storage.read(key: _hostFpKey(host));
  }

  String _hostAllowKey(String host) => 'deckhand.net.allowlist.$host';
  String _hostFpKey(String host) => 'deckhand.ssh.fp.$host';
}
