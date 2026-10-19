import 'package:andropi/ui/terminal_pane.dart';
import 'package:andropi/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  late Terminal terminal;
  late FocusNode focus;
  double? newSize;

  Future<void> pumpPane(WidgetTester tester, {Widget? overlay, double fontSize = 12.5}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    terminal = Terminal(maxLines: 1000);
    focus = FocusNode();
    addTearDown(focus.dispose);
    newSize = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        // The same shape as the terminal screen: the pane in an Expanded above a key bar.
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: TerminalPane(
                  terminal: terminal,
                  controller: TerminalController(),
                  focusNode: focus,
                  fontSize: fontSize,
                  onFontSize: (s) => newSize = s,
                  theme: TerminalThemes.defaultTheme,
                  overlay: overlay,
                ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the terminal fills the width even when the overlay is empty', (tester) async {
    await pumpPane(tester, overlay: const SizedBox.shrink());
    expect(tester.getSize(find.byType(TerminalView)).width, 400);
    // Far more than the single column the empty overlay used to squeeze it into.
    expect(terminal.viewWidth, greaterThan(20));
  });

  testWidgets('tapping the terminal focuses it, which brings up the keyboard', (tester) async {
    await pumpPane(tester, overlay: const SizedBox.shrink());
    focus.unfocus();
    await tester.pump();
    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    // Let the terminal's double-tap timer run out.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('pinching out makes the font bigger, pinching in smaller', (tester) async {
    await pumpPane(tester);
    Future<void> pinch(double from, double to) async {
      final a = await tester.startGesture(Offset(200 - from / 2, 300), pointer: 1);
      final b = await tester.startGesture(Offset(200 + from / 2, 300), pointer: 2);
      for (var i = 1; i <= 5; i++) {
        final d = from + (to - from) * i / 5;
        await a.moveTo(Offset(200 - d / 2, 300));
        await b.moveTo(Offset(200 + d / 2, 300));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await tester.pump();
    }

    await pinch(100, 200);
    expect(newSize, 25);
    newSize = null;
    await pinch(200, 100);
    expect(newSize, 8);
  });
}
