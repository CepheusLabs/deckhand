import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_discovery/deckhand_discovery.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:deckhand_profiles/deckhand_profiles.dart';
import 'package:deckhand_ssh/deckhand_ssh.dart';
import 'package:deckhand_ui/deckhand_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Per-user data directories.
  final appDataDir = await getApplicationSupportDirectory();
  final cacheDirBase = await getApplicationCacheDirectory();
  final paths = DeckhandPaths(
    cacheDir: p.join(cacheDirBase.path, 'Deckhand'),
    stateDir: p.join(appDataDir.path, 'state'),
    logsDir: p.join(appDataDir.path, 'logs'),
    settingsFile: p.join(appDataDir.path, 'settings.json'),
  );
  await Directory(paths.cacheDir).create(recursive: true);
  await Directory(paths.stateDir).create(recursive: true);
  await Directory(paths.logsDir).create(recursive: true);

  // Sidecar binary ships alongside the Flutter executable.
  final sidecar = SidecarClient(binaryPath: _resolveSidecarPath());
  try {
    await sidecar.start();
  } catch (e, st) {
    debugPrint('Sidecar failed to start: $e\n$st');
  }

  runApp(ProviderScope(
    overrides: [
      profileServiceProvider.overrideWithValue(SidecarProfileService(
        sidecar: sidecar,
        paths: paths,
      )),
      sshServiceProvider.overrideWithValue(DartsshService()),
      flashServiceProvider.overrideWithValue(SidecarFlashService(sidecar)),
      discoveryServiceProvider.overrideWithValue(BonsoirDiscoveryService()),
      moonrakerServiceProvider.overrideWithValue(MoonrakerHttpService()),
      upstreamServiceProvider
          .overrideWithValue(SidecarUpstreamService(sidecar: sidecar)),
      securityServiceProvider.overrideWithValue(DefaultSecurityService()),
    ],
    child: const WizardShell(),
  ));
}

String _resolveSidecarPath() {
  final dir = p.dirname(Platform.resolvedExecutable);
  return Platform.isWindows
      ? p.join(dir, 'deckhand-sidecar.exe')
      : p.join(dir, 'deckhand-sidecar');
}
