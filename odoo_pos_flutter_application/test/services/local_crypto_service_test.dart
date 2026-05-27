import 'package:flutter_test/flutter_test.dart';
import 'package:odocart/services/local_crypto_service.dart';

import '../helpers/test_helpers.dart';

void main() {
  setUp(TestSecureStorage.install);

  test('hashPassword verifies correct password and rejects wrong password', () {
    final result = LocalCryptoService.hashPassword('secret-password');

    expect(result['salt'], isNotEmpty);
    expect(result['hash'], isNotEmpty);
    expect(result['iterations'], isNotEmpty);

    expect(
      LocalCryptoService.verifyPassword(
        password: 'secret-password',
        salt: result['salt']!,
        hash: result['hash']!,
        iterations: int.parse(result['iterations']!),
      ),
      isTrue,
    );

    expect(
      LocalCryptoService.verifyPassword(
        password: 'wrong-password',
        salt: result['salt']!,
        hash: result['hash']!,
        iterations: int.parse(result['iterations']!),
      ),
      isFalse,
    );
  });

  test('encryptString/decryptString round trip works and detects tampering', () async {
    final encrypted = await LocalCryptoService.encryptString('cash drawer pin');

    expect(LocalCryptoService.isEncrypted(encrypted), isTrue);
    expect(encrypted, isNot('cash drawer pin'));
    expect(await LocalCryptoService.decryptString(encrypted), 'cash drawer pin');

    final tampered = encrypted.replaceRange(encrypted.length - 2, encrypted.length, 'xx');
    expect(await LocalCryptoService.decryptString(tampered), '');
  });

  test('decryptString returns empty for plain text', () async {
    expect(await LocalCryptoService.decryptString('plain text'), '');
  });
}
