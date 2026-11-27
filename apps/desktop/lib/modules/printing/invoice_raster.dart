part of 'receipt.dart';

// رسم الفاتورة بمحرك Flutter نفسه (تشكيل عربي كامل وخط المنشأة) ثم وضعها صورةً في صفحات PDF.
// مكتبة PDF لا تقرأ خطوط OTF/CFF ولا تشكّل العربية إلا بخطوط محددة، فالرسم النقطي هو الطريق لخط أنيق وسليم.

const _cInk = Color(0xFF10242B), _cMuted = Color(0xFF4E6066), _cOrange = Color(0xFFFF5A26), _cLine = Color(0xFFD5DDDF), _cBg = Color(0xFFF1F4F4);

class _RasterPage {
  final Uint8List png;
  final double widthPt, heightPt;
  const _RasterPage(this.png, this.widthPt, this.heightPt);
}

class _Pen {
  final ui.Canvas c;
  final bool mono; // الحراري: أسود فقط
  _Pen(this.c, {this.mono = false});

  static final _arabic = RegExp(r'[؀-ۿ]');

  /// يرسم نصًا داخل عرض محدد ويعيد ارتفاعه. الاتجاه يُختار من المحتوى: ما فيه عربية يُرسم RTL، والأرقام والرموز LTR.
  double text(String s, double x, double y, double w,
      {double size = 10, int weight = 400, Color color = _cInk, TextAlign align = TextAlign.right, bool draw = true}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(fontFamily: _Raster.family, fontSize: size, fontWeight: FontWeight.values[(weight ~/ 100) - 1], color: mono ? const Color(0xFF000000) : color, height: 1.4)),
      textDirection: _arabic.hasMatch(s) ? TextDirection.rtl : TextDirection.ltr,
      textAlign: align,
    )..layout(minWidth: w, maxWidth: w);
    if (draw) tp.paint(c, Offset(x, y));
    final h = tp.height;
    tp.dispose();
    return h;
  }

  void line(double x, double y, double w, {double thickness = 0.8, Color color = _cLine}) =>
      c.drawRect(Rect.fromLTWH(x, y, w, thickness), Paint()..color = mono ? const Color(0xFF000000) : color);
}

class _Raster {
  static const family = 'LamsatInvoice';
  static const _key = 'lamsat-invoice-font-pack';
  static bool _ready = false;
  static ui.Image? _logo, _logoMono;

