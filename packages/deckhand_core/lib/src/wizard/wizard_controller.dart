import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../models/printer_profile.dart';
import '../services/discovery_service.dart';
import '../services/elevated_helper_service.dart';
import '../services/flash_service.dart';
import '../services/moonraker_service.dart';
import '../services/profile_service.dart';
import '../services/security_service.dart';
import '../services/ssh_service.dart';
import '../services/upstream_service.dart';
import '../shell/shell_quoting.dart';
import 'dsl.dart';
import 'printer_state_probe.dart';

// Method bodies for backup management (restoreBackup, readBackupContent,
// deleteBackup, pruneBackups) live in a separate file so the main
// controller stays navigable. They operate on this controller via
// library-private access because `part of` puts them in the same
// library as WizardController.
part 'wizard_controller_backup.dart';

// Long step-execution bodies (write_file, install_screen, flash_mcus,
// os_download, flash_disk, script + askpass) live in a separate file
// for the same reason. Same `part of` scope-sharing applies.
part 'wizard_controller_steps.dart';

/// Which high-level flow the wizard is running.
enum WizardFlow { none, stockKeep, freshFlash }

/// Wizard state machine - profile-driven, UI-agnostic.
class WizardController {
  WizardController({
    required this.profiles,
    required this.ssh,
    required this.flash,
    required this.discovery,
    required this.moonraker,
    required this.upstream,
    required this.security,
    this.elevatedHelper,
  });

  final ProfileService profiles;
  final SshService ssh;
  final FlashService flash;
  final DiscoveryService discovery;
  final MoonrakerService moonraker;
  final UpstreamService upstream;
  final SecurityService security;

  /// Optional: when non-null, raw-device writes go through the elevated
  /// helper (UAC / pkexec / osascript). Tests leave this null.
  final ElevatedHelperService? elevatedHelper;

  late final DslEvaluator _dsl = DslEvaluator(defaultPredicates());
  final _eventsController = StreamController<WizardEvent>.broadcast();
  final _pendingInput = <String, Completer<Object?>>{};

  PrinterProfile? _profile;
  ProfileCacheEntry? _profileCache;
  SshSession? _session;
  // Remembered so we can run `sudo -S` without allocating a pty. Not
  // persisted anywhere; dropped when the controller disposes.
  String? _sshPassword;
  // Set of askpass helpers staged this session, keyed by step id. The
  // first script step stages the helper; subsequent script steps reuse
  // it. Cleaned up all at once in `dispose()` so each script doesn't
  // pay the upload cost + the per-step cleanup race.
  _ScriptSudoHelper? _sessionAskpass;
  // The `kind:` of the step currently executing under `_runStep` (or
  // null when nothing is running / execution is complete). Read by
  // the stepper so it can switch its "Install" label to a more
  // specific phase label ("Writing image") during long-running steps.
  String? _currentStepKind;
  // Snapshot of what's actually present/running on this specific
  // printer. Populated by [probePrinterState]; screens read from it
  // to dim options that don't apply to THIS machine (service already
  // absent, file already deleted, etc.) even though the profile
  // declares them for the printer type.
  PrinterState _printerState = PrinterState.empty;
  var _state = WizardState.initial();

  WizardState get state => _state;
  PrinterProfile? get profile => _profile;
  String? get currentStepKind => _currentStepKind;
  PrinterState get printerState => _printerState;
  Stream<WizardEvent> get events => _eventsController.stream;

  /// Test-only: inject a canned [PrinterState] so widget tests can
  /// exercise probe-driven UI branches without standing up an SSH
  /// session. Emits [PrinterStateRefreshed] so screens that watch
  /// [wizardStateProvider] rebuild in response.
  ///
  /// The setter body runs inside an `assert(() { ... return true; }())`
  /// wrapper so it's a silent no-op in profile / release builds - a
  /// contributor who accidentally calls this from production code on
  /// a release build gets no state change, never a misleading state
  /// update that could mask real bugs. `@visibleForTesting` stays as
  /// a linter hint on top of the runtime gate.
  @visibleForTesting
  set printerStateForTesting(PrinterState value) {
    assert(() {
      _printerState = value;
      _emit(PrinterStateRefreshed(value));
      return true;
    }());
  }

  Future<void> loadProfile(String profileId, {String? ref}) async {
    final cache = await profiles.ensureCached(profileId: profileId, ref: ref);
    final profile = await profiles.load(cache);
    _profile = profile;
    _profileCache = cache;
    _state = _state.copyWith(profileId: profileId);
    _emit(ProfileLoaded(profile));
  }

  Future<void> connectSsh({
    required String host,
    int? port,
    bool acceptHostKey = false,
  }) async {
    final pf = _profile;
    if (pf == null) {
      throw StateError('Load a profile before connecting SSH.');
    }
    final creds = pf.ssh.defaultCredentials
        .map(
          (c) => PasswordCredential(user: c.user, password: c.password ?? ''),
        )
        .toList();
    final session = await ssh.tryDefaults(
      host: host,
      port: port ?? pf.ssh.defaultPort,
      credentials: creds.cast<SshCredential>(),
      acceptHostKey: acceptHostKey,
    );
    _session = session;
    // Remember the password of whichever default matched, so sudo
    // commands can feed it on stdin.
    for (final c in pf.ssh.defaultCredentials) {
      if (c.user == session.user && c.password != null) {
        _sshPassword = c.password;
        break;
      }
    }
    _state = _state.copyWith(sshHost: host);
    _emit(SshConnected(host: host, user: session.user));
    // Fire the inventory probe in the background so the services /
    // files / screens screens render with machine-specific state
    // without making the user wait at the Connect step for it.
    // Probe failures emit StepWarning internally; the .catchError is a
    // belt-and-suspenders guard so a surprise sync throw at the top of
    // _refreshPrinterState never becomes an unhandled async error.
    unawaited(_refreshPrinterState().catchError((_) {}));
  }

