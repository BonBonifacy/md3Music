import 'package:flutter/widgets.dart';

import '../../data/models/playlist.dart';
import '../../data/models/song.dart';
import '../../data/repositories/favorite_lists_cache.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../utils/playlist_song_sort.dart';

/// 歌单歌曲加载结果。[apiSucceeded] 用于区分「空歌单」与「网络失败」；
/// [isComplete] 为 false 表示分页中途失败、[songs] 只是部分数据
/// （此时不应覆盖本地缓存，详情页应提示重试）。
class PlaylistSongsResult {
  final List<Song> songs;
  final bool apiSucceeded;
  final bool isComplete;
  const PlaylistSongsResult(
    this.songs,
    this.apiSucceeded, {
    this.isComplete = true,
  });
}

/// 歌单歌曲加载器：歌单详情页与收藏页「封面一键播放」共用同一套
/// 「listid / global_collection_id 接口 + 本地缓存」解析逻辑，
/// 避免出现第二套歌单解析实现（见改版计划四）。
class PlaylistSongsLoader {
  /// 「我的收藏」歌单的本地缓存 key。与歌单详情页一致：
  /// subscribedListId 优先，其次 listCreateListid，最后 id。
  static String? cacheKey(Playlist playlist, {required bool isInMyFavorites}) {
    if (!isInMyFavorites) return null;
    final key =
        playlist.subscribedListId ?? playlist.listCreateListid ?? playlist.id;
    return key.isEmpty ? null : key;
  }

  /// 读取本地缓存歌曲（无网络 / 秒开时先用）。失败或无缓存返回空列表。
  static Future<List<Song>> readCached(
    Playlist playlist, {
    required bool isInMyFavorites,
  }) async {
    final key = cacheKey(playlist, isInMyFavorites: isInMyFavorites);
    if (key == null) return const [];
    try {
      return sortSongsByPlaylistPosition(
        await FavoriteListsCache.readPlaylistSongs(key),
      );
    } catch (_) {
      return const [];
    }
  }

  /// 拉取歌单完整歌曲。与歌单详情页 `_fetchSongs` 同一优先级与接口：
  /// 已登录 + listid → `/playlist/track/all/new` 分页；否则走
  /// `global_collection_id`（KugouProvider.getPlaylistTrackAll）。
  /// 成功且 [isInMyFavorites] 时同步写入与详情页同 key 的本地缓存。
  static Future<PlaylistSongsResult> fetch(
    BuildContext context,
    Playlist playlist, {
    bool isInMyFavorites = true,
    bool isAlbum = false,
    String? albumId,
  }) async {
    return fetchDetached(
      playlist,
      isInMyFavorites: isInMyFavorites,
      isAlbum: isAlbum,
      albumId: albumId,
    );
  }

  /// Shared complete pagination, independent of a page or BuildContext lifetime.
  static Future<PlaylistSongsResult> fetchDetached(
    Playlist playlist, {
    bool isInMyFavorites = true,
    bool isAlbum = false,
    String? albumId,
    KugouApiClient? client,
  }) async {
    final api = client ?? KugouApiClient();
    final songs = <Song>[];
    final seen = <String>{};
    bool succeeded = false, complete = false;
    if (isAlbum) {
      final result = await api.getAlbumSongsAll(albumId ?? playlist.id);
      if (result != null) {
        songs.addAll(result.songs.map((s) => s.toSong()));
        succeeded = true;
        complete = result.isComplete;
      }
    } else {
      final listid = playlist.subscribedListId ?? playlist.listCreateListid;
      final gid = playlist.listCreateGid ?? playlist.id;
      var useListId = api.isLoggedIn && listid != null && listid.isNotEmpty;
      const size = 200;
      for (var page = 1; page <= 100; page++) {
        var result = useListId
            ? await api.getPlaylistTrackAllNew(
                listid: listid!,
                page: page,
                pagesize: size,
              )
            : await api.getPlaylistTrackAll(
                id: gid,
                page: page,
                pagesize: size,
              );
        if(page==1 && useListId && (result==null || result.isEmpty) && gid.isNotEmpty &&
            (playlist.listCreateGid!=null || playlist.listCreateListid==null)) {
          useListId=false;
          result=await api.getPlaylistTrackAll(id:gid,page:page,pagesize:size);
        }
        if (result == null) break;
        succeeded = true;
        final before = songs.length;
        for (final item in result) {
          final song = item.toSong();
          if (seen.add('${song.id}:${song.albumAudioId ?? ""}'))
            songs.add(song);
        }
        if (songs.length > 9999) break;
        if (result.length < size) {
          complete = playlist.songCount<=0 || songs.length>=playlist.songCount;
          break;
        }
        if (songs.length == before) break;
      }
    }
    final filtered = sortSongsByPlaylistPosition(
      songs.where((s) => s.title.isNotEmpty && s.title != '-').toList(),
    );
    if (succeeded && complete && filtered.isNotEmpty) {
      final key = cacheKey(playlist, isInMyFavorites: isInMyFavorites);
      if (key != null)
        await FavoriteListsCache.savePlaylistSongs(key, filtered);
    }
    return PlaylistSongsResult(filtered, succeeded, isComplete: complete);
  }
}