  static Future<ByteData> _unpack(String asset) async {
    final data = await rootBundle.load(asset);
    final raw = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final key = _key.codeUnits;
    final out = Uint8List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      out[i] = raw[i] ^ key[i % key.length];
    }
    return ByteData.view(out.buffer);
  }

  static Future<ui.Image> _image(String asset) async {
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    return (await codec.getNextFrame()).image;
  }

  static Future<void> _prepare() async {
    if (!_ready) {
      final loader = FontLoader(family);
      for (final f in const ['inv_a', 'inv_b', 'inv_c']) {
        loader.addFont(_unpack('assets/fonts/$f.bin'));
      }
      await loader.load();
      _ready = true;
    }
    _logo ??= await _image('assets/brand/lamsat-logo.png');
    _logoMono ??= await _image('assets/brand/lamsat-logo-mono.png');
  }

  static Future<Uint8List> _png(ui.Picture picture, int w, int h) async {
    final img = await picture.toImage(w, h);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return bytes!.buffer.asUint8List();
  }

  static Future<List<_RasterPage>> render(Map<String, dynamic> inv, {required PrinterKind kind, required bool reprint}) async {
    await _prepare();
    return kind == PrinterKind.a4 ? _renderA4(inv, reprint) : [await _renderThermal(inv, reprint)];
  }

  // ───────── بيانات مشتركة ─────────
  static List<String> _warrantyLines(Map w, Map? customer, Map? vehicle) => [
        '${w['product_name']}',
        'رقم الضمان: ${w['warranty_no']}',
        'المدة: ${w['months']} شهرًا — من ${w['starts_on']} إلى ${w['expires_on']}',
        if (customer != null) 'العميل: ${customer['name']}${vehicle != null ? ' — اللوحة: ${vehicle['plate']}' : ''}',
        'يُشترط إبراز هذه البطاقة أو رقم الفاتورة عند المطالبة بالضمان.',
      ];

  // ───────── فاتورة A4 ─────────
  static const _a4W = 595.0, _a4H = 842.0, _m = 36.0, _scale = 2.5;

  /// يرسم المحتوى كاملًا على لوحة غير محدودة الارتفاع ويعيد ارتفاعه ومواضع القطع الآمنة بين الصفحات.
  static (double, List<double>) _paintA4(ui.Canvas canvas, Map<String, dynamic> inv, bool reprint) {
    final p = _Pen(canvas);
    const cw = _a4W - 2 * _m;
    int n(String k) => (inv[k] as num).toInt();
    final branch = (inv['branch'] as Map).cast<String, dynamic>();
    final org = (inv['organization'] as Map).cast<String, dynamic>();
    final lines = (inv['lines'] as List).cast<Map>();
    final payments = ((inv['payments'] as List?) ?? const []).cast<Map>();
    final warranties = ((inv['warranties'] as List?) ?? const []).cast<Map>();
    final customer = inv['customer'] as Map?;
    final vehicle = inv['vehicle'] as Map?;
    final breaks = <double>[];
    var y = _m;

    // الترويسة: بيانات المنشأة يمينًا والشعار يسارًا
    final logo = _logo!;
    const lw = 128.0;
    final lh = lw * logo.height / logo.width;
    canvas.drawImageRect(logo, Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()), Rect.fromLTWH(_m, y + 2, lw, lh), Paint()..filterQuality = FilterQuality.high);
    const hx = _m + lw + 20, hw = cw - lw - 20;
    var hy = y;
    hy += p.text('${branch['receipt_header_ar'] ?? org['name_ar']}', hx, hy, hw, size: 19, weight: 700);
    hy += p.text('${branch['name_ar']}', hx, hy, hw, size: 11.5, weight: 500);
    if (branch['phone'] != null) hy += p.text('هاتف: ${branch['phone']}', hx, hy, hw, size: 10, color: _cMuted);
    if (org['tax_registration_no'] != null) hy += p.text('الرقم الضريبي: ${org['tax_registration_no']}', hx, hy, hw, size: 10, color: _cMuted);
    y = (hy > y + lh + 6 ? hy : y + lh + 6) + 10;
    canvas.drawRect(Rect.fromLTWH(_m, y, cw, 2.4), Paint()..color = _cOrange);
    y += 16;

    y += p.text(n('tax_baisa') > 0 ? 'فاتورة ضريبية' : 'فاتورة', _m, y, cw, size: 21, weight: 700) + 2;
    if (inv['status'] == 'voided') y += p.text('فاتورة ملغاة', _m, y, cw, size: 12, weight: 700, color: const Color(0xFFB3261E));
    if (reprint) y += p.text('نسخة معادة الطباعة', _m, y, cw, size: 9.5, color: _cMuted);
    y += 8;

    // بيانات الفاتورة (يمين) والعميل (يسار)
    const half = cw / 2, labelW = 78.0;
    double kv(String k, String v, double x, double yy) {
      p.text(k, x + half - labelW, yy, labelW, size: 9.5, color: _cMuted);
      return p.text(v, x + 8, yy, half - labelW - 16, size: 10.5, weight: 500);
    }

    var ry = y, ly = y;
    ry += kv('رقم الفاتورة', '${inv['invoice_no']}', _m + half, ry) + 3;
    ry += kv('التاريخ', ReceiptPrinter._when(inv), _m + half, ry) + 3;
    ry += kv('الكاشير', '${inv['cashier_name'] ?? ''}', _m + half, ry) + 3;
    if (customer != null) {
      ly += kv('العميل', '${customer['name']}', _m, ly) + 3;
      if (customer['phone'] != null) ly += kv('الهاتف', '${customer['phone']}', _m, ly) + 3;
    }
    if (vehicle != null) ly += kv('اللوحة', '${vehicle['plate']}', _m, ly) + 3;
    y = (ry > ly ? ry : ly) + 12;

    // جدول البنود: الأعمدة من اليمين إلى اليسار
    const cols = <(String, double, TextAlign)>[
      ('#', 24, TextAlign.center), ('الوصف', 195, TextAlign.right), ('الكمية', 62, TextAlign.center), ('السعر', 62, TextAlign.center),
      ('الخصم', 56, TextAlign.center), ('الضريبة', 56, TextAlign.center), ('الإجمالي', 68, TextAlign.center),
    ];
    void row(List<String> cells, double yy, {int weight = 400, double size = 10, Color color = _cInk}) {
      var xr = _m + cw;
      for (var i = 0; i < cols.length; i++) {
        final (_, w, align) = cols[i];
        p.text(cells[i], xr - w + 4, yy, w - 8, size: size, weight: weight, color: color, align: align);
        xr -= w;
      }
    }

    canvas.drawRect(Rect.fromLTWH(_m, y, cw, 26), Paint()..color = _cBg);
    row([for (final c in cols) c.$1], y + 6, weight: 700, size: 9.5);
    y += 26;
    for (final l in lines) {
      final descH = p.text('${l['description_ar']}', 0, 0, 195 - 8, size: 10, draw: false);
      final disc = (l['discount_baisa'] as num).toInt();
      row([
        '${l['line_no']}', '${l['description_ar']}', '${l['qty']} ${l['unit'] ?? ''}'.trim(), formatOmr((l['unit_price_baisa'] as num).toInt()),
        disc > 0 ? formatOmr(disc) : '—', formatOmr((l['tax_baisa'] as num).toInt()), formatOmr((l['total_baisa'] as num).toInt()),
      ], y + 7);
      y += descH + 14;
      p.line(_m, y, cw);
      breaks.add(y);
    }
    y += 14;

    // المدفوعات (يمين) والإجماليات (يسار)
    var py = y, ty = y;
    py += p.text('المدفوعات', _m + half, py, half, size: 11, weight: 700) + 4;
    for (final pay in payments) {
      p.text(formatOmr((pay['amount_baisa'] as num).toInt()), _m + half, py, 90, size: 10.5, align: TextAlign.left);
      py += p.text(ReceiptPrinter._payLabel(pay), _m + half + 90, py, half - 90, size: 10.5, color: _cMuted) + 3;
    }
    if (n('change_baisa') > 0) {
      p.text(formatOmr(n('change_baisa')), _m + half, py, 90, size: 10.5, align: TextAlign.left);
      py += p.text('الباقي للعميل', _m + half + 90, py, half - 90, size: 10.5, color: _cMuted) + 3;
    }
    const tw = half - 30;
    double total(String k, String v, {bool big = false}) {
      p.text(v, _m, ty, 110, size: big ? 17 : 10.5, weight: big ? 700 : 500, align: TextAlign.left);
      return p.text(k, _m + 110, ty, tw - 110, size: big ? 13 : 10, weight: big ? 700 : 400, color: big ? _cInk : _cMuted) + (big ? 0 : 4);
    }

    ty += total('إجمالي البنود', formatOmr(n('subtotal_baisa')));
    if (n('discount_baisa') > 0) ty += total('الخصم', formatOmr(n('discount_baisa')));
    ty += total('الصافي قبل الضريبة', formatOmr(n('net_baisa')));
    if (n('tax_baisa') > 0) {
      ty += total('ضريبة القيمة المضافة ${formatQty((inv['tax_rate_bp'] as num).toInt() * 10)}%${inv['prices_include_tax'] == true ? ' (ضمن السعر)' : ''}', formatOmr(n('tax_baisa')));
    }
    ty += 4;
    p.line(_m, ty, tw, thickness: 1.2, color: _cInk);
    ty += 8;
    ty += total('الإجمالي (ر.ع)', formatOmr(n('total_baisa')), big: true);
    y = (py > ty ? py : ty) + 18;
    breaks.add(y);

    if (branch['receipt_footer_ar'] != null) {
      y += p.text('${branch['receipt_footer_ar']}', _m, y, cw, size: 10, color: _cMuted, align: TextAlign.center) + 12;
      breaks.add(y);
    }

    // بطاقات الضمان
    for (final w in warranties) {
      final rows = _warrantyLines(w, customer, vehicle);
      var h = 14.0 + p.text('بطاقة ضمان', 0, 0, cw - 28, size: 13, weight: 700, draw: false) + 4;
      for (var i = 0; i < rows.length; i++) {
        h += p.text(rows[i], 0, 0, cw - 28, size: i == 0 ? 11.5 : 10, draw: false) + 2;
      }
      h += 12;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(_m, y, cw, h), const Radius.circular(8)), Paint()..color = _cBg);
      canvas.drawRect(Rect.fromLTWH(_m + cw - 4, y + 10, 4, h - 20), Paint()..color = _cOrange);
      var wy = y + 12;
      wy += p.text('بطاقة ضمان', _m + 14, wy, cw - 28, size: 13, weight: 700) + 4;
      for (var i = 0; i < rows.length; i++) {
        wy += p.text(rows[i], _m + 14, wy, cw - 28, size: i == 0 ? 11.5 : 10, weight: i == 0 ? 500 : 400, color: i == rows.length - 1 ? _cMuted : _cInk) + 2;
      }
      y += h + 12;
      breaks.add(y);
    }
    return (y + _m - 12, breaks);
  }

  static Future<List<_RasterPage>> _renderA4(Map<String, dynamic> inv, bool reprint) async {
    final rec = ui.PictureRecorder();
    final (height, breaks) = _paintA4(ui.Canvas(rec), inv, reprint);
    final content = rec.endRecording();

    // تقسيم الصفحات عند حدود الصفوف والبطاقات
    final starts = <double>[0];
    if (height > _a4H) {
      const top = 28.0;
      var start = 0.0;
      while (height - start > _a4H - (start == 0 ? 0 : top)) {
        final limit = start + _a4H - _m - (start == 0 ? 0 : top);
        final candidates = breaks.where((b) => b > start + 60 && b <= limit).toList();
        final next = candidates.isEmpty ? limit : candidates.last;
        starts.add(next);
        start = next;
      }
    }
    final pages = <_RasterPage>[];
    for (var i = 0; i < starts.length; i++) {
      final start = starts[i];
      final end = i + 1 < starts.length ? starts[i + 1] : height;
      final offset = i == 0 ? 0.0 : 28.0;
      final r = ui.PictureRecorder();
      final c = ui.Canvas(r);
      c.scale(_scale);
      c.drawRect(const Rect.fromLTWH(0, 0, _a4W, _a4H), Paint()..color = const Color(0xFFFFFFFF));
      c.save();
      c.clipRect(Rect.fromLTWH(0, offset, _a4W, end - start));
      c.translate(0, offset - start);
      c.drawPicture(content);
      c.restore();
      if (starts.length > 1) {
        _Pen(c).text('صفحة ${i + 1} من ${starts.length}', _m, _a4H - 26, _a4W - 2 * _m, size: 8.5, color: _cMuted, align: TextAlign.center);
      }
      pages.add(_RasterPage(await _png(r.endRecording(), (_a4W * _scale).round(), (_a4H * _scale).round()), _a4W, _a4H));
    }
    content.dispose();
    return pages;
  }

  // ───────── إيصال حراري 80 مم (عرض الطباعة 72 مم = 576 نقطة) ─────────
  static const _tw = 576.0;

  static Future<_RasterPage> _renderThermal(Map<String, dynamic> inv, bool reprint) async {
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    final p = _Pen(canvas, mono: true);
    int n(String k) => (inv[k] as num).toInt();
    final branch = (inv['branch'] as Map).cast<String, dynamic>();
    final org = (inv['organization'] as Map).cast<String, dynamic>();
    final lines = (inv['lines'] as List).cast<Map>();
    final payments = ((inv['payments'] as List?) ?? const []).cast<Map>();
    final warranties = ((inv['warranties'] as List?) ?? const []).cast<Map>();
    final customer = inv['customer'] as Map?;
    final vehicle = inv['vehicle'] as Map?;
    var y = 8.0;

    double center(String s, {double size = 22, int weight = 400}) => p.text(s, 0, y, _tw, size: size, weight: weight, align: TextAlign.center);
    double kv(String k, String v, {double size = 22, int weight = 400}) {
      p.text(v, 0, y, _tw * .55, size: size, weight: weight, align: TextAlign.left);
      return p.text(k, _tw * .55, y, _tw * .45, size: size, weight: weight);
    }

    void rule() {
      y += 8;
      p.line(0, y, _tw, thickness: 2);
      y += 10;
    }

    final logo = _logoMono!;
    const lw = 300.0;
    final lh = lw * logo.height / logo.width;
    canvas.drawImageRect(logo, Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()), Rect.fromLTWH((_tw - lw) / 2, y, lw, lh), Paint()..filterQuality = FilterQuality.high);
    y += lh + 10;
    y += center('${branch['receipt_header_ar'] ?? branch['name_ar']}', size: 28, weight: 700);
    y += center('${branch['name_ar']}');
    if (branch['phone'] != null) y += center('هاتف: ${branch['phone']}', size: 20);
    if (org['tax_registration_no'] != null) y += center('الرقم الضريبي: ${org['tax_registration_no']}', size: 20);
    rule();
    y += kv('رقم الفاتورة', '${inv['invoice_no']}', size: 25, weight: 700);
    y += kv('التاريخ', ReceiptPrinter._when(inv));
    y += kv('الكاشير', '${inv['cashier_name'] ?? ''}');
    if (customer != null) y += kv('العميل', '${customer['name']}');
    if (vehicle != null) y += kv('اللوحة', '${vehicle['plate']}');
    if (inv['status'] == 'voided') y += center('— فاتورة ملغاة —', size: 25, weight: 700);
    if (reprint) y += center('— نسخة معادة الطباعة —', size: 20);
    rule();
    for (final l in lines) {
      final disc = (l['discount_baisa'] as num).toInt();
      y += p.text('${l['description_ar']}', 0, y, _tw, size: 23, weight: 500);
      p.text(formatOmr((l['total_baisa'] as num).toInt()), 0, y, _tw * .35, size: 22, weight: 500, align: TextAlign.left);
      y += p.text('${l['qty']} × ${formatOmr((l['unit_price_baisa'] as num).toInt())}${disc > 0 ? '   خصم ${formatOmr(disc)}' : ''}', _tw * .35, y, _tw * .65, size: 21) + 6;
    }
    rule();
    if (n('discount_baisa') > 0) y += kv('الخصم', formatOmr(n('discount_baisa')));
    y += kv('الصافي قبل الضريبة', formatOmr(n('net_baisa')));
    if (n('tax_baisa') > 0) y += kv('ضريبة القيمة المضافة ${formatQty((inv['tax_rate_bp'] as num).toInt() * 10)}%', formatOmr(n('tax_baisa')));
    y += 6;
    y += kv('الإجمالي (ر.ع)', formatOmr(n('total_baisa')), size: 34, weight: 700) + 6;
    for (final pay in payments) {
      y += kv(ReceiptPrinter._payLabel(pay), formatOmr((pay['amount_baisa'] as num).toInt()));
    }
    if (n('change_baisa') > 0) y += kv('الباقي', formatOmr(n('change_baisa')));
    if (branch['receipt_footer_ar'] != null) {
      rule();
      y += center('${branch['receipt_footer_ar']}', size: 20);
    }
    for (final w in warranties) {
      rule();
      y += center('بطاقة ضمان', size: 26, weight: 700) + 4;
      final rows = _warrantyLines(w, customer, vehicle);
      for (var i = 0; i < rows.length; i++) {
        y += p.text(rows[i], 0, y, _tw, size: i == 0 ? 23 : 20, weight: i == 0 ? 500 : 400) + 2;
      }
    }
    y += 24;

    final content = rec.endRecording();
    final r = ui.PictureRecorder();
    final c = ui.Canvas(r);
    c.drawRect(Rect.fromLTWH(0, 0, _tw, y), Paint()..color = const Color(0xFFFFFFFF));
    c.drawPicture(content);
    final png = await _png(r.endRecording(), _tw.round(), y.ceil());
    content.dispose();
    const widthPt = 72 * PdfPageFormat.mm;
    return _RasterPage(png, widthPt, widthPt * y / _tw);
  }
}
