import 'package:deckhand_core/deckhand_core.dart';

import 'sidecar_client.dart';

/// [FlashService] that delegates to the Go sidecar over JSON-RPC.
class SidecarFlashService implements FlashService {
  SidecarFlashService(this._client);

  final SidecarClient _client;

  @override
  Future<List<DiskInfo>> listDisks() async {
    throw UnimplementedError('SidecarFlashService.listDisks pending sidecar wiring');
  }

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  }) {
    throw UnimplementedError('SidecarFlashService.writeImage');
  }

  @override
  Stream<FlashProgress> readImage({required String diskId, required String outputPath}) {
    throw UnimplementedError('SidecarFlashService.readImage');
  }

  @override
  Future<String> sha256(String path) async {
    throw UnimplementedError('SidecarFlashService.sha256');
  }
}
