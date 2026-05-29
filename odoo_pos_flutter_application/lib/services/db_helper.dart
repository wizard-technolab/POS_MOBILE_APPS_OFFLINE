// lib/services/db_helper.dart

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:convert';

import 'local_crypto_service.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() {
    return _instance;
  }

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    // FIX: safely add session_id column if it doesn't exist yet.
    await _ensureNameColumn(_database!);
    await _ensureSessionIdColumn(_database!);
    await _ensureOdooOrderIdColumn(_database!);
    await _ensureOrderLinesColumns(_database!);
    await _ensureCompanyNameColumn(_database!);
    return _database!;
  }

  // Adds name column to orders table if missing.
  Future<void> _ensureNameColumn(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE orders ADD COLUMN name TEXT DEFAULT ""',
      );
    } catch (_) {
      // Column already exists — ignore error
    }
  }

  // Adds session_id column to orders table if missing.
  Future<void> _ensureSessionIdColumn(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE orders ADD COLUMN session_id INTEGER DEFAULT 0',
      );
    } catch (_) {
      // Column already exists — ignore error
    }
  }

  // Adds company_name column to orders table if missing.
  Future<void> _ensureCompanyNameColumn(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE orders ADD COLUMN company_name TEXT DEFAULT ""',
      );
    } catch (_) {
      // Column already exists — ignore error
    }
  }

  // Adds odoo_order_id column to orders table if missing.
  Future<void> _ensureOdooOrderIdColumn(Database db) async {
    try {
      await db.execute(
        'ALTER TABLE orders ADD COLUMN odoo_order_id INTEGER DEFAULT 0',
      );
    } catch (_) {
      // Column already exists — ignore error
    }
  }

  // Adds missing columns to order_lines table if they don't exist yet.
  Future<void> _ensureOrderLinesColumns(Database db) async {
    final columns = [
      'product_name TEXT DEFAULT ""',
      'price_unit REAL DEFAULT 0.0',
      'variant_attributes TEXT DEFAULT ""',
      'price_subtotal REAL DEFAULT 0.0',
      'price_subtotal_incl REAL DEFAULT 0.0',
      'image TEXT DEFAULT ""',
      'tax_rate REAL DEFAULT 18.0',
      'session_id INTEGER DEFAULT 0',
      'is_combo INTEGER DEFAULT 0',
      'combo_parent_id INTEGER',
      'combo_name TEXT DEFAULT ""',
    ];

    for (final col in columns) {
      try {
        await db.execute('ALTER TABLE order_lines ADD COLUMN $col');
      } catch (_) {
        // Column already exists — ignore error
      }
    }
  }

  // ─────────────────────────────────────────────────────────
  // INITIALIZE DATABASE
  // ─────────────────────────────────────────────────────────
  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'pos_app.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  // ─────────────────────────────────────────────────────────
  // CREATE TABLES
  // ─────────────────────────────────────────────────────────
  Future<void> _onCreate(Database db, int version) async {
    // 🔥 NEW: Sessions table for offline caching
    await db.execute('''
      CREATE TABLE sessions (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        pos_config_id INTEGER,
        pos_config_name TEXT,
        state TEXT DEFAULT 'open',
        synced INTEGER DEFAULT 1,
        created_at INTEGER,
        updated_at INTEGER,
        currency_symbol TEXT DEFAULT '₹',
        currency_name TEXT DEFAULT 'INR'
      )
    ''');

    // Products table
    // Products table — updated
    await db.execute('''
      CREATE TABLE products (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        price REAL NOT NULL,
        category TEXT,
        active INTEGER DEFAULT 1,
        is_combo INTEGER DEFAULT 0,
        combo_groups TEXT,
        tax_id TEXT DEFAULT '[]',
        has_variants INTEGER DEFAULT 0,
        variants TEXT DEFAULT '[]',
        image TEXT,
        qty_available REAL DEFAULT 0.0,
        is_storable INTEGER DEFAULT 1,
        public_description TEXT DEFAULT '',
        optional_product_ids TEXT DEFAULT '[]',
        synced INTEGER DEFAULT 1,
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');

    // Cart items table
    await db.execute('''
      CREATE TABLE cart_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        price REAL NOT NULL,
        quantity INTEGER DEFAULT 1,
        note TEXT DEFAULT '',
        customer_note TEXT DEFAULT '',
        session_id INTEGER DEFAULT 0,
        tax_rate REAL DEFAULT 0.0,
        image TEXT,
        created_at INTEGER,
        FOREIGN KEY (product_id) REFERENCES products(id)
      )
    ''');

    // Offline orders table
    // FIX: added session_id column so sync status can be filtered per session
    await db.execute('''
      CREATE TABLE orders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT DEFAULT '',
        external_id TEXT UNIQUE,
        device_code TEXT,
        customer_id INTEGER,
        customer_name TEXT,
        customer_note TEXT DEFAULT '',
        pos_config_id INTEGER,
        company_name TEXT DEFAULT '',
        session_id INTEGER DEFAULT 0,
        odoo_order_id INTEGER DEFAULT 0,
        status TEXT DEFAULT 'draft',
        synced INTEGER DEFAULT 0,
        sync_attempts INTEGER DEFAULT 0,
        last_sync_attempt INTEGER,
        total REAL,
        tax_amount REAL,
        payment_method TEXT DEFAULT 'Cash',
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');

    // Order lines table
    await db.execute('''
      CREATE TABLE order_lines (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        order_id INTEGER NOT NULL,
        session_id INTEGER DEFAULT 0,
        product_id INTEGER NOT NULL,
        product_name TEXT DEFAULT '',
        quantity INTEGER DEFAULT 1,
        price REAL NOT NULL,
        price_unit REAL DEFAULT 0.0,
        discount REAL DEFAULT 0.0,
        tax_rate REAL DEFAULT 18.0,
        note TEXT DEFAULT '',
        customer_note TEXT DEFAULT '',
        is_combo INTEGER DEFAULT 0,
        combo_parent_id INTEGER,
        combo_name TEXT,
        created_at INTEGER,
        image TEXT,
        variant_attributes TEXT DEFAULT '',
        price_subtotal REAL DEFAULT 0.0,         -- line total excl. tax (qty × price)
        price_subtotal_incl REAL DEFAULT 0.0,    -- line total incl. tax (shown in detail sheet)
        FOREIGN KEY (order_id) REFERENCES orders(id)
      )
    ''');

// Customers table
    await db.execute('''
      CREATE TABLE customers (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        email TEXT,
        synced INTEGER DEFAULT 1,
        sync_attempts INTEGER DEFAULT 0,
        last_sync_attempt INTEGER,
        is_dirty INTEGER DEFAULT 0,
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');

    // Sync log table
    await db.execute('''
      CREATE TABLE sync_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT,
        entity_id INTEGER,
        action TEXT,
        status TEXT,
        error TEXT,
        created_at INTEGER
      )
    ''');

    // Cart customer table
    await db.execute('''
      CREATE TABLE cart_customer (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        customer_id INTEGER NOT NULL,
        customer_name TEXT NOT NULL,
        customer_phone TEXT,
        customer_email TEXT,
        created_at INTEGER
      )
    ''');

    // Login credentials table
    await _createLoginCredentialsTable(db);

    await db.execute('''
      CREATE TABLE combo_cart_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cart_key TEXT UNIQUE,
        combo_product_id INTEGER,
        combo_name TEXT,
        base_price REAL,
        selection TEXT,
        qty INTEGER DEFAULT 1,
        note TEXT DEFAULT '',
        customer_note TEXT DEFAULT '',
        tax_rate REAL DEFAULT 0.0,
        session_id INTEGER DEFAULT 0,
        created_at INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE session_products (
        session_id INTEGER NOT NULL,
        product_id INTEGER NOT NULL,
        updated_at INTEGER,
        PRIMARY KEY (session_id, product_id)
      )
    ''');

    // Pending cart items table — stores cart items for a session that is
    // currently not active. When user switches sessions, their cart items
    // are "parked" here instead of deleted. When they return to the same
    // session, items are restored from this table back into cart_items.
    // This allows multiple sessions to each have their own pending cart.
    await db.execute('''
      CREATE TABLE pending_cart_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        price REAL NOT NULL,
        quantity INTEGER DEFAULT 1,
        note TEXT DEFAULT '',
        customer_note TEXT DEFAULT '',
        session_id INTEGER NOT NULL,
        tax_rate REAL DEFAULT 0.0,
        image TEXT,
        created_at INTEGER
      )
    ''');

    // Pending combo cart items table — same concept as pending_cart_items
    // but for combo products. Parked here on session switch, restored on return.
    await db.execute('''
      CREATE TABLE pending_combo_cart_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cart_key TEXT NOT NULL,
        combo_product_id INTEGER NOT NULL,
        combo_name TEXT NOT NULL,
        base_price REAL DEFAULT 0.0,
        selection TEXT DEFAULT '{}',
        qty INTEGER DEFAULT 1,
        note TEXT DEFAULT '',
        customer_note TEXT DEFAULT '',
        session_id INTEGER NOT NULL,
        tax_rate REAL DEFAULT 0.0,
        created_at INTEGER
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Clean reset of local login credentials only. The app is not deployed yet,
      // so we intentionally do not migrate legacy plain-text rows.
      await db.execute('DROP TABLE IF EXISTS login_credentials');
      await _createLoginCredentialsTable(db);
    }
  }

  Future<void> _createLoginCredentialsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS login_credentials (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_url_enc TEXT NOT NULL,
        db_name_enc TEXT NOT NULL,
        username TEXT NOT NULL,
        password_salt TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        password_iterations INTEGER NOT NULL,
        uid INTEGER,
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');
  }

  // ─────────────────────────────────────────────────────────
  // 🔥 SESSION METHODS (NEW)
  // ─────────────────────────────────────────────────────────

  Future<void> saveOrUpdateSessions(List<Map<String, dynamic>> sessions) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      await txn.delete('sessions');

      for (final session in sessions) {
        await txn.insert(
          'sessions',
          {
            'id': session['id'],
            'name': session['name'],
            'pos_config_id': session['pos_config_id'],
            'pos_config_name': session['pos_config_name'],
            'state': session['state'] ?? 'open',
            'synced': 1,
            'created_at': now,
            'updated_at': now,
            'currency_symbol': session['currency_symbol'] ?? '₹',
            'currency_name': session['currency_name'] ?? 'INR',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });

    await batch.commit(noResult: true);
    debugPrint('✅ Saved ${sessions.length} sessions to local DB');
  }

  Future<List<Map<String, dynamic>>> getSessionsOffline() async {
    final db = await database;
    return await db.query('sessions');
  }

  Future<Map<String, dynamic>?> getSessionById(int sessionId) async {
    final db = await database;
    final result = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    return result.isNotEmpty ? result.first : null;
  }

  // ─────────────────────────────────────────────────────────
  // INSERT/UPDATE PRODUCTS (WITH INCREMENTAL UPDATE)
  // ─────────────────────────────────────────────────────────
  Future<void> insertOrUpdateProducts(List<Map<String, dynamic>> products,
      {int sessionId = 0}) async {
    final db = await database;
    final batch = db.batch();

    final now = DateTime.now().millisecondsSinceEpoch;

    if (sessionId > 0) {
      batch.delete('session_products',
          where: 'session_id = ?', whereArgs: [sessionId]);
    }

    for (final p in products) {
      String? comboGroupsJson;
      if (p['combo_groups'] != null) {
        if (p['combo_groups'] is String) {
          comboGroupsJson = p['combo_groups'];
        } else if (p['combo_groups'] is List) {
          comboGroupsJson = jsonEncode(p['combo_groups']);
        }
      }

      final isCombo = p['is_combo'] == true ||
          p['is_combo'] == 1 ||
          (comboGroupsJson != null && comboGroupsJson.isNotEmpty);

      final optionalProductsJson = jsonEncode(p['optional_product_ids'] ?? []);

      batch.insert(
        'products',
        {
          'id': p['id'],
          'name': p['name'],
          'price': p['price'],
          'category': p['category'] ?? 'Other',
          'active': (p['active'] == true || p['active'] == 1) ? 1 : 0,
          'is_combo': isCombo ? 1 : 0,
          'combo_groups': comboGroupsJson,
          'image': p['image'],
          'tax_id': p['tax_id'] is String
              ? p['tax_id']
              : jsonEncode(p['tax_id'] ?? []),
          'has_variants':
              (p['has_variants'] == true || p['has_variants'] == 1) ? 1 : 0,
          'variants': p['variants'] is String
              ? p['variants']
              : jsonEncode(p['variants'] ?? []),
          'public_description': p['public_description'] ?? '',
          'optional_product_ids': optionalProductsJson,
          'synced': 1,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      if (sessionId > 0) {
        batch.insert(
          'session_products',
          {
            'session_id': sessionId,
            'product_id': p['id'],
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }

    await batch.commit(noResult: true);
  }

  // 🔥 NEW: Incremental update (only update changed products)
  Future<void> incrementalUpdateProducts(
    List<Map<String, dynamic>> products, {
    int sessionId = 0,
  }) async {
    final db = await database;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final p in products) {
      // Check if product exists
      final existing = await db.query(
        'products',
        where: 'id = ?',
        whereArgs: [p['id']],
        limit: 1,
      );

      String? comboGroupsJson;
      if (p['combo_groups'] != null) {
        if (p['combo_groups'] is String) {
          comboGroupsJson = p['combo_groups'];
        } else if (p['combo_groups'] is List) {
          comboGroupsJson = jsonEncode(p['combo_groups']);
        }
      }

      final isCombo = p['is_combo'] == true ||
          p['is_combo'] == 1 ||
          (comboGroupsJson != null && comboGroupsJson.isNotEmpty);

      final qtyAvailableRaw = p['qty_available'];
      final qtyAvailable =
          qtyAvailableRaw != null ? (qtyAvailableRaw as num).toDouble() : 0.0;

      final storableRaw = p['is_storable'];
      final storable = storableRaw != false && storableRaw != 0;

      final optionalProductsJson = jsonEncode(p['optional_product_ids'] ?? []);

      final productData = {
        'id': p['id'],
        'name': p['name'],
        'price': p['price'],
        'category': p['category'] ?? 'Other',
        'active': (p['active'] == true || p['active'] == 1) ? 1 : 0,
        'is_combo': isCombo ? 1 : 0,
        'combo_groups': comboGroupsJson,
        'image': p['image'],
        'tax_id':
            p['tax_id'] is String ? p['tax_id'] : jsonEncode(p['tax_id'] ?? []),
        'has_variants':
            (p['has_variants'] == true || p['has_variants'] == 1) ? 1 : 0,
        'variants': p['variants'] is String
            ? p['variants']
            : jsonEncode(p['variants'] ?? []),
        'qty_available': qtyAvailable,
        'is_storable': storable ? 1 : 0,
        'public_description': p['public_description'] ?? '',
        'optional_product_ids': optionalProductsJson,
        'synced': 1,
        'updated_at': now,
      };

      if (existing.isEmpty) {
        // New product
        productData['created_at'] = now;
        batch.insert(
          'products',
          productData,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        // Update existing
        final old = existing.first;

        // Performance Fix: Only update if core data has changed.
        // Especially avoid updating the 'image' blob if the base64 string is identical.
        bool hasChanged = old['price'] != p['price'] ||
            old['name'] != p['name'] ||
            old['active'] != productData['active'] ||
            old['is_combo'] != productData['is_combo'] ||
            old['variants'] != productData['variants'];

        // Check image separately to avoid heavy string comparison if possible
        if (!hasChanged && productData['image'] != null) {
          if (old['image'] != productData['image']) {
            hasChanged = true;
          }
        }

        if (hasChanged) {
          batch.update(
            'products',
            productData,
            where: 'id = ?',
            whereArgs: [p['id']],
          );
        }
      }

      // Add to session mapping
      if (sessionId > 0) {
        batch.insert(
          'session_products',
          {
            'session_id': sessionId,
            'product_id': p['id'],
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }

    await batch.commit(noResult: true);
  }

  // ─────────────────────────────────────────────────────────
  // LOGIN CREDENTIAL METHODS
  // ─────────────────────────────────────────────────────────

  Future<void> saveLoginCredentials({
    required String serverUrl,
    required String dbName,
    required String username,
    required String password,
    required int uid,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final encryptedServerUrl =
        await LocalCryptoService.encryptString(serverUrl);
    final encryptedDbName = await LocalCryptoService.encryptString(dbName);
    final passwordInfo = LocalCryptoService.hashPassword(password);

    await db.delete('login_credentials');

    await db.insert(
      'login_credentials',
      {
        'server_url_enc': encryptedServerUrl,
        'db_name_enc': encryptedDbName,
        'username': username,
        'password_salt': passwordInfo['salt'],
        'password_hash': passwordInfo['hash'],
        'password_iterations': int.parse(passwordInfo['iterations']!),
        'uid': uid,
        'created_at': now,
        'updated_at': now,
      },
    );
  }

  Future<Map<String, dynamic>?> getSavedLoginCredentials() async {
    final db = await database;

    final result = await db.query(
      'login_credentials',
      limit: 1,
      orderBy: 'id DESC',
    );

    if (result.isEmpty) return null;

    final rawRow = result.first;
    return {
      'id': rawRow['id'],
      'server_url': await LocalCryptoService.decryptString(
        (rawRow['server_url_enc'] ?? '').toString(),
      ),
      'db_name': await LocalCryptoService.decryptString(
        (rawRow['db_name_enc'] ?? '').toString(),
      ),
      'username': rawRow['username'],
      'uid': rawRow['uid'],
      'created_at': rawRow['created_at'],
      'updated_at': rawRow['updated_at'],
    };
  }

  // ─────────────────────────────────────────────────────────
  // PRODUCTS (LOCAL CACHE)
  // ─────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getProducts() async {
    final db = await database;
    return await db.query('products');
  }

  Future<Map<String, dynamic>?> validateOfflineLogin({
    required String username,
    required String password,
  }) async {
    final db = await database;

    final result = await db.query(
      'login_credentials',
      where: 'username = ?',
      whereArgs: [username],
      limit: 5,
    );

    for (final rawRow in result) {
      final iterations = rawRow['password_iterations'] is int
          ? rawRow['password_iterations'] as int
          : int.tryParse((rawRow['password_iterations'] ?? '').toString()) ??
              60000;

      final isValid = LocalCryptoService.verifyPassword(
        password: password,
        salt: (rawRow['password_salt'] ?? '').toString(),
        hash: (rawRow['password_hash'] ?? '').toString(),
        iterations: iterations,
      );

      if (isValid) {
        return {
          'id': rawRow['id'],
          'server_url': await LocalCryptoService.decryptString(
            (rawRow['server_url_enc'] ?? '').toString(),
          ),
          'db_name': await LocalCryptoService.decryptString(
            (rawRow['db_name_enc'] ?? '').toString(),
          ),
          'username': rawRow['username'],
          // Return the typed password for existing login/session flow. It is
          // never read back from SQLite because SQLite stores only a hash.
          'password': password,
          'uid': rawRow['uid'],
          'created_at': rawRow['created_at'],
          'updated_at': rawRow['updated_at'],
        };
      }
    }

    return null;
  }

  Future<void> clearLoginCredentials() async {
    final db = await database;
    await db.delete('login_credentials');
  }

  Future<void> ensureSeedTables() async {
    final db = await database;

    await db.execute('''
      CREATE TABLE IF NOT EXISTS customers (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT,
        email TEXT,
        synced INTEGER DEFAULT 1,
        sync_attempts INTEGER DEFAULT 0,
        last_sync_attempt INTEGER,
        is_dirty INTEGER DEFAULT 0,
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');
  }

  // ─────────────────────────────────────────────────────────
  // RESET/CLEAR DATABASE
  // ─────────────────────────────────────────────────────────
  Future<void> clearDatabase() async {
    final db = await database;
    await db.delete('cart_items');
    await db.delete('combo_cart_items');
    await db.delete('pending_cart_items');
    await db.delete('pending_combo_cart_items');
    await db.delete('session_products');
    await db.delete('cart_customer');
    await db.delete('order_lines');
    await db.delete('orders');
    await db.delete('products');
    await db.delete('customers');
    await db.delete('sync_log');
    await db.delete('login_credentials');
    await db.delete('sessions');
  }

  Future<void> fixOldProductData() async {
    final db = await database;

    try {
      await db.rawUpdate('''
        UPDATE products 
        SET is_combo = 0 
        WHERE combo_groups IS NULL OR combo_groups = '' OR combo_groups = '[]'
      ''');

      debugPrint('✅ Fixed old product data');
    } catch (e) {
      debugPrint('⚠️ Error fixing product data: $e');
    }
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
