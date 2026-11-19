import 'package:dawarich/core/domain/models/point/alex_point_motion.dart';
import 'package:drift/drift.dart';

/// alex-hack: keeps [AlexPointMotion] for points waiting to be uploaded.
///
/// Its own table in the app database, created on first use and outside
/// upstream's schema versions: upstream migrations never clash with it, and
/// plain upstream simply ignores it. Rows are keyed by the point's properties
/// row, which is always freshly inserted (a point's own insert can be ignored
/// as a duplicate).
final class AlexPointMotionStore {
  static const String table = 'alex_point_motion';

  static final Expando<Future<void>> _ready = Expando();

  static Future<void> _ensure(DatabaseConnectionUser db) {
    return _ready[db] ??= _create(db).catchError((Object error) {
      _ready[db] = null; // try again next time
      throw error;
    });
  }

  static Future<void> _create(DatabaseConnectionUser db) async {
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS $table ('
      'properties_id INTEGER PRIMARY KEY, '
      'activity TEXT, '
      'action TEXT, '
      'motion TEXT, '
      'authoritative INTEGER NOT NULL DEFAULT 0)',
    );
    // Points are deleted after upload; drop their motion too.
    await db.customStatement(
      'DELETE FROM $table WHERE properties_id NOT IN (SELECT id FROM point_properties_table)',
    );
  }

  static Future<void> store(
    DatabaseConnectionUser db,
    int propertiesId,
    AlexPointMotion motion,
  ) async {
    if (motion.isEmpty) return;
    await _ensure(db);
    await db.customInsert(
      'INSERT OR REPLACE INTO $table (properties_id, activity, action, motion, authoritative) '
      'VALUES (?, ?, ?, ?, ?)',
      variables: [
        Variable.withInt(propertiesId),
        Variable<String>(motion.activity),
        Variable<String>(motion.action),
        Variable<String>(motion.motion.isEmpty ? null : motion.motion.join(',')),
        Variable.withInt(motion.authoritative ? 1 : 0),
      ],
    );
  }

  /// Motion for these points (points table ids), by point id.
  static Future<Map<int, AlexPointMotion>> forPoints(
    DatabaseConnectionUser db,
    List<int> pointIds,
  ) async {
    final Map<int, AlexPointMotion> result = {};
    if (pointIds.isEmpty) return result;
    await _ensure(db);
    const int chunk = 500; // SQLite's variable limit
    for (int i = 0; i < pointIds.length; i += chunk) {
      final List<int> ids = pointIds.sublist(i, (i + chunk).clamp(0, pointIds.length));
      final String marks = List.filled(ids.length, '?').join(',');
      final rows = await db.customSelect(
        'SELECT p.id AS point_id, m.activity, m.action, m.motion, m.authoritative '
        'FROM points_table p JOIN $table m ON m.properties_id = p.properties_id '
        'WHERE p.id IN ($marks)',
        variables: [for (final id in ids) Variable.withInt(id)],
      ).get();
      for (final row in rows) {
        final String? motion = row.readNullable<String>('motion');
        result[row.read<int>('point_id')] = AlexPointMotion(
          activity: row.readNullable<String>('activity'),
          action: row.readNullable<String>('action'),
          motion: motion == null || motion.isEmpty ? const [] : motion.split(','),
          authoritative: row.read<int>('authoritative') == 1,
        );
      }
    }
    return result;
  }
}
