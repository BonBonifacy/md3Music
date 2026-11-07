import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/download/download_metadata_resolver.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';

// Public /krm/audio and /album/detail response shape sampled on 2026-11-07.
class MetadataApi implements KugouApiClient {
  @override
  Future<Map<String, dynamic>?> getDownloadMetadataByAlbumAudioId(
    String id,
  ) async {
    expect(id, '32100650');
    return {
      'data': [
        {
          'base': {'album_audio_id': 32100650, 'songname': '晴天'},
          'extra': {'composer': '周杰伦', 'lyrics': '周杰伦', 'sort': 3, 'disc': 1},
          'album_info': {
            'album_id': 966846,
            'album_name': '叶惠美',
            'publish_date': '2003-07-31',
            'cover': 'https://cdn.example/{size}.jpg',
          },
          'authors': [
            {
              'base': {'author_name': '周杰伦'},
            },
          ],
          'tags': [
            {'pid': 3, 'name': '流行', 'is_publish': 1},
            {'pid': 7, 'name': '国语', 'is_publish': 1},
            {'pid': 4, 'name': '抒情', 'is_publish': 1},
          ],
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>?> getDownloadAlbumDetail(String id) async => {
    'data': [
      {'album_id': '966846', 'album_name': '叶惠美', 'publish_date': '2003-07-31'},
    ],
  };
  @override
  Future<Map<String, dynamic>?> getDownloadImages(
    String hash, {
    String? albumId,
    String? albumAudioId,
  }) async => {
    'data': [
      {
        'album': [
          {'album_id': 1, 'sizable_cover': 'https://cdn.example/wrong.jpg'},
          {
            'album_id': 966846,
            'sizable_cover': 'https://cdn.example/right.jpg',
          },
        ],
        'author': [
          {'sizable_cover': 'https://cdn.example/portrait.jpg'},
        ],
      },
    ],
  };
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test(
    'KRM roles, album order and style tags retain release identity',
    () async {
      final result = await DownloadMetadataResolver(MetadataApi()).resolve(
        Song(
          id: 'hash',
          albumAudioId: '32100650',
          albumId: '966846',
          title: 'selection',
          artist: 'artist',
          album: 'album',
          duration: Duration.zero,
          isOnline: true,
        ),
      );
      expect(result.fields['title'], '晴天');
      expect(result.fields['artists'], ['周杰伦']);
      expect(result.fields['composers'], ['周杰伦']);
      expect(result.fields['lyricists'], ['周杰伦']);
      expect(result.fields['trackNumber'], 3);
      expect(result.fields['discNumber'], 1);
      expect(result.fields['date'], '2003-07-31');
      expect(result.fields['genres'], ['流行']);
      expect(result.coverUrls, contains('https://cdn.example/right.jpg'));
      expect(
        result.coverUrls,
        isNot(contains('https://cdn.example/wrong.jpg')),
      );
      expect(
        result.coverUrls,
        isNot(contains('https://cdn.example/portrait.jpg')),
      );
    },
  );
  test('only explicit lyric credits fill lyricist and composer roles', () {
    final fields = <String, dynamic>{
          'artists': ['演唱者'],
        },
        provenance = <String, dynamic>{};
    addLyricCredits(
      fields,
      '[1000,100]<0,100,0>作词：词作者\n[2000,100]<0,100,0>作曲：曲作者\n编曲：编曲者',
      provenance,
    );
    expect(fields['lyricists'], ['词作者']);
    expect(fields['composers'], ['曲作者']);
    expect(fields['artists'], ['演唱者']);
  });
  test('structured artist names retain original name boundaries', () {
    expect(
      metadataNames([
        {
          'base': {'author_name': 'AC/DC'},
        },
        {'name': '歌手乙'},
      ]),
      ['AC/DC', '歌手乙'],
    );
  });
}
