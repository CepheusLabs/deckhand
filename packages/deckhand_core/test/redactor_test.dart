import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Redactor', () {
    test('replaces session values with stable placeholders', () {
      final r = Redactor(sessionValues: const {
        'home': '/home/alice',
        'user': 'alice',
        'printer_host': 'printer.local',
      });
      final got = r.redact(
        'Alice (alice@printer.local) saved settings to /home/alice/.deckhand',
      );
      // Email is its own placeholder.
      expect(got.text, contains('<EMAIL>'));
      // Plain user + host get the session placeholders.
      expect(got.text, contains('<HOME>/.deckhand'));
      expect(got.stats.sessionHits, greaterThan(0));
      expect(got.stats.emailCount, 1);
    });

    test('redacts IPv4, MAC, and SSH fingerprint', () {
      final r = Redactor(sessionValues: const {});
      final got = r.redact('''
Connected to 192.168.1.50 (mac aa:bb:cc:dd:ee:ff)
Host key SHA256:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ
''');
      expect(got.text, contains('<IP>'));
      expect(got.text, contains('<MAC>'));
      expect(got.text, contains('<FPR>'));
      expect(got.stats.ipCount, 1);
      expect(got.stats.macCount, 1);
      expect(got.stats.fprCount, 1);
    });

    test('redacts long high-entropy secrets', () {
      final r = Redactor(sessionValues: const {});
      const token = 'a1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuVwXyZ123456';
      final got = r.redact('token=$token in transit');
      expect(got.text, contains('<REDACTED:${token.length}>'));
      expect(got.stats.secretCount, 1);
    });

    test('preserves sha256: prefixed hashes', () {
      // Commit SHA / file hash — reviewer needs these visible.
      final r = Redactor(sessionValues: const {});
      const hash = 'sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
      final got = r.redact(hash);
      expect(got.text, equals(hash));
      expect(got.stats.secretCount, 0);
    });

    test('redactJson redacts the encoded payload', () {
      final r = Redactor(sessionValues: const {'printer_host': 'p1.local'});
      final got = r.redactJson({
        'host': 'p1.local',
        'auth': 'x' * 40, // a fake "secret"
      });
      expect(got.text, contains('<PRINTER_HOST>'));
      expect(got.text, contains('<REDACTED:40>'));
    });

    test('isClean is true only when nothing was redacted', () {
      final r = Redactor(sessionValues: const {});
      expect(r.redact('plain prose with no secrets').stats.isClean, isTrue);
      expect(r.redact('hit 192.168.0.1 there').stats.isClean, isFalse);
    });
  });
}
