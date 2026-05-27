import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../data/repositories/product_repository.dart';
import '../widgets/top_notification.dart';
import '../services/cart_service.dart';
import '../services/app_config.dart';
import '../models/combo_model.dart';
import '../widgets/combo_selection_sheet.dart';
import '../services/product_cache.dart';
import 'dart:convert';
import 'dart:typed_data'; // For Uint8List — cached in _ProductImageTileState
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/api_client.dart';
import '../widgets/product_image.dart'; // NEW: widget to show product image from base64

bool _parseBool(dynamic raw) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    final lower = raw.toLowerCase();
    return lower == 'true' || lower == '1' || lower == 'yes';
  }
  return false;
}

// ─────────────────────────────────────────────
// COLORS
// ─────────────────────────────────────────────
const kBg = Color(0xFF0D0F1C);
const kCard = Color(0xFF151828);
const kCardBorder = Color(0xFF1E2235);
const kPurple = Color(0xFF6C63FF);
const kPurpleLight = Color(0xFF8B83FF);
const kGreen = Color(0xFF1DB954);
const kOrange = Color(0xFFE8A020);
const kRed = Color(0xFFE53935);
const kTextPrimary = Color(0xFFFFFFFF);
const kTextSecondary = Color(0xFF8B90A7);
const kInputBg = Color(0xFF1A1D2E);
const kNavBg = Color(0xFF11131F);

// Blinkit-style cart bar green color
const kCartBarGreen = Color(0xFF0C831F);
const kCartBarGreenDark = Color(0xFF1A5C24);

// Maximum product images shown in the bottom cart bar (Blinkit style = 3)
const int _kMaxBarImages = 3;

// ─────────────────────────────────────────────
// VARIANT DATA MODELS
// ─────────────────────────────────────────────

/// One attribute-value pair on a specific variant.
/// e.g. attribute_name="Color", value_name="Red"
class VariantAttribute {
  final int attributeId;
  final String attributeName;
  final int valueId;
  final String valueName;
  final double
      priceExtra; // Extra charge for this attribute value (e.g. +2.00 for 2XL)

  const VariantAttribute({
    required this.attributeId,
    required this.attributeName,
    required this.valueId,
    required this.valueName,
    this.priceExtra = 0.0,
  });

  factory VariantAttribute.fromJson(Map<String, dynamic> j) => VariantAttribute(
        attributeId: j['attribute_id'] as int,
        attributeName: j['attribute_name'] as String? ?? '',
        valueId: j['value_id'] as int,
        valueName: j['value_name'] as String? ?? '',
        priceExtra: (j['price_extra'] as num? ?? 0).toDouble(),
      );
}

/// One specific product.product variant with its price and attribute values.
class ProductVariant {
  final int variantId; // product.product ID — used as cart key
  final String variantName; // full display name, e.g. "T-Shirt (Red, M)"
  final double price;
  final String? image; // variant-specific base64 image (may be null)
  final List<VariantAttribute> attributes;
  final List<Map<String, dynamic>> taxIds;
  final double qtyAvailable;
  final bool isStorable;

  const ProductVariant({
    required this.variantId,
    required this.variantName,
    required this.price,
    this.image,
    required this.attributes,
    this.taxIds = const [],
    this.qtyAvailable = 0.0,
    this.isStorable = false,
  });

  factory ProductVariant.fromJson(Map<String, dynamic> j) => ProductVariant(
        variantId: j['variant_id'] as int,
        variantName: j['variant_name'] as String? ?? '',
        price: (j['price'] as num).toDouble(),
        image: j['image'] as String?,
        attributes: (j['attributes'] as List? ?? [])
            .map((a) => VariantAttribute.fromJson(a as Map<String, dynamic>))
            .toList(),
        // Load per-variant tax list sent by backend (tax_id field)
        taxIds: (j['tax_id'] as List? ?? [])
            .map((t) => Map<String, dynamic>.from(t as Map))
            .toList(),
        qtyAvailable: (j['qty_available'] as num?)?.toDouble() ?? 0.0,
        isStorable: () {
          final storableRaw = j['is_storable'] ?? j['track_inventory'];
          if (storableRaw != null) {
            return _parseBool(storableRaw);
          }
          final type = j['type'] ?? j['detailed_type'];
          return type == 'product' || type == 'consu';
        }(),
      );

  /// Human-readable label like "Red / M"
  String get attributeLabel => attributes.map((a) => a.valueName).join(' / ');
  bool get isAvailable {
    // If doesn't track inventory → always available
    if (!isStorable) return true;
    // If tracks inventory → check qty
    return qtyAvailable > 0;
  }
}

// ─────────────────────────────────────────────
// PRODUCT MODEL
// ─────────────────────────────────────────────
class ProductModel {
  final int id;
  final String name;
  final double price;
  final String category;
  final bool active;
  final bool isCombo;
  final List<ComboGroup> comboGroups;
  final String? image; // Product image as base64 string from Odoo API

  // ── VARIANT fields ──────────────────────────────────────────
  // hasVariants = true  → popup shows attribute chip selectors.
  // hasVariants = false → popup behaves as before (no selector).
  final bool hasVariants;
  final List<ProductVariant> variants;

  // Tax data from Odoo — each entry: {id, name, amount (percentage)}
  // e.g. [{'id': 3, 'name': 'Tax 18%', 'amount': 18.0}]
  // Empty list means no tax configured on this product.
  final List<Map<String, dynamic>> taxIds;
  final double qtyAvailable;
  final List<int> optionalProductIds;
  final String publicDescription;
  final bool isStorable;

  ProductModel({
    required this.id,
    required this.name,
    required this.price,
    required this.category,
    required this.active,
    this.isCombo = false,
    this.comboGroups = const [],
    this.image,
    this.hasVariants = false,
    this.variants = const [],
    this.taxIds = const [],
    this.qtyAvailable = 0.0,
    this.isStorable = true,
    this.optionalProductIds = const [],
    this.publicDescription = '',
  });

