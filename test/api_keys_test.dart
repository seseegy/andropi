import 'package:andropi/ui/network_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one key per line', () {
    expect(parseApiKeys('key1\nkey2\r\nkey3\n'), ['key1', 'key2', 'key3']);
  });

  test('other separators, quotes, comments and repeats', () {
    expect(parseApiKeys('  "key1", key2;key3 \n\n# old keys\nkey1\n`key4`'), ['key1', 'key2', 'key3', 'key4']);
    expect(parseApiKeys('  \n # nothing\n'), isEmpty);
  });
}
