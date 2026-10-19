import 'package:andropi/ui/terminal_pane.dart';
import 'package:andropi/ui/terminal_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  Terminal shell() => Terminal(maxLines: 100)
    ..resize(40, 10)
    ..write('\$ ls\r\nREADME.md   lib   test\r\n\$ echo hi\r\nhi\r\n');

  test('nothing selected copies nothing', () {
    expect(terminalSelectionText(shell(), TerminalController()), '');
  });

  test('select all copies every line without the padding spaces', () {
    final terminal = shell();
    final controller = TerminalController();
    selectAllTerminal(terminal, controller);
    expect(terminalSelectionText(terminal, controller), '\$ ls\nREADME.md   lib   test\n\$ echo hi\nhi');
  });

  test('a partial selection copies just that part', () {
    final terminal = shell();
    final controller = TerminalController();
    final b = terminal.buffer;
    controller.setSelection(b.createAnchor(0, 1), b.createAnchor(9, 1));
    expect(terminalSelectionText(terminal, controller), 'README.md');
  });

  test('an indented first line keeps its indentation', () {
    final terminal = Terminal(maxLines: 100)
      ..resize(40, 10)
      ..write('server:\r\n  port: 80\r\n  host: x\r\n');
    final controller = TerminalController();
    final b = terminal.buffer;
    controller.setSelection(b.createAnchor(0, 1), b.createAnchor(40, 2));
    expect(terminalSelectionText(terminal, controller), '  port: 80\n  host: x');
  });

  test('font size steps by half points and stays within limits', () {
    expect(terminalFontFor(12.3), 12.5);
    expect(terminalFontFor(3), 8);
    expect(terminalFontFor(60), 28);
  });
}
