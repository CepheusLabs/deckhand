import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'flash_sentinel.dart';

/// [ElevatedHelperService] that launches the sibling
/// `deckhand-elevated-helper` binary with platform-native elevation.
///
/// Why a separate process: the Go sidecar runs as the user and must not
/// have admin/root. Raw block-device writes need elevation, so the
/// helper is one-shot, exits when the write completes, and has no
/// network access.
///
/// Elevation per platform:
///   - Windows: `powershell.exe Start-Process -Verb RunAs -Wait` with
///     stdout redirected to a tempfile; UI tails that file for JSON
///     progress events.
///   - macOS: `osascript -e 'do shell script ... with administrator
///     privileges'` - triggers the Authorization Services dialog.
///   - Linux: `pkexec` - the helper inherits stdio directly so
///     progress streams live on stdout.
class ProcessElevatedHelperService implements ElevatedHelperService {
  ProcessElevatedHelperService({
    required this.helperPath,
    this.sentinelWriter,
  });

  /// Absolute path to the `deckhand-elevated-helper` binary.
  final String helperPath;

  /// When non-null, [writeImage] persists a flash-sentinel before
  /// launching the helper and clears it only after observing the
  /// helper's `event: done`. Production wiring constructs this with
  /// the per-user `<data_dir>/Deckhand/state/flash-sentinels/`
  /// directory; tests that don't care about sentinels leave it null.
  final FlashSentinelWriter? sentinelWriter;

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
    String? expectedSha256,
  }) async* {
    final args = <String>[
      'write-image',
      '--image', imagePath,
      '--target', diskId,
      '--token', confirmationToken,
      '--verify', verifyAfterWrite.toString(),
      if (expectedSha256 != null) ...['--sha256', expectedSha256],
    ];

    // Sentinel goes down before the elevation prompt fires. Anything
    // that interrupts the operation between here and `event: done`
    // — helper crash, UAC denial, user closing the app, power loss
    // — leaves the sentinel in place for the next disks.list to find.
    if (sentinelWriter != null) {
      try {
        await sentinelWriter!.write(
          diskId: diskId,
          imagePath: imagePath,
          imageSha256: expectedSha256,
        );
      } on FileSystemException {
        // A non-writable sentinel directory must not block the flash:
        // sentinels are diagnostic, not load-bearing for safety. The
        // user already cleared the destructive-op confirmation
        // dialog; refusing to flash here would be punitive.
      }
    }

    var sawDone = false;
    try {
      await for (final ev in launchHelper(args)) {
        if (ev.phase == FlashPhase.done) sawDone = true;
        yield ev;
      }
    } finally {
      if (sawDone && sentinelWriter != null) {
        await sentinelWriter!.clear(diskId);
      }
    }
  }

  /// Platform-specific launch surface, factored out so tests can
  /// substitute an in-memory event stream without spawning a real
  /// process. Production callers should not override this.
  @visibleForTesting
  Stream<FlashProgress> launchHelper(List<String> args) {
    if (Platform.isWindows) return _runWindows(args);
    if (Platform.isMacOS) return _runMacOs(args);
    return _runLinux(args);
  }

  // -----------------------------------------------------------------
  // Windows: PowerShell Start-Process -Verb RunAs. Helper output is
  // redirected to a tempfile; we tail it for JSON progress events.
  //
  // Race: the previous implementation's poll loop exited on
  // `ps.exitCode`, which was set the instant PowerShell finished —
  // but the stdout-redirected file might not have been flushed to
  // disk yet (NTFS buffers + PowerShell's own close sequence happen
  // asynchronously). The drain step tried to recover but mixed
  // string-index and byte-offset arithmetic, losing UTF-8 characters
  // or data held in `carry`. This rewrite does two things:
  //   1. Never exit the tail loop until we've done one read strictly
  //      after the process was observed as exited AND the file size
  //      has stopped growing. That guarantees the final progress
  //      event is observed even if it lands after exitCode fires.
  //   2. Use a single byte-offset + UTF-8 decoder across the loop and
  //      drain so partial characters or unfinished lines are never
  //      dropped between phases.

  Stream<FlashProgress> _runWindows(List<String> helperArgs) async* {
    final stdoutFile = File(
      p.join(
        Directory.systemTemp.path,
        'deckhand-helper-${DateTime.now().millisecondsSinceEpoch}.log',
      ),
    );
    final stderrFile = File('${stdoutFile.path}.err');
    await stdoutFile.writeAsString('');

    final argList = helperArgs.map(powerShellQuoteArg).join(',');

    final psCommand = [
      '\$p = Start-Process -FilePath "$helperPath" ',
      '-ArgumentList $argList ',
      '-Verb RunAs -Wait -PassThru ',
      '-RedirectStandardOutput "${stdoutFile.path}" ',
      '-RedirectStandardError "${stderrFile.path}";',
      'exit \$p.ExitCode',
    ].join();

    final ps = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      psCommand,
    ], runInShell: false);

    final exitFuture = ps.exitCode;
    var processExited = false;
    exitFuture.then((_) => processExited = true);

    var offset = 0;
    final decoder = const Utf8Decoder(allowMalformed: true);
    final carry = StringBuffer();

    Future<List<FlashProgress>> readChunkOnce() async {
      final events = <FlashProgress>[];
      final len = await stdoutFile.length();
      if (len <= offset) return events;
      final raf = await stdoutFile.open();
      try {
        await raf.setPosition(offset);
        final bytes = await raf.read(len - offset);
        offset = len;
        final chunk = decoder.convert(bytes);
        carry.write(chunk);
        var s = carry.toString();
        var nl = s.indexOf('\n');
        while (nl >= 0) {
          final line = s.substring(0, nl).trimRight();
          s = s.substring(nl + 1);
          final ev = _parseHelperLine(line);
          if (ev != null) events.add(ev);
          nl = s.indexOf('\n');
        }
        carry
          ..clear()
          ..write(s);
      } finally {
        await raf.close();
      }
      return events;
    }

    try {
      while (!processExited) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        for (final ev in await readChunkOnce()) {
          yield ev;
        }
      }
      // Drain after exit: PowerShell may still be flushing redirected
      // stdout. Keep reading until the file size is stable across two
      // passes so we can't miss the final `done` event.
      await exitFuture;
      var stableSize = -1;
      for (var i = 0; i < 20; i++) {
        for (final ev in await readChunkOnce()) {
          yield ev;
        }
        final size = await stdoutFile.length();
        if (size == stableSize && size == offset) break;
        stableSize = size;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // Any unterminated trailing line gets one last parse attempt.
      if (carry.isNotEmpty) {
        final ev = _parseHelperLine(carry.toString().trimRight());
        if (ev != null) yield ev;
        carry.clear();
      }

      final exit = await exitFuture;
      if (exit != 0) {
        String? errTail;
        try {
          if (await stderrFile.exists()) {
            errTail = (await stderrFile.readAsString()).trim();
            if (errTail.length > 512) {
              errTail = errTail.substring(errTail.length - 512);
            }
          }
        } catch (_) {}
        throw ElevatedHelperException(
          'elevated helper exited with code $exit'
          '${errTail == null || errTail.isEmpty ? "" : "\n$errTail"}',
        );
      }
    } finally {
      for (final f in [stdoutFile, stderrFile]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  // -----------------------------------------------------------------
  // macOS: osascript with administrator privileges. Helper stdout is
  // captured line-by-line.

  Stream<FlashProgress> _runMacOs(List<String> helperArgs) async* {
    // The previous implementation concatenated POSIX-single-quoted
    // args inside an AppleScript double-quoted string and tried to
    // escape with a bare `replaceAll('"', r'\"')`. That left
    // AppleScript-level string-escape edge cases (backslashes,
    // multi-byte chars) unhandled and stacked two fragile layers of
    // quoting on top of a privilege-escalation dialog.
    //
    // Write a one-shot shell script to a private temp file (0700)
    // that execs the helper with a literal argv array, then osascript
    // only needs to quote a single controlled path. The script file
    // is removed in a finally block regardless of outcome.
    final tmpDir = await Directory.systemTemp.createTemp('deckhand-helper-');
    final scriptPath = p.join(tmpDir.path, 'run.sh');
    final script = StringBuffer('#!/bin/sh\nexec ')
      ..write(_shellQuote(helperPath));
    for (final a in helperArgs) {
      script
        ..write(' ')
        ..write(_shellQuote(a));
    }
    script.write('\n');
    await File(scriptPath).writeAsString(script.toString());
    await Process.run('chmod', ['0700', scriptPath]);

    try {
      // `quoted form of` produces a POSIX-safely-quoted version of
      // the string for `do shell script`, so scriptPath is inert
      // even if it ever contains a space or unusual character. The
      // only Dart->AppleScript escaping we still need covers
      // backslash + double-quote inside the AppleScript string
      // literal for scriptPath itself.
      final aquoted = scriptPath.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      final appleScript =
          'do shell script quoted form of "$aquoted" '
          'with administrator privileges';
      final proc = await Process.start('osascript', ['-e', appleScript]);
      yield* _streamLines(proc);
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup; the private temp dir will be reaped
        // by the OS eventually if the delete fails.
      }
    }
  }

  // -----------------------------------------------------------------
  // Linux: pkexec. Helper stdio is inherited so we just parse stdout.

  Stream<FlashProgress> _runLinux(List<String> helperArgs) async* {
    final proc = await Process.start('pkexec', [helperPath, ...helperArgs]);
    yield* _streamLines(proc);
  }

  Stream<FlashProgress> _streamLines(Process proc) async* {
    final events = StreamController<FlashProgress>();
    late StreamSubscription<String> sub;
    sub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final ev = _parseHelperLine(line);
            if (ev != null) events.add(ev);
          },
          onError: events.addError,
          onDone: () async {
            final code = await proc.exitCode;
            if (code != 0) {
              events.addError(
                ElevatedHelperException(
                  'elevated helper exited with code $code',
                ),
              );
            }
            await events.close();
          },
        );
    try {
      yield* events.stream;
    } finally {
      await sub.cancel();
    }
  }
}

