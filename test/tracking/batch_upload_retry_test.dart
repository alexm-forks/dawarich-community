import 'package:dawarich/core/data/repositories/local_point_repository_interfaces.dart';
import 'package:dawarich/core/domain/models/point/local/local_point.dart';
import 'package:dawarich/core/domain/models/point/local/local_point_geometry.dart';
import 'package:dawarich/core/domain/models/point/local/local_point_properties.dart';
import 'package:dawarich/core/network/repositories/api_point_repository_interfaces.dart';
import 'package:dawarich/features/batch/application/usecases/batch_upload_workflow_usecase.dart';
import 'package:dawarich/features/tracking/data/data_transfer_objects/point/upload/dawarich_point_batch_dto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:option_result/option_result.dart';

/// Every upload fails, as with no signal.
class _FailingApi implements IApiPointRepository {
  int calls = 0;

  @override
  Future<Result<(), String>> uploadBatch(DawarichPointBatchDto batch) async {
    calls++;
    return const Err('Connection timed out');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LocalRepo implements IPointLocalRepository {
  final List<int> marked = [];

  @override
  Future<int> markBatchAsUploaded(int userId, List<int> pointIds) async {
    marked.addAll(pointIds);
    return pointIds.length;
  }

  @override
  Future<int> deleteUploadedPointsExceptLast(int userId) async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LocalPoint _point(int id) {
  final DateTime time = DateTime.utc(2026, 1, 1).add(Duration(minutes: id));
  return LocalPoint(
    id: id,
    type: 'Feature',
    geometry: LocalPointGeometry(type: 'Point', longitude: -0.1, latitude: 51.5 + id / 1000),
    properties: LocalPointProperties(
      batteryState: 'discharging',
      batteryLevel: 0.5,
      wifi: '',
      recordTimestamp: time,
      providerTimestamp: time,
      horizontalAccuracy: 5,
      verticalAccuracy: 5,
      altitude: 0,
      speed: 0,
      speedAccuracy: 0,
      course: 0,
      courseAccuracy: 0,
      deviceId: 'test',
    ),
    userId: 1,
    isUploaded: false,
  );
}

void main() {
  test('with no signal, gives up after a few one-by-one retries', () async {
    final api = _FailingApi();
    final local = _LocalRepo();
    final workflow = BatchUploadWorkflowUseCase(api, local);

    final result = await workflow([for (var i = 1; i <= 50; i++) _point(i)], 1);

    // One chunk of 50, then 3 single-point retries, not 50.
    expect(api.calls, 1 + BatchUploadWorkflowUseCase.maxConsecutiveRetryFailures);
    expect(local.marked, isEmpty);
    expect(result, isA<Err<(), String>>());
    expect((result as Err).value, contains('50 point(s) failed'));
  });
}