  /// Connect with a specific username/password. Used as the fallback when
  /// the profile's default credentials don't authenticate (e.g. the user
  /// has changed the stock password).
  Future<void> connectSshWithPassword({
    required String host,
    int? port,
    required String user,
    required String password,
    bool acceptHostKey = false,
  }) async {
    final pf = _profile;
    final p = port ?? pf?.ssh.defaultPort ?? 22;
    final session = await ssh.connect(
      host: host,
      port: p,
      credential: PasswordCredential(user: user, password: password),
      acceptHostKey: acceptHostKey,
    );
    _session = session;
    _sshPassword = password;
    _state = _state.copyWith(sshHost: host);
    _emit(SshConnected(host: host, user: session.user));
    // Probe failures emit StepWarning internally; the .catchError is a
    // belt-and-suspenders guard so a surprise sync throw at the top of
    // _refreshPrinterState never becomes an unhandled async error.
    unawaited(_refreshPrinterState().catchError((_) {}));
  }

  /// Re-run the state probe against the current SSH session. Emits
  /// [PrinterStateRefreshed] when fresh data lands so screens can
  /// rebuild. Called automatically on connect; screens can call it
  /// manually (via [refreshPrinterState]) after a user action that
  /// changes the printer state (e.g. after the install flow
  /// completes and you navigate back to adjust decisions).
  ///
  /// Freshness gate: a background probe finished within the last
  /// [_probeFreshness] skips. Wizard navigation that bounces users
  /// back/forward on option screens (/services -> /files -> /services)
  /// would otherwise re-probe every time, wasting bandwidth and the
  /// printer's CPU.
  static const _probeFreshness = Duration(seconds: 30);
  Future<void> _refreshPrinterState({bool force = false}) async {
    final s = _session;
    final pf = _profile;
    if (s == null || pf == null) return;
    if (!force) {
      final last = _printerState.probedAt;
      if (last != null &&
          DateTime.now().difference(last) < _probeFreshness) {
        return;
      }
    }
    try {
      final probe = PrinterStateProbe(ssh: ssh);
      final report = await probe.probe(session: s, profile: pf);
      _printerState = report;
      _emit(PrinterStateRefreshed(report));
    } catch (e) {
      // Probe is best-effort. If it fails (network blip, missing
      // systemctl, etc.) screens simply render the full abstract
      // option list like they did before probing existed.
      _emit(
        StepWarning(
          stepId: 'printer_state_probe',
          message: 'Could not probe printer state: $e',
        ),
      );
    }
  }

  /// Public entry point for screens that want to trigger a re-probe.
  /// Pass `force: true` to bypass the freshness gate (e.g. after a
  /// restoreBackup so the backup list reflects the new state).
  Future<void> refreshPrinterState({bool force = false}) =>
      _refreshPrinterState(force: force);

  /// Restore a prior write_file auto-snapshot. Copies `backupPath`
  /// back over `originalPath` using sudo when the target is outside
  /// the SSH user's home. `cp -p` preserves the original's mode and
  /// ownership metadata that we captured at backup time - so the
  /// restored file matches what was there before Deckhand touched it.
  /// The backup file is LEFT in place after restore; callers can use
  /// [deleteBackup] to clean up once they're satisfied.
  /// Throws [StepExecutionException] on failure.
  /// Restore a prior `.deckhand-pre-*` backup over its original target.
  /// Implementation in wizard_controller_backup.dart.
  Future<void> restoreBackup(DeckhandBackup backup) =>
      _restoreBackupImpl(this, backup);

  /// Fetch the content of a backup file so the UI can show a preview
  /// before the user commits to restoring. Returns null on read
  /// failure (best-effort; the user can still restore without
  /// preview). Implementation in wizard_controller_backup.dart.
  ///
  /// Guards:
  ///   - 256 KiB byte cap so a big binary can't DoS the UI.
  ///   - 200-line cap; very-long single-line content (minified JSON,
  ///     one-liner configs) truncates at the line level too.
  ///   - Binary detection via layered probe; binary files return a
  ///     marker string rather than garbage.
  Future<String?> readBackupContent(DeckhandBackup backup) =>
      _readBackupContentImpl(this, backup);

  /// Decide if the probe output from the layered binary detector
  /// indicates a non-text file. See [readBackupContent] for the
  /// layering; this is the shared judgement function, kept pure so
  /// the unit test can pin the classification table.
  @visibleForTesting
  static bool looksLikeBinary(String probeOutput) =>
      _looksLikeBinary(probeOutput);

  static bool _looksLikeBinary(String s) {
    if (s.isEmpty) return false;
    final lower = s.toLowerCase();
    // Layer A signals (from `file --mime`).
    if (lower.contains('charset=binary')) return true;
    const binaryMimePrefixes = [
      'application/octet-stream',
      'application/x-executable',
      'application/x-sharedlib',
      'application/x-pie-executable',
      'application/x-mach-binary',
      'application/x-dosexec',
      'application/zip',
      'application/gzip',
      'application/x-tar',
      'application/x-xz',
      'application/x-bzip2',
      'application/x-7z-compressed',
      'application/vnd.ms-cab-compressed',
      'image/',
      'video/',
      'audio/',
    ];
    for (final p in binaryMimePrefixes) {
      if (lower.contains(p)) return true;
    }
    // Layer B signals (from plain `file -b`).
    const binaryKeywords = [
      'elf ',
      'executable',
      'shared object',
      'archive',
      'image data',
      'compiled',
      'compressed',
      'binary',
    ];
    for (final k in binaryKeywords) {
      if (lower.contains(k)) return true;
    }
    // `data` appears on its own line as busybox's catchall for
    // "couldn't classify, probably binary" - match it as a word, not a
    // substring (so "metadata" / "data-driven" in real text don't
    // falsely trip).
    if (RegExp(r'(^|\s|,)data(\s|,|$)').hasMatch(lower)) return true;
    // Layer C: od output contains `\0` glyphs for null bytes. od -An
    // -c renders NUL as `\0`. Count them - a handful in 512 bytes is
    // a strong "binary" signal for text-mostly files too.
    final nulCount = RegExp(r'\\0').allMatches(s).length;
    if (nulCount >= 3) return true;
    return false;
  }

  /// Delete a `.deckhand-pre-*` backup + its `.meta.json` sidecar.
  /// Used by the verify_screen after the user has confirmed they
  /// don't need the rollback snapshot anymore. Throws on failure.
  /// Implementation in wizard_controller_backup.dart.
  Future<void> deleteBackup(DeckhandBackup backup) =>
      _deleteBackupImpl(this, backup);

