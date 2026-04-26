import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Root providers for the Deckhand UI. Each service is intentionally
/// created via `throwUnimplementedProvider` so the app must override
/// them at bootstrap - there are no "magic defaults."
T _throwUnimplemented<T>(String name) =>
    throw UnimplementedError('Provider $name not overridden at app startup');

final profileServiceProvider = Provider<ProfileService>(
  (_) => _throwUnimplemented('profileServiceProvider'),
);
final sshServiceProvider = Provider<SshService>(
  (_) => _throwUnimplemented('sshServiceProvider'),
);
final flashServiceProvider = Provider<FlashService>(
  (_) => _throwUnimplemented('flashServiceProvider'),
);
final discoveryServiceProvider = Provider<DiscoveryService>(
  (_) => _throwUnimplemented('discoveryServiceProvider'),
);
final moonrakerServiceProvider = Provider<MoonrakerService>(
  (_) => _throwUnimplemented('moonrakerServiceProvider'),
);
final upstreamServiceProvider = Provider<UpstreamService>(
  (_) => _throwUnimplemented('upstreamServiceProvider'),
);
final securityServiceProvider = Provider<SecurityService>(
  (_) => _throwUnimplemented('securityServiceProvider'),
);

/// Sidecar self-diagnostic. Wired by the app to a real
/// [DoctorService] that talks to the sidecar's `doctor.run` JSON-RPC
/// method; the S10 welcome screen + Settings → Run preflight button
/// both call this. See [docs/DOCTOR.md].
final doctorServiceProvider = Provider<DoctorService>(
  (_) => _throwUnimplemented('doctorServiceProvider'),
);

/// Persisted user settings (local-profiles-dir, show-stubs, etc.).
/// The Settings screen calls back into this to persist changes, then
/// the user restarts the app to pick up the new profile source.
final deckhandSettingsProvider = Provider<DeckhandSettings>(
  (_) => _throwUnimplemented('deckhandSettingsProvider'),
);

/// Optional: raw-device writes. Null when elevation is unavailable (e.g.
/// early dev builds before the helper binary ships alongside the app).
final elevatedHelperServiceProvider = Provider<ElevatedHelperService?>(
  (_) => null,
);

/// Optional: stock-config snapshot capture/restore. Null disables
/// the S145 archive step (the install still runs but no host-side
/// tar.gz lands). Production wiring constructs a real
/// [ArchiveService]; tests typically leave this null.
final archiveServiceProvider = Provider<ArchiveService?>((_) => null);

/// Where on the host the snapshot archives land. Production wiring
/// sets this to `<data_dir>/state/snapshots/`; null disables the
/// archive step alongside [archiveServiceProvider].
final snapshotsDirProvider = Provider<String?>((_) => null);

/// Where on the host debug bundles ([BundleBuilder] output) land.
/// Production wiring sets this to `<data_dir>/debug-bundles/`. When
/// null the "Save bundle" path on [DebugBundleScreen] surfaces an
/// "unconfigured" snackbar rather than silently dropping the zip.
final debugBundlesDirProvider = Provider<String?>((_) => null);

/// Build-time deckhand version (CalVer + commit count, e.g.
/// `26.4.25-1731`). Threaded into the wizard controller and the
/// on-printer run-state file so debug bundles and HITL artifacts
/// can be correlated to a release. Default `'dev'` for non-release
/// builds; `app/lib/build_info.dart` overrides it at the binding
/// site via `--dart-define=DECKHAND_VERSION=...`.
final deckhandVersionProvider = Provider<String>((_) => 'dev');

/// On-disk session store. The app overrides this with a real path under
/// the user's data dir. Leaving it null disables resume (tests, dev
/// flows where you always want a fresh wizard).
final wizardStateStoreProvider = Provider<WizardStateStore?>((_) => null);

final wizardControllerProvider = Provider<WizardController>((ref) {
  final controller = WizardController(
    profiles: ref.watch(profileServiceProvider),
    ssh: ref.watch(sshServiceProvider),
    flash: ref.watch(flashServiceProvider),
    discovery: ref.watch(discoveryServiceProvider),
    moonraker: ref.watch(moonrakerServiceProvider),
    upstream: ref.watch(upstreamServiceProvider),
    security: ref.watch(securityServiceProvider),
    elevatedHelper: ref.watch(elevatedHelperServiceProvider),
    archive: ref.watch(archiveServiceProvider),
    snapshotsDir: ref.watch(snapshotsDirProvider),
    deckhandVersion: ref.watch(deckhandVersionProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Live wizard state stream. Also *persists* on every change when a
/// [wizardStateStoreProvider] is configured, so a crash mid-wizard
/// leaves a resumable snapshot on disk.
final wizardStateProvider = StreamProvider<WizardState>((ref) async* {
  final controller = ref.watch(wizardControllerProvider);
  final store = ref.watch(wizardStateStoreProvider);
  yield controller.state;
  if (store != null) {
    // Fire-and-forget; save errors are logged and ignored so a disk
    // issue never blocks the wizard from advancing.
    unawaited(store.save(controller.state));
  }
  await for (final _ in controller.events) {
    yield controller.state;
    if (store != null) {
      unawaited(store.save(controller.state));
    }
  }
});
