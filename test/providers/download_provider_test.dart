import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/download_provider.dart';
import 'package:md3music/data/models/download_task.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/download_repository.dart';
import 'package:md3music/core/services/download/download_cover_resolver.dart';
import 'package:md3music/core/services/download/download_lyric_exporter.dart';
import 'package:md3music/core/services/download/download_metadata_resolver.dart';
import 'package:md3music/core/services/download/download_publisher.dart';

class MemoryDownloads extends DownloadRepository {
  final rows = <String, Map<String, dynamic>>{};
  @override
  Future<List<DownloadTask>> load() async =>
      rows.values.map(DownloadTask.fromJson).toList();
  @override
  Future<List<DownloadTask>> insertBatch(List<DownloadTask> tasks) async {
    final keys = (await load()).map((t) => t.dedupKey).toSet();
    final added = <DownloadTask>[];
    for (final t in tasks) {
      if (keys.add(t.dedupKey)) {
        await save(t);
        added.add(t);
      }
    }
    return added;
  }

  @override
  Future<void> save(DownloadTask t) async {
    rows[t.id] = t.toJson();
  }

  @override
  Future<void> close() async {}
}

class TestPublisher extends DownloadPublisher {
  final saved = <String>[];
  @override
  Future<String> publish(DownloadTask t, String source, String stem) async {
    saved.add(stem);
    return (await File(
      source,
    ).copy('${File(source).parent.path}/published-${t.id}.mp3')).path;
  }

  @override
  Future<String?> cancel(String id) async => null;
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 600; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('queue did not reach expected state');
}

Song song(int i) => Song(
  id: 'song$i',
  title: '歌名$i',
  artist: '歌手',
  album: '专辑',
  duration: const Duration(seconds: 1),
  isOnline: true,
);