  factory ProductModel.fromJson(Map<String, dynamic> json) {
    // ← FIX: Explicitly check is_combo field FIRST
    final isComboRaw = json['is_combo'];
    final isComboExplicit = isComboRaw == true || isComboRaw == 1;

    // ← Only parse combo_groups if explicitly marked as combo
    List<ComboGroup> groups = [];
    if (isComboExplicit) {
      final rawGroups = json['combo_groups'];

      List<dynamic> parsedGroups;

      if (rawGroups is String) {
        try {
          parsedGroups = jsonDecode(rawGroups);
        } catch (e) {
          debugPrint('⚠️ Failed to parse combo_groups JSON: $e');
          parsedGroups = [];
        }
      } else if (rawGroups is List) {
        parsedGroups = rawGroups;
      } else {
        parsedGroups = [];
      }

      groups = parsedGroups
          .map((g) => ComboGroup.fromJson(g as Map<String, dynamic>))
          .toList();
    }

    final activeRaw = json['active'];
    final activeBool = activeRaw == true || activeRaw == 1 || activeRaw == null;
    final isCombo = isComboExplicit;

    final storableRaw = json['is_storable'] ?? json['track_inventory'];
    final storable = storableRaw != null
        ? _parseBool(storableRaw)
        : (json['type'] == 'product' ||
            json['type'] == 'consu' ||
            json['detailed_type'] == 'product' ||
            json['detailed_type'] == 'consu');
    // Parse variants — from API: List, from local DB: JSON string
    final hasVariantsRaw = json['has_variants'];
    final hasVariants = hasVariantsRaw == true || hasVariantsRaw == 1;
    List<ProductVariant> variants = [];
    if (hasVariants) {
      final rawVariants = json['variants'];
      List<dynamic> variantList = [];
      if (rawVariants is List) {
        // Direct from API response
        variantList = rawVariants;
      } else if (rawVariants is String &&
          rawVariants.isNotEmpty &&
          rawVariants != '[]') {
        // Loaded from local SQLite DB (stored as JSON string via toMap)
        try {
          variantList = jsonDecode(rawVariants) as List? ?? [];
        } catch (_) {
          variantList = [];
        }
      }
      variants = variantList
          .map((v) => ProductVariant.fromJson(v as Map<String, dynamic>))
          .toList();
    }

    final qtyRaw = json['qty_available'];
    final qty = qtyRaw != null ? (qtyRaw as num).toDouble() : 0.0;
    final optionalIds = () {
      final raw = json['optional_product_ids'];
      if (raw == null) return <int>[];
      if (raw is String) {
        try {
          final decoded = jsonDecode(raw) as List? ?? [];
          return decoded
              .map((id) => id is int ? id : int.tryParse(id.toString()) ?? 0)
              .where((id) => id > 0)
              .toList();
        } catch (_) {
          return <int>[];
        }
      }
      if (raw is List) {
        return raw
            .map((id) => id is int ? id : int.tryParse(id.toString()) ?? 0)
            .where((id) => id > 0)
            .toList();
      }
      return <int>[];
    }();

    // ✅ Parse public_description
    final description = json['public_description'] as String? ?? '';

    return ProductModel(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      price: (json['price'] ?? 0).toDouble(),
      category: json['category'] ?? 'Other',
      active: activeBool,
      isCombo: isCombo,
      comboGroups: groups,
      image: json['image'] as String?,
      hasVariants: hasVariants,
      variants: variants,
      // Parse tax_id from API response: [{id, name, amount}, ...]
      // Falls back to empty list if field is missing (no tax on product).
      // Note: When loaded from local SQLite DB, tax_id is stored as a JSON
      // string (via toMap/jsonEncode). When loaded from API it's already a List.
      taxIds: () {
        final raw = json['tax_id'];
        if (raw == null) return <Map<String, dynamic>>[];
        if (raw is String) {
          // Came from local DB — decode the JSON string back to a List
          try {
            final decoded = jsonDecode(raw) as List? ?? [];
            return decoded
                .map((t) => Map<String, dynamic>.from(t as Map))
                .toList();
          } catch (_) {
            return <Map<String, dynamic>>[];
          }
        }
        if (raw is List) {
          return raw.map((t) => Map<String, dynamic>.from(t as Map)).toList();
        }
        return <Map<String, dynamic>>[];
      }(),
      qtyAvailable: qty,
      isStorable: storable,
      optionalProductIds: optionalIds,
      publicDescription: description,
    );
  }

  bool get isAvailable {
    // Non-storable products are always purchasable
    if (!isStorable) return true;

    // Storable products must have stock
    return qtyAvailable > 0;
  }

  ComboProduct toComboProduct() => ComboProduct(
        id: id,
        name: name,
        basePrice: price,
        category: category,
        active: active,
        groups: comboGroups,
        // Pass tax info so cart service can compute GST on combo items
        taxIds: taxIds,
      );

  Map<String, dynamic> toMap() {
    final comboGroupsJson = isCombo
        ? jsonEncode(comboGroups.map((g) => g.toJson()).toList())
        : null;

    return {
      'id': id,
      'name': name,
      'price': price,
      'category': category,
      'active': active,
      'is_combo': isCombo ? true : false,
      'combo_groups': comboGroupsJson,
      'image': image, // Save base64 image to local DB for offline use
      // Encode taxIds as JSON string so it can be stored in SQLite text column.
      // Decoded back in fromJson via tax_id key.
      'tax_id': jsonEncode(taxIds),
      // Save variant fields so offline mode can show variant popup correctly.
      'has_variants': hasVariants,
      'variants': jsonEncode(variants
          .map((v) => {
                'variant_id': v.variantId,
                'variant_name': v.variantName,
                'price': v.price,
                'image': v.image,
                'attributes': v.attributes
                    .map((a) => {
                          'attribute_id': a.attributeId,
                          'attribute_name': a.attributeName,
                          'value_id': a.valueId,
                          'value_name': a.valueName,
                          'price_extra': a.priceExtra,
                        })
                    .toList(),
                'is_storable': v.isStorable ? 1 : 0,
              })
          .toList()),
      'qty_available': qtyAvailable,
      'is_storable': isStorable ? 1 : 0,
      'optional_product_ids': jsonEncode(optionalProductIds),
      'public_description': publicDescription,
    };
  }
}

// ─────────────────────────────────────────────
// PRODUCT API SERVICE
// ─────────────────────────────────────────────
class ProductApiService {
  static String? _token;

  // ── Authenticate → POST /api/v1/auth ─────────
  static Future<bool> authenticate({
    required String email,
    required String password,
  }) async {
    try {
      final baseUrl = await AppConfig.getServerUrl();
      if (baseUrl.isEmpty) return false;

      final deviceCode = await AppConfig.getDeviceCode();
      final response = await http
          .post(
            Uri.parse('$baseUrl/api/v1/auth'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email,
              'password': password,
              if (deviceCode.isNotEmpty) 'device_code': deviceCode,
            }),
          )
          .timeout(const Duration(seconds: 15));

      final data = jsonDecode(response.body);
      if (data['status'] == 'success' && data['token'] != null) {
        _token = data['token'] as String;
        await AppConfig.saveApiToken(_token!);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Auto-authenticate using saved credentials ─
  static Future<bool> _autoAuth() async {
    final email = await AppConfig.getApiEmail();
    final password = await AppConfig.getApiPassword();
    if (email.isEmpty || password.isEmpty) return false;
    return authenticate(email: email, password: password);
  }

  // ── LOAD FROM LOCAL CACHE ──────────────────────
  static Future<FetchResult> _loadFromLocal() async {
    try {
      final repo = ProductRepository();
      final sessionId = await AppConfig.getPosSessionId();
      final data = await repo.getAllProducts(sessionId: sessionId);

      debugPrint('📦 Loading products from local DB for session $sessionId');
      debugPrint('   Found ${data.length} products for session $sessionId');

      if (data.isEmpty) {
        debugPrint(
            '   ⚠️ No products found for session $sessionId - check if this session has cached products');
        return FetchResult.error(
            'No products cached for this session. Sync products while online first.');
      }

      final products = data.map((e) => ProductModel.fromJson(e)).toList();
      return FetchResult.ok(products, isOffline: true);
    } catch (e) {
      debugPrint('❌ Error loading from local DB: $e');
      return FetchResult.error('Local DB error: $e');
    }
  }

  static Future<void> _saveToLocal(List<ProductModel> products) async {
    try {
      final repo = ProductRepository();
      final sessionId = await AppConfig.getPosSessionId();
      final data = products.map((e) => e.toMap()).toList();

      // Save products linked to the currently selected session
      // The API returns products per session, so we save them for that session only
      if (sessionId > 0) {
        await repo.insertOrUpdateProducts(data, sessionId: sessionId);
        debugPrint('💾 Saved ${data.length} products for session $sessionId');
      }
    } catch (e) {
      debugPrint('❌ Error saving products to local DB: $e');
    }
  }

  static Future<FetchResult> fetchProducts({
    int limit = 100,
    int offset = 0,
  }) async {
    final baseUrl = await AppConfig.getServerUrl();
    if (baseUrl.isEmpty) return _loadFromLocal();

    // Note: We removed the preliminary health check to save data and time.
    // The main GET request will fail naturally if the server is offline.

    try {
      if (_token == null ||
          _token!.isEmpty ||
          AppConfig.isJwtExpired(_token!)) {
        _token = await AppConfig.getApiToken();
      }

      // Try to authenticate if token is still missing or expired.
      if (_token == null ||
          _token!.isEmpty ||
          AppConfig.isJwtExpired(_token!)) {
        await AppConfig.clearApiToken();
        final ok = await _autoAuth();
        if (!ok) {
          return _loadFromLocal();
        }
      }

      final sessionId = await AppConfig.getPosSessionId();
      if (sessionId <= 0) {
        return FetchResult.error('No POS session selected');
      }

      final response = await ApiClient.get(
        '/api/products?limit=$limit&offset=$offset&include_combos=true&session_id=$sessionId',
        headers: {'Content-Type': 'application/json'},
        timeout: const Duration(seconds: 15),
      );

      final result = _parseResponse(response);

      // ── SAVE TO LOCAL CACHE
      if (result.isSuccess) {
        await _saveToLocal(result.products!);
      } else {
        return _loadFromLocal();
      }

      return result;
    } catch (_) {
      // ── ANY NETWORK ERROR → LOCAL DB
      return _loadFromLocal();
    }
  }

  static FetchResult _parseResponse(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      if (data['status'] == 'success') {
        final list = (data['data'] as List? ?? []);
        final products = list.map((p) => ProductModel.fromJson(p)).toList();
        return FetchResult.ok(products);
      }
      return FetchResult.error(data['message'] ?? 'Unknown server error');
    } catch (_) {
      return FetchResult.error('Parse error');
    }
  }
}

class FetchResult {
  final List<ProductModel>? products;
  final String? errorMessage;
  final bool isOffline;

