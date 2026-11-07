import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../../data/models/download_task.dart';

class DownloadPublisher {
  final _cancelled = <String>{};
  final _committed = <String, String>{};
  void beginRetry(String id) {
    _committed.remove(id);
  }

  static const channel = MethodChannel('com.md3music.md3music/downloads');
  Future<String?> cancel(String id) async {
    _cancelled.add(id);
    if (!Platform.isAndroid) return _committed[id];
    return channel.invokeMethod<String>('cancel', {'id': id});
  }

  Future<String?> pickAndroidDirectory() =>
      channel.invokeMethod<String>('pickDirectory');
  Future<String> publish(DownloadTask task, String source, String stem) async {
    _cancelled.remove(task.id);
    final name = '$stem.${task.format}';
    if (Platform.isAndroid) {
      final uri = await channel.invokeMethod<String>('publish', {
        'id': task.id,
        'source': source,
        'name': name,
        'destination': task.options.destination,
        'mime': task.format == 'flac'
            ? 'audio/flac'
            : task.format == 'mp3'
            ? 'audio/mpeg'
            : 'audio/${task.format}',
      });
      if (uri == null) throw const FileSystemException('保存音频失败');
      return uri;
    }
    final dir = Directory(
      task.options.destination ??
          '${(await getApplicationDocumentsDirectory()).path}/MD3Music/Downloads',
    );
    await dir.create(recursive: true);
    // A deterministic per-task staging filename makes publication restartable.
    final temp = File('${dir.path}/.${task.id}.part');
    final journal = File(
      '${File(source).parent.path}/${task.id}.publication.json',
    );
    final digest = (await sha256.bind(File(source).openRead()).first)
        .toString();
    if (await journal.exists()) {
      final saved = jsonDecode(await journal.readAsString()) as Map;
      final old = File(saved['target'] as String);
      if (old.parent.absolute.path == dir.absolute.path &&
          saved['sha256'] == digest &&
          await old.exists() &&
          (await sha256.bind(old.openRead()).first).toString() == digest) {
        _committed[task.id] = old.path;
        return old.path;
      }
    }
    var target = File('${dir.path}/$name');
    if (task.output != null && await File(task.output!).exists()) {
      return task.output!;
    }
    var suffix = 0;
    while (await target.exists()) {
      suffix++;
      target = File(
        '${dir.path}/$stem(${task.id.substring(0, 8)}${suffix == 1 ? '' : '-$suffix'}).${task.format}',
      );
    }
    await File(source).copy(temp.path);
    await journal.writeAsString(
      jsonEncode({'target': target.path, 'sha256': digest}),
      flush: true,
    );
    if (_cancelled.contains(task.id)) {
      await temp.delete();
      throw StateError('已取消保存');
    }
    if (Platform.isWindows) {
      // MoveFileW fails on an existing target, unlike File.rename which can replace it.
      final move = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
            int Function(Pointer<Utf16>, Pointer<Utf16>)
          >('MoveFileW');
      final a = temp.path.toNativeUtf16(), b = target.path.toNativeUtf16();
      try {
        if (move(a, b) == 0) {
          throw FileSystemException('目标不可写或文件名已存在', target.path);
        }
      } finally {
        calloc.free(a);
        calloc.free(b);
      }
    } else {
      if (await target.exists()) {
        throw FileSystemException('文件已存在', target.path);
      }
      await temp.rename(target.path);
    }
    _committed[task.id] = target.path;
    return target.path;
  }
}
