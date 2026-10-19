import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A back gesture in progress (Android 14+ predictive back).
class BackGesture {
  BackGesture(this.route, this.edge);
  final ModalRoute<dynamic> route;
  final SwipeEdge edge;

  /// Set once the finger is released and Android decided to go back.
  bool committed = false;

  /// The route's animation value when it was committed; the exit animates from there to 0.
  double committedAt = 1;
}

/// Android 14+ predictive back: while the user swipes back from a screen edge, the top route follows the finger
/// (pages shrink to reveal the one underneath, sheets and menus slide or fade away); releasing goes back, swiping
/// back to the edge cancels. Routes that veto popping (PopScope) or handle it internally keep the plain back.
///
/// Registered both as a navigator observer (to know the top route) and a binding observer (for the gesture).
class PredictiveBack extends NavigatorObserver with WidgetsBindingObserver {
  PredictiveBack._();
  static final instance = PredictiveBack._();

  /// The gesture in progress, for transitions that draw it (SmoothPageTransitions).
  final gesture = ValueNotifier<BackGesture?>(null);

  Route<dynamic>? _top;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _top = route;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == _top) _top = previousRoute;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == _top) _top = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == _top) _top = newRoute;
  }

  /// How far back the route's animation goes for gesture [progress] (0..1): all the way for pages, part of the way
  /// for sheets and dialogs, which would otherwise vanish long before the finger stops.
  static double _value(ModalRoute<dynamic> route, double progress) =>
      1 - progress.clamp(0.0, 1.0) * (route is PageRoute ? 1 : 0.35);

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = _top;
    if (backEvent.isButtonEvent || gesture.value != null) return false;
    if (route is! ModalRoute || !route.isCurrent || route.navigator == null || !route.popGestureEnabled) return false;
    gesture.value = BackGesture(route, backEvent.swipeEdge);
    route.handleStartBackGesture(progress: _value(route, backEvent.progress));
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    final g = gesture.value;
    if (g == null || g.committed) return;
    g.route.handleUpdateBackGestureProgress(progress: _value(g.route, backEvent.progress));
  }

  @override
  void handleCommitBackGesture() {
    final g = gesture.value;
    if (g == null || g.committed) return;
    final route = g.route;
    final navigator = route.navigator;
    final animation = route.animation;
    if (navigator == null || animation == null || !route.isCurrent) {
      _end(g);
      return;
    }
    g
      ..committed = true
      ..committedAt = animation.value;
    // Rebuild transitions that draw the gesture: they switch to the exit.
    gesture.value = null;
    gesture.value = g;
    HapticFeedback.lightImpact();
    // Pop from where the finger left it (route.handleCommitBackGesture would restart the exit from the top).
    navigator.pop();
    _whenSettled(g, () => navigator.didStopUserGesture());
  }

  @override
  void handleCancelBackGesture() {
    final g = gesture.value;
    if (g == null || g.committed) return;
    if (g.route.isCurrent) g.route.handleCancelBackGesture();
    _whenSettled(g, () {});
  }

  /// Runs [done] and forgets the gesture once the route's animation stops.
  void _whenSettled(BackGesture g, VoidCallback done) {
    final animation = g.route.animation;
    if (animation == null || !animation.isAnimating) {
      done();
      _end(g);
      return;
    }
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status.isAnimating) return;
      animation.removeStatusListener(listener);
      done();
      _end(g);
    };
    animation.addStatusListener(listener);
  }

  void _end(BackGesture g) {
    if (gesture.value == g) gesture.value = null;
  }
}

/// Pages glide in: a short slide from the right with a fade, while the page underneath eases back and dims a
/// little. During a predictive back gesture the page instead shrinks toward the finger with rounded corners,
/// revealing the page underneath, and fades out when released.
class SmoothPageTransitions extends PageTransitionsBuilder {
  const SmoothPageTransitions();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 380);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final enter = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    final under = CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOutCubic);
    final gesture = PredictiveBack.instance.gesture;
    return AnimatedBuilder(
      animation: Listenable.merge([animation, secondaryAnimation, gesture]),
      child: child,
      // One widget structure for every state, so switching between them never rebuilds the page.
      builder: (context, child) {
        final width = MediaQuery.sizeOf(context).width;
        final g = gesture.value;
        var dx = 0.0;
        var scale = 1.0;
        var radius = 0.0;
        var opacity = 1.0;
        // Darkens a page that is behind another one; cheaper than fading the whole page, and nothing shows through.
        var scrim = 0.0;
        var shadow = 0.0;
        if (g != null && g.route == route) {
          // This page follows the back gesture, lifted off the page it reveals.
          final dir = g.edge == SwipeEdge.left ? 1.0 : -1.0;
          final shift = math.max(0.0, width / 20 - 8);
          final drag = 1 - (g.committed ? g.committedAt : animation.value);
          scale = 1 - 0.1 * drag;
          radius = 28 * math.min(1.0, drag * 4);
          shadow = math.min(1.0, drag * 4);
          dx = dir * shift * drag;
          if (g.committed) {
            final c = g.committedAt <= 0 ? 1.0 : (1 - animation.value / g.committedAt).clamp(0.0, 1.0);
            scale -= 0.04 * c;
            dx += dir * 24 * c;
            opacity = 1 - Curves.easeOut.transform(c);
          }
        } else {
          final u = under.value;
          if (g == null) {
            // Underneath a page being pushed or popped: eases back.
            dx = -0.08 * width * u;
            scrim = 0.18 * u;
          } else {
            // Revealed by a back gesture: stays put, brightening as the page above moves away.
            scrim = 0.12 * secondaryAnimation.value;
          }
          // Coming in: slides from the right, fading in over the first part only, so two pages never blend.
          dx += 0.18 * width * (1 - enter.value);
          opacity = (animation.value / 0.4).clamp(0.0, 1.0);
        }
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Transform.translate(
          offset: Offset(dx, 0),
          child: Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  boxShadow: shadow > 0
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: (dark ? 0.5 : 0.22) * shadow),
                            blurRadius: 24,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  clipBehavior: radius > 0 ? Clip.antiAlias : Clip.none,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(color: scrim > 0 ? Colors.black.withValues(alpha: scrim) : null),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
