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
  // Keyed by host. Populated after each discovered IP is probed on
  // /printer/info - confirms it's actually Moonraker and gives us the
  // hostname + Klipper state to show on the card.
  final Map<String, KlippyInfo> _enriched = {};

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
    _enriched.clear();
    // As each probe finishes, fold its results in and update the UI so the
    // user sees printers appearing progressively instead of waiting for
    // the slowest scan. Each newly-found host then gets an /printer/info
    // GET against Moonraker to upgrade the "moonraker?" guess into
    // confirmed info (hostname, Klipper version, state).
    var outstanding = futures.length;
    for (final f in futures) {
      f.then((found) {
        final newlySeen = <DiscoveredPrinter>[];
        for (final p in found) {
          if (merged.putIfAbsent(p.host, () => p) == p) newlySeen.add(p);
        }
        if (!mounted) return;
        setState(() {
          _discovered = merged.values.toList();
        });
        for (final p in newlySeen) {
          _enrich(p);
        }
      }).whenComplete(() {
        outstanding--;
        if (outstanding == 0 && mounted) {
          setState(() => _scanning = false);
        }
      });
    }
  }

  /// Confirm a discovered host actually speaks Moonraker by hitting the
  /// unauthenticated `/printer/info` endpoint. On success, stash the
  /// returned info so the card can render real data (hostname, Klipper
  /// version, state) instead of a generic "moonraker?" guess. Failures
  /// are silent; the card just keeps showing the IP.
  Future<void> _enrich(DiscoveredPrinter p) async {
    try {
      final info = await ref
          .read(moonrakerServiceProvider)
          .info(host: p.host, port: p.port);
      if (!mounted) return;
      setState(() {
        _enriched[p.host] = info;
      });
    } catch (_) {
      // Port was open but the service isn't Moonraker, or auth blocks
      // anonymous GETs. Either way, leave the card as the raw discovery
      // result so the user still sees the IP.
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
                    info: _enriched[p.host],
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
  const _DiscoveredCard({
    required this.printer,
    required this.onTap,
    this.info,
  });
  final DiscoveredPrinter printer;
  final KlippyInfo? info;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enriched = info;

    // Title: prefer Moonraker-reported hostname, then mDNS hostname,
    // then raw IP. Identifying the machine by name is a lot easier
    // than scanning a list of IPs.
    final title =
        (enriched != null && enriched.hostname.trim().isNotEmpty)
        ? enriched.hostname
        : (printer.hostname.isNotEmpty && printer.hostname != printer.host
              ? printer.hostname
              : printer.host);

    // Second line: Klipper software version if we got it, otherwise
    // the discovery-source guess. `moonraker?` stops showing as soon
    // as enrichment confirms it.
    final String detail;
    if (enriched != null) {
      final version = enriched.softwareVersion.trim();
      detail = version.isEmpty
          ? '${printer.host}:${printer.port} · Moonraker'
          : '${printer.host} · $version';
    } else {
      detail = '${printer.host}:${printer.port} · ${printer.service}';
    }

    final stateChip = enriched == null
        ? null
        : _StateChip(state: enriched.klippyState);

    return SizedBox(
      width: 320,
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
                        title,
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (stateChip != null) stateChip,
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});
  final String state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalized = state.toLowerCase();
    final color = switch (normalized) {
      'ready' || 'printing' => theme.colorScheme.tertiary,
      'startup' || 'shutdown' => theme.colorScheme.secondary,
      'error' || 'disconnected' => theme.colorScheme.error,
      _ => theme.colorScheme.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        normalized,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
