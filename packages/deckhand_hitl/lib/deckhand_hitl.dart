/// Public surface of the Deckhand HITL driver.
///
/// **Intentionally narrow.** The headless security/discovery/
/// moonraker stubs that the runner uses internally are NOT
/// exported — they auto-approve every host the wizard asks about,
/// which is correct for a controlled CI rig and devastating in any
/// production context. A future caller that imports them by mistake
/// would silently bypass the user-facing trust prompts.
///
/// If you genuinely need the headless services for a non-CI tool
/// (e.g. an integration test in a downstream repo), import the
/// `src/` path explicitly via
/// `package:deckhand_hitl/src/headless_services.dart` so the choice
/// is loud at the import site.
library;

export 'src/scenario.dart';
export 'src/scenario_runner.dart'
    show ScenarioRunner, RunReport, AssertionResult, Logger, flattenDecisions;
