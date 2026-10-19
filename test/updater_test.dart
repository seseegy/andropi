import 'package:andropi/agent/updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compareVersions orders numerically', () {
    expect(compareVersions('0.1.12', '0.1.9'), 1);
    expect(compareVersions('0.1.9', '0.1.12'), -1);
    expect(compareVersions('v0.2.0', '0.1.99'), 1);
    expect(compareVersions('0.1.3', '0.1.3+7'), 0);
    expect(compareVersions('1.0', '1.0.0'), 0);
    expect(compareVersions('1.0.1-beta', '1.0.0'), 1);
  });

  test('download state', () {
    final d = UpdateDownload({'status': 'running', 'downloaded': 50, 'total': 200});
    expect(d.active, isTrue);
    expect(d.progress, 0.25);
    expect(UpdateDownload({'status': 'paused', 'reason': 2}).reasonText, 'Waiting for a network connection');
    expect(UpdateDownload({'status': 'failed', 'reason': 404}).reasonText, 'The server answered HTTP 404');
    expect(UpdateDownload({'status': 'failed', 'reason': 1006}).reasonText, 'Not enough storage space');
    expect(UpdateDownload(const {}).active, isFalse);
  });
}
