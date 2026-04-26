/// Which high-level flow the wizard is running.
///
/// `none` — user hasn't picked yet (welcome / pick-printer / connect).
/// `stockKeep` — install on top of vendor OS, preserving partitions.
/// `freshFlash` — wipe + reinstall to a clean OS image.
enum WizardFlow { none, stockKeep, freshFlash }
