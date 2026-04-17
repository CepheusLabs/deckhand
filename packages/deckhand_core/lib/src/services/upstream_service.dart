/// Fetch upstream source (Kalico/Klipper/Moonraker) or release assets
/// (Fluidd/Mainsail) into the local cache for install.
abstract class UpstreamService {
  /// Shallow-clone [repoUrl] at [ref] into the cache.
  Future<UpstreamFetchResult> gitFetch({
    required String repoUrl,
    required String ref,
    required String destPath,
    int depth = 1,
  });

  /// Download a GitHub Releases asset matching [assetPattern] from
  /// [repoSlug] (e.g. `fluidd-core/fluidd`), optionally pinned to [tag].
  Future<UpstreamFetchResult> releaseFetch({
    required String repoSlug,
    required String assetPattern,
    required String destPath,
    String? tag,
  });
}

class UpstreamFetchResult {
  const UpstreamFetchResult({
    required this.localPath,
    required this.resolvedRef,
    this.assetName,
  });
  final String localPath;
  final String resolvedRef;
  final String? assetName;
}
