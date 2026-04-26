/// Deckhand profile-script API — consumed by Dart scripts shipped
/// inside profiles' `scripts/` directories.
///
/// **Execution is disabled in v1.** This package ships only the type
/// surface that future profiles may target; there is no runner yet.
/// The capability model, isolate sandbox, and host-side `ScriptContext`
/// implementation will land together in a future release. Until then,
/// [ProfileScriptRuntime.enabled] is permanently `false` and any code
/// path that tries to load a profile-supplied script must refuse.
///
/// This guard exists because loading arbitrary profile-shipped code
/// before the sandbox is implemented would widen the trust model well
/// beyond what the rest of Deckhand has been designed for. A profile
/// vendor would effectively gain the same privileges as the app.
library;

export 'src/api.dart';
export 'src/runtime.dart';
