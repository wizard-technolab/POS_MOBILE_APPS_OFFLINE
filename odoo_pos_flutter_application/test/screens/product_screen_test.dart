import 'package:flutter_test/flutter_test.dart';
import 'package:odocart/screens/product_screen.dart';

void main() {
  test('ProductModel parses API JSON with taxes and optional product ids', () {
    final product = ProductModel.fromJson(<String, dynamic>{
      'id': 99,
      'name': 'Burger',
      'price': 250,
      'category': 'Food',
      'active': true,
      'tax_id': <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'name': 'GST', 'amount': 18},
      ],
      'optional_product_ids': <int>[11, 12],
      'public_description': 'Freshly prepared',
    });

    expect(product.id, 99);
    expect(product.name, 'Burger');
    expect(product.price, 250);
    expect(product.taxIds.single['amount'], 18);
    expect(product.optionalProductIds, <int>[11, 12]);
    expect(product.publicDescription, 'Freshly prepared');
  });

  test('ProductScreen can be constructed', () {
    expect(const ProductScreen(), isA<ProductScreen>());
  });
}