  /// Sweep all `.deckhand-pre-*` backups older than [olderThan] from
  /// the printer. When [keepLatestPerTarget] is true, the single
  /// newest backup for each `originalPath` is spared even when it
  /// would otherwise be in the victim set - useful as a safety net
  /// against "I pruned too aggressively and now have no snapshot of
  /// my sources.list."
  ///
  /// Returns the number of backup files removed (sidecars counted
  /// as part of the same logical backup). Implementation in
  /// wizard_controller_backup.dart.
  Future<int> pruneBackups({
    Duration olderThan = const Duration(days: 30),
    bool keepLatestPerTarget = false,
  }) =>
      _pruneBackupsImpl(
        this,
        olderThan: olderThan,
        keepLatestPerTarget: keepLatestPerTarget,
      );

  Future<void> setDecision(String path, Object value) async {
    // Immutable map merge rather than Map.from() + mutate. Avoids any
    // possibility of two concurrent calls racing on the same temporary
    // mutable map while the copyWith is scheduled.
    _state = _state.copyWith(
      decisions: {..._state.decisions, path: value},
    );
    _emit(DecisionRecorded(path: path, value: value));
  }

  T? decision<T>(String path) => _state.decisions[path] as T?;

  String resolveServiceDefault(StockService svc) {
    final rules =
        ((svc.raw['wizard'] as Map?)?['default_rules'] as List?) ?? const [];
    final env = _buildDslEnv();
    for (final r in rules.whereType<Map>().map(
      (m) => m.cast<String, dynamic>(),
    )) {
      final when = r['when'] as String?;
      final thenVal = r['then'] as String?;
      if (when == null || thenVal == null) continue;
      try {
        if (_dsl.evaluate(when, env)) return thenVal;
      } catch (_) {
        continue;
      }
    }
    return svc.defaultAction;
  }

  /// Build the DSL evaluation env with live probe results folded in
  /// as `probe.*` decision entries. Centralised so every DSL caller
  /// sees the same view of the printer - otherwise we'd leak the
  /// profile-declared "stock OS" assumptions into conditions that
  /// should be live-state-aware.
  DslEnv _buildDslEnv() {
    final decisions = Map<String, Object>.from(_state.decisions);
    final probe = _printerState;
    if (probe.osCodename != null) {
      decisions['probe.os_codename'] = probe.osCodename!;
    }
    if (probe.osId != null) {
      decisions['probe.os_id'] = probe.osId!;
    }
    if (probe.osVersionId != null) {
      decisions['probe.os_version_id'] = probe.osVersionId!;
    }
    if (probe.pythonDefaultVersion != null) {
      decisions['probe.python_default'] = probe.pythonDefaultVersion!;
    }
    // python3.11 presence lets os_python_below short-circuit to false
    // for any threshold <= 3.11 regardless of what the profile claims
    // the stock Python version is.
    if (probe.python311Installed) {
      decisions['probe.os_python_below.3.9'] = false;
      decisions['probe.os_python_below.3.10'] = false;
      decisions['probe.os_python_below.3.11'] = false;
    }
    return DslEnv(
      decisions: decisions,
      profile: _profile?.raw ?? const {},
    );
  }

  void setFlow(WizardFlow flow) {
    _state = _state.copyWith(flow: flow);
    _emit(FlowChanged(flow));
  }

  /// Resolve an outstanding user-input request. UI code calls this when
  /// the user has made a decision for a UI-driven step.
  void resolveUserInput(String stepId, Object? value) {
    final completer = _pendingInput.remove(stepId);
    completer?.complete(value);
  }

  Future<void> startExecution() async {
    final pf = _profile;
    if (pf == null) throw StateError('No profile loaded.');
    final flow = _state.flow == WizardFlow.stockKeep
        ? pf.flows.stockKeep
        : pf.flows.freshFlash;
    if (flow == null || !flow.enabled) {
      throw StateError('Flow ${_state.flow} is not enabled for this profile.');
    }

    for (final step in flow.steps) {
      final id = step['id'] as String? ?? 'unnamed';
      final kind = step['kind'] as String? ?? '';
      _currentStepKind = kind;
      _emit(StepStarted(id));
      try {
        await _runStep(step);
        _emit(StepCompleted(id));
      } catch (e) {
        _emit(StepFailed(stepId: id, error: '$e'));
        rethrow;
      } finally {
        _currentStepKind = null;
      }
    }
    _emit(const ExecutionCompleted());
  }

  Future<void> _runStep(Map<String, dynamic> step) async {
    final kind = step['kind'] as String? ?? '';
    final id = step['id'] as String? ?? '';
    switch (kind) {
      case 'ssh_commands':
        await _runSshCommands(step);
      case 'snapshot_paths':
        await _runSnapshotPaths(step);
      case 'install_firmware':
        await _runInstallFirmware(step);
      case 'link_extras':
        await _runLinkExtras(step);
      case 'install_stack':
        await _runInstallStack(step);
      case 'apply_services':
        await _runApplyServices(step);
      case 'apply_files':
        await _runApplyFiles(step);
      case 'write_file':
        await _runWriteFile(step);
      case 'install_screen':
        await _runInstallScreen(step);
      case 'flash_mcus':
        await _runFlashMcus(step);
      case 'os_download':
        await _runOsDownload(step);
      case 'flash_disk':
        await _runFlashDisk(step);
      case 'wait_for_ssh':
        await _runWaitForSsh(step);
      case 'verify':
        await _runVerify(step);
      case 'conditional':
        await _runConditional(step);
      case 'prompt':
        await _awaitUserInput(id, step);
      case 'choose_one':
      case 'disk_picker':
        await _resolveOrAwaitInput(id, step);
      case 'script':
        await _runScript(step);
      case 'install_marker':
        await _runInstallMarker(step);
      default:
        _emit(
          StepWarning(
            stepId: id,
            message: 'Unknown step kind "$kind" - skipping',
          ),
        );
    }
  }

