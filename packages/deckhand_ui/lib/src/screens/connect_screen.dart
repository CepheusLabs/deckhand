import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _hostController = TextEditingController();
  String? _error;
  bool _connecting = false;

  bool _scanning = false;
  List<DiscoveredPrinter> _discovered = const [];

  @override
  void initState() {
    super.initState();
    // Kick off mDNS scan immediately; user can also type while it runs.
    _scan();
  }

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _discovered = const [];
    });
    final discovery = ref.read(discoveryServiceProvider);

    // mDNS only works if the printer has Moonraker's zeroconf advertiser
    // enabled - many KIAUH/stock installs don't. So we ALSO sweep port
    // 7125 (Moonraker default) across each /24 this host is attached to.
    // Whichever hits first populates the list; results are merged by host.
    final cidrs = await _localCidrs();

    final futures = <Future<List<DiscoveredPrinter>>>[
      discovery.scanMdns(timeout: const Duration(seconds: 4)).catchError(
        (_) => <DiscoveredPrinter>[],
      ),
      for (final c in cidrs)
        discovery
            .scanCidr(
              cidr: c,
              port: 7125,
              timeout: const Duration(seconds: 1),
            )
            .catchError((_) => <DiscoveredPrinter>[]),
    ];

    final merged = <String, DiscoveredPrinter>{};
    // As each probe finishes, fold its results in and update the UI so the
    // user sees printers appearing progressively instead of waiting for
    // the slowest scan.
    var outstanding = futures.length;
    for (final f in futures) {
      f.then((found) {
        for (final p in found) {
          merged.putIfAbsent(p.host, () => p);
        }
        if (!mounted) return;
        setState(() {
          _discovered = merged.values.toList();
        });
      }).whenComplete(() {
        outstanding--;
        if (outstanding == 0 && mounted) {
          setState(() => _scanning = false);
        }
      });
    }
  }

  /// Return /24 CIDRs for every non-loopback IPv4 interface on this host.
  /// Each /24 is probed with a 1-second TCP connect to port 7125 per IP.
  Future<List<String>> _localCidrs() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      final cidrs = <String>{};
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          cidrs.add('${parts[0]}.${parts[1]}.${parts[2]}.0/24');
        }
      }
      return cidrs.toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _connect(String host) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref.read(wizardControllerProvider).connectSsh(host: host);
      if (mounted) context.go('/verify');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manualHost = _hostController.text.trim();
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Connect to your printer',
      helperText:
          'Deckhand scans your LAN two ways: mDNS for printers that advertise '
          'Moonraker, and a TCP sweep of port 7125 across your local subnet. '
          'Pick one below, or enter an IP/hostname manually. Authentication '
          'uses the default SSH credentials declared by this printer\'s profile.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -------- Discovered on LAN --------
          Row(
            children: [
              Text(
                'Found on your network',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(width: 12),
              if (_scanning)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Rescan'),
                onPressed: _scanning || _connecting ? null : _scan,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_scanning && _discovered.isEmpty)
            Text(
              'Nothing responded on port 7125 across your local subnet, and '
              'no Moonraker mDNS advertisements were seen either. Your '
              'printer may be on a different VLAN, behind a firewall, or '
              'using a non-default port - enter the IP/hostname below.',
              style: theme.textTheme.bodySmall,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in _discovered)
                  _DiscoveredCard(
                    printer: p,
                    onTap: _connecting ? null : () => _connect(p.host),
                  ),
              ],
            ),

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),

          // -------- Manual entry --------
          Text('Or enter manually', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Host or IP',
              hintText: 'e.g. 192.168.1.50 or mkspi.local',
              border: OutlineInputBorder(),
            ),
            enabled: !_connecting,
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) {
              final h = v.trim();
              if (h.isNotEmpty) _connect(h);
            },
          ),
          const SizedBox(height: 12),
          if (_connecting) const LinearProgressIndicator(),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
      primaryAction: WizardAction(
        label: _connecting ? 'Connecting…' : 'Connect',
        onPressed: _connecting || manualHost.isEmpty
            ? null
            : () => _connect(manualHost),
      ),
      secondaryActions: [
        WizardAction(
          label: 'Back',
          onPressed: () => context.go('/pick-printer'),
        ),
      ],
    );
  }
}

class _DiscoveredCard extends StatelessWidget {
  const _DiscoveredCard({required this.printer, required this.onTap});
  final DiscoveredPrinter printer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 280,
      child: Card(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.print, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        printer.hostname.isEmpty
                            ? printer.host
                            : printer.hostname,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${printer.host}:${printer.port} · ${printer.service}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
