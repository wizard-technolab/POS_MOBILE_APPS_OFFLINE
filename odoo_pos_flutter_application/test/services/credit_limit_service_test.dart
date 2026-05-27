import 'package:flutter_test/flutter_test.dart';
import 'package:odocart/services/credit_limit_service.dart';

void main() {
  group('CreditLimitService.evaluate', () {
    const baseInfo = CustomerCreditInfo(
      customerId: 10,
      customerName: 'Demo Customer',
      credit: 400,
      creditLimit: 1000,
      creditOnHold: false,
      availableCredit: 600,
    );

    test('returns ok when no credit info is available', () {
      expect(CreditLimitService.evaluate(null, 500), CreditStatus.ok);
    });

    test('returns blocked when customer account is on hold', () {
      const blockedInfo = CustomerCreditInfo(
        customerId: 10,
        customerName: 'Blocked Customer',
        credit: 0,
        creditLimit: 1000,
        creditOnHold: true,
        availableCredit: 1000,
      );

      expect(CreditLimitService.evaluate(blockedInfo, 100),
          CreditStatus.blocked);
    });

    test('returns warning when order total exceeds available credit', () {
      expect(CreditLimitService.evaluate(baseInfo, 700), CreditStatus.warning);
    });

    test('returns ok when order total is within available credit', () {
      expect(CreditLimitService.evaluate(baseInfo, 500), CreditStatus.ok);
    });
  });

  test('buildWarningMessage includes remaining credit and customer name', () {
    const info = CustomerCreditInfo(
      customerId: 10,
      customerName: 'Demo Customer',
      credit: 400,
      creditLimit: 1000,
      creditOnHold: false,
      availableCredit: 600,
    );

    final message = CreditLimitService.buildWarningMessage(info, '₹');

    expect(message, contains('Demo Customer'));
    expect(message, contains('₹600.00'));
    expect(message, contains('₹1000.00'));
  });
}
