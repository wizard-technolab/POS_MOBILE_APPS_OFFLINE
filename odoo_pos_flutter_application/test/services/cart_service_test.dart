import 'package:flutter_test/flutter_test.dart';
import 'package:odocart/models/combo_model.dart';
import 'package:odocart/screens/product_screen.dart';
import 'package:odocart/services/cart_service.dart';

ProductModel _product({
  int id = 1,
  String name = 'Coffee',
  double price = 100,
  List<Map<String, dynamic>> taxIds = const <Map<String, dynamic>>[],
}) {
  return ProductModel(
    id: id,
    name: name,
    price: price,
    category: 'Drinks',
    active: true,
    taxIds: taxIds,
  );
}

void main() {
  group('CartItem', () {
    test('calculates line total and tax amount', () {
      const item = CartItem(
        productId: 1,
        name: 'Coffee',
        price: 100,
        qty: 2,
        taxRate: 18,
      );

      expect(item.lineTotal, 200);
      expect(item.lineTaxAmount, 36);
    });

    test('serializes and deserializes variant attributes', () {
      const item = CartItem(
        productId: 7,
        name: 'T-Shirt',
        price: 500,
        qty: 1,
        variantAttributes: <Map<String, String>>[
          <String, String>{'attribute': 'Color', 'value': 'Red'},
          <String, String>{'attribute': 'Size', 'value': 'M'},
        ],
      );

      final restored = CartItem.fromJson(item.toJson());

      expect(restored.productId, 7);
      expect(restored.variantAttributes, item.variantAttributes);
    });
  });

  group('CartService in-memory cart operations', () {
    late CartService cart;

    setUp(() {
      cart = CartService.instance;
      cart.cartNotifier.value = <int, CartItem>{};
      cart.comboCartNotifier.value = <String, ComboCartItem>{};
      cart.customerNotifier.value = null;
      cart.customerNoteNotifier.value = '';
      cart.clearEditingPendingState();
    });

    test('addItem adds a new product and increments quantity on repeat add',
        () {
      final product = _product(
        taxIds: <Map<String, dynamic>>[
          <String, dynamic>{'id': 1, 'name': 'GST', 'amount': 18},
        ],
      );

      cart.addItem(product);
      cart.addItem(product);

      expect(cart.getQty(product.id), 2);
      expect(cart.cart[product.id]!.taxRate, 18);
      expect(cart.subtotal, 200);
      expect(cart.taxAmount, 36);
      expect(cart.total, 236);
    });

    test('setItemQty removes item when quantity is zero', () {
      final product = _product();
      cart.addItem(product);

      cart.setItemQty(product.id, 0);

      expect(cart.cart.containsKey(product.id), isFalse);
      expect(cart.totalItemCount, 0);
    });

    test('updates kitchen note and customer note independently', () {
      final product = _product();
      cart.addItem(product);

      cart.updateItemNote(product.id, 'No sugar');
      cart.updateItemCustomerNote(product.id, 'Customer prefers hot');

      final item = cart.cart[product.id]!;
      expect(item.note, 'No sugar');
      expect(item.customerNote, 'Customer prefers hot');
    });
  });
}