  Future<void> _runSshCommands(Map<String, dynamic> step) async {
    _requireSession();
    final commands = ((step['commands'] as List?) ?? const []).cast<String>();
    final ignore = step['ignore_errors'] as bool? ?? false;
    for (final cmd in commands) {
      // Substituted values (decisions, firmware fields, profile values)
      // are untrusted input reaching a shell. Render in shell-safe mode
      // so every substitution is single-quoted for its argument context.
      final rendered = _render(cmd, shellSafe: true);
      final res = await _runSsh(rendered);
      _log(step, '[ssh] $rendered -> exit ${res.exitCode}');
      if (!res.success && !ignore) {
        throw StepExecutionException(
          'Command failed: $rendered',
          stderr: res.stderr,
        );
      }
    }
  }

  Future<void> _runSnapshotPaths(Map<String, dynamic> step) async {
    _requireSession();
    final pathIds = ((step['paths'] as List?) ?? const []).cast<String>();
    final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    for (final id in pathIds) {
      final path = _profile!.stockOs.paths.firstWhere(
        (x) => x.id == id,
        orElse: () => throw StepExecutionException('path "$id" not in profile'),
      );
      final snapshotTo = (path.snapshotTo ?? '${path.path}.stock.{{timestamp}}')
          .replaceAll('{{timestamp}}', ts);
      final rendered = _render(snapshotTo);
      // Both source and destination come from untrusted profile/decision
      // values - quote every interpolation to prevent shell injection.
      final qSrc = shellSingleQuote(path.path);
      final qDst = shellSingleQuote(rendered);
      final cmd = 'if [ -e $qSrc ]; then mv $qSrc $qDst; fi';
      final res = await _runSsh(cmd);
      _log(step, '[snapshot] ${path.path} -> $rendered (exit ${res.exitCode})');
      if (!res.success) {
        throw StepExecutionException(
          'snapshot failed for ${path.path}',
          stderr: res.stderr,
        );
      }
    }
  }

  Future<void> _runInstallFirmware(Map<String, dynamic> step) async {
    _requireSession();
    final fw = _selectedFirmware();
    if (fw == null) throw StepExecutionException('no firmware selected');
    final install = fw.installPath ?? '~/klipper';
    _log(step, '[firmware] cloning ${fw.repo} @ ${fw.ref} -> $install');
    // Every profile-supplied value is untrusted input. Paths with `~`
    // need tilde-expansion, so use shellPathEscape; refs and repo URLs
    // get single-quoted.
    final qInstall = shellPathEscape(install);
    final qRef = shellSingleQuote(fw.ref);
    final qRepo = shellSingleQuote(fw.repo);
    final cloneCmd =
        'if [ -d $qInstall/.git ]; then cd $qInstall && git fetch origin && git checkout $qRef && git pull --ff-only; '
        'else rm -rf $qInstall && git clone --depth 1 -b $qRef $qRepo $qInstall; fi';
    final cloneRes = await _runSsh(
      cloneCmd,
      timeout: const Duration(minutes: 10),
    );
    if (!cloneRes.success) {
      throw StepExecutionException('clone failed', stderr: cloneRes.stderr);
    }

    final venv = fw.venvPath ?? '~/klippy-env';
    final qVenv = shellPathEscape(venv);
    final venvCmd =
        'PY=\$(command -v python3.11 || command -v python3) && \$PY -m venv $qVenv && '
        '$qVenv/bin/pip install --quiet -U pip setuptools wheel && '
        '$qVenv/bin/pip install --quiet -r $qInstall/scripts/klippy-requirements.txt';
    final venvRes = await _runSsh(
      venvCmd,
      timeout: const Duration(minutes: 15),
    );
    if (!venvRes.success) {
      throw StepExecutionException('venv setup failed', stderr: venvRes.stderr);
    }
    _log(step, '[firmware] venv ready at $venv');
  }

  Future<void> _runLinkExtras(Map<String, dynamic> step) async {
    final s = _requireSession();
    final fw = _selectedFirmware();
    if (fw == null) throw StepExecutionException('no firmware selected');
    final install = fw.installPath ?? '~/klipper';
    final sources = ((step['sources'] as List?) ?? const []).cast<String>();
    for (final src in sources) {
      final localPath = _resolveProfilePath(src);
      final basename = p.basename(localPath);
      final remote = '$install/klippy/extras/$basename';
      if (await Directory(localPath).exists()) {
        await _uploadDir(localPath, remote);
      } else {
        await ssh.upload(s, localPath, remote);
      }
      _log(step, '[link_extras] installed $basename');
    }
  }

  Future<void> _runInstallStack(Map<String, dynamic> step) async {
    _requireSession();
    final components = ((step['components'] as List?) ?? const [])
        .cast<String>();
    final stack = _profile!.stack;
    for (final c in components) {
      final name = c.replaceAll('?', '');
      final optional = c.endsWith('?');
      final cfg = _stackComponent(stack, name);
      if (cfg == null) {
        if (optional) continue;
        throw StepExecutionException('unknown stack component $name');
      }
      if (name == 'kiauh' && _state.decisions['kiauh'] == false) {
        _log(step, '[stack] kiauh skipped by user');
        continue;
      }
      final repo = cfg['repo'] as String?;
      final ref = cfg['ref'] as String? ?? 'master';
      final install = cfg['install_path'] as String?;
      if (repo != null && install != null) {
        // Every value here comes from profile YAML - untrusted.
        final qInstall = shellPathEscape(install);
        final qRef = shellSingleQuote(ref);
        final qRepo = shellSingleQuote(repo);
        final cmd =
            'if [ -d $qInstall/.git ]; then cd $qInstall && git pull --ff-only; '
            'else git clone --depth 1 -b $qRef $qRepo $qInstall; fi';
        final res = await _runSsh(cmd, timeout: const Duration(minutes: 10));
        if (!res.success) {
          throw StepExecutionException(
            '$name clone failed',
            stderr: res.stderr,
          );
        }
      }
      _log(step, '[stack] $name installed');
    }
  }

