import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';

import 'sidecar_client.dart';

/// [FlashService] that delegates every operation to the Go sidecar.
class SidecarFlashService implements FlashService {
  SidecarFlashService(this._client);

  final SidecarClient _client;

  @override
  Future<List<DiskInfo>> listDisks() async {
    final res = await _client.call('disks.list', const {});
    final disks = (res['disks'] as List? ?? const []).cast<Map>();
    return disks.map(_diskFromJson).toList();
  }

  @override
  Stream<FlashProgress> writeImage({
    required String imagePath,
    required String diskId,
    required String confirmationToken,
    bool verifyAfterWrite = true,
  }) {
    return _client.callStreaming('disks.write_image', {
      'image_path': imagePath,
      'disk_id': diskId,
      'confirmation_token': confirmationToken,
      'verify': verifyAfterWrite,
    }).transform(_flashEventTransformer);
  }

  @override
  Stream<FlashProgress> readImage({
    required String diskId,
    required String outputPath,
  }) {
    return _client.callStreaming('disks.read_image', {
      'device_id': diskId,
      'output': outputPath,
    }).transform(_flashEventTransformer);
  }

  @override
  Future<String> sha256(String path) async {
    final res = await _client.call('disks.hash', {'path': path});
    return res['sha256'] as String;
  }
}

DiskInfo _diskFromJson(Map raw) {
  final parts = ((raw['partitions'] as List?) ?? const []).cast<Map>();
  return DiskInfo(
    id: raw['id'] as String,
    path: raw['path'] as String,
    sizeBytes: (raw['size_bytes'] as num).toInt(),
    bus: raw['bus'] as String? ?? 'Unknown',
    model: raw['model'] as String? ?? 'Unknown disk',
    removable: raw['removable'] as bool? ?? false,
    partitions: parts.map(_partFromJson).toList(),
  );
}

PartitionInfo _partFromJson(Map raw) => PartitionInfo(
      index: (raw['index'] as num).toInt(),
      filesystem: raw['filesystem'] as String? ?? '',
      sizeBytes: (raw['size_bytes'] as num?)?.toInt() ?? 0,
      mountpoint: raw['mountpoint'] as String?,
    );

final _flashEventTransformer =
    StreamTransformer<SidecarEvent, FlashProgress>.fromHandlers(
  handleData: (event, sink) {
    switch (event) {
      case SidecarProgress(:final notification):
        final p = notification.params;
        final done = (p['bytes_done'] as num?)?.toInt() ?? 0;
        final total = (p['bytes_total'] as num?)?.toInt() ?? 0;
        final phase = _phaseFromString(p['phase'] as String?);
        sink.add(FlashProgress(
          bytesDone: done,
          bytesTotal: total,
          phase: phase,
          message: p['message'] as String?,
        ));
      case SidecarResult(:final result):
        final done = (result['bytes'] as num?)?.toInt() ?? 0;
        sink.add(FlashProgress(
          bytesDone: done,
          bytesTotal: done,
          phase: FlashPhase.done,
          message: result['sha256'] as String?,
        ));
    }
  },
);

FlashPhase _phaseFromString(String? s) => switch (s) {
      'reading' || 'writing' => FlashPhase.writing,
      'verifying' || 'write-complete' || 'verified' => FlashPhase.verifying,
      'done' => FlashPhase.done,
      'failed' => FlashPhase.failed,
      _ => FlashPhase.preparing,
    };
