import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../db/listen_stats_db.dart' show ensureDbFactory;
import '../models/download_task.dart';

class DownloadRepository {
  DownloadRepository({this.path});
  final String? path;
  Database? _database;
  Future<Database>? _opening;
  Future<Database> _open() => _opening ??= _doOpen();
  Future<Database> _doOpen() async {
    await ensureDbFactory();
    final p =
        path ?? '${(await getApplicationSupportDirectory()).path}/downloads.db';
    return _database = await openDatabase(
      p,
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE download_tasks (id TEXT PRIMARY KEY, dedup TEXT NOT NULL UNIQUE, payload TEXT NOT NULL)',
        );
      },
    );
  }

  Future<List<DownloadTask>> load() async =>
      (await (await _open()).query('download_tasks', orderBy: 'rowid'))
          .map(
            (r) => DownloadTask.fromJson(
              jsonDecode(r['payload'] as String) as Map<String, dynamic>,
            ),
          )
          .toList();
  Future<List<DownloadTask>> insertBatch(List<DownloadTask> tasks) async {
    final db = await _open();
    final added = <DownloadTask>[];
    await db.transaction((tx) async {
      for (final t in tasks) {
        final old = await tx.query(
          'download_tasks',
          columns: ['id'],
          where: 'dedup = ?',
          whereArgs: [t.dedupKey],
        );
        if (old.isNotEmpty) continue;
        await tx.insert('download_tasks', {
          'id': t.id,
          'dedup': t.dedupKey,
          'payload': jsonEncode(t.toJson()),
        });
        added.add(t);
      }
    });
    return added;
  }

  Future<void> save(DownloadTask t) async => (await _open()).update(
    'download_tasks',
    {'payload': jsonEncode(t.toJson())},
    where: 'id = ?',
    whereArgs: [t.id],
  );
  Future<void> remove(String id) async {
    await (await _open()).delete(
      'download_tasks',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
    _opening = null;
  }
}