  Future<void> _runApplyServices(Map<String, dynamic> step) async {
    _requireSession();
    for (final svc in _profile!.stockOs.services) {
      final action =
          _state.decisions['service.${svc.id}'] as String? ?? svc.defaultAction;
      final unit = svc.raw['systemd_unit'] as String?;
      final proc = svc.raw['process_pattern'] as String?;
      switch (action) {
        case 'remove':
        case 'disable':
          if (unit != null) {
            // systemd_unit is profile-supplied; always quote.
            final qUnit = shellSingleQuote(unit);
            await _runSsh(
              'sudo systemctl disable --now $qUnit 2>/dev/null || true',
            );
          }
          if (proc != null) {
            // process_pattern is profile-supplied. Double-quoting is
            // not enough (it leaves $()/backticks live), so we single-
            // quote and pass to pkill -f as one argument.
            final qProc = shellSingleQuote(proc);
            await _runSsh('sudo pkill -f $qProc 2>/dev/null || true');
          }
          _log(step, '[services] ${svc.id}: disabled');
        case 'stub':
          _log(step, '[services] ${svc.id}: left as stub');
        default:
          _log(step, '[services] ${svc.id}: keeping');
      }
    }
  }

  Future<void> _runApplyFiles(Map<String, dynamic> step) async {
    _requireSession();
    for (final f in _profile!.stockOs.files) {
      final decision =
          _state.decisions['file.${f.id}'] as String? ?? f.defaultAction;
      if (decision != 'delete') continue;
      for (final path in f.paths) {
        if (_isDangerousPath(path)) {
          _log(step, '[files] SKIPPING dangerous path: $path');
          continue;
        }
        final String cmd;
        if (_hasGlob(path)) {
          // Glob path: `find <dir> -maxdepth 1 -name <pattern> -delete`
          // handles the expansion itself (so the shell doesn't need to)
          // and cleanly no-ops when the pattern matches nothing. Only
          // the trailing segment is allowed to contain wildcards; the
          // parent directory must be a concrete path so we refuse to
          // recurse into anything unexpected.
          final dir = p.posix.dirname(path);
          final pattern = p.posix.basename(path);
          if (_hasGlob(dir) || _isDangerousPath(dir)) {
            _log(step, '[files] SKIPPING unsafe glob directory: $dir');
            continue;
          }
          cmd =
              'sudo find ${_shellQuote(dir)} -maxdepth 1 -name ${_shellQuote(pattern)} -print -exec rm -rf {} +';
        } else {
          cmd = 'sudo rm -rf ${_shellQuote(path)}';
        }
        final res = await _runSsh(cmd);
        _log(step, '[files] rm ${f.id}: $path (exit ${res.exitCode})');
        if (res.stdout.trim().isNotEmpty) {
          for (final line in res.stdout.trim().split('\n')) {
            _log(step, '[files]   removed: $line');
          }
        }
      }
    }
  }

  bool _hasGlob(String path) => RegExp(r'[*?\[]').hasMatch(path);

  /// write_file step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runWriteFile(Map<String, dynamic> step) =>
      _runWriteFileImpl(this, step);

  bool _looksLikeSystemPath(SshSession s, String target) {
    // Anything under the login user's home (and /tmp) is writable
    // without elevation; everything else we assume needs sudo.
    if (target.startsWith('/home/${s.user}/')) return false;
    // root's home is /root on every distro Deckhand targets; the
    // generic /home/<user>/ check misses it otherwise.
    if (s.user == 'root' && target.startsWith('/root/')) return false;
    if (target.startsWith('/tmp/')) return false;
    return true;
  }

  /// install_screen step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runInstallScreen(Map<String, dynamic> step) =>
      _runInstallScreenImpl(this, step);

  /// flash_mcus step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runFlashMcus(Map<String, dynamic> step) =>
      _runFlashMcusImpl(this, step);

  /// os_download step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runOsDownload(Map<String, dynamic> step) =>
      _runOsDownloadImpl(this, step);

  /// flash_disk step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runFlashDisk(Map<String, dynamic> step) =>
      _runFlashDiskImpl(this, step);

  /// script step dispatcher. Body in wizard_controller_steps.dart.
  Future<void> _runScript(Map<String, dynamic> step) =>
      _runScriptImpl(this, step);

  /// Writes `~/printer_data/config/<filename>` (default `deckhand.json`)
  /// so the connect screen can recognise this printer as one Deckhand
  /// has already processed - even after the user strips out the stock
  /// vendor artefacts (`phrozen_dev`, MKS bloat, etc.) we were keying
  /// on before. Moonraker serves the file under the `config` root, so
  /// no Klipper restart or printer.cfg surgery is needed.
  Future<void> _runInstallMarker(Map<String, dynamic> step) async {
    _requireSession();
    final pf = _profile;
    if (pf == null) throw StepExecutionException('no profile loaded');
    final filename = step['filename'] as String? ?? 'deckhand.json';
    final targetDir =
        step['target_dir'] as String? ??
        '/home/${_session!.user}/printer_data/config';
    final extra = (step['extra'] as Map?)?.cast<String, dynamic>() ?? const {};

    final payload = <String, dynamic>{
      'profile_id': pf.id,
      'profile_version': pf.version,
      'display_name': pf.displayName,
      'installed_at': DateTime.now().toUtc().toIso8601String(),
      'deckhand_schema': 1,
      ...extra,
    };
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    final target = '$targetDir/$filename';

    // Ensure the config dir exists (fresh installs may not have laid
    // out printer_data yet). Use plain ssh.run, not _runSsh - we don't
    // want sudo wrapping.
    final mkdir = await ssh.run(_requireSession(), 'mkdir -p ${_shellQuote(targetDir)}');
    if (!mkdir.success) {
      throw StepExecutionException(
        'could not create $targetDir',
        stderr: mkdir.stderr,
      );
    }

    // Route through _runWriteFile so `deckhand.json` gets the same
    // auto-backup + metadata-sidecar treatment as every other
    // destructive write. Users who hand-edited the marker (to add
    // notes, pin a specific deckhand_schema, etc.) get a byte-exact
    // rollback.
    final syntheticStep = <String, dynamic>{
      'id': step['id'] as String? ?? 'install_marker',
      'kind': 'write_file',
      'target': target,
      'content': json,
      'mode': '0644',
      'backup': step['backup'] as bool? ?? true,
    };
    await _runWriteFile(syntheticStep);
    _log(step, '[marker] wrote $target (${json.length} bytes)');
  }

