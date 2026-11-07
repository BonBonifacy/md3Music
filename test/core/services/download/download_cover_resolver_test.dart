import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:md3music/core/services/download/download_cover_resolver.dart';

void main() {
  test(
    'selects actual highest resolution and preserves original encoded bytes',
    () async {
      final root = await Directory.systemTemp.createTemp('md3-cover-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dio = Dio();
      final large = img.encodePng(img.Image(width: 96, height: 96));
      final small = img.encodePng(img.Image(width: 32, height: 32));
      server.listen((r) async {
        r.response.add(r.uri.path == '/0' ? large : small);
        await r.response.close();
      });
      try {
        final cover = await DownloadCoverResolver(dio).resolve(
          ['http://127.0.0.1:${server.port}/{size}'],
          '${root.path}/cover',
          CancelToken(),
        );
        expect((cover.width, cover.height), (96, 96));
        expect(cover.digest, sha256.convert(large).toString());
        expect(await File(cover.path).readAsBytes(), large);
      } finally {
        dio.close(force: true);
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
}
