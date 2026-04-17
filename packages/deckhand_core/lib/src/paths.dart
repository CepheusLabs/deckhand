/// Host paths Deckhand reads and writes. Embedders pass an instance at
/// app bootstrap so tests can redirect to tempdirs.
class DeckhandPaths {
  const DeckhandPaths({
    required this.cacheDir,
    required this.stateDir,
    required this.logsDir,
    required this.settingsFile,
  });

  final String cacheDir;
  final String stateDir;
  final String logsDir;
  final String settingsFile;
}
