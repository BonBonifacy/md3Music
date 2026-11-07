import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../data/models/download_task.dart';
import '../../providers/download_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import 'download_page.dart';

void openDownloads(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const DownloadPage()));

Future<void> startDownload(
  BuildContext context,
  Future<List<Song>> Function() selection,
) async {
  final queue = context.read<DownloadProvider>();
  var quality = KugouQuality.lossless, fallback = true;
  String? destination;
  final options = await showDialog<DownloadOptions>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, setState) => AlertDialog(
        title: const Text('下载音乐'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: quality,
                decoration: const InputDecoration(labelText: '优先音质'),
                items: [
                  for (final e in KugouQuality.labels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => quality = v ?? quality),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('允许音质降级'),
                value: fallback,
                onChanged: (v) => setState(() => fallback = v),
              ),
              const Text(
                '文件名：歌手-歌名\n最高可用原图封面 · ESLyric 逐字歌词\n歌名、歌手、专辑、曲序、日期、流派及词曲作者',
              ),
              const SizedBox(height: 12),
              Text(
                destination ??
                    (Platform.isAndroid
                        ? '共享音乐库 Music/MD3Music（旧系统请选目录）'
                        : '文档/MD3Music/Downloads'),
              ),
              TextButton.icon(
                icon: const Icon(Icons.folder_open),
                label: const Text('选择保存目录'),
                onPressed: () async {
                  try {
                    final dir = Platform.isAndroid
                        ? await queue.publisher.pickAndroidDirectory()
                        : await getDirectoryPath();
                    if (dialog.mounted && dir != null) {
                      setState(() => destination = dir);
                    }
                  } catch (e) {
                    showToast('无法取得目录写权限：$e');
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialog,
              DownloadOptions(
                quality: quality,
                allowFallback: fallback,
                destination: destination,
              ),
            ),
            child: const Text('加入下载队列'),
          ),
        ],
      ),
    ),
  );
  if (options == null) return;
  showToast('正在读取下载曲目');
  try {
    final songs = await selection();
    final count = await queue.enqueue(songs, options);
    showToast(count > 0 ? '已加入 $count 首，请在下载管理查看' : '没有新增任务：曲目已入队或来源不支持');
  } catch (e) {
    showToast('无法加入下载：$e', long: true);
  }
}

class DownloadSongAction extends StatelessWidget {
  const DownloadSongAction({super.key, required this.song});
  final Song song;
  @override
  Widget build(BuildContext context) {
    if (!song.isOnline || song.isCloud || song.isLongAudio) {
      return const SizedBox.shrink();
    }
    return ListTile(
      leading: const Icon(Icons.download_outlined),
      title: const Text('下载歌曲'),
      onTap: () async {
        await startDownload(context, () async => [song]);
        if (context.mounted) Navigator.pop(context);
      },
    );
  }
}