  const FetchResult._(
      {this.products, this.errorMessage, this.isOffline = false});

  factory FetchResult.ok(List<ProductModel> p, {bool isOffline = false}) =>
      FetchResult._(products: p, isOffline: isOffline);

  factory FetchResult.error(String msg) => FetchResult._(errorMessage: msg);

  bool get isSuccess => products != null;
}

// ─────────────────────────────────────────────
// PRODUCT SCREEN
// ─────────────────────────────────────────────
class ProductScreen extends StatefulWidget {
  final VoidCallback? onCartTap;
  const ProductScreen({super.key, this.onCartTap});

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  // ── State ──
  bool _isLoading = true;
  bool _isOffline = false;

  // Listens to connectivity changes so the offline banner reacts instantly
  // when wifi drops or restores — no manual refresh needed.
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  String _errorMessage = '';

  List<ProductModel> _allProducts = [];
  List<ProductModel> _filteredProducts = [];
  List<String> _categories = ['All'];
  String _selectedCategory = 'All';

  // ── Search ──
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProducts();
    _searchCtrl.addListener(_applyFilters);
    // Reload products when session changes in Settings
    sessionChangeNotifier.addListener(_onSessionChanged);
    _startConnectivityListener();
  }

  // Listens to real-time connectivity changes.
  // When wifi drops → _isOffline = true → banner shows instantly.
  // When wifi restores → _isOffline = false → banner hides instantly.
  void _startConnectivityListener() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      final isOffline =
          result.isEmpty || result.first == ConnectivityResult.none;
      if (mounted && _isOffline != isOffline) {
        setState(() => _isOffline = isOffline);
      }
    });
  }

  void _onSessionChanged() {
    debugPrint('🔄 Session changed → reloading products');
    if (mounted) _loadProducts();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    sessionChangeNotifier.removeListener(_onSessionChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────
  // DATA
  // ─────────────────────────────────────────

  Future<void> _loadProducts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _isOffline = false;
    });

    final result = await ProductApiService.fetchProducts();

    if (!mounted) return;

    if (!result.isSuccess) {
      setState(() {
        _isLoading = false;
        _errorMessage = result.errorMessage!;
      });
      return;
    }

    final products = result.products!;

    if (products.isEmpty) {
      setState(() {
        _isLoading = false;
        _errorMessage =
            'No products found on the server.\nMake sure products have "Can be Sold" enabled in Odoo.';
        _isOffline = result.isOffline;
      });
      return;
    }

    // ← ADD: Debug output for offline mode
    final comboCount = products.where((p) => p.isCombo).length;
    debugPrint(
        '✅ Loaded ${products.length} products ($comboCount combos) - Offline: ${result.isOffline}');

    // Build category list
    final catSet = <String>{};
    for (final p in products) {
      if (p.category.isNotEmpty) catSet.add(p.category);
    }

    // ← ADD: Include "Combos" category if any combo exists
    if (comboCount > 0) {
      catSet.add('Combos');
    }

    setState(() {
      _allProducts = products;
      _categories = ['All', ...catSet.toList()..sort()];
      _isLoading = false;
      _isOffline = result.isOffline;
    });

    // Populate cache for Cart screen lookup
    ProductCache.instance.setAll(products);

    _applyFilters();
  }

