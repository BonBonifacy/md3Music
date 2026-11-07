import 'package:material_ui/material_ui.dart';
import 'dart:async';
import '../../core/utils/app_toast.dart';
import 'package:provider/provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/player_provider.dart';
import '../../data/models/download_task.dart';
import '../../data/models/song.dart';

class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key});
  @override
  Widget build(BuildContext context) {
    final queue = context.watch<DownloadProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('下载管理')),
      body: FutureBuilder<void>(
        future: queue.initialize(),
        builder: (context, state) {
          if (state.hasError) {
            return Center(child: Text('读取下载队列失败：${state.error}'));
          }
          if (state.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final tasks = queue.tasks;
          if (tasks.isEmpty) {
            return const Center(
              child: Text('暂无下载任务\n在歌曲菜单或歌单中选择下载', textAlign: TextAlign.center),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '音频完成 ${tasks.where((t) => t.status == DownloadStatus.completed).length}/${tasks.length} · 标签齐全 ${tasks.where((t) => t.fullyComplete).length}',
                    ),
                    TextButton(
                      onPressed: () {
                        for (final t in tasks.where(
                          (t) => t.running || t.status == DownloadStatus.queued,
                        )) {
                          downloadAction(queue.pause(t));
                        }
                      },
                      child: const Text('全部暂停'),
                    ),
                    TextButton(
                      onPressed: () {
                        for (final t in tasks.where(
                          (t) =>
                              t.status == DownloadStatus.paused ||
                              t.status == DownloadStatus.failed,
                        )) {
                          downloadAction(queue.resume(t));
                        }
                      },
                      child: const Text('继续 / 重试'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final status = switch (task.status) {
                      DownloadStatus.queued => '等待下载',
                      DownloadStatus.resolving => '解析音源',
                      DownloadStatus.downloading => '下载中',
                      DownloadStatus.verifying => '核验与获取封面/歌词',
                      DownloadStatus.tagging => '写入标签',
                      DownloadStatus.publishing => '保存文件',
                      DownloadStatus.paused => '已暂停',
                      DownloadStatus.completed =>
                        task.fullyComplete ? '下载完成' : '音频已下载，标签未完成',
                      DownloadStatus.failed => '下载失败',
                      DownloadStatus.cancelled => '已取消',
                    };
                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${task.song.artist}-${task.song.displayName}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              '$status · 请求 ${task.options.quality} / 实际 ${task.actualQuality ?? "待解析"}',
                            ),
                            if (task.coverSize != null)
                              Text(
                                '封面 ${task.coverSize} · 歌词 ${switch (task.lyricProfile) {
                                  'eslyric_enhanced' => '逐字（ESLyric）',
                                  'lrc' => '逐行',
                                  'plain' => '纯文本',
                                  _ => '未获取',
                                }}',
                              ),
                            if (task.running)
                              LinearProgressIndicator(
                                value:
                                    task.status == DownloadStatus.downloading &&
                                        task.total > 0
                                    ? (task.received / task.total).clamp(
                                        0.0,
                                        1.0,
                                      )
                                    : null,
                              ),
                            if (task.status == DownloadStatus.downloading)
                              Text(
                                '${(task.received / 1048576).toStringAsFixed(1)} MiB${task.total > 0 ? " / ${(task.total / 1048576).toStringAsFixed(1)} MiB" : ""}',
                              ),
                            if (task.error != null)
                              Text(
                                task.error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            if (task.missing.isNotEmpty)
                              Text(
                                '未完成：${task.missing.map(downloadFieldLabel).join("、")}',
                              ),
                            if (task.output != null)
                              SelectableText(task.output!),
                            Wrap(
                              spacing: 8,
                              children: [
                                if (task.running ||
                                    task.status == DownloadStatus.queued)
                                  TextButton(
                                    onPressed: () =>
                                        downloadAction(queue.pause(task)),
                                    child: const Text('暂停'),
                                  ),
                                if (!task.running &&
                                    task.status != DownloadStatus.queued &&
                                    !task.fullyComplete)
                                  TextButton(
                                    onPressed: () =>
                                        downloadAction(queue.resume(task)),
                                    child: Text(
                                      task.status == DownloadStatus.completed
                                          ? '重试标签（另存新文件）'
                                          : '继续 / 重试',
                                    ),
                                  ),
                                if (task.status != DownloadStatus.completed &&
                                    task.status != DownloadStatus.cancelled)
                                  TextButton(
                                    onPressed: () => downloadAction(
                                      queue.pause(task, cancel: true),
                                    ),
                                    child: const Text('取消'),
                                  ),
                                if (task.output != null)
                                  TextButton(
                                    onPressed: () =>
                                        context.read<PlayerProvider>().playSong(
                                          Song(
                                            id: 'local_${task.output}',
                                            title: task.song.title,
                                            artist: task.song.artist,
                                            album: task.song.album,
                                            duration: task.song.duration,
                                            localPath: task.output,
                                            isOnline: false,
                                            localLyrics:
                                                (task.tags?['lyrics']
                                                        as Map?)?['text']
                                                    as String?,
                                          ),
                                        ),
                                    child: const Text('离线播放'),
                                  ),
                                if (!task.running &&
                                    task.status != DownloadStatus.queued)
                                  TextButton(
                                    onPressed: () =>
                                        downloadAction(queue.remove(task)),
                                    child: const Text('移除记录（保留成品）'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

String downloadFieldLabel(String field) =>
    const {
      'title': '歌名',
      'artists': '歌手',
      'album': '专辑',
      'trackNumber': '曲序',
      'date': '发行日期',
      'genres': '流派',
      'composers': '作曲者',
      'lyricists': '作词者',
    }[field] ??
    field;

void downloadAction(Future<void> action) {
  unawaited(
    action.catchError((Object error) {
      showToast('操作失败：${downloadError(error)}');
    }),
  );
}
