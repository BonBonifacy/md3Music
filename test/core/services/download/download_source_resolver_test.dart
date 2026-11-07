import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/download/download_source_resolver.dart';

void main() {
  const chain = ['high', 'flac', '320', '128'];
  int rank(String q) => 4 - chain.indexOf(q);
  test(
    'a silent downgrade does not prevent finding the better FLAC source',
    () async {
      final calls = <String>[];
      final result = await resolveDownloadSource(
        qualities: chain,
        rank: rank,
        vip: true,
        cancel: CancelToken(),
        request: (q, vip) async {
          calls.add('$q:$vip');
          return {
            'url': ['https://cdn.example/song'],
            'priv_status': 1,
            'quality': q == 'flac' ? 'flac' : '128',
          };
        },
      );
      expect(result['quality'], 'flac');
      expect(calls, contains('flac:true'));
    },
  );
  test(
    'trials and missing VIP authorization are rejected but short complete songs are allowed',
    () async {
      for (final bad in [
        {'priv_status': 0},
        {'is_free_part': 1},
        {
          'fail_process': ['buy'],
        },
        {'isTrial': true},
      ]) {
        await expectLater(
          resolveDownloadSource(
            qualities: ['128'],
            rank: rank,
            vip: false,
            cancel: CancelToken(),
            request: (q, v) async => {
              'url': 'https://cdn.example/song',
              'quality': q,
              ...bad,
            },
          ),
          throwsStateError,
        );
      }
      final result = await resolveDownloadSource(
        qualities: ['128'],
        rank: rank,
        vip: false,
        cancel: CancelToken(),
        request: (q, v) async => {
          'url': 'https://cdn.example/short',
          'quality': q,
          'fileSize': 1000,
        },
      );
      expect(result['fileSize'], 1000);
    },
  );
  test(
    'strict quality rejects fallback and cancellation stops resolution',
    () async {
      await expectLater(
        resolveDownloadSource(
          qualities: ['flac'],
          rank: rank,
          vip: false,
          cancel: CancelToken(),
          request: (q, v) async => {
            'url': 'https://cdn.example/a',
            'quality': '128',
          },
        ),
        throwsStateError,
      );
      final token = CancelToken()..cancel();
      await expectLater(
        resolveDownloadSource(
          qualities: chain,
          rank: rank,
          vip: true,
          cancel: token,
          request: (q, v) async => throw StateError('must not request'),
        ),
        throwsA(isA<DioException>()),
      );
    },
  );
}
