import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/download/download_publisher.dart';
import 'package:md3music/data/models/download_task.dart';
import 'package:md3music/data/models/song.dart';

void main() {
  test(
    'publication preserves existing files and recovers a commit after process restart',
    () async {
      final root = await Directory.systemTemp.createTemp('md3-publish-');
      final dest = await Directory('${root.path}/music').create();
      final source = await File('${root.path}/source').writeAsBytes([1, 2, 3]);
      final t = DownloadTask(
        id: newDownloadId(),
        song: Song(
          id: 'hash',
          title: '歌名',
          artist: '歌手',
          album: '专辑',
          duration: Duration.zero,
          isOnline: true,
        ),
        owner: 'A',
        options: DownloadOptions(destination: dest.path),
        batchId: 'batch',
      )..format = 'mp3';
      try {
        final first = await DownloadPublisher().publish(
          t,
          source.path,
          '歌手-歌名',
        );
        expect(first, endsWith('歌手-歌名.mp3'));
        // A new publisher has no in-memory state; the durable intent reconciles the move.
        expect(
          await DownloadPublisher().publish(t, source.path, '歌手-歌名'),
          first,
        );
        expect(dest.listSync().whereType<File>().length, 1);
        await source.writeAsBytes([4, 5, 6]);
        final retry = await DownloadPublisher().publish(
          t,
          source.path,
          '歌手-歌名',
        );
        expect(retry, isNot(first));
        expect(await File(first).readAsBytes(), [1, 2, 3]);
        expect(await File(retry).readAsBytes(), [4, 5, 6]);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
