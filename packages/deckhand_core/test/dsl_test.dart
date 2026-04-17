import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dsl = DslEvaluator(defaultPredicates());

  DslEnv env(Map<String, Object?> decisions, {Map<String, dynamic>? profile}) =>
      DslEnv(decisions: decisions, profile: profile ?? const {});

  group('DslEvaluator', () {
    test('selected(step, option) matches decision map', () {
      expect(
        dsl.evaluate('selected(screen, voronFDM)', env({'screen': 'voronFDM'})),
        isTrue,
      );
      expect(
        dsl.evaluate('selected(screen, voronFDM)', env({'screen': 'arco_screen'})),
        isFalse,
      );
    });

    test('NOT inverts', () {
      expect(
        dsl.evaluate('NOT selected(screen, voronFDM)', env({'screen': 'x'})),
        isTrue,
      );
    });

    test('AND / OR compose', () {
      final e = env({'firmware': 'kalico', 'screen': 'voronFDM'});
      expect(
        dsl.evaluate(
          'selected(firmware, kalico) AND selected(screen, voronFDM)',
          e,
        ),
        isTrue,
      );
      expect(
        dsl.evaluate(
          'selected(firmware, kalico) AND selected(screen, arco_screen)',
          e,
        ),
        isFalse,
      );
      expect(
        dsl.evaluate(
          'selected(firmware, bogus) OR selected(screen, voronFDM)',
          e,
        ),
        isTrue,
      );
    });

    test('equals(path, string)', () {
      expect(
        dsl.evaluate('equals(firmware, "kalico")', env({'firmware': 'kalico'})),
        isTrue,
      );
    });

    test('in_set matches', () {
      expect(
        dsl.evaluate(
          'in_set(screen, [voronFDM, mksclient])',
          env({'screen': 'voronFDM'}),
        ),
        isTrue,
      );
    });

    test('unknown predicate throws', () {
      expect(() => dsl.evaluate('made_up()', env({})), throwsA(isA<DslException>()));
    });

    test('parentheses force precedence', () {
      final e = env({'a': '1', 'b': '2', 'c': '3'});
      expect(
        dsl.evaluate(
          '(selected(a, "1") OR selected(b, "99")) AND selected(c, "3")',
          e,
        ),
        isTrue,
      );
    });
  });
}