  /// For `choose_one` / `disk_picker` steps: if a pre-wizard screen
  /// already recorded the decision, emit the resolution and move on;
  /// otherwise fall back to awaiting user input.
  Future<void> _resolveOrAwaitInput(
    String id,
    Map<String, dynamic> step,
  ) async {
    final existing = _lookupExistingDecision(step);
    if (existing != null) {
      _log(step, '[input] using existing decision: $existing');
      _emit(DecisionRecorded(path: id, value: existing));
      return;
    }
    await _awaitUserInput(id, step);
  }

  /// Checks known decision keys that may already hold the answer for
  /// this step. Keeps the controller in sync with the pre-wizard
  /// screens (flash_target_screen, choose_os_screen) without hardcoding
  /// their step ids in the profile.
  Object? _lookupExistingDecision(Map<String, dynamic> step) {
    final kind = step['kind'] as String? ?? '';
    final optionsFrom = step['options_from'] as String?;
    final id = step['id'] as String? ?? '';

    // Most specific first: step id.
    final byId = _state.decisions[id];
    if (byId != null) return byId;

    if (kind == 'disk_picker') {
      return _state.decisions['flash.disk'];
    }
    if (kind == 'choose_one' && optionsFrom == 'os.fresh_install_options') {
      return _state.decisions['flash.os'];
    }
    return null;
  }

  Future<void> _runWaitForSsh(Map<String, dynamic> step) async {
    final host = _state.sshHost;
    if (host == null) throw StepExecutionException('no ssh host set');
    final timeoutSecs = (step['timeout_seconds'] as num?)?.toInt() ?? 600;
    final ok = await discovery.waitForSsh(
      host: host,
      timeout: Duration(seconds: timeoutSecs),
    );
    if (!ok)
      throw StepExecutionException(
        'ssh did not come up within $timeoutSecs seconds',
      );
    _log(step, '[ssh] up at $host');
  }

  Future<void> _runVerify(Map<String, dynamic> step) async {
    final s = _requireSession();
    for (final v in _profile!.verifiers) {
      final kind = v.raw['kind'] as String? ?? '';
      switch (kind) {
        case 'ssh_command':
          final cmd = v.raw['command'] as String;
          // Verifiers are supposed to be read-only checks. If a
          // profile author writes `sudo foo` inside a verify step,
          // that is either a mistake or a privilege-escalation
          // sneaking in through the back door - neither is what we
          // want. Run via ssh.run directly (no sudo-injection strip)
          // so any `sudo` inside the command prompts for a password
          // and fails fast, rather than silently picking up the
          // cached session password.
          final res = await ssh.run(s, cmd);
          final contains = v.raw['expect_stdout_contains'] as String?;
          final equals = v.raw['expect_stdout_equals'] as String?;
          var passed = res.success;
          if (contains != null)
            passed = passed && res.stdout.contains(contains);
          if (equals != null)
            passed = passed && res.stdout.trim() == equals.trim();
          _log(step, '[verify] ${v.id}: ${passed ? "PASS" : "FAIL"}');
          if (!passed && !(v.raw['optional'] as bool? ?? false)) {
            throw StepExecutionException('verifier ${v.id} failed');
          }
        case 'http_get':
          final host = _state.sshHost;
          if (host == null) {
            _log(step, '[verify] ${v.id}: no host - skipping');
            continue;
          }
          final url = (v.raw['url'] as String? ?? '').replaceAll(
            '{{host}}',
            host,
          );
          try {
            final info = await moonraker.info(host: host);
            _log(
              step,
              '[verify] ${v.id}: $url → klippy_state=${info.klippyState}',
            );
          } catch (e) {
            _log(step, '[verify] ${v.id}: $e');
            if (!(v.raw['optional'] as bool? ?? false)) {
              throw StepExecutionException('verifier ${v.id} failed: $e');
            }
          }
        case 'moonraker_gcode':
          _log(step, '[verify] ${v.id}: moonraker_gcode not yet wired');
        default:
          _log(step, '[verify] ${v.id}: unknown kind $kind');
      }
    }
  }

