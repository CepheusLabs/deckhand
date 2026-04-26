import 'dart:io';
import 'dart:math' as math;

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Pseudo-fuzz harness for the DSL evaluator. Dart doesn't ship a
/// native fuzz runner the way Go does, so we drive it from a seeded
/// PRNG: deterministic per CI run, but exercises a much wider input
/// surface than hand-authored cases.
///
/// Contract under test:
///   1. The evaluator MUST NOT throw any error type other than
///      [DslException]. A panic / cast failure here would surface as
///      a wizard crash on a profile author's first typo.
///   2. The evaluator MUST terminate (i.e. depth-bounded). The
///      grammar is recursive descent; nested parens or AND/OR chains
///      must not blow the stack.
void main() {
  final dsl = DslEvaluator(defaultPredicates());

  group('DSL fuzz', () {
    // Replays every saved corpus entry first so a fix-then-revert
    // can't sneak through. New random expressions then explore the
    // space; any failure persists itself to the corpus dir for
    // later replay.
    test('corpus + seeded random expressions never panic', () {
      final env = DslEnv(
        decisions: const {
          'firmware': 'kalico',
          'screen': 'voronFDM',
          'kiauh': true,
        },
        profile: const {'os': {'stock': {'python': '3.11'}}},
      );

      void check(String src) {
        try {
          dsl.evaluate(src, env);
        } on DslException {
          // Allowed: malformed inputs surface as DslException.
        } catch (e, st) {
          // Persist the offending input so the test re-runs it on
          // every future invocation, not just the seed that
          // produced it.
          _persistFailure(src);
          fail('expected only DslException, got ${e.runtimeType}: $e\n'
              'source: ${src.length > 200 ? "${src.substring(0, 200)}..." : src}\n$st');
        }
      }

      for (final src in _loadCorpus()) {
        check(src);
      }

      final rnd = math.Random(0xDECC);
      for (var i = 0; i < 2000; i++) {
        check(_randomExpression(rnd));
      }
    });

    test('deeply nested parens still terminate (no stack overflow)', () {
      // 1024 layers of `(`...`)` exercises the recursive-descent
      // depth bound. If the parser had a bug here it would blow the
      // VM stack rather than throwing — so this test gates on the
      // call returning at all.
      const depth = 1024;
      final opens = List.filled(depth, '(').join();
      final closes = List.filled(depth, ')').join();
      final inside = '${opens}selected(firmware, kalico)$closes';
      expect(() => dsl.evaluate(inside, _emptyEnv()), returnsNormally);
    });

    test('long AND/OR chains never deadlock', () {
      // 256 OR'd predicates — historically the parser used to be
      // O(n^2) here. Pin O(n) by capping the runtime.
      final src = List.filled(
        256,
        'selected(firmware, kalico)',
      ).join(' OR ');
      final stopwatch = Stopwatch()..start();
      dsl.evaluate(src, _emptyEnv());
      stopwatch.stop();
      // Generous bound — on any vaguely sane parser this is well
      // under 100ms; the test is here to catch a regression to
      // exponential or quadratic behavior.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}

DslEnv _emptyEnv() => DslEnv(
      decisions: const {'firmware': 'kalico'},
      profile: const {},
    );

/// On-disk fuzz corpus. Each file is a single failing expression that
/// previously slipped past the lex/parse/predicate pipeline. The
/// corpus replays first on every test run so a regression that
/// brings back an old crash fails fast — not "after another 2000
/// random rolls". Keep this directory under version control.
Directory _corpusDir() {
  final scriptDir = Directory(p.dirname(Platform.script.toFilePath()));
  // Resolve test/dsl_fuzz_test.dart's parent. Falls back to CWD when
  // run via `flutter test` which sets `Platform.script` to a temp
  // bootstrap file.
  final testRoot = Directory(p.join(Directory.current.path, 'test'));
  final base = testRoot.existsSync() ? testRoot : scriptDir;
  return Directory(p.join(base.path, 'fuzz_corpus', 'dsl'));
}

Iterable<String> _loadCorpus() sync* {
  final dir = _corpusDir();
  if (!dir.existsSync()) return;
  for (final f in dir.listSync().whereType<File>()) {
    yield f.readAsStringSync();
  }
}

void _persistFailure(String src) {
  try {
    final dir = _corpusDir()..createSync(recursive: true);
    final hash = src.hashCode.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    File(p.join(dir.path, 'crash-$hash.txt')).writeAsStringSync(src);
  } on Object {
    // Persistence is best-effort. The test still fails the moment
    // the offending input was hit; corpus persistence is a bonus.
  }
}

const _idents = [
  'selected', 'in_set', 'equals', 'profile_field_equals',
  'decision_made', 'os_codename_is', 'os_codename_in',
  'os_python_below', 'unknown_predicate',
];

const _decisionPaths = [
  'firmware', 'screen', 'kiauh', 'flash.disk', 'probe.os_codename',
];

const _values = [
  'kalico', 'klipper', 'voronFDM', 'arco_screen', '3.10', '3.11',
];

String _randomExpression(math.Random rnd, {int depth = 0}) {
  // Hard-cap depth so our random walk doesn't run forever.
  if (depth > 6) return _atom(rnd);
  final pick = rnd.nextInt(10);
  switch (pick) {
    case 0:
    case 1:
      return 'NOT ${_randomExpression(rnd, depth: depth + 1)}';
    case 2:
    case 3:
      return '(${_randomExpression(rnd, depth: depth + 1)} AND '
          '${_randomExpression(rnd, depth: depth + 1)})';
    case 4:
    case 5:
      return '(${_randomExpression(rnd, depth: depth + 1)} OR '
          '${_randomExpression(rnd, depth: depth + 1)})';
    default:
      return _atom(rnd);
  }
}

String _atom(math.Random rnd) {
  final ident = _idents[rnd.nextInt(_idents.length)];
  // Sometimes emit malformed predicates to exercise error paths.
  if (rnd.nextInt(20) == 0) return ident;
  final argCount = rnd.nextInt(3);
  final args = List.generate(argCount, (_) => _randomArg(rnd));
  return '$ident(${args.join(', ')})';
}

String _randomArg(math.Random rnd) {
  final kind = rnd.nextInt(5);
  switch (kind) {
    case 0:
      return _decisionPaths[rnd.nextInt(_decisionPaths.length)];
    case 1:
      return '"${_values[rnd.nextInt(_values.length)]}"';
    case 2:
      return rnd.nextInt(100).toString();
    case 3:
      return rnd.nextBool().toString();
    default:
      // List literal.
      final n = rnd.nextInt(3);
      final items = List.generate(
        n,
        (_) => '"${_values[rnd.nextInt(_values.length)]}"',
      );
      return '[${items.join(', ')}]';
  }
}
