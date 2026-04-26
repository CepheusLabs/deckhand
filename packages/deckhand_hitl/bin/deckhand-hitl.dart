// deckhand-hitl — headless wizard driver for HITL CI.
//
// Phase 2: now drives the full WizardController against a real
// printer. The driver loads a profile, opens an SSH session,
// applies decisions from the scenario YAML, runs the install flow,
// and evaluates the scenario's post-execution assertions.
//
// Usage:
//   deckhand-hitl
//     --scenario <path>
//     --sidecar-path <path>
//     [--helper-path <path>]
//     [--output-dir <path>]
//     [--bail-on-first-failure]
//
// What this driver covers:
//   - Sidecar handshake + doctor.run
//   - Profile fetch (with optional DECKHAND_PROFILES_LOCAL override)
//   - SSH connect (password from env named in scenario.printer.ssh)
//   - WizardController.startExecution end-to-end
//   - Post-flow assertions: ports, remote files, run-state step
//     statuses, wall-time drift
//
// What this driver does NOT cover:
//   - Disk flash (the elevated helper path is exercised by
//     scenarios.flow=fresh_flash; without an attached eMMC mux on
//     the runner host this will fail at flash-target. Wire your
//     rig's reset script — see packaging/hitl/scripts/ — before
//     running fresh-flash scenarios.)

import 'dart:io';

import 'package:args/args.dart';
import 'package:deckhand_hitl/deckhand_hitl.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('scenario', help: 'Path to scenario YAML', mandatory: true)
    ..addOption('sidecar-path',
        help: 'Path to deckhand-sidecar binary', mandatory: true)
    ..addOption('helper-path', help: 'Path to deckhand-elevated-helper binary')
    ..addOption('output-dir',
        help: 'Where to write artifacts',
        defaultsTo: 'hitl-artifacts')
    ..addFlag('bail-on-first-failure',
        help:
            'Exit 1 on the first failed assertion rather than running the '
            'whole scenario through.')
    ..addFlag('help', abbr: 'h', negatable: false);

  ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}\n\n${parser.usage}');
    exit(2);
  }
  if (args['help'] as bool) {
    stdout.writeln(parser.usage);
    exit(0);
  }

  final scenarioPath = args['scenario'] as String;
  final sidecarPath = args['sidecar-path'] as String;
  final helperPath = args['helper-path'] as String?;
  final outputDir = args['output-dir'] as String;
  final bailFast = args['bail-on-first-failure'] as bool;

  if (!File(scenarioPath).existsSync()) {
    stderr.writeln('error: scenario not found: $scenarioPath');
    exit(2);
  }
  if (!File(sidecarPath).existsSync()) {
    stderr.writeln('error: sidecar not found: $sidecarPath');
    exit(2);
  }

  Scenario scenario;
  try {
    scenario = Scenario.fromYaml(await File(scenarioPath).readAsString());
  } on FormatException catch (e) {
    stderr.writeln('error: malformed scenario: $e');
    exit(2);
  }

  final runner = ScenarioRunner(
    scenario: scenario,
    sidecarPath: sidecarPath,
    helperPath: helperPath,
    outputDir: outputDir,
    bailOnFirstFailure: bailFast,
  );

  final report = await runner.run();

  stdout.writeln('');
  stdout.writeln('---');
  stdout.writeln(
    'HITL ${scenario.profile}/${scenario.flow}: '
    '${report.results.length - report.failedCount} pass, '
    '${report.failedCount} fail '
    '(${report.elapsed.inSeconds}s)',
  );

  exit(report.failedCount == 0 ? 0 : 1);
}
