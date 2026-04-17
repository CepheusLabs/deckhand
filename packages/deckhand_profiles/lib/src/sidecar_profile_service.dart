import 'package:deckhand_core/deckhand_core.dart';

/// [ProfileService] implementation that fetches profiles via the Go
/// sidecar (which uses go-git for shallow clones). Stub for now.
class SidecarProfileService implements ProfileService {
  SidecarProfileService();

  @override
  Future<ProfileRegistry> fetchRegistry({bool force = false}) async {
    throw UnimplementedError('SidecarProfileService.fetchRegistry pending sidecar wiring');
  }

  @override
  Future<ProfileCacheEntry> ensureCached({required String profileId, String? ref}) async {
    throw UnimplementedError('SidecarProfileService.ensureCached pending sidecar wiring');
  }

  @override
  Future<PrinterProfile> load(ProfileCacheEntry cacheEntry) async {
    throw UnimplementedError('SidecarProfileService.load pending parser');
  }
}
