/// Minimal JSON-RPC 2.0 client that spawns the Go sidecar binary and
/// talks to it over stdin/stdout. Stub.
class SidecarClient {
  SidecarClient({required this.binaryPath});

  final String binaryPath;

  Future<void> start() async {
    throw UnimplementedError('SidecarClient.start pending Process.start wiring');
  }

  Future<Map<String, dynamic>> call(String method, Map<String, dynamic> params) async {
    throw UnimplementedError('SidecarClient.call pending JSON-RPC framing');
  }

  Stream<Map<String, dynamic>> subscribe(String method, Map<String, dynamic> params) {
    throw UnimplementedError('SidecarClient.subscribe');
  }

  Future<void> shutdown() async {
    throw UnimplementedError('SidecarClient.shutdown');
  }
}
