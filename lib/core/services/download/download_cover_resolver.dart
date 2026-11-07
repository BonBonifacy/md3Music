import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

class DownloadCover {
  const DownloadCover(this.path, this.width, this.height, this.digest);
  final String path, digest;
  final int width, height;
  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'sha256': digest,
  };
}

(int, int)? imageDimensions(Uint8List b) {
  if (b.length >= 24 && b[0] == 137 && b[1] == 80 && b[2] == 78 && b[3] == 71) {
    final data = ByteData.sublistView(b);
    return (data.getUint32(16), data.getUint32(20));
  }
  if (b.length < 4 || b[0] != 255 || b[1] != 216) return null;
  var p = 2;
  while (p + 4 <= b.length) {
    if (b[p] != 255) return null;
    while (p < b.length && b[p] == 255) {
      p++;
    }
    if (p >= b.length) break;
    final marker = b[p++];
    if (marker == 0xd9 || marker == 0xda) break;
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue;
    if (p + 2 > b.length) break;
    final n = (b[p] << 8) | b[p + 1];
    if (n < 2 || p + n > b.length) return null;
    if ([
          0xc0,
          0xc1,
          0xc2,
          0xc3,
          0xc5,
          0xc6,
          0xc7,
          0xc9,
          0xca,
          0xcb,
          0xcd,
          0xce,
          0xcf,
        ].contains(marker) &&
        n >= 7) {
      return ((b[p + 5] << 8) | b[p + 6], (b[p + 3] << 8) | b[p + 4]);
    }
    p += n;
  }
  return null;
}

class DownloadCoverResolver {
  DownloadCoverResolver(this.dio);
  final Dio dio;
  Future<DownloadCover> resolve(
    List<String> urls,
    String path,
    CancelToken cancel,
  ) async {
    DownloadCover? best;
    bool exceeded = false;
    for (final raw in urls) {
      final variants = raw.contains('{size}')
          ? [
              for (final size in [
                '0',
                '4000',
                '2000',
                '1080',
                '1000',
                '800',
                '400',
              ])
                raw.replaceAll('{size}', size),
            ]
          : [raw];
      for (final url in variants) {
        if (cancel.isCancelled) throw cancel.cancelError!;
        try {
          final uri = Uri.parse(url);
          if (!['https', 'http'].contains(uri.scheme)) continue;
          final res = await dio.get<ResponseBody>(
            url,
            options: Options(responseType: ResponseType.stream),
            cancelToken: cancel,
          );
          final stream = res.data;
          if (stream == null) continue;
          final bytes = BytesBuilder(copy: false);
          var count = 0;
          await for (final chunk in stream.stream) {
            count += chunk.length;
            if (count > 64 * 1024 * 1024) {
              exceeded = true;
              throw const FormatException('封面超出资源上限');
            }
            bytes.add(chunk);
          }
          final b = bytes.takeBytes();
          final size = imageDimensions(b);
          if (size != null && size.$1 * size.$2 > 100000000) {
            exceeded = true;
          }
          if (size == null ||
              size.$1 <= 0 ||
              size.$2 <= 0 ||
              size.$1 * size.$2 > 100000000) {
            continue;
          }
          if (best == null || size.$1 * size.$2 > best.width * best.height) {
            await File(path).writeAsBytes(b, flush: true);
            best = DownloadCover(
              path,
              size.$1,
              size.$2,
              sha256.convert(b).toString(),
            );
          }
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) rethrow;
        } catch (_) {
          if (cancel.isCancelled) throw cancel.cancelError!;
        }
      }
    }
    if (exceeded) throw const FormatException('原图超过资源上限，未自动降清晰度');
    if (best == null) throw const FormatException('未取得有效的专辑封面');
    return best;
  }
}