// ← ADD: Filter by Combos category
  void _applyFilters() {
    final q = _searchCtrl.text.toLowerCase().trim();
    setState(() {
      _filteredProducts = _allProducts.where((p) {
        // Handle "Combos" special category
        final matchCat = _selectedCategory == 'All' ||
            (_selectedCategory == 'Combos' && p.isCombo) ||
            (p.category == _selectedCategory);

        final matchSearch = q.isEmpty || p.name.toLowerCase().contains(q);
        return matchCat && matchSearch;
      }).toList();
    });
  }

  // ─────────────────────────────────────────
  // CART
  // ─────────────────────────────────────────

  void _addToCart(ProductModel p) {
    // CartService uses ValueNotifier (cartNotifier) — the cart badge and
    // quantity buttons update automatically via ValueListenableBuilder.
    // setState() here was causing the ENTIRE product list to rebuild,
    // which reset scroll position and felt like a page refresh. Removed.
    CartService.instance.addItem(p);
  }

  void _removeFromCart(int id) {
    // Same fix — no setState needed, ValueNotifier handles UI update.
    CartService.instance.removeItem(id);
  }

  Future<void> _openComboSheet(ProductModel p) async {
    final cartKey = await showComboSelectionSheet(
      context,
      p.toComboProduct(),
    );
    if (cartKey != null && mounted) {
      showTopNotification(
        context,
        '${p.name} added to cart',
        color: kGreen,
        icon: Icons.check_circle_rounded,
        duration: const Duration(seconds: 2),
      );
    }
  }

  // ─────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Stack(
          children: [
            // ── Main content column ──────────────────────────────────────
            Column(
              children: [
                _buildTopBar(),
                if (_isOffline) _buildOfflineBanner(),
                _buildSearchBar(),
                _buildCategoryChips(),
                const SizedBox(height: 8),
                Expanded(
                  // Listen to both cart notifiers so padding updates instantly
                  // when cart becomes empty or gets its first item.
                  child: ValueListenableBuilder<Map<int, CartItem>>(
                    valueListenable: CartService.instance.cartNotifier,
                    builder: (_, __, ___) => ValueListenableBuilder(
                      valueListenable: CartService.instance.comboCartNotifier,
                      builder: (_, __, ___) {
                        final hasItems =
                            CartService.instance.totalItemCount > 0;
                        return Padding(
                          // Add bottom padding only when cart bar is visible.
                          // When cart is empty the bar hides and padding = 0,
                          // so no ugly gap appears at the bottom of the grid.
                          padding: EdgeInsets.only(bottom: hasItems ? 76 : 0),
                          child: _buildBody(),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),

            // ── Blinkit-style sticky bottom cart bar ─────────────────────
            // Sits above the product grid. Shows up to 3 product images.
            // Hides automatically when cart is empty.
            _BlinkitCartBar(
              onTap: () {
                if (widget.onCartTap != null) widget.onCartTap!();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Offline Banner ─────────────────────────
  Widget _buildOfflineBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: kOrange.withValues(alpha: 0.15),
      child: Row(
        children: [
          const Icon(Icons.wifi_off_rounded, color: kOrange, size: 16),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'You are in Offline Mode',
              style: TextStyle(color: kOrange, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

// ── Top Bar ───────────────────────────────────
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Products',
                style: TextStyle(
                  color: kTextPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),

              // ── POS SESSION DISPLAY ──
              FutureBuilder<String>(
                future: AppConfig.getPosSessionName(),
                builder: (_, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const SizedBox.shrink();
                  }

                  if (snap.data?.isNotEmpty ?? false) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.point_of_sale_rounded,
                            color: kGreen,
                            size: 13,
                          ),
                          const SizedBox(width: 4),
                          // Constrain width so long session names don't
                          // overflow the top bar — clip with ellipsis.
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 200),
                            child: Text(
                              snap.data!,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: const TextStyle(
                                color: kGreen,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  // Optional fallback (better UX)
                  return const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'No POS session selected',
                      style: TextStyle(
                        color: kOrange,
                        fontSize: 11,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),

          const Spacer(),

          // ── CART BUTTON ──
          // FIX: Listen to BOTH cartNotifier (regular products) AND
          // comboCartNotifier (combo products) so the badge on the header
          // cart icon refreshes immediately when a combo is added to the cart.
          // Before this fix, only cartNotifier was watched, so combos added
          // would only appear after a manual refresh / screen switch.
          ValueListenableBuilder(
            valueListenable: CartService.instance.cartNotifier,
            builder: (_, __, ___) {
              // Inner builder: re-renders when combo cart changes
              return ValueListenableBuilder(
                valueListenable: CartService.instance.comboCartNotifier,
                builder: (_, __, ___) {
                  // totalItemCount includes both regular + combo quantities
                  final count = CartService.instance.totalItemCount;

                  return GestureDetector(
                    onTap: () {
                      if (widget.onCartTap != null) {
                        widget.onCartTap!();
                      }
                    },
                    // SizedBox gives extra space so the badge can render
                    // outside the 44x44 icon box without pixel overflow.
                    child: SizedBox(
                      width: 52,
                      height: 52,
                      child: Stack(
                        // clipBehavior.none lets badge overflow icon boundary
                        // without causing RenderFlex pixel errors.
                        clipBehavior: Clip.none,
                        children: [
                          // Cart icon button — centred in the SizedBox
                          Positioned(
                            bottom: 0,
                            left: 0,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: kCard,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: kCardBorder),
                              ),
                              child: const Icon(
                                Icons.shopping_cart_outlined,
                                color: kTextPrimary,
                                size: 22,
                              ),
                            ),
                          ),
                          // Badge — uses borderRadius instead of BoxShape.circle
                          // so 2-digit counts (10+) render correctly without
                          // stretching the shape and causing pixel errors.
                          if (count > 0)
                            Positioned(
                              right: 0,
                              top: 0,
                              child: Container(
                                constraints: const BoxConstraints(
                                  minWidth: 18,
                                  minHeight: 18,
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 2),
                                // FIX: alignment centers the digit both
                                // horizontally and vertically in the badge.
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: kPurple,
                                  // borderRadius handles multi-digit counts;
                                  // BoxShape.circle only works for single digits.
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  // Cap display at 99+ to avoid very wide badge
                                  count > 99 ? '99+' : '$count',
                                  textAlign: TextAlign
                                      .center, // FIX: center number in badge
                                  style: const TextStyle(
                                    color: kTextPrimary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Search Bar ────────────────────────────────
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(color: kTextPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search products...',
          hintStyle: const TextStyle(color: kTextSecondary),
          prefixIcon:
              const Icon(Icons.search_rounded, color: kTextSecondary, size: 20),
          suffixIcon: _searchCtrl.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear_rounded,
                      color: kTextSecondary, size: 18),
                  onPressed: () => _searchCtrl.clear(),
                )
              : null,
          filled: true,
          fillColor: kInputBg,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kCardBorder)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kCardBorder)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kPurple)),
        ),
      ),
    );
  }

  // ── Category Chips ────────────────────────────
  Widget _buildCategoryChips() {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final cat = _categories[i];
          final selected = _selectedCategory == cat;
          return GestureDetector(
            onTap: () {
              setState(() => _selectedCategory = cat);
              _applyFilters();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? kPurple : kCard,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: selected ? kPurple : kCardBorder),
              ),
              child: Text(
                cat,
                style: TextStyle(
                  color: selected ? kTextPrimary : kTextSecondary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Body (loading / error / grid) ─────────────
  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: kPurple));
    }

    if (_errorMessage.isNotEmpty && _allProducts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  color: kTextSecondary, size: 52),
              const SizedBox(height: 16),
              Text(
                _errorMessage,
                style: const TextStyle(color: kTextSecondary, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _loadProducts,
                icon: const Icon(Icons.refresh_rounded,
                    color: kTextPrimary, size: 18),
                label:
                    const Text('Retry', style: TextStyle(color: kTextPrimary)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPurple,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_filteredProducts.isEmpty) {
      return const Center(
        child: Text('No products match your search.',
            style: TextStyle(color: kTextSecondary, fontSize: 14)),
      );
    }

    return RefreshIndicator(
      color: kPurple,
      backgroundColor: kCard,
      onRefresh: _loadProducts,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          // Increased height by lowering ratio (0.72 = taller card) so
          // image + name + category + price row all fit without gap/overflow.
          childAspectRatio: 0.72,
        ),
        itemCount: _filteredProducts.length,
        itemBuilder: (_, i) => _buildProductCard(_filteredProducts[i]),
      ),
    );
  }

  Widget _buildProductCard(ProductModel p) {
    // FIX: Wrap the entire card in nested ValueListenableBuilders so that
    // qty buttons (+ / -) update instantly when cart changes — without
    // calling setState() which was rebuilding the whole product list and
    // resetting the scroll position (felt like a page refresh).
    return ValueListenableBuilder(
      valueListenable: CartService.instance.cartNotifier,
      builder: (_, __, ___) {
        return ValueListenableBuilder(
          valueListenable: CartService.instance.comboCartNotifier,
          builder: (_, __, ___) {
            // ─────────────────────────────────────────────
            // STOCK LOGIC
            // ─────────────────────────────────────────────
            bool isOutOfStock = false;
            if (p.isCombo) {
              isOutOfStock = p.toComboProduct().isOutOfStock;
            } else if (p.hasVariants && p.variants.isNotEmpty) {
              // A variant product is only OOS if ALL variants are OOS
              isOutOfStock = !p.variants.any((v) => v.isAvailable);
            } else {
              isOutOfStock = !p.isAvailable;
            }

            final canAddToCart = !isOutOfStock;

            // ─────────────────────────────────────────────
            // CART QTY LOGIC
            // ─────────────────────────────────────────────

            // FIX: For variant products, cart stores items by variantId
            // (product.product id), NOT by template id (p.id).
            // So cart[p.id] always returns 0 for variant products.
            // Solution: Sum qty across ALL variant ids belonging
            // to this template.
            final regularQty = p.hasVariants && p.variants.isNotEmpty
                ? CartService.instance.getTotalVariantQtyForTemplate(
                    p.variants.map((v) => v.variantId).toList(),
                  )
                : CartService.instance.cart[p.id]?.qty ?? 0;

            final comboQty = p.isCombo
                ? CartService.instance.getComboQtyForProduct(p.id)
                : 0;

            // ─────────────────────────────────────────────
            // UI COLORS / ICONS
            // ─────────────────────────────────────────────

            final bgColors = [
              const Color(0xFF2D4A3E),
              const Color(0xFF2A2D4E),
              const Color(0xFF4A2D2D),
              const Color(0xFF3E3A2D),
              const Color(0xFF2D3A4A),
            ];

            final icons = [
              Icons.fastfood_rounded,
              Icons.local_cafe_rounded,
              Icons.restaurant_rounded,
              Icons.lunch_dining_rounded,
              Icons.local_pizza_rounded,
            ];

            final color = bgColors[p.id % bgColors.length];
            final icon = icons[p.id % icons.length];

            return GestureDetector(
              onTap: canAddToCart
                  ? () => p.isCombo
                      ? _openComboSheet(p)
                      : _showDetail(p, color, icon)
                  : null,
              child: Container(
                decoration: BoxDecoration(
                  color: canAddToCart ? kCard : kCard.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: p.isCombo
                        ? kOrange.withValues(alpha: 0.5)
                        : kCardBorder,
                    width: p.isCombo ? 1.5 : 1,
                  ),
                ),
                child: Padding(
                  // Reduced from 12 to 10 to give content more room
                  // without clipping the bottom price/button row.
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            // Product image
                            _ProductImageTile(
                              key: ValueKey('img_${p.id}'),
                              image: p.image,
                              color: color,
                              icon: icon,
                            ),

                            // ─────────────────────────────────────────────
                            // OUT OF STOCK OVERLAY
                            // ─────────────────────────────────────────────

                            if (!canAddToCart)
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  alignment: Alignment.center,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      Icon(Icons.block_rounded,
                                          color: Colors.white, size: 36),
                                      SizedBox(height: 6),
                                      Text(
                                        'Out of Stock',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                            // ─────────────────────────────────────────────
                            // COMBO BADGE
                            // ─────────────────────────────────────────────

                            if (p.isCombo)
                              Positioned(
                                top: 6,
                                left: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: kOrange,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'COMBO',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),

                            if (!canAddToCart)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: kRed,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text(
                                    'OUT OF STOCK',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                      // Reduced gap: image → name (10 to 8)
                      const SizedBox(height: 8),

                      // ─────────────────────────────────────────────
                      // PRODUCT NAME
                      // ─────────────────────────────────────────────

                      Text(
                        p.name,
                        style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),

                      const SizedBox(height: 2),

                      // ─────────────────────────────────────────────
                      // PRODUCT SUBTITLE
                      // ─────────────────────────────────────────────

                      Text(
                        p.isCombo
                            ? '${p.comboGroups.length} groups · choose items'
                            : p.category,
                        style: const TextStyle(
                          color: kTextSecondary,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),

                      // Reduced gap: category → price row (8 to 6)
                      const SizedBox(height: 6),

                      Row(
                        children: [
                          // ─────────────────────────────────────────────
                          // PRICE
                          // ─────────────────────────────────────────────

                          Text(
                            '${AppConfig.currencySymbol}${p.price.toStringAsFixed(0)}',
                            style: TextStyle(
                              color:
                                  canAddToCart ? kPurpleLight : kTextSecondary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),

                          const Spacer(),

                          // ─────────────────────────────────────────────
                          // COMBO BUTTON
                          // ─────────────────────────────────────────────

                          if (p.isCombo)
                            GestureDetector(
                              onTap: canAddToCart
                                  ? () => _openComboSheet(p)
                                  : null,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: canAddToCart ? kOrange : kInputBg,
                                      borderRadius: BorderRadius.circular(8),
                                      border: canAddToCart
                                          ? null
                                          : Border.all(
                                              color: kCardBorder,
                                            ),
                                    ),
                                    child: Icon(
                                      Icons.add_rounded,
                                      color: canAddToCart
                                          ? Colors.white
                                          : kTextSecondary,
                                      size: 18,
                                    ),
                                  ),
                                  if (comboQty > 0 && canAddToCart)
                                    Positioned(
                                      right: -6,
                                      top: -6,
                                      child: Container(
                                        width: 16,
                                        height: 16,
                                        decoration: const BoxDecoration(
                                          color: kGreen,
                                          shape: BoxShape.circle,
                                        ),
                                        child: Center(
                                          child: Text(
                                            '$comboQty',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            )

                          // ─────────────────────────────────────────────
                          // ADD BUTTON
                          // ─────────────────────────────────────────────

                          else if (regularQty == 0)
                            GestureDetector(
                              onTap: canAddToCart
                                  ? () => p.hasVariants
                                      ? _showDetail(
                                          p,
                                          color,
                                          icon,
                                        )
                                      : _addToCart(p)
                                  : null,
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: canAddToCart ? kPurple : kInputBg,
                                  borderRadius: BorderRadius.circular(8),
                                  border: canAddToCart
                                      ? null
                                      : Border.all(
                                          color: kCardBorder,
                                        ),
                                ),
                                child: Icon(
                                  Icons.add_rounded,
                                  color: canAddToCart
                                      ? kTextPrimary
                                      : kTextSecondary,
                                  size: 18,
                                ),
                              ),
                            )

                          // ─────────────────────────────────────────────
                          // QTY CONTROLS
                          // ─────────────────────────────────────────────

                          else
                            Row(
                              children: [
                                _qtyBtn(
                                  icon: Icons.remove_rounded,
                                  color: kInputBg,
                                  onTap: canAddToCart
                                      ? () => p.hasVariants
                                          ? _showDetail(
                                              p,
                                              color,
                                              icon,
                                            )
                                          : _removeFromCart(
                                              p.id,
                                            )
                                      : null,
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  child: Text(
                                    '$regularQty',
                                    style: const TextStyle(
                                      color: kTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                _qtyBtn(
                                  icon: Icons.add_rounded,
                                  color: canAddToCart ? kPurple : kInputBg,
                                  onTap: canAddToCart
                                      ? () => p.hasVariants
                                          ? _showDetail(
                                              p,
                                              color,
                                              icon,
                                            )
                                          : _addToCart(p)
                                      : null,
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _qtyBtn({
    required IconData icon,
    required Color color,
    required VoidCallback? onTap, // ✅ Make nullable
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(7),
          border: color == kInputBg ? Border.all(color: kCardBorder) : null,
        ),
        child: Icon(icon, color: kTextPrimary, size: 14),
      ),
    );
  }

  // ── Product Detail Bottom Sheet ───────────────
  // ── Build a unique cart key for a variant: "templateId_variantId" ──────
  // We encode the variant id into the product id field using a hash trick:
  // Flutter's cart Map<int, CartItem> uses productId as key.
  // Using variantId directly keeps each variant as a separate line item —
  // which is the correct Odoo POS behaviour.
  void _addVariantToCart(ProductModel template, ProductVariant variant) {
    // Create a lightweight ProductModel that carries variant-specific data.
    // variantId (product.product id) is used as the cart key so different
    // variants of the same template appear as separate cart lines.
    final variantProduct = ProductModel(
      id: variant.variantId,
      name: '${template.name} (${variant.attributeLabel})',
      price: variant.price,
      category: template.category,
      active: template.active,
      // Use variant image if available, fall back to template image
      image: variant.image ?? template.image,
      // Pass variant-specific tax from Odoo; fall back to template tax
      // so GST badge shows correctly on cart item row.
      taxIds: variant.taxIds.isNotEmpty ? variant.taxIds : template.taxIds,
    );
    // Use addVariantItem so attribute pairs (Color, Size etc.) are stored in
    // CartItem and shown as chips in the cart tile and order history detail sheet.
    CartService.instance.addVariantItem(variantProduct, variant.attributes);
  }

  void _removeVariantFromCart(int variantId) {
    CartService.instance.removeItem(variantId);
  }

  // ── Group variant attributes for the chip selector UI ───────────────────
  // Returns: { "Color": [{"id":1,"name":"Red"}, {"id":2,"name":"Blue"}], ... }
  Map<String, List<Map<String, dynamic>>> _groupAttributes(
      List<ProductVariant> variants) {
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final v in variants) {
      for (final attr in v.attributes) {
        grouped.putIfAbsent(attr.attributeName, () => []);
        // Avoid duplicate value chips
        if (!grouped[attr.attributeName]!.any((e) => e['id'] == attr.valueId)) {
          grouped[attr.attributeName]!.add({
            'id': attr.valueId,
            'name': attr.valueName,
            'attribute_id': attr.attributeId,
            'price_extra': attr.priceExtra,
          });
        }
      }
    }
    return grouped;
  }

  // ── Find the variant that matches ALL currently selected attribute values ─
  // Returns null if no complete selection yet (user hasn't picked all attrs).
  ProductVariant? _findMatchingVariant(
    List<ProductVariant> variants,
    Map<int, int> selectedValues, // attributeId → valueId
  ) {
    if (selectedValues.isEmpty) return null;
    for (final v in variants) {
      // Every attribute in THIS variant must match a selected value
      final matches = v.attributes.every(
        (a) => selectedValues[a.attributeId] == a.valueId,
      );
      if (matches && v.attributes.length == selectedValues.length) return v;
    }
    return null;
  }

  // ── Product Detail Bottom Sheet — UPDATED ──────────────
  // ✅ Disables out-of-stock variants
  // ✅ Shows public_description
  // ✅ Shows optional products after adding to cart
  void _showDetail(ProductModel p, Color color, IconData icon) {
    final Map<int, int> selectedValues = {};
    ProductVariant? matched;

    // Local quantity map: cartId → user-chosen qty inside the popup.
    // Keyed by cartId so each variant gets its own independent counter.
    // Always initialized to at least 1 so the popup never shows "0".
    final Map<int, int> localQtyMap = {};

    // Auto-select first value of each attribute when product has variants
    if (p.hasVariants && p.variants.isNotEmpty) {
      final grouped = _groupAttributes(p.variants);
      for (final entry in grouped.entries) {
        final values = entry.value;
        // Try to find the first value that has at least one available variant
        for (final val in values) {
          final attrId = val['attribute_id'] as int;
          final valueId = val['id'] as int;
          // Check if any variant with this value is available
          final hasAvailable = p.variants.any((v) =>
              v.isAvailable &&
              v.attributes
                  .any((a) => a.attributeId == attrId && a.valueId == valueId));
          if (hasAvailable) {
            selectedValues[attrId] = valueId;
            break;
          }
        }
        // Fallback: if no available value found, select first anyway (will show as unavailable)
        if (!selectedValues.containsKey(values.first['attribute_id'] as int)) {
          selectedValues[values.first['attribute_id'] as int] =
              values.first['id'] as int;
        }
      }
      matched = _findMatchingVariant(p.variants, selectedValues);
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setModal) {
          if (p.hasVariants) {
            matched = _findMatchingVariant(p.variants, selectedValues);
          }

          // Determine cart key: variantId for variants, product id otherwise
          final cartId =
              (p.hasVariants && matched != null) ? matched!.variantId : p.id;

          // Initialize local qty for this cartId on first encounter.
          // If item is already in cart, start from that qty; otherwise default to 1.
          if (!localQtyMap.containsKey(cartId)) {
            final cartQty = CartService.instance.cart[cartId]?.qty ?? 0;
            localQtyMap[cartId] = cartQty > 0 ? cartQty : 1;
          }
          final qty = localQtyMap[cartId]!;

          // Display price: variant price if matched, else template base price
          final displayPrice =
              (p.hasVariants && matched != null) ? matched!.price : p.price;
          final displayImage =
              (p.hasVariants && matched != null && matched!.image != null)
                  ? matched!.image
                  : p.image;

          // ✅ Check if current selection is out of stock
          // For variants: check the matched combination.
          // For simple products: check the template stock.
          final isSelectionOutOfStock = p.hasVariants
              ? (matched != null && !matched!.isAvailable)
              : !p.isAvailable;

          return SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 24,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: kCardBorder,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 20),

                // Product image
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AspectRatio(
                    aspectRatio: 1 / 1,
                    child: Stack(
                      children: [
                        displayImage != null && displayImage.isNotEmpty
                            ? Container(
                                color: color,
                                alignment: Alignment.center,
                                child: ProductImage(
                                  key: ValueKey(
                                      'detail_${p.id}_${matched?.variantId ?? 0}'),
                                  imageBase64: displayImage,
                                  fit: BoxFit.contain,
                                ),
                              )
                            : Container(
                                color: color,
                                alignment: Alignment.center,
                                child:
                                    Icon(icon, color: Colors.white70, size: 60),
                              ),
                        // ✅ Out of stock overlay for current selection
                        if (isSelectionOutOfStock)
                          Positioned.fill(
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.5),
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: const [
                                  Icon(Icons.block_rounded,
                                      color: Colors.white, size: 40),
                                  SizedBox(height: 8),
                                  Text(
                                    'This variant is\nout of stock',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Product name
                Text(p.name,
                    style: const TextStyle(
                        color: kTextPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(p.category,
                    style:
                        const TextStyle(color: kTextSecondary, fontSize: 14)),

                // ✅ NEW: Public Description
                if (p.publicDescription.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: kInputBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kCardBorder),
                    ),
                    child: Text(
                      // Strip basic HTML tags for display
                      _stripHtml(p.publicDescription),
                      style: const TextStyle(
                        color: kTextSecondary,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],

                // VARIANT ATTRIBUTE SELECTORS
                if (p.hasVariants && p.variants.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  ..._groupAttributes(p.variants).entries.map((entry) {
                    final attrName = entry.key;
                    final values = entry.value;
                    final attrId = values.first['attribute_id'] as int;
                    final selectedId = selectedValues[attrId];

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            attrName,
                            style: const TextStyle(
                              color: kTextSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: values.map((val) {
                              final valueId = val['id'] as int;
                              final isSelected = selectedId == valueId;

                              // ✅ FIX: An attribute chip is OOS ONLY if ALL variants
                              // containing this specific value are out of stock.
                              final variantsWithThisValue = p.variants.where(
                                (v) => v.attributes.any((a) =>
                                    a.attributeId == attrId &&
                                    a.valueId == valueId),
                              );
                              final isOutOfStockVariant =
                                  variantsWithThisValue.isNotEmpty &&
                                      !variantsWithThisValue
                                          .any((v) => v.isAvailable);

                              return GestureDetector(
                                onTap: isOutOfStockVariant
                                    ? null
                                    : () {
                                        setModal(() {
                                          selectedValues[attrId] = valueId;
                                        });
                                      },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: isOutOfStockVariant
                                        ? kInputBg
                                        : isSelected
                                            ? kPurple
                                            : kInputBg,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: isOutOfStockVariant
                                          ? kCardBorder
                                          : isSelected
                                              ? kPurple
                                              : kCardBorder,
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Builder(builder: (_) {
                                    final extra =
                                        (val['price_extra'] as num? ?? 0)
                                            .toDouble();
                                    return Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          val['name'] as String,
                                          style: TextStyle(
                                            color: isOutOfStockVariant
                                                ? kTextSecondary
                                                : isSelected
                                                    ? kTextPrimary
                                                    : kTextSecondary,
                                            fontSize: 13,
                                            fontWeight: isSelected
                                                ? FontWeight.w600
                                                : FontWeight.normal,
                                          ),
                                        ),
                                        if (extra > 0) ...[
                                          const SizedBox(width: 5),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 5, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: kOrange.withValues(
                                                  alpha:
                                                      isSelected ? 1.0 : 0.85),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              '+${AppConfig.currencySymbol}${extra.toStringAsFixed(2)}',
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w700),
                                            ),
                                          ),
                                        ],
                                        if (isOutOfStockVariant) ...[
                                          const SizedBox(width: 4),
                                          Container(
                                            width: 4,
                                            height: 4,
                                            decoration: const BoxDecoration(
                                                color: kRed,
                                                shape: BoxShape.circle),
                                          ),
                                        ],
                                      ],
                                    );
                                  }),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    );
                  }),
                  if (matched == null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: const [
                          Icon(Icons.info_outline_rounded,
                              color: kOrange, size: 15),
                          SizedBox(width: 6),
                          Text(
                            'This combination is not available',
                            style: TextStyle(color: kOrange, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                ],

                const SizedBox(height: 20),

                // Price + qty controls
                Row(
                  children: [
                    Text(
                      '${AppConfig.currencySymbol}${displayPrice.toStringAsFixed(2)}',
                      style: const TextStyle(
                          color: kPurpleLight,
                          fontSize: 24,
                          fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Row(children: [
                      _qtyBtn(
                        icon: Icons.remove_rounded,
                        // Dim the minus button when qty is already at 1 (minimum)
                        color: qty <= 1
                            ? kInputBg.withValues(alpha: 0.5)
                            : kInputBg,
                        onTap: () {
                          if (qty <= 1) return;
                          if (p.hasVariants && matched != null) {
                            _removeVariantFromCart(matched!.variantId);
                          } else {
                            _removeFromCart(p.id);
                          }
                          setModal(() {
                            localQtyMap[cartId] = qty - 1;
                          });
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text('$qty',
                            style: const TextStyle(
                                color: kTextPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                      ),
                      _qtyBtn(
                        icon: Icons.add_rounded,
                        color: isSelectionOutOfStock ? kInputBg : kPurple,
                        onTap: () {
                          if (p.hasVariants && matched == null) return;
                          if (isSelectionOutOfStock) return;

                          if (p.hasVariants) {
                            _addVariantToCart(p, matched!);
                          } else {
                            _addToCart(p);
                          }
                          setModal(() {
                            localQtyMap[cartId] = qty + 1;
                          });
                        },
                      ),
                    ]),
                  ],
                ),
                const SizedBox(height: 24),

                // Add to Cart button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: isSelectionOutOfStock
                        ? null
                        : () {
                            if (p.hasVariants && matched == null) return;
                            final currentCartQty =
                                CartService.instance.cart[cartId]?.qty ?? 0;

                            if (currentCartQty == 0) {
                              // Item not yet in cart — add it once, then set to localQty
                              if (p.hasVariants) {
                                _addVariantToCart(p, matched!);
                              } else {
                                _addToCart(p);
                              }
                              // If user increased qty above 1, apply the extra quantity
                              if (qty > 1) {
                                CartService.instance.setItemQty(cartId, qty);
                              }
                            } else {
                              // Item already in cart — just update to the chosen qty
                              CartService.instance.setItemQty(cartId, qty);
                            }
                            Navigator.pop(ctx);

                            // ✅ Show optional products sheet after adding to cart
                            if (p.optionalProductIds.isNotEmpty) {
                              _showOptionalProductsSheet(p);
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          isSelectionOutOfStock ? kInputBg : kPurple,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      elevation: 0,
                    ),
                    child: Text(
                      isSelectionOutOfStock
                          ? 'Out of Stock'
                          : (p.hasVariants && matched == null
                              ? 'Select a variant'
                              : (CartService.instance.cart[cartId] != null
                                  ? 'Update Cart ($qty)'
                                  : 'Add to Cart ($qty)')),
                      style: const TextStyle(
                          color: kTextPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  // ✅ NEW: Strip basic HTML tags from description
  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  // ✅ NEW: Show optional/upsell products bottom sheet
  void _showOptionalProductsSheet(ProductModel sourceProduct) {
    // Find optional products from the cached product list
    final optionalProducts = _allProducts
        .where((p) => sourceProduct.optionalProductIds.contains(p.id))
        .where((p) => p.isAvailable) // Only show in-stock optional products
        .toList();

    if (optionalProducts.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: false,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: kCardBorder, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),

            // Header
            Row(
              children: [
                const Icon(Icons.star_rounded, color: kOrange, size: 22),
                const SizedBox(width: 8),
                const Text(
                  'You might also like',
                  style: TextStyle(
                    color: kTextPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: const Text(
                    'Skip',
                    style: TextStyle(
                      color: kTextSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Optional products list
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.35,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: optionalProducts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final op = optionalProducts[i];
                  return _buildOptionalProductTile(ctx, op);
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionalProductTile(BuildContext ctx, ProductModel op) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kInputBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kCardBorder),
      ),
      child: Row(
        children: [
          // Product image thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 48,
              child: op.image != null && op.image!.isNotEmpty
                  ? ProductImage(
                      imageBase64: op.image!,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      color: const Color(0xFF2D4A3E),
                      alignment: Alignment.center,
                      child: const Icon(Icons.fastfood_rounded,
                          color: Colors.white70, size: 22),
                    ),
            ),
          ),
          const SizedBox(width: 12),

          // Product info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  op.name,
                  style: const TextStyle(
                    color: kTextPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${AppConfig.currencySymbol}${op.price.toStringAsFixed(0)}',
                  style: const TextStyle(
                    color: kPurpleLight,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // Add button — opens full product detail popup for ALL products.
          // Previously simple products were added directly without qty control.
          // Now both variant and simple products open _showDetail so the user
          // gets a quantity counter + "Add to Cart" button before confirming.
          GestureDetector(
            onTap: () {
              Navigator.pop(ctx); // Close the optional products sheet first

              final bgColors = [
                const Color(0xFF2D4A3E),
                const Color(0xFF2A2D4E),
                const Color(0xFF4A2D2D),
              ];
              final icons = [
                Icons.fastfood_rounded,
                Icons.local_cafe_rounded,
                Icons.restaurant_rounded,
              ];

              // Open the product detail popup — handles variant and simple products.
              // User can adjust quantity and tap "Add to Cart" to confirm.
              _showDetail(op, bgColors[op.id % 3], icons[op.id % 3]);
            },
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: kPurple,
                borderRadius: BorderRadius.circular(8),
              ),
              child:
                  const Icon(Icons.add_rounded, color: kTextPrimary, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BLINKIT-STYLE BOTTOM CART BAR
// ─────────────────────────────────────────────────────────────────────────────
//
// Sits at the bottom of the product screen inside a Stack.
// Shows up to _kMaxBarImages circular product thumbnails (newest on left/top).
// When a 4th product is added, it takes the first slot and the oldest drops off
// because we always take the last _kMaxBarImages items from the cart map
// (Dart Map preserves insertion order → last = newest).
// Hides automatically when cart is empty.
//
class _BlinkitCartBar extends StatelessWidget {
  final VoidCallback onTap;

  const _BlinkitCartBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Listen to cartNotifier (fires on EVERY cart change: add, remove, qty +/-)
    // so the item count and images update immediately when user taps + or -.
    // cartVersionNotifier alone only fires on add/remove, missing qty updates.
    return ValueListenableBuilder<Map<int, CartItem>>(
      valueListenable: CartService.instance.cartNotifier,
      builder: (_, __, ___) {
        // Also listen to combo cart so combo qty changes update the bar too
        return ValueListenableBuilder(
          valueListenable: CartService.instance.comboCartNotifier,
          builder: (_, __, ___) {
            final totalCount = CartService.instance.totalItemCount;

            // Hide when cart is empty
            if (totalCount == 0) return const SizedBox.shrink();

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
                        color: kCartBarGreen,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 14),

                          // ── Overlapping product image circles ──────────
                          _OverlappingImages(images: _buildImageList()),

                          const SizedBox(width: 14),

                          // ── "View cart" + live item count ─────────────
                          // totalCount updates on every + / - press because
                          // we are now listening to cartNotifier above
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'View cart',
                                  style: TextStyle(
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

                          // ── Arrow ──────────────────────────────────────
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
          },
        );
      },
    );
  }

  /// Collect product images from cart for the thumbnail strip.
  ///
  /// Strategy (Blinkit rule):
  /// - Read regular cart items in insertion order, reversed → newest first.
  /// - Cap at [_kMaxBarImages] (default 3).
  /// - When 4th item is added, it becomes index-0; oldest falls off naturally.
  List<String?> _buildImageList() {
    final cart = CartService.instance.cart;
    final comboCart = CartService.instance.comboCart;

    // Reverse insertion order so newest item is first
    final regularImages =
        cart.values.toList().reversed.map((item) => item.image).toList();

    // Combo items have no stored image → null shows a placeholder icon
    final comboImages =
        comboCart.values.toList().reversed.map((_) => null as String?).toList();

    final allImages = [...regularImages, ...comboImages];

    // Cap at max — this enforces the "4th replaces 1st" Blinkit behaviour
    return allImages.take(_kMaxBarImages).toList();
  }
}

// ── Overlapping circular thumbnails ─────────────────────────────────────────
class _OverlappingImages extends StatelessWidget {
  final List<String?> images;

  const _OverlappingImages({required this.images});

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();

    const double imageSize = 40.0;
    const double overlap = 12.0; // pixels each image overlaps the previous one
    final totalWidth = imageSize + (images.length - 1) * (imageSize - overlap);

    return SizedBox(
      width: totalWidth,
      height: imageSize,
      child: Stack(
        children: List.generate(images.length, (index) {
          // Render in reverse order so the first image (newest) appears on top
          final renderIndex = images.length - 1 - index;
          return Positioned(
            left: renderIndex * (imageSize - overlap),
            child: _CircleThumb(
              imageBase64: images[renderIndex],
              size: imageSize,
            ),
          );
        }),
      ),
    );
  }
}

// ── Single circular thumbnail with white border ──────────────────────────────
class _CircleThumb extends StatelessWidget {
  final String? imageBase64;
  final double size;

  const _CircleThumb({required this.imageBase64, required this.size});

  /// Decode base64 image string to bytes. Returns null on failure.
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
        color: kCartBarGreenDark,
        // White border visually separates overlapping circles
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: ClipOval(
        child: bytes != null
            ? Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true, // Prevents flash when image updates
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

// ─────────────────────────────────────────────────────────────────────────────
// PRODUCT IMAGE TILE
// Separate StatefulWidget so the decoded image is cached and never re-decoded
// when the parent ValueListenableBuilder rebuilds on qty changes.
// AutomaticKeepAliveClientMixin keeps state alive when scrolled off screen.
// ─────────────────────────────────────────────────────────────────────────────
class _ProductImageTile extends StatefulWidget {
  final String? image;
  final Color color;
  final IconData icon;

  const _ProductImageTile({
    super.key,
    required this.image,
    required this.color,
    required this.icon,
  });

  @override
  State<_ProductImageTile> createState() => _ProductImageTileState();
}

class _ProductImageTileState extends State<_ProductImageTile>
    with AutomaticKeepAliveClientMixin {
  // ── ROOT CAUSE FIX ───────────────────────────────────────────────────────
  // ProductImage.build() called _decode() every time, returning a NEW
  // Uint8List object on every parent rebuild (cart notifier fires on + press).
  // Image.memory() creates MemoryImage(bytes) which uses reference equality.
  // New Uint8List object ≠ same reference → Flutter treated it as a different
  // image provider → re-decoded and repainted → visible flicker on + press.
  //
  // FIX: Decode bytes ONCE in initState, cache as field.
  // Every rebuild passes the SAME Uint8List reference → MemoryImage equality
  // check passes → Flutter skips re-render → zero flicker.
  // ─────────────────────────────────────────────────────────────────────────
  Uint8List? _cachedBytes;

  @override
  void initState() {
    super.initState();
    _decodeAndCache(widget.image); // Decode once on first build
  }

  @override
  void didUpdateWidget(_ProductImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only re-decode if the image string actually changed (e.g. product sync)
    if (oldWidget.image != widget.image) {
      _decodeAndCache(widget.image);
    }
  }

  void _decodeAndCache(String? raw) {
    if (raw == null || raw.isEmpty) {
      _cachedBytes = null;
      return;
    }
    try {
      // Strip data-URI prefix if present: "data:image/png;base64,<data>"
      final b64 = raw.contains(',') ? raw.split(',').last : raw;
      _cachedBytes = base64Decode(b64);
    } catch (_) {
      _cachedBytes = null;
    }
  }

  @override
  bool get wantKeepAlive => true; // Keep state alive when scrolled off screen

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required by AutomaticKeepAliveClientMixin
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: _cachedBytes != null
            ? Image.memory(
                _cachedBytes!, // Same reference every rebuild → no flicker
                fit: BoxFit.contain, // cover: fills the card area consistently
                gaplessPlayback: true,
              )
            : Container(
                color: widget.color,
                alignment: Alignment.center,
                child: Icon(widget.icon, color: Colors.white70, size: 40),
              ),
      ),
    );
  }
}
