import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart' show compute;

/// 本地歌词加载器：内嵌歌词优先，其次读取同目录同名歌词文件。
///
/// 本地音乐歌词来源（参考 Lyrico 歌词文件约定）：
/// 1. 音频内嵌歌词（ID3 USLT / SYLT、Vorbis LYRICS、MP4 ©lyr）—— 最高优先；
/// 2. 音频同目录同名歌词文件（.lrc / .ttml / .txt，按此顺序查找）。
class LocalLyricLoader {
  LocalLyricLoader._();

  /// 支持的本地歌词文件扩展名（按优先级排列）。
  static const List<String> lyricExtensions = ['.lrc', '.ttml', '.txt'];

  /// compute 超时不会取消后台 isolate；限制同时解析的本地音乐歌词任务，
  /// 防止快速切歌时多个大 ID3/FLAC 标签解析任务堆积。
  static String? _activeAsyncReadPath;
  static Future<String?>? _activeAsyncRead;

  /// 需要缓冲完整文件或标签时的读取上限，避免大音频和大封面占用过多内存。
  static const int _maxEmbeddedReadBytes = 16 * 1024 * 1024;

  /// 优先使用扫描阶段缓存的歌词（如 SAF `content://`），再按普通本地路径读取。
  static Future<String?> loadForSongAsync({
    required String? localPath,
    String? cachedLyrics,
  }) async {
    if (cachedLyrics != null && cachedLyrics.isNotEmpty) return cachedLyrics;
    if (localPath == null || localPath.isEmpty) return null;
    return loadForAudioAsync(localPath);
  }

  /// 加载本地歌曲歌词：先内嵌，无内嵌时查找同目录同名歌词文件。
  ///
  /// 兼容 file:// URI 与裸绝对路径。返回歌词文本，无则 null。
  static String? loadForAudio(String filePath) {
    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    if (path.isEmpty) return null;

    final embedded = _readEmbeddedLyrics(path);
    if (embedded != null && embedded.isNotEmpty) return embedded;

    return _findSidecarLyric(path);
  }

  /// 异步版本：把内嵌歌词的元数据读取与侧车歌词文件读取整体移入后台 isolate
  /// 执行，并带超时兜底。任何耗时/异常/超时都不会阻塞主隔离区（避免在切歌/播放
  /// 瞬间拖垮 UI 甚至被判定为无响应而崩溃）；返回 null 时由调用方回退到酷狗接口。
  static Future<String?> loadForAudioAsync(String filePath) async {
    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    if (path.isEmpty) return null;

    final active = _activeAsyncRead;
    if (active != null) {
      // 同一首歌复用解析任务；不同歌曲等当前 isolate 结束后串行启动，避免并发
      // 解析占用内存。旧逻辑在路径不同时直接返回 null，快速切歌就会丢掉新歌歌词。
      if (_activeAsyncReadPath != path) {
        try {
          await active.timeout(const Duration(seconds: 5));
        } catch (_) {
          return null;
        }
        return loadForAudioAsync(path);
      }
      try {
        return await active.timeout(const Duration(seconds: 5));
      } catch (_) {
        return null;
      }
    }

    final read = Future<String?>.sync(
      () => compute(_loadForAudioInIsolate, path),
    );
    _activeAsyncReadPath = path;
    _activeAsyncRead = read;
    void clearRead() {
      if (identical(_activeAsyncRead, read)) {
        _activeAsyncReadPath = null;
        _activeAsyncRead = null;
      }
    }

    // 超时只结束调用方等待，底层 compute 仍运行；完成前不能释放并发闸门。
    read.then<void>((_) => clearRead(), onError: (_, _) => clearRead());
    try {
      return await read.timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }

  /// 读取音频内嵌歌词（ID3 USLT / SYLT / Vorbis LYRICS / MP4 ©lyr）。
  ///
  /// FLAC 特殊处理：audio_metadata_reader 1.4.1 的 FlacParser 用
  /// `comment.split("=")[1]` 解析 Vorbis comment，含 `=` 的歌词值
  /// （如 TTML XML 声明的 `version="1.0"`）会被截断到第一个 `=`，
  /// 因此 FLAC 内嵌歌词改为手动解析 LYRICS 标签（取第一个 `=` 后完整值）。
  static String? _readEmbeddedLyrics(String filePath) {
    final lowerPath = filePath.toLowerCase();
    final isMp3 = lowerPath.endsWith('.mp3');
    if (lowerPath.endsWith('.flac')) {
      final flacLyrics = _readFlacLyrics(filePath);
      if (flacLyrics != null && flacLyrics.isNotEmpty) return flacLyrics;
    }
    // MP3 的 USLT 自行解析：audio_metadata_reader 1.8.1 取正文时用
    // `rest.sublist(1, ...)`，会把 LRC 首行的 `[` 一并吞掉，首行变成
    // `00:26.400]...`，被 LyricParserChain 误判为静态歌词并原样显示时间戳。
    if (isMp3) {
      final usltLyrics = _readMp3UsltLyrics(filePath);
      if (usltLyrics != null && usltLyrics.isNotEmpty) return usltLyrics;
    }
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      if (file.lengthSync() <= _maxEmbeddedReadBytes) {
        final lyrics = readMetadata(file, getImage: false).lyrics;
        if (lyrics != null && lyrics.isNotEmpty) return lyrics;
      }
    } catch (_) {}

    // USLT 和通用元数据优先，SYLT 为 MP3 提供同步歌词回退。
    return isMp3 ? _readMp3SyncedLyrics(filePath) : null;
  }

