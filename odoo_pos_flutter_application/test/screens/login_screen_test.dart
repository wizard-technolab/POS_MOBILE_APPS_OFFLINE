import 'package:flutter_test/flutter_test.dart';
import 'package:odocart/screens/login_screen.dart';

void main() {
  test('LoginScreen can be constructed', () {
    expect(const LoginScreen(), isA<LoginScreen>());
  });

  test('production login should require HTTPS server URL - add UI validation here', () {
    // TODO: After you add HTTPS-only validation in LoginScreen, convert this
    // into a widget test that enters http://example.com and expects an error.
    expect(Uri.parse('https://odoo.example.com').isScheme('https'), isTrue);
    expect(Uri.parse('http://odoo.example.com').isScheme('https'), isFalse);
  });
}
