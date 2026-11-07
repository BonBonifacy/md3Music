// Online smoke check against a public artwork template; stores only the selected raw image.
// dart run scripts/tools/verify_download_cover.dart TEMPLATE OUTPUT
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:md3music/core/services/download/download_cover_resolver.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) throw ArgumentError('TEMPLATE OUTPUT required');
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );
  try {
    final result = await DownloadCoverResolver(
      dio,
    ).resolve([args[0]], args[1], CancelToken());
    stdout.writeln(jsonEncode(result.toJson()));
  } finally {
    dio.close(force: true);
  }
}
