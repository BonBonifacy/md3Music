import '../../../data/models/song.dart';
import '../../../services/kugou_api/kugou_api_client.dart';

class DownloadMetadata {
  DownloadMetadata(this.fields, this.coverUrls, this.provenance);
  final Map<String, dynamic> fields, provenance;
  final List<String> coverUrls;
}

Map<String, dynamic> firstRecord(dynamic response) {
  if (response is! Map) return {};
  final data = response['data'] ?? response;
  if (data is List) {
    return data.isEmpty ? {} : Map<String, dynamic>.from(data.first as Map);
  }
  if (data is Map) {
    final list = data['info'];
    if (list is List && list.isNotEmpty && list.first is Map) {
      return Map<String, dynamic>.from(list.first as Map);
    }
    return Map<String, dynamic>.from(data);
  }
  return {};
}

/// Only explicit credit fields are interpreted as roles. Artist arrays are never composers.
List<String> metadataNames(dynamic v) {
  if (v is String) return v.trim().isEmpty ? [] : [v.trim()];
  if (v is List) {
    return v
        .expand(
          (x) => metadataNames(
            x is Map ? (x['name'] ?? x['author_name'] ?? x['base']) : x,
          ),
        )
        .toSet()
        .toList();
  }
  if (v is Map) return metadataNames(v['name'] ?? v['author_name']);
  return [];
}

