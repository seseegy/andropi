import 'package:andropi/agent/models.dart';
import 'package:andropi/ui/kit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the capabilities a fetched model carries', () {
    final m = CustomModel({
      'id': 'claude-fable-5.1',
      'contextWindow': 1000000,
      'maxTokens': 128000,
      'reasoning': true,
      'canDisableThinking': false,
      'input': ['text', 'image'],
    });
    expect(
      (m.contextWindow, m.maxTokens, m.reasoning, m.canDisableThinking, m.vision),
      (1000000, 128000, true, false, true),
    );
  });

  test('reasoning and vision can be switched by hand', () {
    final m = CustomModel({'id': 'local-model'});
    expect((m.reasoning, m.vision, m.canDisableThinking), (false, false, true));
    final on = m.copyWith(reasoning: true, vision: true);
    expect((on.reasoning, on.vision, on.id), (true, true, 'local-model'));
    final off = CustomModel({'id': 'x', 'reasoning': true, 'canDisableThinking': false}).copyWith(reasoning: false);
    expect((off.reasoning, off.canDisableThinking), (false, true));
  });

  test('effort and token labels', () {
    expect(CustomModel({'id': 'a', 'reasoning': true, 'effort': false}).effort, false);
    expect(CustomModel({'id': 'b', 'reasoning': true}).effort, true);
    expect(
      [formatTokens(1048576), formatTokens(872000), formatTokens(1500000), formatTokens(12000000), formatTokens(400)],
      ['1M', '872k', '1.5M', '12M', '400'],
    );
  });
}
