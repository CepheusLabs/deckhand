import 'dart:async';

import '../models/printer_profile.dart';
import '../services/profile_service.dart';
import '../services/ssh_service.dart';
import '../services/flash_service.dart';
import '../services/discovery_service.dart';
import '../services/moonraker_service.dart';
import '../services/upstream_service.dart';
import '../services/security_service.dart';
import 'dsl.dart';

/// Which high-level flow the wizard is running.
enum WizardFlow { none, stockKeep, freshFlash }

/// Wizard state machine — profile-driven, UI-agnostic.
///
/// The UI binds to [events] and makes decisions through the controller's
/// public methods. Decisions accumulate in [state] until the user starts
/// execution.
class WizardController {
  WizardController({
    required this.profiles,
    required this.ssh,
    required this.flash,
    required this.discovery,
    required this.moonraker,
    required this.upstream,
    required this.security,
  });

  final ProfileService profiles;
  final SshService ssh;
  final FlashService flash;
  final DiscoveryService discovery;
  final MoonrakerService moonraker;
  final UpstreamService upstream;
  final SecurityService security;

  late final DslEvaluator _dsl = DslEvaluator(defaultPredicates());
  final _eventsController = StreamController<WizardEvent>.broadcast();
  PrinterProfile? _profile;
  SshSession? _session;
  var _state = WizardState.initial();

  WizardState get state => _state;
  PrinterProfile? get profile => _profile;
  Stream<WizardEvent> get events => _eventsController.stream;

  // -------------------------------------------------------------
  // Profile selection

  Future<void> loadProfile(String profileId, {String? ref}) async {
    final cache = await profiles.ensureCached(profileId: profileId, ref: ref);
    final profile = await profiles.load(cache);
    _profile = profile;
    _state = _state.copyWith(profileId: profileId);
    _emit(ProfileLoaded(profile));
  }

  // -------------------------------------------------------------
  // SSH

  Future<void> connectSsh({required String host, int? port}) async {
    final p = _profile;
    if (p == null) {
      throw StateError('Load a profile before connecting SSH.');
    }
    final creds = p.ssh.defaultCredentials
        .map((c) => PasswordCredential(user: c.user, password: c.password ?? ''))
        .toList();
    final session = await ssh.tryDefaults(
      host: host,
      port: port ?? p.ssh.defaultPort,
      credentials: creds.cast<SshCredential>(),
    );
    _session = session;
    _state = _state.copyWith(sshHost: host);
    _emit(SshConnected(host: host, user: session.user));
  }

  // -------------------------------------------------------------
  // Decisions

  Future<void> setDecision(String path, Object value) async {
    final updated = Map<String, Object>.from(_state.decisions);
    updated[path] = value;
    _state = _state.copyWith(decisions: updated);
    _emit(DecisionRecorded(path: path, value: value));
  }

  T? decision<T>(String path) => _state.decisions[path] as T?;

  /// Resolve the default action for a given service entry by evaluating
  /// its `default_rules` (DSL expressions) in order; the first match wins.
  /// Falls back to the `default_action` field if nothing matches.
  String resolveServiceDefault(StockService svc) {
    final rules = ((svc.raw['wizard'] as Map?)?['default_rules'] as List?) ?? const [];
    final env = DslEnv(
      decisions: _state.decisions,
      profile: _profile?.raw ?? const {},
    );
    for (final r in rules.whereType<Map>().map((m) => m.cast<String, dynamic>())) {
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

  // -------------------------------------------------------------
  // Flow

  void setFlow(WizardFlow flow) {
    _state = _state.copyWith(flow: flow);
    _emit(FlowChanged(flow));
  }

  /// Execute the currently-selected flow. Emits step events as each step
  /// starts / reports progress / completes.
  Future<void> startExecution() async {
    final p = _profile;
    if (p == null) throw StateError('No profile loaded.');
    final flow = _state.flow == WizardFlow.stockKeep
        ? p.flows.stockKeep
        : p.flows.freshFlash;
    if (flow == null || !flow.enabled) {
      throw StateError('Flow ${_state.flow} is not enabled for this profile.');
    }

    for (final step in flow.steps) {
      final id = step['id'] as String? ?? 'unnamed';
      _emit(StepStarted(id));
      try {
        await _runStep(step);
        _emit(StepCompleted(id));
      } catch (e) {
        _emit(StepFailed(stepId: id, error: '$e'));
        rethrow;
      }
    }
    _emit(const ExecutionCompleted());
  }

  Future<void> _runStep(Map<String, dynamic> step) async {
    final kind = step['kind'] as String? ?? '';
    switch (kind) {
      case 'ssh_commands':
        await _runSshCommands(step);
      case 'prompt':
      case 'conditional':
      case 'snapshot_paths':
      case 'install_firmware':
      case 'link_extras':
      case 'install_stack':
      case 'apply_services':
      case 'apply_files':
      case 'write_file':
      case 'install_screen':
      case 'flash_mcus':
      case 'os_download':
      case 'flash_disk':
      case 'wait_for_ssh':
      case 'verify':
      case 'disk_picker':
      case 'choose_one':
        // Step kinds that are either UI-driven or still wiring up
        // concrete execution. The wizard-controller-level runner emits
        // a StepCompleted immediately so the UI can show "ok, next" and
        // the specific step runner can take over in a follow-up.
        break;
      default:
        // Unknown step kind — emit a warning event so the UI can surface
        // it without aborting the flow.
        _emit(StepWarning(
          stepId: step['id'] as String? ?? '',
          message: 'Unknown step kind "$kind" — skipping',
        ));
    }
  }

  Future<void> _runSshCommands(Map<String, dynamic> step) async {
    final s = _session;
    if (s == null) throw StateError('SSH not connected; cannot run step.');
    final commands = ((step['commands'] as List?) ?? const []).cast<String>();
    for (final cmd in commands) {
      final res = await ssh.run(s, cmd);
      _emit(StepLog(
        stepId: step['id'] as String? ?? '',
        line: '[ssh] $cmd → exit ${res.exitCode}',
      ));
      if (!res.success && !(step['ignore_errors'] as bool? ?? false)) {
        throw StateError('Command failed: $cmd — ${res.stderr.trim()}');
      }
    }
  }

  void _emit(WizardEvent e) => _eventsController.add(e);

  Future<void> dispose() async {
    await _eventsController.close();
    if (_session != null) await ssh.disconnect(_session!);
  }
}

// -----------------------------------------------------------------

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
  }) =>
      WizardState(
        profileId: profileId ?? this.profileId,
        decisions: decisions ?? this.decisions,
        currentStep: currentStep ?? this.currentStep,
        flow: flow ?? this.flow,
        sshHost: sshHost ?? this.sshHost,
      );
}

// -----------------------------------------------------------------
// Events

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
  const StepProgress({required this.stepId, required this.percent, this.message});
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

class ExecutionCompleted extends WizardEvent {
  const ExecutionCompleted();
}
