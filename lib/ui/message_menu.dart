import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// One row of a message menu.
class MessageAction {
  const MessageAction(this.id, this.label, this.icon, {this.destructive = false});
  final String id;
  final String label;
  final IconData icon;
  final bool destructive;
}

/// iOS-style context menu for a chat bubble, like WhatsApp on iPhone: the screen blurs, the bubble lifts in place,
/// and the actions appear right under it (or above it when there is no room). Returns the chosen action's id.
///
/// [bubbleContext] is the bubble's own context (for its position); [bubble] is drawn again on top of the blur.
Future<String?> showMessageMenu(
  BuildContext bubbleContext, {
  required Widget bubble,
  required List<MessageAction> actions,
  bool alignRight = true,
}) {
  final box = bubbleContext.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Future.value();
  final rect = box.localToGlobal(Offset.zero) & box.size;
  HapticFeedback.mediumImpact();
  return Navigator.of(bubbleContext).push<String>(
    PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (context, animation, _) =>
          _MessageMenu(animation: animation, rect: rect, bubble: bubble, actions: actions, alignRight: alignRight),
    ),
  );
}

class _MessageMenu extends StatelessWidget {
  const _MessageMenu({
    required this.animation,
    required this.rect,
    required this.bubble,
    required this.actions,
    required this.alignRight,
  });

  final Animation<double> animation;
  final Rect rect;
  final Widget bubble;
  final List<MessageAction> actions;
  final bool alignRight;

  static const _rowHeight = 46.0;
  static const _menuWidth = 240.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final media = MediaQuery.of(context);
    final screen = media.size;
    final top = media.padding.top + 12;
    final bottom = screen.height - media.padding.bottom - 12;
    final menuHeight = actions.length * _rowHeight + (actions.length - 1) * 0.5;

    // A long message is shown cut short, so the menu always fits on screen.
    final bubbleHeight = math.min(rect.height, (bottom - top) - menuHeight - _gap);
    var bubbleTop = rect.top;
    // Prefer the menu under the bubble; slide the bubble up when that would run off the bottom.
    if (bubbleTop + bubbleHeight + _gap + menuHeight > bottom) bubbleTop = bottom - menuHeight - _gap - bubbleHeight;
    bubbleTop = math.max(bubbleTop, top);
    final menuTop = bubbleTop + bubbleHeight + _gap;
    final menuLeft = alignRight
        ? (rect.right - _menuWidth).clamp(12.0, screen.width - _menuWidth - 12)
        : rect.left.clamp(12.0, screen.width - _menuWidth - 12);

    final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final dark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: curve,
      builder: (context, _) {
        final t = curve.value;
        return Stack(
          children: [
            // Tap anywhere outside to close.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14 * t, sigmaY: 14 * t),
                  child: ColoredBox(color: Colors.black.withValues(alpha: (dark ? 0.45 : 0.22) * t)),
                ),
              ),
            ),
            // The bubble, lifted in place.
            Positioned(
              left: rect.left,
              width: rect.width,
              top: rect.top + (bubbleTop - rect.top) * t,
              height: bubbleHeight,
              child: IgnorePointer(
                child: Transform.scale(
                  scale: 1 + 0.03 * t,
                  alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18 * t),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: 0,
                        maxHeight: double.infinity,
                        child: SizedBox(width: rect.width, child: bubble),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // The actions.
            Positioned(
              left: menuLeft,
              top: menuTop,
              width: _menuWidth,
              child: Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.85 + 0.15 * t,
                  alignment: alignRight ? Alignment.topRight : Alignment.topLeft,
                  child: Material(
                    color: p.raised,
                    elevation: 12,
                    shadowColor: Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < actions.length; i++) ...[
                          if (i > 0) Divider(height: 0.5, thickness: 0.5, color: p.border),
                          _ActionRow(action: actions[i]),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action});
  final MessageAction action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = action.destructive ? p.danger : p.text;
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).pop(action.id);
      },
      child: SizedBox(
        height: _MessageMenu._rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(action.label, style: TextStyle(fontSize: 15.5, color: color)),
              ),
              Icon(action.icon, size: 19, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
