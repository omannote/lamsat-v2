import 'package:flutter_test/flutter_test.dart';
import 'package:lamsat_pos/core/money.dart';
import 'package:lamsat_pos/modules/pos/cart.dart';
import 'package:lamsat_pos/modules/printing/receipt.dart';

Product _p(String id, int price, {String kind = 'item', bool taxable = true}) => Product(
    id: id, sku: id, kind: kind, nameAr: id, unit: 'حبة', wholeUnitsOnly: true, trackStock: kind == 'item',
    taxable: taxable, exactBarcode: false, unitPriceBaisa: price);

void main() {
  const inclusive = TaxSettings(enabled: true, rateBp: 500, pricesIncludeTax: true);
  const exclusive = TaxSettings(enabled: true, rateBp: 500, pricesIncludeTax: false);
  const none = TaxSettings(enabled: false, rateBp: 500, pricesIncludeTax: true);

  test('العملة من الإعدادات: الخانات، فاصل الآلاف، موضع الرمز', () {
    Currency.apply({
      'currency': {'code': 'OMR', 'symbol': 'OMR', 'decimals': 2, 'thousands_separator': true, 'symbol_before': true},
    });
    expect(formatOmr(1250505), '1,250.51');
    expect(money(5000), 'OMR 5.00');
    expect(parseOmr('1,250.5'), 1250500);
    expect(parseOmr('1.255'), isNull); // أدق من الخانات المضبوطة
    expect(parseMilli('1.255'), 1255); // الكميات والنسب تبقى بثلاث خانات
    Currency.apply({
      'currency': {'symbol': 'ر.ع', 'decimals': 0},
    });
    expect(formatOmr(12500), '13');
    Currency.apply({});
    expect(formatOmr(1250505), '1250.505');
    expect(money(5000), '5.000 ر.ع');
  });

  test('المبالغ: تنسيق وتحليل بالبيسة', () {
    expect(formatOmr(116000), '116.000');
    expect(formatOmr(5), '0.005');
    expect(parseOmr('12.5'), 12500);
    expect(parseOmr('12'), 12000);
    expect(parseOmr('١٢٫٥٠٠'), 12500);
    expect(parseOmr('12.5555'), isNull);
    expect(parseOmr('abc'), isNull);
    expect(roundDiv(15525, 10), 1553); // 1552.5 → 1553
    expect(roundDiv(15524, 10), 1552);
  });

  // القيم نفسها التي يتحقق منها اختبار الخادم tests/scenarios/phase1_sale.test.mjs
  test('أربعة إطارات مع تركيب — ضريبة ضمن السعر', () {
    final c = Cart();
    c.add(_p('tire', 28000));
    c.lines[0].qtyMilli = 4000;
    c.add(_p('install', 1000, kind: 'service'));
    c.lines[1].qtyMilli = 4000;
    expect(c.lines[0].tax(inclusive), 5333);
    expect(c.lines[1].tax(inclusive), 190);
    expect(c.tax(inclusive), 5523);
    expect(c.total(inclusive), 116000);
  });

  test('ضريبة مضافة مع خصم — مطابقة للخادم', () {
    final c = Cart();
    c.add(_p('tire', 34500));
    c.lines[0].discountBaisa = 3450;
    c.add(_p('install', 1000, kind: 'service'));
    c.lines[1].qtyMilli = 3000;
    expect(c.lines[0].tax(exclusive), 1553);
    expect(c.total(exclusive), 35753);
    expect(c.total(none), 34050);
  });

  test('إضافة الصنف نفسه تزيد الكمية', () {
    final c = Cart();
    c.add(_p('a', 1000));
    expect(c.add(_p('a', 1000)), 0);
    expect(c.lines.single.qtyMilli, 2000);
  });

  test('توزيع الدفع المختلط والباقي', () {
    var (s, e) = PaymentSplit.compute(total: 35500, cardBaisa: 20000, tenderedBaisa: 20000);
    expect(e, isNull);
    expect([s!.cash, s.card, s.change], [15500, 20000, 4500]);
    (s, e) = PaymentSplit.compute(total: 35500, cardBaisa: 0, tenderedBaisa: 30000);
    expect(s, isNull);
    (s, e) = PaymentSplit.compute(total: 35500, cardBaisa: 35500, tenderedBaisa: null);
    expect([s!.cash, s.card, s.change], [0, 35500, 0]);
    (s, e) = PaymentSplit.compute(total: 35500, cardBaisa: 40000, tenderedBaisa: null);
    expect(s, isNull);
    // تحويل + آجل + نقدي
    (s, e) = PaymentSplit.compute(total: 35500, cardBaisa: 0, transferBaisa: 10000, creditBaisa: 20000, tenderedBaisa: 6000);
    expect([s!.cash, s.transfer, s.credit, s.change], [5500, 10000, 20000, 500]);
    (s, e) = PaymentSplit.compute(total: 35500, cardBaisa: 20000, transferBaisa: 10000, creditBaisa: 10000, tenderedBaisa: null);
    expect(s, isNull);
  });

  test('المسودة تُحفظ وتُستعاد بالكميات والخصم والعميل', () {
    final c = Cart()..add(_p('tire', 28000));
    c.lines[0].qtyMilli = 4000;
    c.lines[0].discountBaisa = 2000;
    c.customer = const CustomerRef(id: 'c1', name: 'سالم', plate: '777');
    final d = Cart()..loadDraft(c.toDraft());
    expect(d.lines.single.qtyMilli, 4000);
    expect(d.lines.single.discountBaisa, 2000);
    expect(d.total(inclusive), c.total(inclusive));
    expect(d.customer!.plate, '777');
  });

  test('رقم واتساب: 8 خانات عُمانية تُسبق بـ 968، وغير الصالح يُرفض', () {
    expect(ReceiptPrinter.whatsappPhone('9123 4567'), '96891234567');
    expect(ReceiptPrinter.whatsappPhone('+968 91234567'), '96891234567');
    expect(ReceiptPrinter.whatsappPhone('0096891234567'), '96891234567');
    expect(ReceiptPrinter.whatsappPhone('123'), isNull);
    expect(ReceiptPrinter.whatsappPhone(null), isNull);
  });

  test('الحمولة ثابتة عند إعادة الإرسال', () {
    final c = Cart()..add(_p('a', 1000));
    final p = c.toPayload(cashSessionId: 's', tax: inclusive, cashBaisa: 1000, cardBaisa: 0, cashTenderedBaisa: 5000);
    expect(p['expected_total_baisa'], 1000);
    expect(p['cash_tendered_baisa'], 5000);
    expect((p['lines'] as List).single['qty'], 1);
    expect((p['payments'] as List).single, {'method': 'cash', 'amount_baisa': 1000});
  });
}