class DownloadMetadataResolver {
  DownloadMetadataResolver(this.api);
  final KugouApiClient api;
  Future<DownloadMetadata> resolve(Song song) async {
    Map<String, dynamic> raw = {};
    if (song.albumAudioId?.isNotEmpty == true) {
      raw = firstRecord(
        await api.getDownloadMetadataByAlbumAudioId(song.albumAudioId!),
      );
    }
    final base = Map<String, dynamic>.from(raw['base'] as Map? ?? {});
    if (base['album_audio_id'] != null &&
        base['album_audio_id'].toString() != song.albumAudioId) {
      throw const FormatException('元数据发行版本与所选歌曲不符');
    }
    final albumInfo = Map<String, dynamic>.from(
      raw['album_info'] as Map? ?? {},
    );
    final albumId =
        (albumInfo['album_id'] ??
                albumInfo['id'] ??
                base['album_id'] ??
                song.albumId)
            ?.toString();
    if (song.albumId?.isNotEmpty == true && albumId != song.albumId) {
      throw const FormatException('专辑身份与所选歌曲不符');
    }
    Map<String, dynamic> album = {};
    if (albumId?.isNotEmpty == true) {
      album = firstRecord(await api.getDownloadAlbumDetail(albumId!));
    }
    final extra = Map<String, dynamic>.from(raw['extra'] as Map? ?? {});
    final values = {...albumInfo, ...extra, ...raw, ...base};
    final fields = <String, dynamic>{
      'title':
          (base['audio_name'] ??
                  base['songname'] ??
                  base['name'] ??
                  song.displayName)
              .toString(),
      'album':
          (album['album_name'] ??
                  albumInfo['album_name'] ??
                  base['album_name'] ??
                  song.album)
              .toString(),
    };
    final authors = metadataNames(raw['authors']);
    fields['artists'] = authors.isNotEmpty ? authors : [song.artist];
    fields['artists'] = (fields['artists'] as List<String>)
        .where((s) => !isUnknownArtist(s))
        .toList();
    if (isUnknownAlbum(fields['album'] as String)) fields.remove('album');
    final provenance = <String, dynamic>{
      'identity': song.albumAudioId ?? song.id,
      'title': base.isEmpty ? 'selection' : 'krm/base',
      'artists': authors.isEmpty ? 'selection' : 'krm/authors',
      'album': album.isEmpty ? 'selection' : 'album/detail',
    };
    final albumArtists = metadataNames(album['authors']);
    if (albumArtists.isNotEmpty) {
      fields['albumArtists'] = albumArtists;
      provenance['albumArtists'] = 'album/authors';
    }
    for (final entry in {
      'composers': ['composers', 'composer'],
      'lyricists': ['lyricists', 'lyricist'],
      'genres': ['genres', 'genre'],
    }.entries) {
      for (final key in entry.value) {
        final names = metadataNames(values[key]);
        if (names.isNotEmpty) {
          fields[entry.key] = names;
          provenance[entry.key] = 'krm/$key';
          break;
        }
      }
    }
    // /krm/audio extra.lyrics is the lyricist credit, not the lyric content.
    if (fields['lyricists'] == null &&
        metadataNames(extra['lyrics']).isNotEmpty) {
      fields['lyricists'] = metadataNames(extra['lyrics']);
      provenance['lyricists'] = 'krm/extra.lyrics';
    }
    if (fields['genres'] == null && raw['tags'] is List) {
      // KuGou KRM top-level published style tags have parent 3; language (7),
      // mood (4) and scene (5/6) must not be exported as genres.
      final genres = metadataNames(
        (raw['tags'] as List)
            .whereType<Map>()
            .where(
              (t) =>
                  t['pid']?.toString() == '3' &&
                  t['is_publish']?.toString() == '1',
            )
            .toList(),
      );
      if (genres.isNotEmpty) {
        fields['genres'] = genres;
        provenance['genres'] = 'krm/tags[pid=3,is_publish=1]';
      }
    }
    for (final pair in {'trackNumber': 'sort', 'discNumber': 'disc'}.entries) {
      final n = int.tryParse(extra[pair.value]?.toString() ?? '');
      if (n != null && n > 0 && n <= 65535) {
        fields[pair.key] = n;
        provenance[pair.key] = 'krm/extra.${pair.value}';
      }
    }
    final date =
        (album['publish_date'] ??
                albumInfo['publish_date'] ??
                base['publish_date'])
            ?.toString();
    if (date != null &&
        RegExp(r'^\d{4}(?:-\d{2})?(?:-\d{2})?').hasMatch(date)) {
      fields['date'] = RegExp(
        r'^\d{4}(?:-\d{2})?(?:-\d{2})?',
      ).firstMatch(date)!.group(0);
      provenance['date'] = 'album/publish_date';
    }
    for (final entry in {
      'trackNumber': ['track_number', 'track_no', 'tracknum'],
      'trackTotal': ['track_total'],
      'discNumber': ['disc_number', 'disc_no'],
      'discTotal': ['disc_total'],
    }.entries) {
      for (final key in entry.value) {
        final n = int.tryParse(values[key]?.toString() ?? '');
        if (n != null && n > 0 && n <= 65535) {
          fields[entry.key] = n;
          provenance[entry.key] = 'krm/$key';
          break;
        }
      }
    }
    final covers = <String>[];
    void add(dynamic value) {
      if (value is String && value.startsWith('http')) covers.add(value);
    }

    for (final m in [album, albumInfo]) {
      for (final key in [
        'sizable_cover',
        'album_sizable_cover',
        'cover',
        'img',
        'pic',
      ]) {
        add(m[key]);
      }
    }
    final images = await api.getDownloadImages(
      song.id,
      albumId: albumId,
      albumAudioId: song.albumAudioId,
    );
    void collect(dynamic node, {bool albumContext = false}) {
      if (node is List) {
        for (final item in node) {
          collect(item, albumContext: albumContext);
        }
      }
      if (node is Map) {
        if (albumContext &&
            node['album_id'] != null &&
            node['album_id'].toString() != albumId) {
          return;
        }
        for (final e in node.entries) {
          final k = e.key.toString().toLowerCase();
          if (k.contains('author') || k.contains('singer')) continue;
          final isAlbum = albumContext || k.contains('album');
          if (isAlbum &&
              (k.contains('cover') ||
                  k.contains('url') ||
                  k == 'img' ||
                  k == 'pic')) {
            add(e.value);
          }
          collect(e.value, albumContext: isAlbum);
        }
      }
    }

    collect(images);
    if (covers.isEmpty && song.artworkUri != null) add(song.artworkUri);
    return DownloadMetadata(fields, covers.toSet().toList(), provenance);
  }
}

void addLyricCredits(
  Map<String, dynamic> fields,
  String raw,
  Map<String, dynamic> provenance,
) {
  for (final pair in {'composers': '作曲', 'lyricists': '作词'}.entries) {
    if (fields[pair.key] != null) continue;
    // Strip only timing syntax, then accept a standalone, explicitly attributed credit line.
    final lines = raw
        .split(RegExp(r'\r?\n'))
        .map(
          (s) => s.replaceAll(RegExp(r'\[\d+[^\]]*\]|<[-\d,]+>'), '').trim(),
        );
    for (final line in lines) {
      final match = RegExp('^${pair.value}[：:]\\s*(.+)\$').firstMatch(line);
      if (match != null && match.group(1)!.length <= 512) {
        fields[pair.key] = [match.group(1)!.trim()];
        provenance[pair.key] = 'lyric/explicit-credit';
        break;
      }
    }
  }
}