  /// 读取 MP3 ID3v2 USLT（Unsynchronised lyrics/text）帧的完整歌词正文。
  ///
  /// 格式：编码(1) + 语言(3) + 内容描述符 + 终止符 + 歌词正文。
  /// 第三方库在该帧上会吞掉正文首字符，所以这里按规范自行截取。
  static String? _readMp3UsltLyrics(String filePath) =>
      _readMp3TagFrame(filePath, 'USLT', _parseUsltPayload);

  /// 解析 USLT 帧载荷，返回完整歌词正文（不做任何截断）。
  static String? _parseUsltPayload(List<int> payload) {
    if (payload.length < 5) return null;
    final encoding = payload[0];
    if (encoding > 3) return null;
    // 跳过编码字节与 3 字节语言码后，先读到内容描述符的终止符。
    final descriptionEnd = _findId3Terminator(payload, 4, encoding);
    if (descriptionEnd < 0) return null;
    final textStart = descriptionEnd + _id3TerminatorLength(encoding);
    if (textStart >= payload.length) return null;
    final text = _decodeId3Text(payload, textStart, payload.length, encoding);
    return text.trim().isEmpty ? null : text;
  }

  /// 读取 MP3 ID3v2 SYLT（Synchronized lyric/text）帧。
  ///
  /// SYLT 的每条文本都带一个毫秒时间戳，但不同写入器可能按整行或按词写入。
  /// 这里把每条记录转换成普通 LRC 行，目标是保证 MD3/AM 至少能正常显示歌词文本；
  /// 不在本地读取层改变现有 AppleLyricsView 的逐字渲染逻辑。
  static String? _readMp3SyncedLyrics(String filePath) =>
      _readMp3TagFrame(filePath, 'SYLT', _parseSyltPayload);

  static String? _parseSyltPayload(List<int> payload) {
    final entries = _parseSylt(payload);
    final lyrics = _formatSyltAsLrc(entries);
    return lyrics != null && lyrics.isNotEmpty ? lyrics : null;
  }

