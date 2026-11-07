import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/data/models/download_task.dart';
import 'package:md3music/data/repositories/download_repository.dart';
import 'package:md3music/providers/download_provider.dart';
import 'package:md3music/modules/download/download_page.dart';

class Rows extends DownloadRepository {
  Rows(this.tasks);
  final List<DownloadTask> tasks;
  @override
  Future<List<DownloadTask>> load() async => tasks;
  @override
  Future<void> save(DownloadTask t) async {}
  @override
  Future<void> close() async {}
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('md3-ui-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  testWidgets('empty queue gives a useful entry hint', (tester) async {
    final queue = DownloadProvider(
      repository: Rows([]),
      ownerReader: () => '',
      stagingDirectory: root.path,
    );
    await tester.runAsync(queue.initialize);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: queue,
        child: const MaterialApp(home: DownloadPage()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('暂无下载任务'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    queue.dispose();
  });
  testWidgets(
    'saved audio with missing tags is visibly separate from complete success',
    (tester) async {
      final task =
          DownloadTask(
              id: newDownloadId(),
              song: Song(
                id: 'hash',
                title: '歌名',
                artist: '歌手',
                album: '专辑',
                duration: Duration.zero,
                isOnline: true,
              ),
              owner: '',
              options: const DownloadOptions(),
              batchId: 'batch',
            )
            ..status = DownloadStatus.completed
            ..missing = ['genres']
            ..coverSize = '2000×2000'
            ..lyricProfile = 'eslyric_enhanced';
      final queue = DownloadProvider(
        repository: Rows([task]),
        ownerReader: () => '',
        stagingDirectory: root.path,
      );
      await tester.runAsync(queue.initialize);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: queue,
          child: const MaterialApp(home: DownloadPage()),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('歌手-歌名'), findsOneWidget);
      expect(find.textContaining('音频已下载，标签未完成'), findsOneWidget);
      expect(find.textContaining('标签齐全 0'), findsOneWidget);
      expect(find.textContaining('2000×2000'), findsOneWidget);
      expect(find.textContaining('流派'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      queue.dispose();
    },
  );
}
