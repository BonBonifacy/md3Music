import '../../../widgets/apple_lyrics/models/lyric_line.dart';
import '../../../widgets/apple_lyrics/parsers/krc_parser.dart';
import '../../../services/kugou_api/kugou_models.dart';
import '../lyric_info_json_builder.dart' show lrcTagMs, elrcWordTag;

class DownloadLyrics {
  const DownloadLyrics(this.text, this.profile, this.wordTimed, {this.rawKrc});
  final String text, profile;
  final bool wordTimed;
  final String? rawKrc;
  Map<String, dynamic> toJson() => {
    'format': profile,
    'text': text,
    'wordTimed': wordTimed,
  };
}

DownloadLyrics exportDownloadLyrics(KugouLyric source) {
  final krc = source.decodedKrcContent ?? source.decodedContent ?? '';
  if (RegExp(r'^\[\d+,\d+\]', multiLine: true).hasMatch(krc)) {
    final lines = KrcParser.parse(krc);
    if (lines.any((l) => l.hasWordTiming)) {
      final offset =
          int.tryParse(
            RegExp(
                  r'^\[offset:(-?\d+)\]',
                  multiLine: true,
                ).firstMatch(krc)?.group(1) ??
                '0',
          ) ??
          0;
      return DownloadLyrics(
        serializeEsLyric(lines, offsetMs: offset),
        'eslyric_enhanced',
        true,
        rawKrc: krc,
      );
    }
  }
  final text = source.decodedContent ?? '';
  if (text.trim().isEmpty) throw const FormatException('没有可获取的歌词');
  return DownloadLyrics(
    text,
    RegExp(r'\[\d+:\d+').hasMatch(text) ? 'lrc' : 'plain',
    false,
  );
}

String serializeEsLyric(List<LyricLine> lines, {int offsetMs = 0}) {
  final result = StringBuffer();
  for (final line in lines) {
    if (line.text.isEmpty) continue;
    final start = line.startTime - offsetMs;
    if (start < 0) throw const FormatException('歌词偏移产生负时间');
    result.write(lrcTagMs(start));
    if (line.words.isEmpty) {
      result.writeln(line.text);
      continue;
    }
    int? boundary;
    for (final word in line.words) {
      final t = word.startTime - offsetMs, end = t + word.duration;
      if (t < 0 || word.duration <= 0 || (boundary != null && t < boundary)) {
        throw const FormatException('逐字歌词时间边界无效');
      }
      if (boundary != t) result.write(elrcWordTag(t));
      result.write(word.text);
      result.write(elrcWordTag(end));
      boundary = end;
    }
    result.writeln();
  }
  if (result.isEmpty) throw const FormatException('逐字歌词为空');
  return result.toString().trimRight();
}
