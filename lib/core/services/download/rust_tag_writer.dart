import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

typedef _OpenNative = Uint64 Function(Pointer<Utf8>);
typedef _WriteNative = Pointer<Utf8> Function(Uint64, Pointer<Utf8>);
typedef _CloseNative = Void Function(Uint64);
typedef _FreeNative = Void Function(Pointer<Utf8>);

Map<String, dynamic> _writeTags(List<String> args) {
  final lib = DynamicLibrary.open(
    Platform.isWindows ? 'kugou_server.dll' : 'libkugou_server.so',
  );
  final open = lib.lookupFunction<_OpenNative, int Function(Pointer<Utf8>)>(
    'md3_tag_writer_open',
  );
  final write = lib
      .lookupFunction<_WriteNative, Pointer<Utf8> Function(int, Pointer<Utf8>)>(
        'md3_tag_writer_write',
      );
  final close = lib.lookupFunction<_CloseNative, void Function(int)>(
    'md3_tag_writer_close',
  );
  final free = lib.lookupFunction<_FreeNative, void Function(Pointer<Utf8>)>(
    'md3_tag_writer_free_json',
  );
  final root = args[0].toNativeUtf8(), request = args[1].toNativeUtf8();
  int handle = 0;
  Pointer<Utf8> response = nullptr;
  try {
    handle = open(root);
    if (handle == 0) throw StateError('无法初始化标签暂存目录');
    if (args.length > 2 && args[2] == 'inspect') {
      final inspect = lib
          .lookupFunction<
            _WriteNative,
            Pointer<Utf8> Function(int, Pointer<Utf8>)
          >('md3_tag_writer_inspect');
      response = inspect(handle, request);
    } else {
      response = write(handle, request);
    }
    if (response == nullptr) throw StateError('标签服务无响应');
    return Map<String, dynamic>.from(
      jsonDecode(response.toDartString()) as Map,
    );
  } finally {
    if (response != nullptr) free(response);
    if (handle != 0) close(handle);
    calloc.free(root);
    calloc.free(request);
  }
}

class RustTagWriter {
  Future<Map<String, dynamic>> inspect(String root, String id) async {
    try {
      return await Isolate.run(() => _writeTags([root, id, 'inspect']));
    } catch (error) {
      return {'ok': false, 'errorCode': '音频核验服务不可用，请重建原生库：$error'};
    }
  }

  Future<Map<String, dynamic>> write(
    String root,
    String id,
    Map<String, dynamic> fields,
  ) async {
    try {
      return await Isolate.run(
        () => _writeTags([
          root,
          jsonEncode({'schemaVersion': 1, 'jobId': id, 'fields': fields}),
        ]),
      );
    } catch (error) {
      return {'ok': false, 'errorCode': '标签服务不可用或原生库过旧：$error'};
    }
  }
}
