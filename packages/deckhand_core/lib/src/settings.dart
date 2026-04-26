import 'dart:convert';
import 'dart:io';

/// User preferences persisted to `settings.json` in Deckhand's data dir.
/// Schema is intentionally loose (JSON-backed) - we'll tighten as
/// real settings land.
class DeckhandSettings {
  DeckhandSettings({required this.path, Map<String, dynamic>? initial})
    : _values = Map.of(initial ?? const {});

  final String path;
  final Map<String, dynamic> _values;

  static Future<DeckhandSettings> load(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return DeckhandSettings(path: path);
    }
    try {
      final text = await file.readAsString();
      final json = jsonDecode(text);
      return DeckhandSettings(
        path: path,
        initial: (json as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return DeckhandSettings(path: path);
    }
  }

  T? get<T>(String key, [T? fallback]) {
    final v = _values[key];
    if (v is T) return v;
    return fallback;
  }

  void set<T>(String key, T value) {
    _values[key] = value;
  }

  Set<String> get allowedHosts {
    final raw = _values['allowed_hosts'];
    if (raw is List) return raw.cast<String>().toSet();
    return <String>{};
  }

  set allowedHosts(Set<String> hosts) {
    _values['allowed_hosts'] = hosts.toList();
  }

  bool get showStubProfiles => _values['show_stub_profiles'] == true;
  set showStubProfiles(bool v) => _values['show_stub_profiles'] = v;

  bool get useEdgeProfileChannel => _values['use_edge_profile_channel'] == true;
  set useEdgeProfileChannel(bool v) => _values['use_edge_profile_channel'] = v;

  /// Absolute path to a locally-checked-out copy of `deckhand-profiles`.
  /// When set, the profile service reads profiles from this directory
  /// instead of fetching them from GitHub. Useful for profile authoring.
  /// Null / empty string means "fetch from GitHub".
  String? get localProfilesDir {
    final v = _values['local_profiles_dir'];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }
  set localProfilesDir(String? v) {
    if (v == null || v.trim().isEmpty) {
      _values.remove('local_profiles_dir');
    } else {
      _values['local_profiles_dir'] = v.trim();
    }
  }

  /// How many days old a `.deckhand-pre-*` backup has to be before the
  /// Verify screen's "Prune" action removes it. Default 30.
  int get pruneOlderThanDays {
    final v = _values['prune_older_than_days'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 30;
  }
  set pruneOlderThanDays(int v) =>
      _values['prune_older_than_days'] = v < 1 ? 1 : v;

  /// When true, prune leaves the newest snapshot per target alone even
  /// if it's old enough to remove, so a catastrophic mistake always
  /// has at least one rollback path.
  bool get pruneKeepNewestPerTarget {
    final v = _values['prune_keep_newest_per_target'];
    return v is bool ? v : true; // default: safe (keep one)
  }
  set pruneKeepNewestPerTarget(bool v) =>
      _values['prune_keep_newest_per_target'] = v;

  /// Dry-run mode. When enabled, every destructive side effect is
  /// logged but not executed: disk writes, remote `sudo` commands,
  /// file mutations, firmware fetches. The wizard still walks the
  /// user through the full flow so authors can test a profile against
  /// a real printer without risk.
  ///
  /// Exposed as a setting (not just an env var) so QA can leave it on
  /// by default on a bring-up laptop.
  bool get dryRun {
    final v = _values['dry_run'];
    return v is bool ? v : false;
  }
  set dryRun(bool v) => _values['dry_run'] = v;

  /// Preferred UI locale as a BCP-47 code (e.g. `en`, `es`). Null
  /// means "follow the OS locale, falling back to English". The
  /// settings screen exposes a picker; main.dart applies the choice
  /// before runApp via Slang's `LocaleSettings.setLocale`.
  String? get preferredLocale {
    final v = _values['preferred_locale'];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }
  set preferredLocale(String? v) {
    if (v == null || v.trim().isEmpty) {
      _values.remove('preferred_locale');
    } else {
      _values['preferred_locale'] = v.trim();
    }
  }

  /// Last window geometry — width, height, x, y. Persisted on every
  /// move/resize so the next launch lands on the same monitor and
  /// size the user left it on. Returns null when no previous launch
  /// has saved one.
  WindowGeometry? get windowGeometry {
    final raw = _values['window_geometry'];
    if (raw is! Map) return null;
    final width = (raw['width'] as num?)?.toDouble();
    final height = (raw['height'] as num?)?.toDouble();
    final x = (raw['x'] as num?)?.toDouble();
    final y = (raw['y'] as num?)?.toDouble();
    if (width == null || height == null) return null;
    return WindowGeometry(width: width, height: height, x: x, y: y);
  }
  set windowGeometry(WindowGeometry? g) {
    if (g == null) {
      _values.remove('window_geometry');
      return;
    }
    _values['window_geometry'] = <String, dynamic>{
      'width': g.width,
      'height': g.height,
      if (g.x != null) 'x': g.x,
      if (g.y != null) 'y': g.y,
    };
  }

  Future<void> save() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_values),
    );
  }
}

/// Persistent window size + position. `x`/`y` are nullable so a
/// first-time saver that knows size but not position (which the
/// platform may not expose) can still record something useful.
class WindowGeometry {
  const WindowGeometry({
    required this.width,
    required this.height,
    this.x,
    this.y,
  });

  final double width;
  final double height;
  final double? x;
  final double? y;

  @override
  String toString() =>
      'WindowGeometry(${width}x$height @ ${x ?? "?"},${y ?? "?"})';
}