  Future<void> _runConditional(Map<String, dynamic> step) async {
    final when = step['when'] as String?;
    if (when == null) return;
    final env = _buildDslEnv();
    final matches = _dsl.evaluate(when, env);
    if (!matches) {
      _log(step, '[conditional] skipping - condition false');
      return;
    }
    final thenSteps = ((step['then'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    for (final sub in thenSteps) {
      await _runStep(sub.cast<String, dynamic>());
    }
  }

  Future<Object?> _awaitUserInput(String id, Map<String, dynamic> step) async {
    final completer = Completer<Object?>();
    _pendingInput[id] = completer;
    _emit(UserInputRequired(stepId: id, step: step));
    return completer.future;
  }

  /// Runs [command] over SSH. If [command] starts with `sudo`,
  /// `/usr/bin/sudo`, or `/bin/sudo` and we have a cached password
  /// for the session, strips that sudo word and delegates to
  /// [SshService.run] with `sudoPassword`. The SshService then wraps
  /// in `echo <pw> | sudo -S ...`, so sudo reads the password on stdin
  /// without needing a pty.
  ///
  /// Commands that START with a `KEY=value` env assignment (e.g. the
  /// askpass-wrapped `SUDO_ASKPASS=... sudo -A -E ...` form built by
  /// `_runScript`) are intentionally NOT stripped: we already routed
  /// auth through askpass, and combining `-S` with `-A` varies by sudo
  /// version. Anything without a sudo at position zero runs as-is.
  Future<SshCommandResult> _runSsh(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final s = _requireSession();
    final stripped = _stripSudoPrefix(command);
    if (stripped != null && _sshPassword != null) {
      return ssh.run(
        s,
        stripped,
        timeout: timeout,
        sudoPassword: _sshPassword,
      );
    }
    return ssh.run(s, command, timeout: timeout);
  }

  /// Returns the command with the `sudo` token removed if [command]
  /// begins with sudo / /usr/bin/sudo / /bin/sudo. Returns null for
  /// everything else (subshells, env-prefixed commands, commands that
  /// start with any other word).
  ///
  /// Compound commands (`sudo X && rm Y`, `sudo X | grep Y`) are
  /// matched - the outer `sudo -S` replacement still produces the
  /// right behaviour because we only authenticate sudo and let the
  /// rest of the shell line run unchanged.
  String? _stripSudoPrefix(String command) {
    final m = RegExp(
      r'^(?<sudo>sudo|/usr/bin/sudo|/bin/sudo)(?:\s+(?<rest>.*))?$',
    ).firstMatch(command);
    if (m == null) return null;
    return m.namedGroup('rest') ?? '';
  }

  SshSession _requireSession() {
    final s = _session;
    if (s == null) throw StepExecutionException('SSH not connected');
    return s;
  }

  FirmwareChoice? _selectedFirmware() {
    final id = _state.decisions['firmware'] as String?;
    if (id == null) return null;
    for (final c in _profile?.firmware.choices ?? const <FirmwareChoice>[]) {
      if (c.id == id) return c;
    }
    return null;
  }

  Map<String, dynamic>? _stackComponent(StackConfig stack, String name) {
    switch (name) {
      case 'moonraker':
        return stack.moonraker;
      case 'kiauh':
        return stack.kiauh;
      case 'crowsnest':
        return stack.crowsnest;
      default:
        final choices = ((stack.webui?['choices'] as List?) ?? const [])
            .cast<Map>();
        for (final c in choices) {
          if ((c['id'] as String?) == name) return c.cast<String, dynamic>();
        }
        return null;
    }
  }

  /// Turn a profile-declared relative path into an absolute local path.
  ///
  /// Three conventions, in priority order:
  ///   - absolute (`/etc/foo`): returned as-is.
  ///   - profile-local (`./scripts/foo.sh`): resolved against the
  ///     profile's directory (where profile.yaml lives).
  ///   - repo-root-relative (`shared/scripts/build-python.sh`): resolved
  ///     against the deckhand-builds repo root. Profile dirs live at
  ///     `<root>/printers/<id>/`, so the repo root is two levels up.
  ///
  /// Bare paths without a prefix default to profile-local (the legacy
  /// behaviour) - add `./` for new profiles to make the intent loud.
  String _resolveProfilePath(String ref) {
    final profileDir = _profileCache?.localPath ?? '.';
    if (ref.startsWith('/')) return ref;
    if (ref.startsWith('./')) return p.join(profileDir, ref.substring(2));
    // `shared/` is the repo-level tree of scripts and templates reused
    // across printers. Resolve it against the repo root.
    if (ref.startsWith('shared/') || ref.startsWith('shared\\')) {
      final repoRoot = p.dirname(p.dirname(profileDir));
      return p.join(repoRoot, ref);
    }
    return p.join(profileDir, ref);
  }

  Future<void> _uploadDir(String localDir, String remote) async {
    final s = _requireSession();
    final tmpTar = p.join(
      Directory.systemTemp.path,
      'deckhand-upload-${DateTime.now().millisecondsSinceEpoch}.tar',
    );
    final result = await Process.run('tar', [
      '-cf',
      tmpTar,
      '-C',
      p.dirname(localDir),
      p.basename(localDir),
    ]);
    if (result.exitCode != 0) {
      throw StepExecutionException('local tar failed: ${result.stderr}');
    }
    try {
      final remoteTar =
          '/tmp/deckhand-upload-${DateTime.now().millisecondsSinceEpoch}.tar';
      await ssh.upload(s, tmpTar, remoteTar);
      final extract =
          'mkdir -p "$remote" && tar -xf "$remoteTar" -C "\$(dirname "$remote")" && rm -f "$remoteTar"';
      final res = await _runSsh(extract);
      if (!res.success) {
        throw StepExecutionException(
          'remote extract failed',
          stderr: res.stderr,
        );
      }
    } finally {
      try {
        await File(tmpTar).delete();
      } catch (_) {}
    }
  }

  String _mcuConfig(Map<String, dynamic> mcu) {
    final chip = mcu['chip'] as String? ?? '';
    final clock = mcu['clock_hz'] as num? ?? 0;
    final clockRef = mcu['clock_ref_hz'] as num? ?? 0;
    final flashOffset = mcu['application_offset'] as String? ?? '';
    final transport = (mcu['transport'] as Map?)?.cast<String, dynamic>() ?? {};
    final selectKey = transport['select'] as String? ?? '';
    final baud = transport['baud'] as num?;
    final lines = [
      'CONFIG_MACH_STM32=y',
      'CONFIG_MCU="$chip"',
      'CONFIG_CLOCK_FREQ=$clock',
      'CONFIG_CLOCK_REF_FREQ=$clockRef',
      if (flashOffset.isNotEmpty)
        'CONFIG_FLASH_APPLICATION_ADDRESS=$flashOffset',
      'CONFIG_${selectKey.toUpperCase()}=y',
      if (baud != null) 'CONFIG_SERIAL_BAUD=$baud',
    ];
    return lines.join('\n');
  }

  bool _isDangerousPath(String path) {
    const dangerous = {
      '/',
      '/bin',
      '/boot',
      '/etc',
      '/home',
      '/lib',
      '/lib64',
      '/opt',
      '/root',
      '/run',
      '/sbin',
      '/srv',
      '/sys',
      '/usr',
      '/var',
    };
    return dangerous.contains(path);
  }

  /// Deprecated - use the canonical [shellSingleQuote] from deckhand_core.
  /// Kept as a thin shim while callers migrate off.
  String _shellQuote(String s) => shellSingleQuote(s);

  /// 16 hex chars from Random.secure(). Good enough to make a `/tmp`
  /// path unguessable for the duration of a session; cheaper than
  /// pulling a uuid package for a single call site.
  String _randomSuffix() {
    final rng = Random.secure();
    final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Build a `VAR=value VAR2=value2 ` prefix for a script step's
  /// `env:` map. Keys MUST match `[A-Za-z_][A-Za-z0-9_]*` (the POSIX
  /// shell identifier grammar) so a profile cannot inject shell syntax
  /// through a key name; values are single-quoted regardless of
  /// content.
  String _buildEnvPrefix(Object? rawEnv) {
    if (rawEnv == null) return '';
    if (rawEnv is! Map) {
      throw StepExecutionException(
        'script step `env:` must be a map, got ${rawEnv.runtimeType}',
      );
    }
    final validKey = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    final buf = StringBuffer();
    rawEnv.forEach((k, v) {
      final key = '$k';
      if (!validKey.hasMatch(key)) {
        throw StepExecutionException(
          'env key "$key" is not a valid shell identifier',
        );
      }
      buf
        ..write(key)
        ..write('=')
        ..write(shellSingleQuote('${v ?? ''}'))
        ..write(' ');
    });
    return buf.toString();
  }

  /// Expand `{{...}}` templates in [template].
  ///
  /// When [shellSafe] is true every substituted value is wrapped with
  /// [shellSingleQuote] (or [shellPathEscape] for known-path keys) so
  /// the result can be safely passed to a shell. The `{{timestamp}}`
  /// value is always safe and needs no quoting.
  String _render(String template, {bool shellSafe = false}) {
    String q(String v, {bool isPath = false}) {
      if (!shellSafe) return v;
      return isPath ? shellPathEscape(v) : shellSingleQuote(v);
    }

    return template.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) {
      final key = m.group(1)!.trim();
      if (key == 'timestamp') {
        // Deterministic and safe - no shell metacharacters possible.
        return DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
      }
      if (key.startsWith('decisions.')) {
        final v = '${_state.decisions[key.substring('decisions.'.length)] ?? ''}';
        return q(v);
      }
      if (key.startsWith('profile.')) {
        final v = '${_profile?.raw[key.substring('profile.'.length)] ?? ''}';
        return q(v);
      }
      if (key.startsWith('firmware.')) {
        final fw = _selectedFirmware();
        if (fw == null) return q('');
        switch (key) {
          case 'firmware.install_path':
            return q(fw.installPath ?? '', isPath: true);
          case 'firmware.venv_path':
            return q(fw.venvPath ?? '', isPath: true);
          case 'firmware.id':
            return q(fw.id);
          case 'firmware.ref':
            return q(fw.ref);
          case 'firmware.repo':
            return q(fw.repo);
        }
      }
      return m.group(0)!;
    });
  }

  void _log(Map<String, dynamic> step, String line) {
    _emit(StepLog(stepId: step['id'] as String? ?? '', line: line));
  }

  void _emit(WizardEvent e) => _eventsController.add(e);

  Future<void> dispose() async {
    // Scrub the session askpass helper *before* tearing down the SSH
    // session so the password file doesn't linger on /tmp until the
    // next reboot. Best-effort: a broken connection here shouldn't
    // break disposal.
    final helper = _sessionAskpass;
    final session = _session;
    if (helper != null && session != null) {
      try {
        await ssh.run(
          session,
          'rm -rf '
          '${_shellQuote(helper.askpassPath)} '
          '${_shellQuote(helper.binDir)}',
        );
      } catch (_) {}
      _sessionAskpass = null;
    }
    await _eventsController.close();
    if (_session != null) await ssh.disconnect(_session!);
    // Overwrite then drop the cached SSH password so the GC has no
    // reason to hold onto its backing string. Dart strings are
    // immutable so this is a best-effort hint, not a guarantee.
    _sshPassword = null;
    _session = null;
    _pendingInput.clear();
  }
}

/// Paths to transient sudo helper assets a script step staged on the
/// remote printer. Returned from [_installSudoAskpassHelper] so the
/// caller's `finally` block can clean them up again.
class _ScriptSudoHelper {
  const _ScriptSudoHelper({required this.askpassPath, required this.binDir});
  final String askpassPath;
  final String binDir;
}

class WizardState {
  const WizardState({
    required this.profileId,
    required this.decisions,
    required this.currentStep,
    required this.flow,
    this.sshHost,
  });

  factory WizardState.initial() => const WizardState(
    profileId: '',
    decisions: {},
    currentStep: 'welcome',
    flow: WizardFlow.none,
  );

  final String profileId;
  final Map<String, Object> decisions;
  final String currentStep;
  final WizardFlow flow;
  final String? sshHost;

  WizardState copyWith({
    String? profileId,
    Map<String, Object>? decisions,
    String? currentStep,
    WizardFlow? flow,
    String? sshHost,
  }) => WizardState(
    profileId: profileId ?? this.profileId,
    decisions: decisions ?? this.decisions,
    currentStep: currentStep ?? this.currentStep,
    flow: flow ?? this.flow,
    sshHost: sshHost ?? this.sshHost,
  );
}

class StepExecutionException implements Exception {
  StepExecutionException(this.message, {this.stderr});
  final String message;
  final String? stderr;
  @override
  String toString() =>
      'StepExecutionException: $message${stderr != null && stderr!.isNotEmpty ? "\n$stderr" : ""}';
}

sealed class WizardEvent {
  const WizardEvent();
}

class ProfileLoaded extends WizardEvent {
  const ProfileLoaded(this.profile);
  final PrinterProfile profile;
}

class SshConnected extends WizardEvent {
  const SshConnected({required this.host, required this.user});
  final String host;
  final String user;
}

class DecisionRecorded extends WizardEvent {
  const DecisionRecorded({required this.path, required this.value});
  final String path;
  final Object value;
}

class FlowChanged extends WizardEvent {
  const FlowChanged(this.flow);
  final WizardFlow flow;
}

class StepStarted extends WizardEvent {
  const StepStarted(this.stepId);
  final String stepId;
}

class StepProgress extends WizardEvent {
  const StepProgress({
    required this.stepId,
    required this.percent,
    this.message,
  });
  final String stepId;
  final double percent;
  final String? message;
}

class StepLog extends WizardEvent {
  const StepLog({required this.stepId, required this.line});
  final String stepId;
  final String line;
}

class StepCompleted extends WizardEvent {
  const StepCompleted(this.stepId);
  final String stepId;
}

class StepFailed extends WizardEvent {
  const StepFailed({required this.stepId, required this.error});
  final String stepId;
  final String error;
}

class StepWarning extends WizardEvent {
  const StepWarning({required this.stepId, required this.message});
  final String stepId;
  final String message;
}

class UserInputRequired extends WizardEvent {
  const UserInputRequired({required this.stepId, required this.step});
  final String stepId;
  final Map<String, dynamic> step;
}

class ExecutionCompleted extends WizardEvent {
  const ExecutionCompleted();
}

/// Emitted once the state probe lands fresh data. Screens watching
/// `wizardStateProvider` rebuild on this (via the generic stream)
/// and re-render with machine-specific state applied.
class PrinterStateRefreshed extends WizardEvent {
  const PrinterStateRefreshed(this.state);
  final PrinterState state;
}
