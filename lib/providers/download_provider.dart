import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../data/models/song.dart';
import '../core/services/remote/remote_storage_config.dart';
import '../data/models/download_task.dart';
import '../data/repositories/download_repository.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../core/services/download/download_transfer.dart';
import '../core/services/download/download_cover_resolver.dart';
import '../core/services/download/download_metadata_resolver.dart';
import '../core/services/download/download_lyric_exporter.dart';
import '../core/services/download/download_publisher.dart';
import '../core/services/download/rust_tag_writer.dart';

class DownloadProvider extends ChangeNotifier {
  DownloadProvider({
    DownloadRepository? repository,
    this.onDownloaded,
    DownloadPublisher? publisher,
    Dio? dio,
    this.stagingDirectory,
    this.ownerReader,
    this.sourceResolver,
    this.metadataResolver,
    this.lyricResolver,
    this.coverResolver,
    Future<Map<String, dynamic>> Function(String, String)? inspectSource,
    Future<Map<String, dynamic>> Function(String, String, Map<String, dynamic>)?
    writeTags,
  }) : repository = repository ?? DownloadRepository(),
       publisher = publisher ?? DownloadPublisher(),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 30),
               maxRedirects: 5,
             ),
           ),
       writeTags = writeTags ?? RustTagWriter().write,
       inspectSource = inspectSource ?? RustTagWriter().inspect;
  final DownloadRepository repository;
  final Future<void> Function(Song)? onDownloaded;
  KugouApiClient get api => KugouApiClient();
  final DownloadPublisher publisher;
  final Dio _dio;
  final String? stagingDirectory;
  final String Function()? ownerReader;
  final Future<Map<String, dynamic>> Function(DownloadTask, CancelToken)?
  sourceResolver;
  final Future<DownloadMetadata> Function(Song)? metadataResolver;
  final Future<DownloadLyrics> Function(Song)? lyricResolver;
  final Future<DownloadCover> Function(List<String>, String, CancelToken)?
  coverResolver;
  final Future<Map<String, dynamic>> Function(
    String,
    String,
    Map<String, dynamic>,
  )
  writeTags;
  final Future<Map<String, dynamic>> Function(String, String) inspectSource;
  final List<DownloadTask> _tasks = [];
  final Map<String, CancelToken> _tokens = {};
  final Set<String> _active = {};
  final Map<String, Future<void>> _flights = {};
  String? _lastOwner;
  Future<void>? _initializing;
  Future<void> _tagTail = Future.value();
  Timer? _progress;
  bool _disposed = false;
  String? _root;
  String get owner => ownerReader?.call() ?? api.userid ?? '';
  List<DownloadTask> get tasks =>
      List.unmodifiable(_tasks.where((t) => t.owner == owner));
  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    _root =
        stagingDirectory ??
        '${(await getApplicationSupportDirectory()).path}/download_staging';
    await Directory(_root!).create(recursive: true);
    _tasks.addAll(await repository.load());
    for (final task in _tasks) {
      if (task.running || task.status == DownloadStatus.queued) {
        task.status = DownloadStatus.paused;
        await repository.save(task);
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _tick() {
    _progress ??= Timer(const Duration(milliseconds: 250), () {
      _progress = null;
      _notify();
    });
  }

  void syncOwner() {
    if (_lastOwner == owner) return;
    _lastOwner = owner;
    for (final t in _tasks.where(
      (t) =>
          t.owner != owner && (t.running || t.status == DownloadStatus.queued),
    )) {
      unawaited(pause(t));
    }
    _notify();
  }

  Future<int> enqueue(List<Song> songs, DownloadOptions options) async {
    await initialize();
    final batch = newDownloadId();
    final supported = songs.where(
      (s) =>
          s.isOnline &&
          !s.isCloud &&
          !s.isLongAudio &&
          s.remoteType == SongRemoteType.none,
    );
    final added = await repository.insertBatch([
      for (final s in supported)
        DownloadTask(
          id: newDownloadId(),
          song: s,
          owner: owner,
          options: options,
          batchId: batch,
        ),
    ]);
    _tasks.addAll(added);
    _notify();
    _pump();
    return added.length;
  }

  Future<void> pause(DownloadTask task, {bool cancel = false}) async {
    if (task.status == DownloadStatus.completed) return;
    task.generation++;
    _tokens[task.id]?.cancel('user');
    task.status = cancel ? DownloadStatus.cancelled : DownloadStatus.paused;
    _notify();
    String? published;
    try {
      published = await publisher.cancel(task.id);
    } catch (_) {
      /* The stop remains accepted if the native channel has gone away. */
    }
    if (published != null) {
      task.output = published;
      task.status = DownloadStatus.completed;
    } else {
      task.status = cancel ? DownloadStatus.cancelled : DownloadStatus.paused;
    }
    await repository.save(task);
    _notify();
  }

  Future<void> resume(DownloadTask task) async {
    if (task.owner != owner || task.running) return;
    task.generation++;
    if (task.status == DownloadStatus.completed) task.output = null;
    publisher.beginRetry(task.id);
    task.tags = null;
    task.status = DownloadStatus.queued;
    task.error = null;
    await repository.save(task);
    _notify();
    _pump();
  }

  Future<void> remove(DownloadTask task) async {
    await pause(task, cancel: true);
    await _flights[task.id];
    await repository.remove(task.id);
    _tasks.remove(task);
    for (final ext in [
      'source',
      'source.part',
      'tagged',
      'cover',
      'tagging.tmp',
      'publication.json',
      'krc',
    ]) {
      final file = File('$_root/${task.id}.$ext');
      if (await file.exists()) await file.delete();
    }
    _notify();
  }

  void _pump() {
    if (_disposed) return;
    for (final task
        in _tasks
            .where((t) => t.owner == owner && t.status == DownloadStatus.queued)
            .toList()) {
      if (_active.length >= 3) break;
      if (!_active.add(task.id)) continue;
      final flight = _run(task)
          .catchError((Object error) {
            task.error = '下载记录保存失败：${downloadError(error)}';
            if (task.running || task.status == DownloadStatus.queued) {
              task.status = DownloadStatus.failed;
            }
            _notify();
          })
          .whenComplete(() {
            _active.remove(task.id);
            _tokens.remove(task.id);
            _flights.remove(task.id);
            _pump();
          });
      _flights[task.id] = flight;
      unawaited(flight);
    }
  }

  Future<void> _state(DownloadTask t, DownloadStatus status) async {
    if (t.status == DownloadStatus.paused ||
        t.status == DownloadStatus.cancelled) {
      return;
    }
    t.status = status;
    await repository.save(t);
    _notify();
  }

  Future<void> _run(DownloadTask task) async {
    final generation = task.generation, token = CancelToken();
    _tokens[task.id] = token;
    bool valid() =>
        !_disposed &&
        generation == task.generation &&
        task.owner == owner &&
        !token.isCancelled;
    void check() {
      if (!valid()) throw StateError('任务已停止或账号已更换');
    }

    try {
      final source = '$_root/${task.id}.source';
      if (!await File(source).exists()) {
        task.sourceDigest = null;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            await _state(task, DownloadStatus.resolving);
            final info = sourceResolver != null
                ? await sourceResolver!(task, token)
                : await api.resolveSongDownloadUrl(
                    task.song.id,
                    quality: task.options.quality,
                    allowFallback: task.options.allowFallback,
                    albumId: task.song.albumId,
                    albumAudioId: task.song.albumAudioId,
                    cancelToken: token,
                  );
            check();
            task.actualQuality = info['quality']?.toString();
            task.expectedBytes =
                int.tryParse(
                  (info['fileSize'] ?? info['file_size'] ?? '0').toString(),
                ) ??
                0;
            await _state(task, DownloadStatus.downloading);
            await DownloadTransfer(_dio).transfer(
              task,
              info['url'] as String,
              source,
              token,
              () {
                _tick();
              },
            );
            check();
            break;
          } on DioException catch (e) {
            check();
            final status = e.response?.statusCode;
            final retryable =
                e.type == DioExceptionType.connectionError ||
                e.type == DioExceptionType.connectionTimeout ||
                e.type == DioExceptionType.receiveTimeout ||
                status == 403 ||
                status == 408 ||
                status == 429 ||
                (status != null && status >= 500);
            if (attempt == 2 || !retryable) rethrow;
            await Future<void>.delayed(
              Duration(milliseconds: 500 * (1 << attempt)),
            );
            check();
          }
        }
      }
      final sourceFile = await File(source).open();
      try {
        task.format = audioFormat(await sourceFile.read(16));
      } finally {
        await sourceFile.close();
      }
      await _state(task, DownloadStatus.verifying);
      if (task.expectedBytes > 0 &&
          await File(source).length() != task.expectedBytes) {
        await File(source).delete();
        throw const FormatException('下载长度与音源声明不一致，请重试');
      }
      final inspection = await inspectSource(_root!, task.id);
      check();
      if (inspection['ok'] != true) {
        throw FormatException(inspection['errorCode']?.toString() ?? '音频无法解析');
      }
      final expected = task.song.duration.inMilliseconds;
      final actual = (inspection['durationMs'] as num?)?.toInt() ?? 0;
      if (expected > 0 &&
          (actual - expected).abs() > 5000 &&
          (actual - expected).abs() > expected * 0.03) {
        await File(source).delete();
        throw const FormatException('音频时长与曲目不符，可能为试听或损坏响应');
      }
      if (task.sourceDigest != null &&
          task.sourceDigest != inspection['sha256']) {
        await File(source).delete();
        task.sourceDigest = null;
        throw const FormatException('暂存音频校验失败，请重试');
      }
      task.sourceDigest = inspection['sha256'] as String?;
      task.missing = [];
      task.error = null;
      Map<String, dynamic> fields = task.tags ?? {};
      if (fields.isEmpty) {
        final metadata = metadataResolver != null
            ? await metadataResolver!(task.song)
            : await DownloadMetadataResolver(api).resolve(task.song);
        check();
        fields = metadata.fields;
        task.provenance = metadata.provenance;
        try {
          final cover = coverResolver != null
              ? await coverResolver!(
                  metadata.coverUrls,
                  '$_root/${task.id}.cover',
                  token,
                )
              : await DownloadCoverResolver(
                  _dio,
                ).resolve(metadata.coverUrls, '$_root/${task.id}.cover', token);
          check();
          fields['cover'] = cover.toJson();
          task.coverSize = '${cover.width}×${cover.height}';
        } catch (e) {
          check();
          task.missing.add('封面：${downloadError(e)}');
        }
        try {
          final DownloadLyrics exported;
          if (lyricResolver != null) {
            exported = await lyricResolver!(task.song);
          } else {
            final result = await api.getLyricResult(
              task.song.id,
              songName: '${task.song.title} ${task.song.artist}',
              fmt: 'krc',
            );
            check();
            final lyric = result.lyric;
            if (lyric == null) throw const FormatException('未找到歌词');
            exported = exportDownloadLyrics(lyric);
          }
          check();
          fields['lyrics'] = exported.toJson();
          if (exported.rawKrc != null) {
            await File(
              '$_root/${task.id}.krc',
            ).writeAsString(exported.rawKrc!, flush: true);
            check();
          }
          task.provenance['lyrics'] = exported.rawKrc != null
              ? 'kugou/krc'
              : 'kugou/line-or-plain';
          task.lyricProfile = exported.profile;
          if (!exported.wordTimed) task.missing.add('源歌词无逐字时间');
          addLyricCredits(
            fields,
            exported.rawKrc ?? exported.text,
            task.provenance,
          );
        } catch (e) {
          check();
          task.missing.add('逐字歌词：${downloadError(e)}');
        }
        task.tags = fields;
      }
      for (final key in [
        'title',
        'artists',
        'album',
        'trackNumber',
        'date',
        'genres',
        'composers',
        'lyricists',
      ]) {
        final value = fields[key];
        if (value == null ||
            (value is String && value.trim().isEmpty) ||
            (value is List && value.isEmpty)) {
          task.missing.add(key);
        }
      }
      if (fields['cover'] == null &&
          !task.missing.any((s) => s.startsWith('封面'))) {
        task.missing.add('封面');
      }
      if (fields['lyrics'] == null &&
          !task.missing.any((s) => s.startsWith('逐字'))) {
        task.missing.add('逐字歌词');
      }
      if (fields['lyrics'] is Map &&
          fields['lyrics']['wordTimed'] != true &&
          !task.missing.contains('源歌词无逐字时间')) {
        task.missing.add('源歌词无逐字时间');
      }
      var artifact = source;
      await _state(task, DownloadStatus.tagging);
      final previous = _tagTail;
      final released = Completer<void>();
      _tagTail = released.future;
      try {
        await previous;
        check();
        final result = await writeTags(_root!, task.id, fields);
        check();
        if (result['ok'] == true && result['commentFree'] == true) {
          artifact = '$_root/${task.id}.tagged';
        } else {
          task.error =
              result['errorCode']?.toString() ?? '标签库未确认 comment 已清除，请更新组件';
          // A failed cover/metadata update must not publish the original comment.
          if (inspection['hasComments'] != false) {
            final cleaned = await writeTags(_root!, task.id, {});
            check();
            if (cleaned['ok'] != true || cleaned['commentFree'] != true) {
              throw StateError('无法清除 comment，音频保留在暂存目录，未发布成品');
            }
            artifact = '$_root/${task.id}.tagged';
          }
        }
      } finally {
        released.complete();
      }
      check();
      await _state(task, DownloadStatus.publishing);
      check();
      final artists = metadataNames(fields['artists']).join('、');
      final stem = downloadFileStem(
        artists.isEmpty ? task.song.artist : artists,
        fields['title']?.toString() ?? task.song.displayName,
      );
      final output = await publisher.publish(task, artifact, stem);
      // Publication is a commit: an accepted output must be reconciled even after a late pause.
      task.output = output;
      if (!valid() && task.status != DownloadStatus.completed) {
        await repository.save(task);
        return;
      }
      await _state(task, DownloadStatus.completed);
      try {
        await onDownloaded?.call(
          Song(
            id: 'local_$output',
            title: fields['title']?.toString() ?? task.song.displayName,
            artist: artists.isEmpty ? task.song.artist : artists,
            album: fields['album']?.toString() ?? task.song.album,
            duration: task.song.duration,
            localPath: output,
            isOnline: false,
            quality: task.actualQuality,
            localLyrics: (fields['lyrics'] as Map?)?['text'] as String?,
          ),
        );
      } catch (_) {
        // A library cache failure must not turn a committed audio file into a failed download.
        task.error = '音频已保存，本地曲库索引更新失败，可从保存路径播放';
        await repository.save(task);
        _notify();
      }
      // Keep the verified original only while metadata needs a retry. Completed
      // files are already owned by the publication target and need no second copy.
      for (final ext in [
        'tagged',
        if (task.fullyComplete) ...['source', 'cover'],
      ]) {
        try {
          final staged = File('$_root/${task.id}.$ext');
          if (await staged.exists()) await staged.delete();
        } catch (_) {
          /* Removing the queue record also retries staging cleanup. */
        }
      }
    } catch (e) {
      if (valid()) {
        task.error = downloadError(e);
        await _state(task, DownloadStatus.failed);
      } else {
        await repository.save(task);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _progress?.cancel();
    for (final t in _tokens.values) {
      t.cancel('disposed');
    }
    _dio.close(force: true);
    unawaited(
      Future.wait(_flights.values.toList()).whenComplete(repository.close),
    );
    super.dispose();
  }
}

String downloadError(Object error) {
  if (error is DioException) {
    return '网络请求失败：${error.type.name}${error.response?.statusCode == null ? '' : ' (${error.response!.statusCode})'}';
  }
  return error.toString();
}
