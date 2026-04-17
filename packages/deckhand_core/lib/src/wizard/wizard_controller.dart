/// Wizard state machine — profile-driven, UI-agnostic.
///
/// The UI binds to [events] and issues commands through the controller's
/// public methods. Decisions accumulate in [state] until the user starts
/// execution.
class WizardController {
  WizardController();

  final List<WizardEvent> _buffered = [];
  WizardState _state = WizardState.initial();

  WizardState get state => _state;
  Stream<WizardEvent> get events => const Stream.empty();

  Future<void> loadProfile(String profileId) async {
    // Stub. Real implementation in the full scaffolding pass.
    _state = _state.copyWith(profileId: profileId);
  }

  Future<void> setDecision(String path, Object value) async {
    final updated = Map<String, Object>.from(_state.decisions);
    updated[path] = value;
    _state = _state.copyWith(decisions: updated);
  }

  T? decision<T>(String path) => _state.decisions[path] as T?;

  Future<void> startExecution() async {
    // Stub. Real implementation streams steps through [events].
  }
}

class WizardState {
  const WizardState({required this.profileId, required this.decisions, required this.currentStep});

  factory WizardState.initial() => const WizardState(profileId: '', decisions: {}, currentStep: 'welcome');

  final String profileId;
  final Map<String, Object> decisions;
  final String currentStep;

  WizardState copyWith({String? profileId, Map<String, Object>? decisions, String? currentStep}) =>
      WizardState(
        profileId: profileId ?? this.profileId,
        decisions: decisions ?? this.decisions,
        currentStep: currentStep ?? this.currentStep,
      );
}

sealed class WizardEvent {
  const WizardEvent();
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

class StepCompleted extends WizardEvent {
  const StepCompleted(this.stepId);
  final String stepId;
}

class StepFailed extends WizardEvent {
  const StepFailed({required this.stepId, required this.error});
  final String stepId;
  final String error;
}
