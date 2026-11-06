import 'package:flutter_test/flutter_test.dart';
import 'package:feride_v5_2/harness/progress_tracker.dart';

void main() {
  group('ProgressTracker Tests', () {
    late ProgressTracker tracker;

    setUp(() {
      tracker = ProgressTracker();
    });

    test('initial state is clean', () {
      expect(tracker.totalSteps, 0);
      expect(tracker.stepsSinceLastMutation, 0);
      expect(tracker.inspectedPaths, isEmpty);
    });

    test('mutation tools reset stepsSinceLastMutation to 0', () {
      // 3 read-only calls
      tracker.recordToolCall('read_file', {'path': '/a/foo.dart'});
      tracker.recordToolCall('read_file', {'path': '/a/bar.dart'});
      tracker.recordToolCall('run_command', {'command': 'cat pubspec.yaml'});
      expect(tracker.stepsSinceLastMutation, 3);

      // Mutating call
      final status = tracker.recordToolCall('write_to_file', {'path': '/a/foo.dart', 'content': 'test'});
      expect(status, ProgressActionStatus.progress);
      expect(tracker.stepsSinceLastMutation, 0);
    });

    test('reaches warning threshold at 5 consecutive read-only steps', () {
      for (int i = 1; i <= 4; i++) {
        final status = tracker.recordToolCall('read_file', {'path': '/file$i.txt'});
        expect(status, ProgressActionStatus.readOnly);
      }

      final status5 = tracker.recordToolCall('read_file', {'path': '/file5.txt'});
      expect(status5, ProgressActionStatus.warning);
      expect(tracker.stepsSinceLastMutation, 5);
    });

    test('reaches stalled threshold at 8 consecutive read-only steps', () {
      for (int i = 1; i <= 7; i++) {
        tracker.recordToolCall('read_file', {'path': '/file$i.txt'});
      }
      expect(tracker.stepsSinceLastMutation, 7);

      final status8 = tracker.recordToolCall('read_file', {'path': '/file8.txt'});
      expect(status8, ProgressActionStatus.stalled);
      expect(tracker.stepsSinceLastMutation, 8);
    });

    test('detects loop when exact same tool and args are called 3 times', () {
      final status1 = tracker.recordToolCall('read_file', {'path': '/loop.txt'});
      expect(status1, ProgressActionStatus.readOnly);

      final status2 = tracker.recordToolCall('read_file', {'path': '/loop.txt'});
      expect(status2, ProgressActionStatus.readOnly);

      final status3 = tracker.recordToolCall('read_file', {'path': '/loop.txt'});
      expect(status3, ProgressActionStatus.loopDetected);
    });

    test('tracks inspected paths for read_file and read_document', () {
      tracker.recordToolCall('read_file', {'path': '/path1.txt'});
      tracker.recordToolCall('read_document', {'path': '/path2.pdf'});
      expect(tracker.inspectedPaths, contains('/path1.txt'));
      expect(tracker.inspectedPaths, contains('/path2.pdf'));
    });
  });
}
