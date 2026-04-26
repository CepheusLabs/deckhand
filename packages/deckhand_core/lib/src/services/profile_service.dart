import '../models/printer_profile.dart';

/// Fetch + parse printer profiles from the deckhand-profiles repo.
abstract class ProfileService {
  /// Fetch the profile registry (tiny YAML at the repo root).
  Future<ProfileRegistry> fetchRegistry({bool force = false});

  /// Ensure a given profile tag is cached locally. Shallow-clones the
  /// deckhand-profiles repo at that tag if needed.
  Future<ProfileCacheEntry> ensureCached({
    required String profileId,
    String? ref,
  });

  /// Parse a cached profile.yaml into an in-memory model.
  Future<PrinterProfile> load(ProfileCacheEntry cacheEntry);
}

class ProfileRegistry {
  const ProfileRegistry({required this.entries});
  final List<ProfileRegistryEntry> entries;
}

class ProfileRegistryEntry {
  const ProfileRegistryEntry({
    required this.id,
    required this.displayName,
    required this.manufacturer,
    required this.model,
    required this.status,
    required this.directory,
    this.latestTag,
  });
  final String id;
  final String displayName;
  final String manufacturer;
  final String model;
  final String status; // stub | alpha | beta | stable | deprecated
  final String directory;
  final String? latestTag;
}

class ProfileCacheEntry {
  const ProfileCacheEntry({
    required this.profileId,
    required this.ref,
    required this.localPath,
    required this.resolvedSha,
  });
  final String profileId;
  final String ref;
  final String localPath;
  final String resolvedSha;
}

// PrinterProfile lives in models/printer_profile.dart and is re-exported
// from the library entrypoint.
