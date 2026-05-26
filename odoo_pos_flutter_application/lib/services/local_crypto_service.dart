import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

import 'secure_storage_service.dart';

/// Field-level encryption/helper functions for sensitive SQLite values.
///
/// Uses per-installation key material stored in platform secure storage.
/// SQLite only stores encrypted configuration values and a salted PBKDF2
/// password hash for offline login validation.
class LocalCryptoService {
  static const String _keyName = 'local_data_key_material_v2';
  static const String _prefix = 'enc:v2:';
  static const int _passwordIterations = 60000;
  static const int _passwordHashLength = 32;

  static bool isEncrypted(String? value) {
    return value != null && value.startsWith(_prefix);
  }

  static Future<String> encryptString(String value) async {
    if (value.isEmpty || isEncrypted(value)) return value;

    final material = await _getOrCreateKeyMaterial();
    final aesKey = encrypt.Key(Uint8List.fromList(material.sublist(0, 32)));
    final macKey = material.sublist(32, 64);
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(
        aesKey,
        mode: encrypt.AESMode.cbc,
        padding: 'PKCS7',
      ),
    );

    final encrypted = encrypter.encrypt(value, iv: iv);
    final ivBytes = Uint8List.fromList(iv.bytes);
    final cipherBytes = Uint8List.fromList(encrypted.bytes);
    final macBytes = _hmacBytes(macKey, _joinBytes([ivBytes, cipherBytes]));

    return '$_prefix${base64UrlEncode(ivBytes)}:'
        '${base64UrlEncode(cipherBytes)}:'
        '${base64UrlEncode(macBytes)}';
  }

  static Future<String> decryptString(String value) async {
    if (value.isEmpty) return '';
    if (!isEncrypted(value)) return '';

    try {
      final body = value.substring(_prefix.length);
      final parts = body.split(':');
      if (parts.length != 3) return '';

      final ivBytes = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(parts[0])),
      );
      final cipherBytes = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final storedMac = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(parts[2])),
      );

      final material = await _getOrCreateKeyMaterial();
      final aesKey = encrypt.Key(Uint8List.fromList(material.sublist(0, 32)));
      final macKey = material.sublist(32, 64);
      final expectedMac =
          _hmacBytes(macKey, _joinBytes([ivBytes, cipherBytes]));

      if (!_constantTimeEquals(storedMac, expectedMac)) return '';

      final encrypter = encrypt.Encrypter(
        encrypt.AES(
          aesKey,
          mode: encrypt.AESMode.cbc,
          padding: 'PKCS7',
        ),
      );

      return encrypter.decrypt(
        encrypt.Encrypted(cipherBytes),
        iv: encrypt.IV(ivBytes),
      );
    } catch (_) {
      return '';
    }
  }

  static Map<String, String> hashPassword(String password) {
    final salt = _randomBytes(16);
    final hash = _pbkdf2(
      utf8.encode(password),
      salt,
      _passwordIterations,
      _passwordHashLength,
    );

    return {
      'salt': base64UrlEncode(salt),
      'hash': base64UrlEncode(hash),
      'iterations': _passwordIterations.toString(),
    };
  }

  static bool verifyPassword({
    required String password,
    required String salt,
    required String hash,
    int iterations = _passwordIterations,
  }) {
    try {
      final saltBytes = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(salt)),
      );
      final expectedHash = Uint8List.fromList(
        base64Url.decode(base64Url.normalize(hash)),
      );
      final actualHash = _pbkdf2(
        utf8.encode(password),
        saltBytes,
        iterations,
        expectedHash.length,
      );
      return _constantTimeEquals(actualHash, expectedHash);
    } catch (_) {
      return false;
    }
  }

  static Future<List<int>> _getOrCreateKeyMaterial() async {
    final existing = await SecureStorageService.read(_keyName);
    if (existing != null && existing.isNotEmpty) {
      final bytes = base64Url.decode(base64Url.normalize(existing));
      if (bytes.length == 64) return bytes;
    }

    final keyBytes = _randomBytes(64);
    await SecureStorageService.write(_keyName, base64UrlEncode(keyBytes));
    return keyBytes;
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static Uint8List _pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int keyLength,
  ) {
    final hmac = Hmac(sha256, password);
    final blocksNeeded =
        (keyLength / hmac.convert(<int>[]).bytes.length).ceil();
    final derived = <int>[];

    for (var block = 1; block <= blocksNeeded; block++) {
      final blockSalt = <int>[
        ...salt,
        (block >> 24) & 0xff,
        (block >> 16) & 0xff,
        (block >> 8) & 0xff,
        block & 0xff,
      ];

      var u = hmac.convert(blockSalt).bytes;
      final t = List<int>.from(u);

      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }

      derived.addAll(t);
    }

    return Uint8List.fromList(derived.take(keyLength).toList());
  }

  static Uint8List _hmacBytes(List<int> key, List<int> data) {
    return Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);
  }

  static Uint8List _joinBytes(List<Uint8List> chunks) {
    final length = chunks.fold<int>(0, (sum, item) => sum + item.length);
    final result = Uint8List(length);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}
