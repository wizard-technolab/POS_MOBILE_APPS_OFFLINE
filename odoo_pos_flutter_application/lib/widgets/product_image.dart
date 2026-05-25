// ─────────────────────────────────────────────────────────────────────────────
// product_image.dart
//
// Reusable widget that shows a product image from a base64 string.
// Usage:  ProductImage(imageBase64: product['image'])
//
// - If imageBase64 is null/empty  → grey placeholder with icon
// - If imageBase64 is valid       → decoded image shown
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';

class ProductImage extends StatelessWidget {
  /// Base64 string from Odoo API.
  /// Format: "data:image/png;base64,iVBORw0..." or just the base64 part.
  final String? imageBase64;

  final double? width;
  final double? height;
  final BoxFit fit;
  final Color placeholderColor;
  final IconData placeholderIcon;

  const ProductImage({
    super.key,
    required this.imageBase64,
    this.width,
    this.height,
    this.fit = BoxFit.contain, // cover: filled thumbnails look better in grids
    this.placeholderColor = const Color(0xFF2A2D4E),
    this.placeholderIcon = Icons.image_not_supported_outlined,
  });

  // Decode base64 string → raw bytes. Returns null if invalid.
  static Uint8List? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final String b64 = raw.contains(',') ? raw.split(',').last : raw;
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _decode(imageBase64);

    if (bytes == null) {
      // No image — show placeholder
      return Container(
        width: width,
        height: height,
        color: placeholderColor,
        alignment: Alignment.center,
        child: Icon(placeholderIcon, color: Colors.white38, size: 32),
      );
    }

    return Image.memory(
      bytes,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, __, ___) => Container(
        width: width,
        height: height,
        color: placeholderColor,
        alignment: Alignment.center,
        child: Icon(placeholderIcon, color: Colors.white38, size: 32),
      ),
    );
  }
}
