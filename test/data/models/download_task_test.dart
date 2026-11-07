import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/download_task.dart';

void main() {
  test('download names are exactly artist-title without added spaces', () {
    expect(downloadFileStem('歌手', '歌名'), '歌手-歌名');
    expect(
      downloadFileStem(' Artist Name ', ' Song Title '),
      'Artist Name-Song Title',
    );
    expect(downloadFileStem('AC/DC', 'A:B?'), 'AC_DC-A_B_');
    expect(downloadFileStem('CON', 'NUL'), '_CON-_NUL');
  });
  test('task IDs stay inside the Rust staging filename contract', () {
    final ids = List.generate(1000, (_) => newDownloadId());
    expect(ids.toSet().length, 1000);
    expect(
      ids.every(
        (s) =>
            RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$').hasMatch(s),
      ),
      true,
    );
  });
}
