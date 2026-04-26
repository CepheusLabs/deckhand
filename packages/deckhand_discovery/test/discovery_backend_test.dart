import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_discovery/src/discovery_backend.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory [DiscoveryBackend] that returns whatever records the test
/// seeded. No mDNS stack, no sockets - pure Dart.
class _FakeBackend implements DiscoveryBackend {
  _FakeBackend(this.records);
  final List<MdnsServiceRecord> records;

  @override
  Future<List<MdnsServiceRecord>> collectMdns({
    required String serviceType,
    required Duration timeout,
  }) async {
    // Filter by serviceType so a test that seeds mixed records can
    // verify the backend API narrows correctly.
    return records.where((r) => r.type == serviceType).toList();
  }
}

void main() {
  group('printerFromMdns', () {
    test('maps every mDNS field onto the corresponding DiscoveredPrinter '
        'field', () {
      const svc = MdnsServiceRecord(
        name: 'mks-pi-abc',
        type: '_moonraker._tcp',
        host: '192.168.1.42',
        port: 7125,
      );
      final p = printerFromMdns(svc);
      expect(p, isA<DiscoveredPrinter>());
      expect(p.host, '192.168.1.42');
      expect(p.hostname, 'mks-pi-abc');
      expect(p.port, 7125);
      expect(p.service, '_moonraker._tcp');
    });

    test('preserves unusual ports and non-IP hosts', () {
      // mDNS resolvers sometimes hand back a .local hostname instead
      // of an A-record IP. DiscoveredPrinter takes both; this locks
      // that contract down.
      const svc = MdnsServiceRecord(
        name: 'arco',
        type: '_moonraker._tcp',
        host: 'arco.local',
        port: 8080,
      );
      final p = printerFromMdns(svc);
      expect(p.host, 'arco.local');
      expect(p.port, 8080);
    });
  });

  group('DiscoveryBackend (fake)', () {
    test('emits only records matching the requested service type', () async {
      final backend = _FakeBackend([
        const MdnsServiceRecord(
          name: 'printer-a',
          type: '_moonraker._tcp',
          host: '10.0.0.2',
          port: 7125,
        ),
        const MdnsServiceRecord(
          name: 'random-device',
          type: '_workstation._tcp',
          host: '10.0.0.3',
          port: 22,
        ),
        const MdnsServiceRecord(
          name: 'printer-b',
          type: '_moonraker._tcp',
          host: '10.0.0.4',
          port: 7125,
        ),
      ]);

      final got = await backend.collectMdns(
        serviceType: '_moonraker._tcp',
        timeout: const Duration(milliseconds: 10),
      );
      final printers = got.map(printerFromMdns).toList();

      expect(printers.map((p) => p.hostname), ['printer-a', 'printer-b']);
      expect(printers.every((p) => p.service == '_moonraker._tcp'), isTrue);
    });

    test('returns empty list when no services match', () async {
      final backend = _FakeBackend(const []);
      final got = await backend.collectMdns(
        serviceType: '_moonraker._tcp',
        timeout: const Duration(milliseconds: 10),
      );
      expect(got, isEmpty);
    });
  });

  // TODO(test-hardware): end-to-end mDNS validation requires a second
  // process on the network broadcasting a `_moonraker._tcp` service so
  // bonsoir has something to resolve. That belongs in an integration
  // harness, not a CI unit run. The backend seam + fake above covers
  // the pure-Dart transformation; BonsoirDiscoveryService itself is
  // exercised by the integration tests under
  // `packages/deckhand_core/test/e2e_real_printer_test.dart`.
}
