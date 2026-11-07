import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/download/download_transfer.dart';
import 'package:md3music/data/models/download_task.dart';
import 'package:md3music/data/models/song.dart';

void main() {
  late Directory dir;
  late HttpServer server;
  late Dio dio;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('md3-transfer-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    dio = Dio();
  });
  tearDown(() async {
    dio.close(force: true);
    await server.close(force: true);
    await dir.delete(recursive: true);
  });
  DownloadTask task() => DownloadTask(
    id: newDownloadId(),
    song: const Song(
      id: 'hash',
      title: 't',
      artist: 'a',
      album: 'b',
      duration: Duration(seconds: 1),
      isOnline: true,
    ),
    owner: '',
    options: const DownloadOptions(),
    batchId: 'b',
  );
  final bytes = Uint8List.fromList([
    ...('ID3'.codeUnits),
    ...List.generate(300, (i) => i % 255),
  ]);
  test('a valid 206 appends only at the exact verified offset', () async {
    final t = task()..etag = '"same"';
    final path = '${dir.path}/audio';
    await File('$path.part').writeAsBytes(bytes.sublist(0, 100));
    server.listen((r) async {
      expect(r.headers.value('range'), 'bytes=100-');
      r.response.statusCode = 206;
      r.response.headers.set('etag', '"same"');
      r.response.headers.set(
        'content-range',
        'bytes 100-${bytes.length - 1}/${bytes.length}',
      );
      r.response.add(bytes.sublist(100));
      await r.response.close();
    });
    await DownloadTransfer(dio).transfer(
      t,
      'http://127.0.0.1:${server.port}/audio',
      path,
      CancelToken(),
      () {},
    );
    expect(await File(path).readAsBytes(), bytes);
    expect(t.format, 'mp3');
  });
  test('200 after a range request safely replaces partial data', () async {
    final t = task()..etag = '"old"';
    final path = '${dir.path}/audio';
    await File('$path.part').writeAsBytes([1, 2, 3]);
    server.listen((r) async {
      r.response.contentLength = bytes.length;
      r.response.add(bytes);
      await r.response.close();
    });
    await DownloadTransfer(dio).transfer(
      t,
      'http://127.0.0.1:${server.port}/audio',
      path,
      CancelToken(),
      () {},
    );
    expect(await File(path).readAsBytes(), bytes);
  });
  test('HTML is never published as an audio file', () async {
    server.listen((r) async {
      r.response.contentLength = 18;
      r.response.write('<html>error</html>');
      await r.response.close();
    });
    final path = '${dir.path}/audio';
    await expectLater(
      DownloadTransfer(dio).transfer(
        task(),
        'http://127.0.0.1:${server.port}',
        path,
        CancelToken(),
        () {},
      ),
      throwsFormatException,
    );
    expect(await File(path).exists(), false);
  });
  test('unknown-length responses need an independent API length', () async {
    server.listen((r) async {
      r.response.add(bytes);
      await r.response.close();
    });
    final path = '${dir.path}/unknown';
    await expectLater(
      DownloadTransfer(dio).transfer(
        task(),
        'http://127.0.0.1:${server.port}',
        path,
        CancelToken(),
        () {},
      ),
      throwsFormatException,
    );
    final t = task()..expectedBytes = bytes.length;
    await DownloadTransfer(dio).transfer(
      t,
      'http://127.0.0.1:${server.port}',
      path,
      CancelToken(),
      () {},
    );
    expect(await File(path).readAsBytes(), bytes);
  });
  test('a changed ETag cannot append another resource', () async {
    final t = task()..etag = 'old';
    final path = '${dir.path}/changed';
    await File('$path.part').writeAsBytes(bytes.take(100).toList());
    server.listen((r) async {
      r.response.statusCode = 206;
      r.response.headers.set('etag', 'new');
      r.response.headers.set(
        'content-range',
        'bytes 100-${bytes.length - 1}/${bytes.length}',
      );
      r.response.add(bytes.sublist(100));
      await r.response.close();
    });
    await expectLater(
      DownloadTransfer(dio).transfer(
        t,
        'http://127.0.0.1:${server.port}',
        path,
        CancelToken(),
        () {},
      ),
      throwsFormatException,
    );
    expect(await File(path).exists(), false);
    expect(await File('$path.part').exists(), false);
  });
}
