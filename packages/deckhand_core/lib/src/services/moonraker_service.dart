/// Moonraker WebSocket / HTTP client.
abstract class MoonrakerService {
  Future<KlippyInfo> info({required String host, int port = 7125});

  /// Query `print_stats` to decide whether a destructive op is safe.
  Future<bool> isPrinting({required String host, int port = 7125});
}

class KlippyInfo {
  const KlippyInfo({
    required this.state,
    required this.hostname,
    required this.softwareVersion,
    required this.klippyState,
  });
  final String state;
  final String hostname;
  final String softwareVersion;
  final String klippyState;
}
