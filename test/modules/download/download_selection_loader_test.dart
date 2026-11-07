import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/playlist.dart';
import 'package:md3music/modules/playlist/playlist_songs_loader.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

class Pages implements KugouApiClient {
  Pages(this.fetch);
  final Future<List<KugouSongDetail>?> Function(int) fetch;
  @override
  bool get isLoggedIn => false;
  @override
  Future<List<KugouSongDetail>?> getPlaylistTrackAll({
    required String id,
    int page = 1,
    int pagesize = 30,
  }) => fetch(page);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  const list = Playlist(id: 'list', name: 'list', songCount: 230, songs: []);
  List<KugouSongDetail> page(int start, int count) => List.generate(
    count,
    (i) => KugouSongDetail(hash: 'hash${start + i}', songName: '歌${start + i}'),
  );
  test('all selection includes later pages in stable order', () async {
    final result = await PlaylistSongsLoader.fetchDetached(
      list,
      isInMyFavorites: false,
      client: Pages((p) async => p == 1 ? page(0, 200) : page(200, 30)),
    );
    expect(result.isComplete, true);
    expect(result.songs.length, 230);
    expect(result.songs.last.id, 'hash229');
  });
  test('repeated or missing pages can never report all songs loaded', () async {
    for (final next in [page(0, 200), null, <KugouSongDetail>[]]) {
      final result = await PlaylistSongsLoader.fetchDetached(
        list,
        isInMyFavorites: false,
        client: Pages((p) async => p == 1 ? page(0, 200) : next),
      );
      expect(result.isComplete, false);
      expect(result.songs.length, 200);
    }
  });
}
