import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('dryRun setting defaults to false', () async {
    final tmp = Directory.systemTemp.createTempSync('deckhand-dry-');
    try {
      final s = await DeckhandSettings.load(p.join(tmp.path, 'settings.json'));
      expect(s.dryRun, isFalse);
    } finally {
      try { tmp.deleteSync(recursive: true); } catch (_) {}
    }
  });

  test('dryRun setting persists across reload', () async {
    final tmp = Directory.systemTemp.createTempSync('deckhand-dry-');
    final path = p.join(tmp.path, 'settings.json');
    try {
      final s = await DeckhandSettings.load(path);
      s.dryRun = true;
      await s.save();
      final reloaded = await DeckhandSettings.load(path);
      expect(reloaded.dryRun, isTrue);
    } finally {
      try { tmp.deleteSync(recursive: true); } catch (_) {}
    }
  });
}
