import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/cart_service.dart';

// Maximum number of product images shown in the bottom cart bar
const int _kMaxBarImages = 3;

/// Blinkit-style sticky bottom cart bar.
///
/// Shows up to [_kMaxBarImages] product thumbnails (newest first).
/// When a 4th product is added, the oldest image is pushed out automatically
/// because we always read the last [_kMaxBarImages] items from the cart map.
///
/// Usage: Wrap your screen body in a Stack and add this widget at the bottom.
///   Stack(children: [
///     YourBody(),
///     CartBottomBar(onTap: () => navigateToCart()),
///   ])
class CartBottomBar extends StatelessWidget {
  /// Called when the user taps the bar → navigate to cart screen
  final VoidCallback onTap;

  const CartBottomBar({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Listen to cartVersionNotifier so bar only rebuilds when items are
    // added or removed — NOT on every qty increment (performance win)
    return ValueListenableBuilder<int>(
      valueListenable: CartService.instance.cartVersionNotifier,
      builder: (_, __, ___) {
        // Also watch combo cart so combos show up in the bar
        return ValueListenableBuilder(
          valueListenable: CartService.instance.comboCartNotifier,
          builder: (_, __, ___) {
            final totalCount = CartService.instance.totalItemCount;

            // Hide bar completely when cart is empty
            if (totalCount == 0) return const SizedBox.shrink();

            return _CartBarContent(
              totalCount: totalCount,
              onTap: onTap,
            );
          },
        );
      },
    );
  }
}

// ── Internal widget that renders the actual bar UI ──────────────────────────
class _CartBarContent extends StatelessWidget {
  final int totalCount;
  final VoidCallback onTap;

  const _CartBarContent({
    required this.totalCount,
    required this.onTap,
  });

  /// Build the image list to show in the bar.
  ///
  /// Strategy (Blinkit-style):
  /// - Collect all cart items (regular + combo) with their image and add time.
  /// - Sort newest-first using the insertion order of the cart map.
  ///   (Dart Map preserves insertion order, so last key = most recently added)
  /// - Take only the first [_kMaxBarImages] items.
  /// - Result: when 4th product is added, the 4th becomes index-0 (top/left)
  ///   and the oldest one naturally falls off because we cap at 3.
  List<String?> _buildImageList() {
    final cart = CartService.instance.cart;
    final comboCart = CartService.instance.comboCart;

    // Get regular cart items in insertion order (newest last in map)
    // We reverse so newest is first in our list
    final regularImages =
        cart.values.toList().reversed.map((item) => item.image).toList();

    // Get combo cart items — combos don't have a product image stored in
    // ComboCartItem, so we pass null (shows placeholder icon)
    final comboImages =
        comboCart.values.toList().reversed.map((_) => null as String?).toList();

    // Merge: regular items first (they have images), combos after
    final allImages = [...regularImages, ...comboImages];

    // Cap at max — this is the "4th added removes 1st" behaviour
    return allImages.take(_kMaxBarImages).toList();
  }

  @override
  Widget build(BuildContext context) {
    final images = _buildImageList();

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                // Blinkit uses a dark green — adjust to match your theme
                color: const Color(0xFF0C831F),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),

                  // ── Product image thumbnails ────────────────────────────
                  // Overlapping circles — newest image on top (left-most)
                  _OverlappingImages(images: images),

                  const SizedBox(width: 12),

                  // ── "View cart" label + item count ─────────────────────
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'View cart',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '$totalCount ${totalCount == 1 ? 'item' : 'items'}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── Arrow icon ──────────────────────────────────────────
                  const Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Overlapping circular image thumbnails ───────────────────────────────────
class _OverlappingImages extends StatelessWidget {
  final List<String?> images; // nullable = show placeholder

  const _OverlappingImages({required this.images});

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();

    const double imageSize = 40;
    const double overlap = 12; // how much each image overlaps the previous
    final totalWidth = imageSize + (images.length - 1) * (imageSize - overlap);

    return SizedBox(
      width: totalWidth,
      height: imageSize,
      child: Stack(
        children: List.generate(images.length, (index) {
          // Newest image (index 0) is placed last in Stack → renders on top
          // We reverse render order so newest = topmost (left-side)
          final renderIndex = images.length - 1 - index;
          final imageBase64 = images[renderIndex];

          return Positioned(
            left: renderIndex * (imageSize - overlap),
            child: _CircleThumb(imageBase64: imageBase64, size: imageSize),
          );
        }),
      ),
    );
  }
}

// ── Single circular thumbnail ────────────────────────────────────────────────
class _CircleThumb extends StatelessWidget {
  final String? imageBase64;
  final double size;

  const _CircleThumb({required this.imageBase64, required this.size});

  Uint8List? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      // Strip data-URI prefix if present: "data:image/png;base64,<data>"
      final b64 = raw.contains(',') ? raw.split(',').last : raw;
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _decode(imageBase64);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1A5C24), // dark green fallback background
        border: Border.all(color: const Color(0xFF0C831F), width: 2),
      ),
      child: ClipOval(
        child: bytes != null
            ? Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            : const Icon(
                Icons.fastfood_rounded,
                color: Colors.white70,
                size: 20,
              ),
      ),
    );
  }
}
