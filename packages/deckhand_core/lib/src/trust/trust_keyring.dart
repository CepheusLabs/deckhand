/// The bundled profile-trust keyring. See [docs/PROFILE-TRUST.md] for the
/// trust model. This module wraps the armored bytes + the "is the
/// placeholder still in place?" check.
///
/// Loading from a Flutter asset bundle lives in
/// `package:deckhand_ui/trust_keyring_asset.dart` (only available
/// from Flutter contexts); the headless driver loads from the file
/// system directly via [loadFromString]. Keeping `deckhand_core`
/// Flutter-free means the wizard controller can run in a pure Dart
/// CLI (HITL) without dragging Flutter UI types into the AOT build.
class TrustKeyring {
  const TrustKeyring._({required this.armored, required this.isPlaceholder});

  /// Armored PGP keyring contents. Forwarded verbatim to the sidecar's
  /// `profiles.fetch` method as `trusted_keys`.
  final String armored;

  /// True when the bundled asset is still the dev placeholder rather
  /// than a real keyring. Production wiring MUST refuse to enable
  /// `require_signed_tag` when this is true; otherwise the very first
  /// profile fetch on a fresh install would error out and the user
  /// would have no path forward.
  final bool isPlaceholder;

  /// Asset path within the Flutter asset bundle. The keyring file
  /// itself lives at `app/assets/keyring.asc` (a leaf-app asset) —
  /// Flutter's `packages/<pkg>/...` indirection only works when the
  /// owning package declares assets in its own `flutter:` block,
  /// which `deckhand_core` deliberately doesn't (it's pure Dart so
  /// the HITL driver can compile against it). The constant lives
  /// here as the single source of truth for both the Flutter
  /// loader (`deckhand_ui/trust_keyring_asset.dart`) and any
  /// future tooling that needs to read the file off disk.
  static const assetKey = 'assets/keyring.asc';
  static const _placeholderMarker =
      '-----BEGIN DECKHAND PROFILE TRUST PLACEHOLDER-----';

  /// Build a [TrustKeyring] from already-loaded armored bytes.
  ///
  /// The Flutter app loads the asset via `rootBundle.loadString` (in
  /// `deckhand_ui`); the HITL driver reads the file off disk; tests
  /// inject canned material via [forTest]. Either way, this is the
  /// common construction point so the placeholder-detection rule
  /// stays in one place.
  static TrustKeyring loadFromString(String armored) {
    return TrustKeyring._(
      armored: armored,
      isPlaceholder: armored.trimLeft().startsWith(_placeholderMarker),
    );
  }

  /// Construct a keyring for tests. Use sparingly — most tests
  /// should override the profile service provider with a fake
  /// instead of wiring real trust material.
  static TrustKeyring forTest({
    required String armored,
    bool isPlaceholder = false,
  }) {
    return TrustKeyring._(armored: armored, isPlaceholder: isPlaceholder);
  }
}
