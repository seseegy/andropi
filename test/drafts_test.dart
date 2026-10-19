import 'package:andropi/agent/drafts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final drafts = Drafts.instance;

  test('keeps a draft per chat and drops it when emptied', () {
    drafts.set('a', 'half a thought');
    drafts.set('b', 'other chat');
    expect(drafts.get('a'), 'half a thought');
    expect(drafts.get('b'), 'other chat');
    drafts.set('a', '   ');
    expect(drafts.get('a'), '');
    expect(drafts.get(null), '');
  });

  test('keeps only the newest 50 drafts', () {
    for (var i = 0; i < 60; i++) {
      drafts.set('chat$i', 'draft $i');
    }
    expect(drafts.get('chat0'), '');
    expect(drafts.get('chat9'), '');
    expect(drafts.get('chat10'), 'draft 10');
    expect(drafts.get('chat59'), 'draft 59');
    drafts.flush();
  });
}
