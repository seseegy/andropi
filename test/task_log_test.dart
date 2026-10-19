import 'dart:async';

import 'package:andropi/ui/task_log.dart';
import 'package:andropi/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('back does not close a running task, and does once it is done', (tester) async {
    final done = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => runWithLog<String>(context, title: 'Deploying', task: (log, ci) => done.future),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    // The spinner never settles while the task runs.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Deploying'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Deploying'), findsOneWidget);

    done.complete('ok');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Deploying'), findsNothing);
  });

  testWidgets('Hide closes a running task, which reports when it ends', (tester) async {
    // A phone-sized screen; the default 800x600 test surface is shorter than the sheet.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.7;
    addTearDown(tester.view.reset);
    final done = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  runWithLog<String>(context, title: 'Deploying', openUrl: (_) {}, task: (log, ci) => done.future),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    // Let the sheet slide in (the spinner never lets pumpAndSettle finish).
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Hide'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Hide'), findsNothing);

    done.complete('https://site.pages.dev');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Deploying: done · https://site.pages.dev'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });
}
