import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:odocart/services/app_config.dart';

import '../helpers/test_helpers.dart';

String _unsignedJwtWithExp(DateTime expiry) {
  final header = base64UrlEncode(utf8.encode(jsonEncode(<String, dynamic>{
    'alg': 'none',
    'typ': 'JWT',
  })));
  final payload = base64UrlEncode(utf8.encode(jsonEncode(<String, dynamic>{
    'exp': expiry.millisecondsSinceEpoch ~/ 1000,
  })));
  return '$header.$payload.';
}

void main() {
  setUp(TestSecureStorage.install);

  test('saves and trims server URL', () async {
    await AppConfig.saveServerUrl('  https://odoo.example.com  ');

    expect(await AppConfig.getServerUrl(), 'https://odoo.example.com');
  });

  test('saves and reads POS session id/name from SharedPreferences', () async {
    await AppConfig.savePosSessionId(55);
    await AppConfig.savePosSessionName('  Main Session  ');

    expect(await AppConfig.getPosSessionId(), 55);
    expect(await AppConfig.getPosSessionName(), 'Main Session');
  });

  test('isJwtExpired returns false for future token and true for expired token', () {
    final futureToken = _unsignedJwtWithExp(
      DateTime.now().add(const Duration(hours: 1)),
    );
    final expiredToken = _unsignedJwtWithExp(
      DateTime.now().subtract(const Duration(hours: 1)),
    );

    expect(AppConfig.isJwtExpired(futureToken), isFalse);
    expect(AppConfig.isJwtExpired(expiredToken), isTrue);
    expect(AppConfig.isJwtExpired('bad-token'), isTrue);
  });
}
