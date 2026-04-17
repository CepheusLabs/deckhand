import 'package:deckhand_core/deckhand_core.dart';

/// WebSocket-based [MoonrakerService]. Stub for now.
class MoonrakerWsService implements MoonrakerService {
  @override
  Future<KlippyInfo> info({required String host, int port = 7125}) async {
    throw UnimplementedError('MoonrakerWsService.info');
  }

  @override
  Future<bool> isPrinting({required String host, int port = 7125}) async {
    throw UnimplementedError('MoonrakerWsService.isPrinting');
  }
}
