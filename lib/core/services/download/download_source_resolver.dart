import 'package:dio/dio.dart';

/// Probe all useful quality levels before accepting an upstream silent downgrade.
Future<Map<String, dynamic>> resolveDownloadSource({
  required List<String> qualities,
  required int Function(String) rank,
  required bool vip,
  required CancelToken cancel,
  required Future<Map<String, dynamic>?> Function(String, bool) request,
}) async {
  Map<String, dynamic>? best;
  for (final quality in qualities) {
    if (best != null && rank(best['quality'] as String) >= rank(quality)) break;
    for (final newEndpoint in [if (vip) true, false]) {
      if (cancel.isCancelled) throw cancel.cancelError!;
      final data = await request(quality, newEndpoint);
      if (cancel.isCancelled) throw cancel.cancelError!;
      if (data == null) continue;
      final failure = data['fail_process'];
      if ((failure is List && failure.isNotEmpty) ||
          data['priv_status']?.toString() == '0' ||
          (newEndpoint && data['priv_status']?.toString() != '1') ||
          data['is_free_part']?.toString() == '1' ||
          data['isTrial'] == true ||
          data['is_trial']?.toString() == '1') {
        continue;
      }
      final raw = data['url'];
      final url = raw is List
          ? (raw.isEmpty ? '' : raw.first.toString())
          : (raw?.toString() ?? '');
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        continue;
      }
      final actual = data['quality']?.toString();
      // The embedded server provides actual quality. Do not label an unknown result as requested quality.
      if (actual == null ||
          !['high', 'flac', '320', '128', 'viper_tape'].contains(actual) ||
          actual.isEmpty ||
          rank(actual) < rank(qualities.last)) {
        continue;
      }
      final candidate = {...data, 'url': url, 'quality': actual};
      if (rank(actual) >= rank(quality)) return candidate;
      if (best == null || rank(actual) > rank(best['quality'] as String)) {
        best = candidate;
      }
    }
  }
  if (best != null) return best;
  throw StateError('无法取得所选音质的完整音源（可能仅提供试听或权限不足）');
}
