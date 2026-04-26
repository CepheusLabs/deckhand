/// Build-time constants threaded into the wizard controller and the
/// run-state file. Updated by the release workflow's "compute
/// version" step before `flutter build`. The default ('dev') keeps
/// non-release builds honest about what they are.
///
/// To override locally without editing this file, pass
/// `--dart-define=DECKHAND_VERSION=26.4.25-1731` to `flutter run` /
/// `flutter build`. The wizard controller surfaces this verbatim
/// into `~/.deckhand/run-state.json` so a maintainer reading a
/// debug bundle can correlate "this install was from release X".
library;

const String deckhandVersion = String.fromEnvironment(
  'DECKHAND_VERSION',
  defaultValue: 'dev',
);
