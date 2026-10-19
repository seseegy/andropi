import 'dart:convert';
import 'dart:io';

import 'package:andropi/agent/drafts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  final drafts = Drafts.instance;

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('drafts');
    // A draft saved by the text-only version.
    File('${root.path}/drafts.json').writeAsStringSync(jsonEncode({'old': 'from before'}));
    Drafts.root = root.path;
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  test('reads text-only drafts from the previous format', () {
    expect(drafts.get('old'), 'from before');
    expect(drafts.files('old'), isEmpty);
  });

  test('keeps a draft per chat and drops it when emptied', () {
    drafts.set('a', 'half a thought');
    drafts.set('b', 'other chat');
    expect(drafts.get('a'), 'half a thought');
    expect(drafts.get('b'), 'other chat');
    drafts.set('a', '   ');
    expect(drafts.get('a'), '');
    expect(drafts.get(null), '');
  });

  test('copies attachments so they outlive the picker cache', () async {
    final picked = File('${root.path}/cache_photo.jpg')..writeAsStringSync('jpeg bytes');
    await drafts.setFiles('c', [(path: picked.path, name: 'photo.jpg', mime: 'image/jpeg')]);
    picked.deleteSync();
    final files = drafts.files('c');
    expect(files, hasLength(1));
    expect(files.single.name, 'photo.jpg');
    expect(files.single.path, startsWith('${root.path}/draft-files/'));
    expect(File(files.single.path).readAsStringSync(), 'jpeg bytes');
    // Saving the copies again does not copy them a second time.
    await drafts.setFiles('c', files);
    expect(drafts.files('c').single.path, files.single.path);
  });

  test('a draft with only attachments is kept, and removing them clears it', () async {
    final f = File('${root.path}/doc.pdf')..writeAsStringSync('pdf');
    await drafts.setFiles('d', [(path: f.path, name: 'doc.pdf', mime: null)]);
    expect(drafts.files('d'), hasLength(1));
    await drafts.setFiles('d', const []);
    expect(drafts.files('d'), isEmpty);
  });

  test('a later change wins over a slower earlier copy', () async {
    final f = File('${root.path}/big.bin')..writeAsBytesSync(List.filled(1 << 20, 7));
    final slow = drafts.setFiles('e', [(path: f.path, name: 'big.bin', mime: null)]);
    await drafts.setFiles('e', const []);
    await slow;
    expect(drafts.files('e'), isEmpty);
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
    final saved = jsonDecode(File('${root.path}/drafts.json').readAsStringSync()) as Map;
    expect((saved['chat59'] as Map)['text'], 'draft 59');
  });
}