void main() {
  late Directory root;
  late HttpServer server;
  late MemoryDownloads repository;
  late TestPublisher publisher;
  late DownloadProvider queue;
  var account = 'A';
  Completer<void>? tagGate;
  Completer<void>? lyricGate;
  var lyricWaiting = false;
  var failTags = false, failCleanup = false, sourceHasComments = true;
  final tagPayloads = <Map<String, dynamic>>[];
  var tags = 0, maxTags = 0, resolving = 0, maxResolving = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('md3-queue-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      r.response.contentLength = 103;
      r.response.add([73, 68, 51, ...List.filled(100, 0)]);
      await r.response.close();
    });
    repository = MemoryDownloads();
    publisher = TestPublisher();
    account = 'A';
    tagGate = null;
    lyricGate = null;
    lyricWaiting = false;
    failTags = false;
    failCleanup = false;
    sourceHasComments = true;
    tagPayloads.clear();
    tags = 0;
    maxTags = 0;
    resolving = 0;
    maxResolving = 0;
    queue = DownloadProvider(
      repository: repository,
      publisher: publisher,
      stagingDirectory: root.path,
      ownerReader: () => account,
      dio: Dio(),
      inspectSource: (root, id) async => {
        'ok': true,
        'durationMs': 1000,
        'sha256': 'a' * 64,
        'hasComments': sourceHasComments,
      },
      sourceResolver: (t, cancel) async {
        resolving++;
        if (resolving > maxResolving) maxResolving = resolving;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        resolving--;
        return {
          'url': 'http://127.0.0.1:${server.port}/audio',
          'quality': '128',
        };
      },
      metadataResolver: (s) async => DownloadMetadata(
        {
          'title': s.title,
          'artists': [s.artist],
          'album': s.album,
          'trackNumber': 1,
          'date': '2026',
          'genres': ['Pop'],
          'composers': ['曲作者'],
          'lyricists': ['词作者'],
        },
        [],
        {},
      ),
      coverResolver: (urls, path, cancel) async =>
          DownloadCover(path, 32, 32, 'a' * 64),
      lyricResolver: (s) async {
        lyricWaiting = true;
        await lyricGate?.future;
        return const DownloadLyrics(
          '[00:01.000]<00:01.000>字<00:01.300>',
          'eslyric_enhanced',
          true,
        );
      },
      writeTags: (path, id, fields) async {
        tagPayloads.add(Map<String, dynamic>.from(fields));
        tags++;
        if (tags > maxTags) maxTags = tags;
        await (tagGate?.future ??
            Future<void>.delayed(const Duration(milliseconds: 10)));
        tags--;
        if ((failTags && fields.isNotEmpty) || (failCleanup && fields.isEmpty)) {
          return {'ok': false, 'errorCode': 'injected_tag_failure'};
        }
        await File('$path/$id.source').copy('$path/$id.tagged');
        return {'ok': true, 'commentFree': true};
      },
    );
  });
  tearDown(() async {
    if (lyricGate != null && !lyricGate!.isCompleted) lyricGate!.complete();
    tagGate?.complete();
    queue.dispose();
    await server.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await root.delete(recursive: true);
  });
  test('bounded queue deduplicates batch and serializes tags', () async {
    expect(
      await queue.enqueue([
        for (var i = 0; i < 8; i++) song(i),
      ], const DownloadOptions()),
      8,
    );
    expect(await queue.enqueue([song(0)], const DownloadOptions()), 0);
    await until(
      () => queue.tasks.every((t) => t.status == DownloadStatus.completed),
    );
    expect(maxResolving, lessThanOrEqualTo(3));
    expect(maxTags, 1);
    expect(queue.tasks.every((t) => t.fullyComplete), true);
    expect(publisher.saved.first, startsWith('歌手-歌名'));
  });
  test('restored running tasks stay paused until the user resumes', () async {
    final task =
        DownloadTask(
            id: newDownloadId(),
            song: song(9),
            owner: 'A',
            options: const DownloadOptions(),
            batchId: 'old',
          )
          ..status = DownloadStatus.downloading
          ..received = 42
          ..etag = 'same';
    await repository.save(task);
    await queue.initialize();
    expect(queue.tasks.single.status, DownloadStatus.paused);
    expect(queue.tasks.single.received, 42);
    expect(queue.tasks.single.etag, 'same');
    expect(publisher.saved, isEmpty);
    expect(repository.rows[task.id]!['status'], 'paused');
  });
  test('cancel during native tag work discards the late result', () async {
    tagGate = Completer<void>();
    await queue.enqueue([song(0)], const DownloadOptions());
    await until(() => tags == 1);
    final t = queue.tasks.single;
    await queue.pause(t, cancel: true);
    tagGate!.complete();
    tagGate = null;
    await until(() => tags == 0);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(t.status, DownloadStatus.cancelled);
    expect(publisher.saved, isEmpty);
  });
  test('changing account stops the old queue without publishing', () async {
    tagGate = Completer<void>();
    await queue.enqueue([song(0)], const DownloadOptions());
    await until(() => tags == 1);
    final task = queue.tasks.single;
    account = 'B';
    queue.syncOwner();
    tagGate!.complete();
    tagGate = null;
    await until(() => tags == 0);
    expect(task.status, DownloadStatus.paused);
    expect(queue.tasks, isEmpty);
    expect(publisher.saved, isEmpty);
  });
  test('late lyrics cannot replace a cancelled status with tagging', () async {
    lyricGate = Completer<void>();
    await queue.enqueue([song(1)], const DownloadOptions());
    await until(() => lyricWaiting);
    final task = queue.tasks.single;
    await queue.pause(task, cancel: true);
    lyricGate!.complete();
    lyricGate = null;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(task.status, DownloadStatus.cancelled);
    expect(publisher.saved, isEmpty);
    expect(tags, 0);
  });
  test('failed metadata publishes only the comment-cleaned copy', () async {
    failTags = true;
    await queue.enqueue([song(2)], const DownloadOptions());
    await until(() => queue.tasks.single.status == DownloadStatus.completed);
    expect(tagPayloads.length, 2);
    expect(tagPayloads.last, isEmpty);
    expect(queue.tasks.single.error, 'injected_tag_failure');
    expect(queue.tasks.single.fullyComplete, false);
    expect(publisher.saved.length, 1);
  });
  test(
    'comment cleanup failure never publishes the original with comments',
    () async {
      failTags = true;
      failCleanup = true;
      await queue.enqueue([song(3)], const DownloadOptions());
      await until(() => queue.tasks.single.status == DownloadStatus.failed);
      expect(publisher.saved, isEmpty);
      expect(queue.tasks.single.output, isNull);
      expect(queue.tasks.single.error, contains('无法清除 comment'));
    },
  );
  test(
    'verified comment-free original can still be published after tag failure',
    () async {
      sourceHasComments = false;
      failTags = true;
      await queue.enqueue([song(4)], const DownloadOptions());
      await until(() => queue.tasks.single.status == DownloadStatus.completed);
      expect(tagPayloads.length, 1);
      expect(publisher.saved.length, 1);
      expect(queue.tasks.single.error, 'injected_tag_failure');
    },
  );
}
