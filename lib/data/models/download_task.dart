import 'dart:math';
import 'song.dart';

enum DownloadStatus {
  queued,
  resolving,
  downloading,
  verifying,
  tagging,
  publishing,
  paused,
  completed,
  failed,
  cancelled,
}

String newDownloadId() {
  final random = Random.secure();
  final hex = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class DownloadOptions {
  const DownloadOptions({
    this.quality = 'flac',
    this.allowFallback = true,
    this.destination,
  });
  final String quality;
  final bool allowFallback;

  /// Null: platform default. Android custom destinations must be writable SAF URIs.
  final String? destination;
  Map<String, dynamic> toJson() => {
    'quality': quality,
    'allowFallback': allowFallback,
    'destination': destination,
  };
  factory DownloadOptions.fromJson(Map<String, dynamic> json) =>
      DownloadOptions(
        quality: json['quality'] as String? ?? 'flac',
        allowFallback: json['allowFallback'] as bool? ?? true,
        destination: json['destination'] as String?,
      );
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.song,
    required this.owner,
    required this.options,
    required this.batchId,
  });
  final String id, owner, batchId;
  final Song song;
  final DownloadOptions options;
  DownloadStatus status = DownloadStatus.queued;
  int received = 0, total = 0, generation = 0;
  int expectedBytes = 0;
  String? sourceDigest;
  String? etag, modified, actualQuality, format, output, error;
  List<String> missing = [];
  Map<String, dynamic>? tags;
  Map<String, dynamic> provenance = {};
  String? coverSize, lyricProfile;
  bool get running => [
    DownloadStatus.resolving,
    DownloadStatus.downloading,
    DownloadStatus.verifying,
    DownloadStatus.tagging,
    DownloadStatus.publishing,
  ].contains(status);
  bool get fullyComplete =>
      status == DownloadStatus.completed && missing.isEmpty && error == null;
  String get dedupKey =>
      '$owner:${song.id.toLowerCase()}:${song.albumAudioId ?? ''}:${options.quality}:${options.destination ?? 'default'}';
  Map<String, dynamic> toJson() => {
    'id': id,
    'song': (song.toJson()
      ..remove('url')
      ..remove('artworkUri')),
    'owner': owner,
    'batchId': batchId,
    'options': options.toJson(),
    'status': status.name,
    'received': received,
    'total': total,
    'expectedBytes': expectedBytes,
    'sourceDigest': sourceDigest,
    'etag': etag,
    'modified': modified,
    'actualQuality': actualQuality,
    'format': format,
    'output': output,
    'error': error,
    'missing': missing,
    'tags': tags,
    'provenance': provenance,
    'coverSize': coverSize,
    'lyricProfile': lyricProfile,
  };
  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    final t = DownloadTask(
      id: j['id'] as String,
      song: Song.fromJson(Map<String, dynamic>.from(j['song'] as Map)),
      owner: j['owner'] as String,
      options: DownloadOptions.fromJson(
        Map<String, dynamic>.from(j['options'] as Map),
      ),
      batchId: j['batchId'] as String,
    );
    t.status = DownloadStatus.values.firstWhere(
      (s) => s.name == j['status'],
      orElse: () => DownloadStatus.paused,
    );
    t.received = (j['received'] as num?)?.toInt() ?? 0;
    t.total = (j['total'] as num?)?.toInt() ?? 0;
    t.expectedBytes = (j['expectedBytes'] as num?)?.toInt() ?? 0;
    t.sourceDigest = j['sourceDigest'] as String?;
    t.etag = j['etag'] as String?;
    t.modified = j['modified'] as String?;
    t.actualQuality = j['actualQuality'] as String?;
    t.format = j['format'] as String?;
    t.output = j['output'] as String?;
    t.error = j['error'] as String?;
    t.missing = List<String>.from(j['missing'] as List? ?? []);
    t.tags = j['tags'] == null
        ? null
        : Map<String, dynamic>.from(j['tags'] as Map);
    t.provenance = Map<String, dynamic>.from(j['provenance'] as Map? ?? {});
    t.coverSize = j['coverSize'] as String?;
    t.lyricProfile = j['lyricProfile'] as String?;
    return t;
  }
}

/// Preserve the requested artist-title separator; only sanitize filesystem-invalid characters.
String downloadFileStem(String artist, String title) {
  String clean(String s, String fallback) {
    s = s
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty) s = fallback;
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(s)) {
      s = '_$s';
    }
    return String.fromCharCodes(s.runes.take(80));
  }

  return '${clean(artist, '未知歌手')}-${clean(title, '未命名歌曲')}';
}
