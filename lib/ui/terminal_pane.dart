import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'theme.dart';

/// A terminal font size: steps of 0.5, between 8 and 28.
double terminalFontFor(double size) => ((size * 2).round() / 2).clamp(8.0, 28.0).toDouble();

/// The terminal surface: the view filling all the space it gets, two-finger pinch to change the font size, and an
/// optional overlay (the selection toolbar) along the top.
class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.terminal,
    required this.controller,
    required this.focusNode,
    required this.fontSize,
    required this.onFontSize,
    required this.theme,
    this.dark = false,
    this.onPinchStart,
    this.overlay,
  });

  final Terminal terminal;
  final TerminalController controller;
  final FocusNode focusNode;
  final double fontSize;

  /// The new size when a pinch ends.
  final ValueChanged<double> onFontSize;
  final TerminalTheme theme;
  final bool dark;

  /// A second finger came down: whatever the first one started (a selection) should be dropped.
  final VoidCallback? onPinchStart;

  /// Drawn over the top of the terminal, e.g. the selection toolbar; may build to nothing.
  final Widget? overlay;

  @override
  State<TerminalPane> createState() => TerminalPaneState();
}

class TerminalPaneState extends State<TerminalPane> {
  final _pointers = <int, Offset>{};
  double? _pinchStartDistance;
  double _scrollHold = 0;

  /// While pinching the terminal is only scaled; the font (and the pty size) changes once, on release.
  final _scale = ValueNotifier<double>(1);
  final _scroll = ScrollController();

  /// Whether two fingers are pinching right now.
  bool get pinching => _pinchStartDistance != null;

  @override
  void dispose() {
    _scale.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // Read from raw pointers so it doesn't fight the terminal's own drag and long-press.
  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      final pts = _pointers.values.toList();
      _pinchStartDistance = (pts[0] - pts[1]).distance;
      _scrollHold = _scroll.hasClients ? _scroll.offset : 0;
      widget.onPinchStart?.call();
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final start = _pinchStartDistance;
    if (_pointers.length != 2 || start == null || start < 10) return;
    final pts = _pointers.values.toList();
    final target = terminalFontFor(widget.fontSize * (pts[0] - pts[1]).distance / start);
    _scale.value = target / widget.fontSize;
    // The first finger also drives the terminal's scrolling; hold it still while pinching.
    if (_scroll.hasClients && _scroll.offset != _scrollHold) _scroll.jumpTo(_scrollHold);
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2 && _pinchStartDistance != null) {
      _pinchStartDistance = null;
      final size = terminalFontFor(widget.fontSize * _scale.value);
      _scale.value = 1;
      if (size != widget.fontSize) widget.onFontSize(size);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      // The terminal takes the whole area; with a loose fit the stack would shrink to its overlay.
      fit: StackFit.expand,
      children: [
        Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: ValueListenableBuilder<double>(
            valueListenable: _scale,
            builder: (context, scale, child) => scale == 1
                ? child!
                : ClipRect(
                    child: Transform.scale(scale: scale, alignment: Alignment.topLeft, child: child),
                  ),
            child: TerminalView(
              widget.terminal,
              // A new view per terminal (tab), as before.
              key: ObjectKey(widget.terminal),
              controller: widget.controller,
              scrollController: _scroll,
              focusNode: widget.focusNode,
              autofocus: true,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              keyboardType: TextInputType.visiblePassword,
              keyboardAppearance: widget.dark ? Brightness.dark : Brightness.light,
              textStyle: TerminalStyle(fontFamily: mono, fontSize: widget.fontSize),
              theme: widget.theme,
            ),
          ),
        ),
        if (widget.overlay != null) Positioned(top: 8, left: 0, right: 0, child: widget.overlay!),
      ],
    );
  }
}