  /// 按帧长度跳过封面等无关数据，将匹配 [frameId] 的载荷交给 [parse]。
  static String? _readMp3TagFrame(
    String filePath,
    String frameId,
    String? Function(List<int> payload) parse,
  ) {
    RandomAccessFile? file;
    try {
      final input = File(filePath).openSync();
      file = input;
      final header = input.readSync(10);
      if (header.length < 10 ||
          header[0] != 0x49 ||
          header[1] != 0x44 ||
          header[2] != 0x33) {
        return null;
      }

      final version = header[3];
      if (version != 3 && version != 4) return null;
      final tagSize = _readSynchsafeInt(header, 6);
      final available = input.lengthSync() - 10;
      final readLength = tagSize < available ? tagSize : available;
      if (readLength <= 0) return null;

      final tagUnsynchronized = (header[5] & 0x80) != 0;
      // ID3v2.3 对整个标签应用去同步，须先还原字节才能读取原帧长度。
      // ID3v2.4 的长度按磁盘上的帧计算，可以直接跳过不需要的数据。
      List<int>? restoredTag;
      if (version == 3 && tagUnsynchronized) {
        if (readLength > _maxEmbeddedReadBytes) return null;
        restoredTag = _removeId3Unsynchronization(input.readSync(readLength));
      }
      final tag = restoredTag;
      final tagEnd = tag?.length ?? readLength;
      List<int> readTag(int offset, int length) {
        if (tag != null) return tag.sublist(offset, offset + length);
        input.setPositionSync(10 + offset);
        return input.readSync(length);
      }

      var offset = 0;
      if ((header[5] & 0x40) != 0) {
        if (tagEnd < 4) return null;
        final size = readTag(0, 4);
        if (size.length != 4) return null;
        offset = version == 4
            ? _readSynchsafeInt(size, 0)
            : 4 + _readUint32Be(size, 0);
        if (offset < 4 || offset > tagEnd) return null;
      }

      for (var frames = 0; frames < 16384 && offset + 10 <= tagEnd; frames++) {
        final frameHeader = readTag(offset, 10);
        if (frameHeader.length != 10 || frameHeader[0] == 0) break;
        final frameSize = version == 4
            ? _readSynchsafeInt(frameHeader, 4)
            : _readUint32Be(frameHeader, 4);
        final frameStart = offset + 10;
        offset = frameStart + frameSize;
        if (frameSize <= 0 || offset > tagEnd) break;
        if (frameSize > _maxEmbeddedReadBytes ||
            String.fromCharCodes(frameHeader.take(4)) != frameId) {
          continue;
        }

        final formatFlags = frameHeader[9];
        final compressedOrEncrypted = version == 4 ? 0x0c : 0xc0;
        if ((formatFlags & compressedOrEncrypted) != 0) continue;

        var payload = readTag(frameStart, frameSize);
        if (payload.length != frameSize) break;
        if (version == 4 && (tagUnsynchronized || (formatFlags & 0x02) != 0)) {
          payload = _removeId3Unsynchronization(payload);
        }
        final groupingFlag = version == 4 ? 0x40 : 0x20;
        final groupIdLength = (formatFlags & groupingFlag) != 0 ? 1 : 0;
        final dataLengthIndicator = version == 4 && (formatFlags & 0x01) != 0
            ? 4
            : 0;
        final payloadStart = groupIdLength + dataLengthIndicator;
        if (payloadStart >= payload.length) continue;
        final lyrics = parse(
          payloadStart == 0 ? payload : payload.sublist(payloadStart),
        );
        if (lyrics != null && lyrics.isNotEmpty) return lyrics;
      }
    } catch (_) {
      return null;
    } finally {
      file?.closeSync();
    }
    return null;
  }

  static int _readSynchsafeInt(List<int> bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return ((bytes[offset] & 0x7F) << 21) |
        ((bytes[offset + 1] & 0x7F) << 14) |
        ((bytes[offset + 2] & 0x7F) << 7) |
        (bytes[offset + 3] & 0x7F);
  }

  static int _readUint32Be(List<int> bytes, int offset) {
    if (offset < 0 || offset + 4 > bytes.length) return 0;
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static List<int> _removeId3Unsynchronization(List<int> bytes) {
    final result = <int>[];
    for (var i = 0; i < bytes.length; i++) {
      result.add(bytes[i]);
      if (bytes[i] == 0xFF && i + 1 < bytes.length && bytes[i + 1] == 0x00) {
        i++;
      }
    }
    return result;
  }

  static List<_SyltEntry> _parseSylt(List<int> payload) {
    if (payload.length < 7) return const [];
    final encoding = payload[0];
    if (encoding > 3) return const [];
    // SYLT timestamp format 2 is milliseconds. MPEG-frame timestamps cannot be
    // converted without the audio stream's frame rate, so leave them untouched.
    if (payload[4] != 2) return const [];

    var offset = 1 + 3 + 1 + 1;
    final descriptionEnd = _findId3Terminator(payload, offset, encoding);
    if (descriptionEnd < 0) return const [];
    offset = descriptionEnd + _id3TerminatorLength(encoding);

    final entries = <_SyltEntry>[];
    while (offset < payload.length) {
      final textEnd = _findId3Terminator(payload, offset, encoding);
      if (textEnd < 0 ||
          textEnd + _id3TerminatorLength(encoding) + 4 > payload.length) {
        break;
      }
      final text = _decodeId3Text(payload, offset, textEnd, encoding).trim();
      offset = textEnd + _id3TerminatorLength(encoding);
      final timestamp = _readUint32Be(payload, offset);
      offset += 4;
      if (text.isNotEmpty) entries.add(_SyltEntry(text, timestamp));
    }
    return entries;
  }

  static int _id3TerminatorLength(int encoding) =>
      encoding == 1 || encoding == 2 ? 2 : 1;

  static int _findId3Terminator(List<int> bytes, int start, int encoding) {
    final length = _id3TerminatorLength(encoding);
    if (length == 1) {
      for (var i = start; i < bytes.length; i++) {
        if (bytes[i] == 0) return i;
      }
      return -1;
    }
    for (var i = start; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) return i;
    }
    return -1;
  }

