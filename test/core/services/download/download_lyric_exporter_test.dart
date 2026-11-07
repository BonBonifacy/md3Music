import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/download/download_lyric_exporter.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/lrc_parser.dart';

void main() {
  test('KRC conversion retains final word end and silence', () {
    const krc = '[1000,1200]<0,200,0>你<500,300,0>好';
    final result = exportDownloadLyrics(
      const KugouLyric(content: '', decodedKrcContent: krc),
    );
    expect(result.wordTimed, true);
    expect(result.profile, 'eslyric_enhanced');
    expect(
      result.text,
      '[00:01.000]<00:01.000>你<00:01.200><00:01.500>好<00:01.800>',
    );
    final lines = LrcParser.parse(result.text);
    expect(lines.single.words.map((w) => w.startTime), [1000, 1500]);
    expect(lines.single.words.map((w) => w.duration), [200, 300]);
  });
  test('line-only source is explicitly not word timed', () {
    final result = exportDownloadLyrics(
      const KugouLyric(content: '', decodedContent: '[00:01.000]line'),
    );
    expect(result.wordTimed, false);
    expect(result.profile, 'lrc');
  });
  test('bad real-word timing is rejected rather than flattened', () {
    expect(
      () => serializeEsLyric([
        const LyricLine(
          startTime: 0,
          duration: 100,
          text: 'a',
          words: [LyricWord(startTime: 0, duration: 0, text: 'a')],
        ),
      ]),
      throwsFormatException,
    );
  });
}
