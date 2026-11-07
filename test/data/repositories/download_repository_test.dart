import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/download_task.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/repositories/download_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'SQLite transaction deduplicates 1000 selections and survives reopening',
    () async {
      final root = await Directory.systemTemp.createTemp('md3-db-');
      final path = '${root.path}/downloads.db';
      var db = DownloadRepository(path: path);
      DownloadTask task(int i, {String owner = 'A'}) => DownloadTask(
        id: newDownloadId(),
        song: Song(
          id: 'hash$i',
          title: '歌$i',
          artist: '歌手',
          album: '专辑',
          duration: Duration.zero,
          isOnline: true,
          url: 'https://secret.example/token',
        ),
        owner: owner,
        options: const DownloadOptions(),
        batchId: 'batch',
      );
      try {
        final batch = [for (var i = 0; i < 1000; i++) task(i)];
        expect((await db.insertBatch([...batch, task(0)])).length, 1000);
        expect(await db.insertBatch([task(0)]), isEmpty);
        expect((await db.insertBatch([task(0, owner: 'B')])).length, 1);
        batch.first.status = DownloadStatus.paused;
        batch.first.received = 420;
        batch.first.etag = 'v1';
        await db.save(batch.first);
        await db.close();
        db = DownloadRepository(path: path);
        final saved = await db.load();
        expect(saved.length, 1001);
        expect(saved.first.status, DownloadStatus.paused);
        expect(saved.first.received, 420);
        expect(saved.first.etag, 'v1');
        expect(saved.first.song.url, isNull);
        await db.remove(saved.first.id);
        expect((await db.load()).length, 1000);
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
}
