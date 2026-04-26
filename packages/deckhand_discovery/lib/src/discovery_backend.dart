import 'package:deckhand_core/deckhand_core.dart';

/// Minimal service-record shape emitted by an mDNS backend.
///
/// Deliberately narrower than bonsoir's `ResolvedBonsoirService` so the
/// backend interface doesn't leak bonsoir types into the rest of the
/// app. Fakes (tests) can construct these directly without pulling a
/// bonsoir dependency.
class MdnsServiceRecord {
  const MdnsServiceRecord({
    required this.name,
    required this.type,
    required this.host,
    required this.port,
  });

  /// Service instance name (e.g. `mks-pi-123`).
  final String name;

  /// Service type (e.g. `_moonraker._tcp`).
  final String type;

  /// Resolved host - IP or DNS name, whichever the responder gave us.
  final String host;

  /// Service port.
  final int port;
}

/// Seam that owns mDNS transport. The production implementation wraps
/// bonsoir; tests supply a [FakeDiscoveryBackend] that emits canned
/// records without touching the network or mDNS stack.
abstract class DiscoveryBackend {
  /// Collect resolved mDNS records for [serviceType] until [timeout]
  /// elapses. Implementations must not throw on transport errors -
  /// return the set observed so far.
  Future<List<MdnsServiceRecord>> collectMdns({
    required String serviceType,
    required Duration timeout,
  });
}

/// Convert an [MdnsServiceRecord] to a [DiscoveredPrinter]. Pulled out
/// of the backend so the same transform is used whether records come
/// from bonsoir or a test fake.
DiscoveredPrinter printerFromMdns(MdnsServiceRecord svc) => DiscoveredPrinter(
      host: svc.host,
      hostname: svc.name,
      port: svc.port,
      service: svc.type,
    );
