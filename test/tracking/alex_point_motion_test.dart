import 'package:dawarich/core/data/drift/database/sqlite_client.dart';
import 'package:dawarich/core/data/repositories/drift/drift_local_point_repository.dart';
import 'package:dawarich/core/data/repositories/local_point_repository_interfaces.dart';
import 'package:dawarich/core/domain/models/point/alex_point_motion.dart';
import 'package:dawarich/core/domain/models/point/local/local_point.dart';
import 'package:dawarich/core/domain/models/point/local/local_point_geometry.dart';
import 'package:dawarich/core/domain/models/point/local/local_point_properties.dart';
import 'package:dawarich/core/network/repositories/api_point_repository_interfaces.dart';
import 'package:dawarich/features/batch/application/usecases/batch_upload_workflow_usecase.dart';
import 'package:dawarich/features/tracking/application/converters/alex_activity.dart';
import 'package:dawarich/features/tracking/data/data_transfer_objects/point/upload/dawarich_point_batch_dto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:option_result/option_result.dart';
import 'package:tracelet/tracelet.dart' as tl;

LocalPoint _point(int minute, {AlexPointMotion? motion, int id = 0}) {
  final DateTime time = DateTime.utc(2026, 11, 20, 9, minute);
  return LocalPoint(
    id: id,
    type: 'Feature',
    geometry: LocalPointGeometry(type: 'Point', longitude: -0.1, latitude: 51.5 + minute / 1000),
    properties: LocalPointProperties(
      batteryState: 'discharging',
      batteryLevel: 0.5,
      wifi: '',
      recordTimestamp: time,
      providerTimestamp: time,
      horizontalAccuracy: 5,
      verticalAccuracy: 5,
      altitude: 0,
      speed: 1.4,
      speedAccuracy: 0,
      course: 0,
      courseAccuracy: 0,
      deviceId: 'test',
      alexMotion: motion,
    ),
    userId: 1,
    isUploaded: false,
  );
}

class _CapturingApi implements IApiPointRepository {
  final List<Map<String, dynamic>> sent = [];

  @override
  Future<Result<(), String>> uploadBatch(DawarichPointBatchDto batch) async {
    sent.addAll(batch.points.map((p) => p.properties.toJson()));
    return const Ok(());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late SQLiteClient db;
  late DriftPointLocalRepository repo;

  setUp(() {
    db = SQLiteClient.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = DriftPointLocalRepository(db);
  });
  tearDown(() => db.close());

  test('JSON matches what Dawarich reads', () {
    expect(AlexPointMotion.atPlace.toJson(), {
      'action': 'stationary_presence',
      'motion': ['stationary'],
      'motion_authoritative': true,
    });
    expect(const AlexPointMotion(activity: 'WALKING').toJson(), {'activity': 'WALKING'});
  });

  test('activity recognition becomes Google activity names, uncertain ones none', () {
    expect(
      alexGoogleActivity(const tl.LocationActivity(
          type: tl.ActivityType.onBicycle, confidence: tl.ActivityConfidence.high)),
      'ON_BICYCLE',
    );
    expect(
      alexGoogleActivity(const tl.LocationActivity(
          type: tl.ActivityType.inVehicle, confidence: tl.ActivityConfidence.medium)),
      'IN_VEHICLE',
    );
    expect(
      alexGoogleActivity(const tl.LocationActivity(
          type: tl.ActivityType.walking, confidence: tl.ActivityConfidence.low)),
      isNull,
    );
    expect(
      alexGoogleActivity(const tl.LocationActivity(
          type: tl.ActivityType.unknown, confidence: tl.ActivityConfidence.high)),
      isNull,
    );
  });

  test('motion is stored with the point and read back by point id', () async {
    final walk = await repo.storePoint(_point(1, motion: const AlexPointMotion(activity: 'WALKING')));
    final home = await repo.storePoint(_point(2, motion: AlexPointMotion.atPlace));
    final plain = await repo.storePoint(_point(3));

    final motion = await repo.alexMotionFor([walk, home, plain]);
    expect(motion[walk], const AlexPointMotion(activity: 'WALKING'));
    expect(motion[home], AlexPointMotion.atPlace);
    expect(motion.containsKey(plain), isFalse);
  });

  test('motion of deleted points is cleaned up when the app next starts', () async {
    final dir = await Directory.systemTemp.createTemp('alex_motion');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/db.sqlite');

    final first = SQLiteClient.forTesting(DatabaseConnection(NativeDatabase(file)));
    final firstRepo = DriftPointLocalRepository(first);
    final id = await firstRepo.storePoint(_point(1, motion: const AlexPointMotion(activity: 'STILL')));
    await firstRepo.deletePoints(1, [id]);
    await first.close();

    final second = SQLiteClient.forTesting(DatabaseConnection(NativeDatabase(file)));
    addTearDown(second.close);
    expect(await DriftPointLocalRepository(second).alexMotionFor([id]), isEmpty);
    final row = await second.customSelect('SELECT COUNT(*) AS n FROM alex_point_motion').getSingle();
    expect(row.read<int>('n'), 0);
  });

  test('upload sends the motion fields with each point', () async {
    final walk = await repo.storePoint(_point(1, motion: const AlexPointMotion(activity: 'WALKING')));
    final home = await repo.storePoint(_point(2, motion: AlexPointMotion.atPlace));
    final plain = await repo.storePoint(_point(3));
    final IPointLocalRepository local = repo;
    final api = _CapturingApi();

    final batch = await local.getCurrentBatch(1);
    expect(batch.map((p) => p.id).toSet(), {walk, home, plain});
    final result = await BatchUploadWorkflowUseCase(api, local)(batch, 1);

    expect(result, isA<Ok<(), String>>());
    expect(api.sent, hasLength(3));
    expect(api.sent[0]['activity'], 'WALKING');
    expect(api.sent[0].containsKey('action'), isFalse);
    expect(api.sent[1]['action'], 'stationary_presence');
    expect(api.sent[1]['motion'], ['stationary']);
    expect(api.sent[1]['motion_authoritative'], isTrue);
    expect(api.sent[2].keys, isNot(contains('activity')));
  });
}
