import 'package:deckhand_core/deckhand_core.dart';

/// [DiscoveryService] backed by the bonsoir mDNS package. Stub.
class BonsoirDiscoveryService implements DiscoveryService {
  @override
  Future<List<DiscoveredPrinter>> scanMdns({Duration timeout = const Duration(seconds: 5)}) async {
    throw UnimplementedError('BonsoirDiscoveryService.scanMdns');
  }

  @override
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    throw UnimplementedError('BonsoirDiscoveryService.scanCidr');
  }

  @override
  Future<bool> waitForSsh({
    required String host,
    int port = 22,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    throw UnimplementedError('BonsoirDiscoveryService.waitForSsh');
  }
}
