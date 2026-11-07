import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../../../data/models/download_task.dart';

String audioFormat(Uint8List b) {
  if (b.length >= 4 && String.fromCharCodes(b.take(4)) == 'fLaC') return 'flac';
  if (b.length >= 3 && String.fromCharCodes(b.take(3)) == 'ID3') return 'mp3';
  if (b.length >= 2 && b[0] == 255 && (b[1] & 0xe0) == 0xe0) return 'mp3';
  if (b.length >= 12 && String.fromCharCodes(b.sublist(4, 8)) == 'ftyp') {
    return 'm4a';
  }
  if (b.length >= 4 && String.fromCharCodes(b.take(4)) == 'OggS') return 'ogg';
  throw const FormatException('响应不是支持的音频文件');
}

class DownloadTransfer {
  DownloadTransfer(this.dio);
  final Dio dio;
  Future<void> transfer(
    DownloadTask task,
    String url,
    String path,
    CancelToken cancel,
    void Function() progress,
  ) async {
    final part = File('$path.part');
    var offset = await part.exists() ? await part.length() : 0;
    final validator = task.etag ?? task.modified;
    if (offset > 0 && validator == null) {
      await part.delete();
      offset = 0;
    }
    final res = await dio.get<ResponseBody>(
      url,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'Accept-Encoding': 'identity',
          if (offset > 0) 'Range': 'bytes=$offset-',
          if (offset > 0) 'If-Range': validator,
        },
        validateStatus: (s) => s != null && (s == 200 || s == 206 || s == 416),
      ),
    );
    if (res.statusCode == 416) {
      await res.data?.stream.listen(null).cancel();
      if (await part.exists()) await part.delete();
      task.received = 0;
      throw const FormatException('续传范围失效，请继续以重新下载');
    }
    if (res.statusCode == 206) {
      final match = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(res.headers.value('content-range') ?? '');
      if (match == null ||
          int.parse(match.group(1)!) != offset ||
          int.parse(match.group(2)!) < offset ||
          int.parse(match.group(2)!) >= int.parse(match.group(3)!) ||
          (task.etag == null &&
              task.modified != null &&
              res.headers.value('last-modified') != null &&
              task.modified != res.headers.value('last-modified')) ||
          (task.etag != null &&
              res.headers.value('etag') != null &&
              task.etag != res.headers.value('etag'))) {
        await res.data?.stream.listen(null).cancel();
        if (await part.exists()) await part.delete();
        throw const FormatException('续传资源或范围发生变化');
      }
      task.total = int.parse(match.group(3)!);
    } else {
      offset = 0;
      task.total = int.tryParse(res.headers.value('content-length') ?? '') ?? 0;
    }
    task.etag = res.headers.value('etag');
    if (task.total > 4 * 1024 * 1024 * 1024) {
      await res.data?.stream.listen(null).cancel();
      throw const FormatException('音频超出 4 GiB 资源上限');
    }
    task.modified = res.headers.value('last-modified');
    task.received = offset;
    final sink = part.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    try {
      final body = res.data;
      if (body == null) throw const FormatException('音频响应为空');
      await for (final chunk in body.stream) {
        if (cancel.isCancelled) throw cancel.cancelError!;
        task.received += chunk.length;
        if (task.received > 4 * 1024 * 1024 * 1024) {
          throw const FormatException('音频超出 4 GiB 资源上限');
        }
        sink.add(chunk);
        await sink.flush();
        progress();
      }
    } finally {
      await sink.close();
    }
    if (cancel.isCancelled) throw cancel.cancelError!;
    if (task.total <= 0 && task.expectedBytes <= 0) {
      throw const FormatException('音源未提供文件长度，无法确认完整下载');
    }
    if (task.received == 0 ||
        (task.total > 0 && task.received != task.total) ||
        (task.expectedBytes > 0 && task.received != task.expectedBytes)) {
      throw const FormatException('音频长度不完整');
    }
    final file = await part.open();
    try {
      task.format = audioFormat(await file.read(16));
    } finally {
      await file.close();
    }
    await part.rename(path);
  }
}