  static String _decodeId3Text(
    List<int> bytes,
    int start,
    int end,
    int encoding,
  ) {
    final value = bytes.sublist(start, end);
    switch (encoding) {
      case 0:
        return latin1.decode(value);
      case 3:
        return utf8.decode(value, allowMalformed: true);
      case 1:
      case 2:
        return _decodeUtf16(value, littleEndian: encoding == 1);
      default:
        return '';
    }
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    var start = 0;
    var little = littleEndian;
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      little = true;
      start = 2;
    } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      little = false;
      start = 2;
    }
    final codeUnits = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      codeUnits.add(
        little
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(codeUnits);
  }

  static String? _formatSyltAsLrc(List<_SyltEntry> entries) {
    if (entries.isEmpty) return null;
    entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final buffer = StringBuffer();
    for (final entry in entries) {
      final minutes = entry.timestamp ~/ 60000;
      final seconds = (entry.timestamp % 60000) ~/ 1000;
      final milliseconds = entry.timestamp % 1000;
      final text = entry.text.replaceAll(RegExp(r'\r?\n'), ' ').trim();
      if (text.isEmpty) continue;
      buffer
        ..write('[')
        ..write(minutes.toString().padLeft(2, '0'))
        ..write(':')
        ..write(seconds.toString().padLeft(2, '0'))
        ..write('.')
        ..write(milliseconds.toString().padLeft(3, '0'))
        ..write(']')
        ..writeln(text);
    }
    final result = buffer.toString().trimRight();
    return result.isEmpty ? null : result;
  }

  /// 手动解析 FLAC 的 Vorbis comment，读取 LYRICS 标签完整值。
  ///
  /// FLAC metadata block：1 字节头（last 标志 + block type）+ 3 字节大端长度；
  /// block type 4 = VORBIS_COMMENT，内部为小端长度 + UTF-8 字符串的序列。
  static String? _readFlacLyrics(String filePath) {
    RandomAccessFile? file;
    try {
      final input = File(filePath).openSync();
      file = input;
      final fileLength = input.lengthSync();
      if (String.fromCharCodes(input.readSync(4)) != 'fLaC') return null;

      int readUint32() =>
          ByteData.sublistView(input.readSync(4)).getUint32(0, Endian.little);

      for (
        var blocks = 0;
        blocks < 4096 && input.positionSync() + 4 <= fileLength;
        blocks++
      ) {
        final header = input.readSync(4);
        if (header.length != 4) return null;
        final blockLength = (header[1] << 16) | (header[2] << 8) | header[3];
        final blockEnd = input.positionSync() + blockLength;
        if (blockEnd > fileLength) return null;
        if ((header[0] & 0x7f) == 4) {
          if (blockLength < 8) return null;
          final vendorLength = readUint32();
          final vendorEnd = input.positionSync() + vendorLength;
          if (vendorEnd + 4 > blockEnd) return null;
          input.setPositionSync(vendorEnd);
          final count = readUint32();
          if (count > 1000000) return null;
          for (var i = 0; i < count; i++) {
            if (input.positionSync() + 4 > blockEnd) return null;
            final size = readUint32();
            final commentEnd = input.positionSync() + size;
            if (commentEnd > blockEnd) return null;
            if (size <= 1024 * 1024 + 128) {
              final comment = utf8.decode(input.readSync(size));
              final separator = comment.indexOf('=');
              if (separator > 0 &&
                  comment.substring(0, separator).toUpperCase() == 'LYRICS') {
                return comment.substring(separator + 1);
              }
            } else {
              input.setPositionSync(commentEnd);
            }
          }
          return null;
        }
        if ((header[0] & 0x80) != 0) break;
        input.setPositionSync(blockEnd);
      }
    } catch (_) {
      return null;
    } finally {
      file?.closeSync();
    }
    return null;
  }

  /// 查找音频同目录下的同名歌词文件（.lrc / .ttml / .txt 优先级）。
  static String? _findSidecarLyric(String audioPath) {
    try {
      final audio = File(audioPath);
      if (!audio.existsSync()) return null;
      final dir = audio.parent;
      final baseName = audioPath.split(Platform.pathSeparator).last;
      final dot = baseName.lastIndexOf('.');
      final stem = dot > 0 ? baseName.substring(0, dot) : baseName;

      for (final ext in lyricExtensions) {
        final candidate = File('${dir.path}${Platform.pathSeparator}$stem$ext');
        if (candidate.existsSync()) {
          return candidate.readAsStringSync();
        }
      }
    } catch (_) {}
    return null;
  }
}

/// compute isolate 的工作函数：在后台 isolate 中同步执行完整歌词加载。
String? _loadForAudioInIsolate(String path) =>
    LocalLyricLoader.loadForAudio(path);

class _SyltEntry {
  final String text;
  final int timestamp;

  const _SyltEntry(this.text, this.timestamp);
}
