// lib/widgets/top_notification.dart
//
// Amazon-style floating popup notification — appears at top-center of screen.
//
// Usage:
//   showTopNotification(context, 'Item added to cart');
//   showTopNotification(context, 'Error!', color: Colors.red);
//   showTopNotification(context, 'Done', icon: Icons.check_circle_rounded);
//   showTopNotification(context, 'Info', duration: Duration(seconds: 4));

import 'package:flutter/material.dart';

/// Shows a floating Amazon-style popup notification at the top-center
/// of the screen. Slides down, holds, then slides back up and removes itself.
void showTopNotification(
  BuildContext context,
  String message, {
  Color color = const Color(0xFF1E2235),
  IconData? icon,
  Duration duration = const Duration(milliseconds: 2500),
}) {
  // rootNavigator: true — ensures overlay sits above bottom sheets and dialogs
  final overlay = Navigator.of(context, rootNavigator: true).overlay;
  if (overlay == null) return;

  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (_) => _TopNotificationWidget(
      message: message,
      color: color,
      icon: icon,
      duration: duration,
      onDismissed: () => entry.remove(),
    ),
  );

  overlay.insert(entry);
}

// ─────────────────────────────────────────────────────────────────────────────
// INTERNAL WIDGET
// ─────────────────────────────────────────────────────────────────────────────
class _TopNotificationWidget extends StatefulWidget {
  const _TopNotificationWidget({
    required this.message,
    required this.color,
    required this.duration,
    required this.onDismissed,
    this.icon,
  });

  final String message;
  final Color color;
  final IconData? icon;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_TopNotificationWidget> createState() => _TopNotificationWidgetState();
}

class _TopNotificationWidgetState extends State<_TopNotificationWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );

    // Slides down from slightly above visible area
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    // Fades in during first 60% of animation
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.0, 0.6)),
    );

    // Slight scale-up for a "pop" feel like Amazon
    _scaleAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );

    // Enter → hold → exit → remove from overlay
    _controller.forward().then((_) async {
      await Future.delayed(widget.duration);
      if (mounted) {
        await _controller.reverse();
        widget.onDismissed();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final screenWidth = MediaQuery.of(context).size.width;

    return Positioned(
      // Sit just below the status bar with a small gap
      top: topPadding + 12,
      // Center the card horizontally on screen
      left: (screenWidth - _cardWidth(screenWidth)) / 2,
      width: _cardWidth(screenWidth),
      child: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: ScaleTransition(
            scale: _scaleAnim,
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: widget.color,
                  // All 4 corners rounded — Amazon floating card style
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.45),
                      blurRadius: 20,
                      spreadRadius: 1,
                      offset: const Offset(0, 6),
                    ),
                    // Subtle inner glow on top edge for depth
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.04),
                      blurRadius: 0,
                      spreadRadius: 0,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon inside a subtle circular container
                    if (widget.icon != null) ...[
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          widget.icon,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],

                    // Message — wraps if text is long
                    Flexible(
                      child: Text(
                        widget.message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Card width: 88% of screen width, clamped between 240px and 420px
  double _cardWidth(double screenWidth) {
    return (screenWidth * 0.88).clamp(240.0, 420.0);
  }
}
