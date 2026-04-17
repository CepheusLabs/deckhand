import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PrinterProfile.fromJson', () {
    test('parses a minimal profile', () {
      final raw = <String, dynamic>{
        'schema_version': 1,
        'profile_id': 'test',
        'profile_version': '0.1.0',
        'display_name': 'Test Printer',
        'status': 'alpha',
        'required_hosts': ['github.com'],
        'hardware': {'architecture': 'aarch64'},
        'os': {
          'fresh_install_options': [
            {'id': 'img1', 'display_name': 'Image 1', 'url': 'http://x'},
          ],
        },
        'ssh': {
          'default_credentials': [
            {'user': 'mks', 'password': 'makerbase'},
          ],
        },
        'firmware': {
          'choices': [
            {'id': 'kalico', 'display_name': 'Kalico', 'repo': 'http://k', 'ref': 'main'},
          ],
          'default_choice': 'kalico',
        },
        'mcus': [
          {'id': 'main', 'chip': 'stm32f407xx'},
        ],
        'screens': [
          {'id': 'arco_screen', 'recommended': true},
        ],
        'addons': [],
        'flows': {
          'stock_keep': {'enabled': true, 'steps': []},
        },
      };

      final p = PrinterProfile.fromJson(raw);
      expect(p.id, 'test');
      expect(p.version, '0.1.0');
      expect(p.displayName, 'Test Printer');
      expect(p.status, ProfileStatus.alpha);
      expect(p.requiredHosts, ['github.com']);
      expect(p.firmware.choices.length, 1);
      expect(p.firmware.choices.first.id, 'kalico');
      expect(p.firmware.defaultChoice, 'kalico');
      expect(p.mcus.length, 1);
      expect(p.mcus.first.id, 'main');
      expect(p.screens.length, 1);
      expect(p.screens.first.recommended, isTrue);
      expect(p.flows.stockKeep?.enabled, isTrue);
      expect(p.os.freshInstallOptions.length, 1);
    });

    test('defaults empty collections when missing', () {
      final p = PrinterProfile.fromJson(<String, dynamic>{
        'profile_id': 'empty',
        'profile_version': '0.0.0',
        'display_name': 'Empty',
        'status': 'stub',
      });
      expect(p.status, ProfileStatus.stub);
      expect(p.mcus, isEmpty);
      expect(p.screens, isEmpty);
      expect(p.addons, isEmpty);
      expect(p.stockOs.services, isEmpty);
    });

    test('parses stock_os inventory', () {
      final p = PrinterProfile.fromJson(<String, dynamic>{
        'profile_id': 't',
        'profile_version': '0.1.0',
        'display_name': 't',
        'status': 'alpha',
        'stock_os': {
          'services': [
            {'id': 'frpc', 'display_name': 'FRP', 'default_action': 'remove'},
          ],
          'files': [
            {
              'id': 'rsa_priv',
              'display_name': 'RSA private key',
              'paths': ['/a', '/b'],
              'default_action': 'delete',
            },
          ],
          'paths': [
            {'id': 'klipper', 'path': '/home/mks/klipper', 'action': 'snapshot_and_replace'},
          ],
        },
      });
      expect(p.stockOs.services.length, 1);
      expect(p.stockOs.services.first.id, 'frpc');
      expect(p.stockOs.files.single.paths, ['/a', '/b']);
      expect(p.stockOs.paths.single.action, 'snapshot_and_replace');
    });
  });
}