/// Test-only re-export of [_parseHelperLine]. The platform-specific
/// `_runWindows` / `_runMacOs` / `_runLinux` paths can't be unit-
/// tested without spawning a real elevated process, but the parser
/// they all funnel through is OS-agnostic and load-bearing — every
/// `event:done` / `event:error` line the helper emits goes through
/// here. Tests use this seam to pin the contract.
@visibleForTesting
FlashProgress? parseHelperLineForTesting(String line) =>
    _parseHelperLine(line);

FlashProgress? _parseHelperLine(String line) {
  if (line.trim().isEmpty) return null;
  Map<String, dynamic> obj;
  try {
    obj = jsonDecode(line) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final event = obj['event'] as String?;
  switch (event) {
    case 'preparing':
      return FlashProgress(
        bytesDone: 0,
        bytesTotal: 0,
        phase: FlashPhase.preparing,
        message: obj['device'] as String?,
      );
    case 'progress':
      final done = (obj['bytes_done'] as num?)?.toInt() ?? 0;
      final total = (obj['bytes_total'] as num?)?.toInt() ?? 0;
      final phase = _phaseFromString(obj['phase'] as String?);
      return FlashProgress(
        bytesDone: done,
        bytesTotal: total,
        phase: phase,
        message: obj['sha256'] as String?,
      );
    case 'done':
      final done = (obj['bytes'] as num?)?.toInt() ?? 0;
      return FlashProgress(
        bytesDone: done,
        bytesTotal: done,
        phase: FlashPhase.done,
        message: obj['sha256'] as String?,
      );
    case 'error':
      return FlashProgress(
        bytesDone: 0,
        bytesTotal: 0,
        phase: FlashPhase.failed,
        message: obj['message'] as String?,
      );
    default:
      return null;
  }
}

FlashPhase _phaseFromString(String? s) => switch (s) {
  'writing' => FlashPhase.writing,
  'verifying' || 'write-complete' || 'verified' => FlashPhase.verifying,
  'done' => FlashPhase.done,
  'failed' => FlashPhase.failed,
  _ => FlashPhase.preparing,
};

// Delegate to the canonical helper in deckhand_core so every corner of
// the app uses the same implementation. Shim kept as a thin wrapper to
// avoid touching the call sites.
String _shellQuote(String s) => shellSingleQuote(s);

/// Quote [arg] for inclusion in a PowerShell `-ArgumentList a,b,c`
/// literal. Double-wraps + doubles any embedded `"` per PowerShell's
/// native escaping rules. No shell expansion happens because we pass
/// the args as an array, not a single string.
///
/// Public so the unit test can pin the semantics down - a bad escape
/// could silently misquote a disk path with a space and flash the
/// wrong device.
String powerShellQuoteArg(String arg) => '"${arg.replaceAll('"', '""')}"';

class ElevatedHelperException implements Exception {
  ElevatedHelperException(this.message);
  final String message;
  @override
  String toString() => 'ElevatedHelperException: $message';
}
