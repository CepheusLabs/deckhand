/// Loads the profile-trust keyring from the bundled Flutter asset.
///
/// `deckhand_core` deliberately stays Flutter-free so the headless
/// HITL driver can compile against it without pulling Flutter UI
/// types into the AOT build. This shim lives in `deckhand_ui` (which
/// is already Flutter-flavored) and bridges to the canonical
/// [TrustKeyring.loadFromString] constructor in core.
library;

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Load the keyring from the Flutter asset bundle. Production GUI
/// wiring (`app/lib/main.dart`) calls this on startup, then forwards
/// the resulting [TrustKeyring] into [SidecarProfileService].
Future<TrustKeyring> loadBundledTrustKeyring() async {
  final armored = await rootBundle.loadString(TrustKeyring.assetKey);
  return TrustKeyring.loadFromString(armored);
}
