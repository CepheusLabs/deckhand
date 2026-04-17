import 'package:deckhand_core/deckhand_core.dart';

/// [SshService] backed by dartssh2. Stub for now.
class DartsshService implements SshService {
  @override
  Future<SshSession> connect({
    required String host,
    int port = 22,
    required SshCredential credential,
    bool acceptHostKey = false,
  }) async {
    throw UnimplementedError('DartsshService.connect pending dartssh2 wiring');
  }

  @override
  Future<SshSession> tryDefaults({
    required String host,
    int port = 22,
    required List<SshCredential> credentials,
  }) async {
    throw UnimplementedError('DartsshService.tryDefaults');
  }

  @override
  Future<SshCommandResult> run(
    SshSession session,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? sudoPassword,
  }) async {
    throw UnimplementedError('DartsshService.run');
  }

  @override
  Stream<String> runStream(SshSession session, String command) =>
      const Stream.empty();

  @override
  Future<int> upload(SshSession session, String localPath, String remotePath, {int? mode}) async {
    throw UnimplementedError('DartsshService.upload');
  }

  @override
  Future<int> download(SshSession session, String remotePath, String localPath) async {
    throw UnimplementedError('DartsshService.download');
  }

  @override
  Future<void> disconnect(SshSession session) async {}
}
