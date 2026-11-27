/// المبالغ أعداد صحيحة بجزء من الألف من وحدة العملة (في عُمان: البيسة). لا يُستخدم double في الحساب.
/// العملة ورمزها وعدد الخانات المعروضة تُضبط من إعدادات المنشأة وتُحمَّل عند الدخول.
class Currency {
  static String code = 'OMR';
  static String symbol = 'ر.ع';
  static int decimals = 3;
  static bool symbolBefore = false;
  static bool group = false;
  static String phoneCode = '968';
  /// نص رسالة واتساب المخصص من الإعدادات (null = النص الافتراضي).
  static String? whatsappMessage;

  static void apply(Map<String, dynamic> settings) {
    final c = ((settings['currency'] as Map?) ?? const {}).cast<String, dynamic>();
    code = '${c['code'] ?? 'OMR'}';
    symbol = '${c['symbol'] ?? 'ر.ع'}';
    decimals = ((c['decimals'] as num?)?.toInt() ?? 3).clamp(0, 3);
    symbolBefore = c['symbol_before'] == true;
    group = c['thousands_separator'] == true;
    phoneCode = '${settings['phone_country_code'] ?? '968'}';
    final w = '${settings['whatsapp_message_ar'] ?? ''}'.trim();
    whatsappMessage = w.isEmpty ? null : w;
  }
}

/// المبلغ بعدد الخانات المضبوط (تقريب النصف إلى أعلى) وبفاصل الآلاف إن فُعّل. بلا رمز العملة.
String formatOmr(int baisa) {
  final sign = baisa < 0 ? '-' : '';
  final unit = const [1000, 100, 10, 1][Currency.decimals];
  final scaled = (baisa.abs() * 2 + unit) ~/ (unit * 2);
  final pow = 1000 ~/ unit;
  var whole = '${scaled ~/ pow}';
  if (Currency.group) whole = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return Currency.decimals == 0 ? '$sign$whole' : '$sign$whole.${(scaled % pow).toString().padLeft(Currency.decimals, '0')}';
}

/// المبلغ مع رمز العملة في موضعه المضبوط.
String money(int baisa) => Currency.symbolBefore ? '${Currency.symbol} ${formatOmr(baisa)}' : '${formatOmr(baisa)} ${Currency.symbol}';

/// يحوّل مبلغًا مكتوبًا إلى جزء من الألف. يقبل خانات عشرية بقدر المضبوط في الإعدادات. يعيد null إذا كان النص غير صالح.
int? parseOmr(String input) {
  var s = input.trim();
  if (Currency.group) s = s.replaceAll(',', '');
  final v = parseMilli(s);
  if (v == null) return null;
  final unit = const [1000, 100, 10, 1][Currency.decimals];
  return v % unit == 0 ? v : null;
}

/// يحوّل رقمًا بثلاث خانات عشرية على الأكثر (كمية أو نسبة) مثل "12" أو "12.5" إلى جزء من الألف.
int? parseMilli(String input) {
  final s = _latinDigits(input.trim());
  final m = RegExp(r'^(\d{1,9})(?:[.,](\d{1,3}))?$').firstMatch(s);
  if (m == null) return null;
  return int.parse(m.group(1)!) * 1000 + int.parse((m.group(2) ?? '').padRight(3, '0'));
}

/// يحوّل كمية مثل "4" أو "1.5" إلى جزء من الألف. يعيد null إذا كان النص غير صالح أو صفرًا.
int? parseQtyMilli(String input) {
  final v = parseMilli(input);
  return (v == null || v <= 0) ? null : v;
}

String formatQty(int milli) =>
    milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

/// قسمة بتقريب النصف إلى أعلى للأعداد غير السالبة — مطابقة لقاعدة الخادم (round في PostgreSQL).
int roundDiv(int numerator, int denominator) => (numerator * 2 + denominator) ~/ (denominator * 2);

String _latinDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final i = ar.indexOf(ch);
    b.write(i >= 0 ? '$i' : (ch == '٫' ? '.' : ch));
  }
  return b.toString();
}
