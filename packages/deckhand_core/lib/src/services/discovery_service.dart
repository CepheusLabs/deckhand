/// Find printers on the LAN (mDNS) and verify reachability.
abstract class DiscoveryService {
  /// mDNS scan for Moonraker services (`_moonraker._tcp.local`).
  Future<List<DiscoveredPrinter>> scanMdns({Duration timeout = const Duration(seconds: 5)});

  /// Optional: plain TCP sweep over a CIDR for Moonraker's port.
  Future<List<DiscoveredPrinter>> scanCidr({
    required String cidr,
    int port = 7125,
    Duration timeout = const Duration(seconds: 5),
  });

  /// Polls until SSH is reachable at [host]:[port], or timeout.
  Future<bool> waitForSsh({
    required String host,
    int port = 22,
    Duration timeout = const Duration(minutes: 10),
  });
}

class DiscoveredPrinter {
  const DiscoveredPrinter({
    required this.host,
    required this.hostname,
    required this.port,
    required this.service,
  });
  final String host;
  final String hostname;
  final int port;
  final String service;
}
