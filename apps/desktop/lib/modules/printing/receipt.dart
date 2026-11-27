import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/money.dart';

part 'invoice_raster.dart';

class PrintFailure implements Exception {
  final String message;
  PrintFailure(this.message);
}

/// نوع الطابعة المختارة من الإعدادات: يحدد شكل الفاتورة المطبوعة والمحفوظة PDF.
enum PrinterKind {
  thermal80('thermal80', 'طابعة حرارية للإيصالات (80 مم)'),
  a4('a4', 'طابعة عادية للفواتير (A4)');

  final String code, label;
  const PrinterKind(this.code, this.label);
  static PrinterKind fromCode(String? c) => values.firstWhere((k) => k.code == c, orElse: () => thermal80);
}

class ReceiptPrinter {
  static const _prefName = 'receipt_printer_name';
  static const _prefKind = 'receipt_printer_kind';
  static pw.Font? _regular, _bold;
  static pw.MemoryImage? _logo, _logoColor;

  static Future<String?> savedPrinterName() async => (await SharedPreferences.getInstance()).getString(_prefName);

  static Future<void> savePrinterName(String? name) async {
    final p = await SharedPreferences.getInstance();
    name == null ? await p.remove(_prefName) : await p.setString(_prefName, name);
  }

  static Future<PrinterKind> savedKind() async => PrinterKind.fromCode((await SharedPreferences.getInstance()).getString(_prefKind));

  static Future<void> saveKind(PrinterKind kind) async => (await SharedPreferences.getInstance()).setString(_prefKind, kind.code);

  static Future<List<Printer>> listPrinters() => Printing.listPrinters();

  static Future<void> _loadAssets() async {
    _regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
    _logo ??= pw.MemoryImage((await rootBundle.load('assets/brand/lamsat-logo-mono.png')).buffer.asUint8List());
    _logoColor ??= pw.MemoryImage((await rootBundle.load('assets/brand/lamsat-logo.png')).buffer.asUint8List());
  }

  static const _roll80 = PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 4 * PdfPageFormat.mm);

  static PdfPageFormat _format(PrinterKind kind) => kind == PrinterKind.a4 ? PdfPageFormat.a4 : _roll80;

  static String _when(Map<String, dynamic> inv) {
    final t = DateTime.parse(inv['approved_at'] as String).toUtc().add(const Duration(hours: 4)); // توقيت مسقط
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  static String _payLabel(Map p) {
    final ref = p['card_reference'] != null ? ' (${p['card_reference']})' : '';
    return switch (p['method']) {
      'cash' => 'نقدي',
      'deposit' => 'عربون مسدَّد',
      'transfer' => 'تحويل بنكي$ref',
      'credit' => 'آجل على الحساب',
      _ => 'بطاقة$ref',
    };
  }

  /// يبني PDF الفاتورة من تمثيلها كما أعاده الخادم (approve_sale / get_invoice) بالشكل المناسب لنوع الطابعة.
  /// الفاتورة تُرسم بخط المنشأة عبر محرك Flutter وتوضع صورةً في PDF؛ إن تعذّر ذلك يُستخدم التخطيط الاحتياطي بخط DejaVu.
  static Future<Uint8List> buildPdf(Map<String, dynamic> inv, {required PrinterKind kind, bool reprint = false}) async {
    try {
      final pages = await _Raster.render(inv, kind: kind, reprint: reprint);
      final doc = pw.Document(title: inv['invoice_no'] as String);
      for (final p in pages) {
        final image = pw.MemoryImage(p.png);
        doc.addPage(pw.Page(
          pageFormat: kind == PrinterKind.a4
              ? PdfPageFormat(p.widthPt, p.heightPt, marginAll: 0)
              : PdfPageFormat(80 * PdfPageFormat.mm, p.heightPt + 8 * PdfPageFormat.mm, marginAll: 4 * PdfPageFormat.mm),
          build: (_) => pw.Image(image, fit: pw.BoxFit.fill),
        ));
      }
      return await doc.save();
    } catch (_) {
      return _buildPdfVector(inv, kind: kind, reprint: reprint);
    }
  }

  static Future<Uint8List> _buildPdfVector(Map<String, dynamic> inv, {required PrinterKind kind, bool reprint = false}) async {
    await _loadAssets();
    final doc = pw.Document(title: inv['invoice_no'] as String);
    final theme = pw.ThemeData.withFont(base: _regular!, bold: _bold!);
    if (kind == PrinterKind.a4) {
      doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 36, marginRight: 36, marginTop: 36, marginBottom: 36),
        textDirection: pw.TextDirection.rtl,
        theme: theme,
        build: (_) => _a4(inv, reprint),
      ));
    } else {
      doc.addPage(pw.Page(pageFormat: _roll80, textDirection: pw.TextDirection.rtl, theme: theme, build: (_) => _thermal(inv, reprint)));
    }
    return doc.save();
  }

  // ───────── إيصال حراري 80 مم ─────────
  static pw.Widget _thermal(Map<String, dynamic> inv, bool reprint) {
    int n(String k) => (inv[k] as num).toInt();
    final branch = (inv['branch'] as Map).cast<String, dynamic>();
    final org = (inv['organization'] as Map).cast<String, dynamic>();
    final lines = (inv['lines'] as List).cast<Map>();
    final payments = ((inv['payments'] as List?) ?? const []).cast<Map>();
    final customer = inv['customer'] as Map?;
    final vehicle = inv['vehicle'] as Map?;
    const small = pw.TextStyle(fontSize: 8);
    final strong = pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold);
    pw.Widget row(String label, String value, {pw.TextStyle? style}) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [pw.Text(label, style: style ?? small), pw.Text(value, style: style ?? small, textDirection: pw.TextDirection.ltr)],
        );
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      pw.Center(child: pw.Image(_logo!, width: 42 * PdfPageFormat.mm)),
      pw.SizedBox(height: 4),
      pw.Center(child: pw.Text((branch['receipt_header_ar'] ?? branch['name_ar']) as String, style: strong)),
      if (branch['phone'] != null) pw.Center(child: pw.Text('هاتف: ${branch['phone']}', style: small)),
      if (org['tax_registration_no'] != null) pw.Center(child: pw.Text('الرقم الضريبي: ${org['tax_registration_no']}', style: small)),
      pw.Divider(thickness: .6),
      row('رقم الفاتورة', inv['invoice_no'] as String, style: strong),
      row('التاريخ', _when(inv)),
      row('الكاشير', (inv['cashier_name'] ?? '') as String),
      if (customer != null) row('العميل', '${customer['name']}'),
      if (vehicle != null) row('اللوحة', '${vehicle['plate']}'),
      if (inv['status'] == 'voided') pw.Center(child: pw.Text('— فاتورة ملغاة —', style: strong)),
      if (reprint) pw.Center(child: pw.Text('— نسخة معادة الطباعة —', style: small)),
      pw.Divider(thickness: .6),
      for (final l in lines) ...[
        pw.Text('${l['description_ar']}', style: const pw.TextStyle(fontSize: 9)),
        row(
            '${l['qty']} × ${formatOmr((l['unit_price_baisa'] as num).toInt())}'
            '${(l['discount_baisa'] as num) > 0 ? '  خصم ${formatOmr((l['discount_baisa'] as num).toInt())}' : ''}',
            formatOmr((l['total_baisa'] as num).toInt())),
        pw.SizedBox(height: 2),
      ],
      pw.Divider(thickness: .6),
      if (n('discount_baisa') > 0) row('الخصم', formatOmr(n('discount_baisa'))),
      row('الصافي قبل الضريبة', formatOmr(n('net_baisa'))),
      if (n('tax_baisa') > 0) row('ضريبة القيمة المضافة ${formatQty((inv['tax_rate_bp'] as num).toInt() * 10)}%', formatOmr(n('tax_baisa'))),
      pw.SizedBox(height: 2),
      row('الإجمالي (ر.ع)', formatOmr(n('total_baisa')), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 2),
      for (final p in payments) row(_payLabel(p), formatOmr((p['amount_baisa'] as num).toInt())),
      if (n('change_baisa') > 0) row('الباقي', formatOmr(n('change_baisa'))),
      pw.Divider(thickness: .6),
      if (branch['receipt_footer_ar'] != null) pw.Center(child: pw.Text(branch['receipt_footer_ar'] as String, style: small)),
      ..._warrantyCards(inv, 8),
      pw.SizedBox(height: 8),
    ]);
  }

  // ───────── فاتورة A4 ─────────
  static List<pw.Widget> _a4(Map<String, dynamic> inv, bool reprint) {
    int n(String k) => (inv[k] as num).toInt();
    final branch = (inv['branch'] as Map).cast<String, dynamic>();
    final org = (inv['organization'] as Map).cast<String, dynamic>();
    final lines = (inv['lines'] as List).cast<Map>();
    final payments = ((inv['payments'] as List?) ?? const []).cast<Map>();
    final customer = inv['customer'] as Map?;
    final vehicle = inv['vehicle'] as Map?;
    const ink = PdfColor.fromInt(0xFF10242B);
    const muted = PdfColor.fromInt(0xFF62727A);
    const line = PdfColor.fromInt(0xFFDFE5E8);
    const normal = pw.TextStyle(fontSize: 10, color: ink);
    final bold = pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: ink);
    const label = pw.TextStyle(fontSize: 9, color: muted);

    pw.Widget kv(String k, String v, {bool ltr = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Row(children: [
            pw.SizedBox(width: 78, child: pw.Text(k, style: label)),
            pw.Expanded(child: pw.Text(v, style: normal, textDirection: ltr ? pw.TextDirection.ltr : pw.TextDirection.rtl, textAlign: pw.TextAlign.right)),
          ]),
        );

    // الجدول يُبنى باتجاه LTR صريح حتى يكون ترتيب الأعمدة ثابتًا: الإجمالي يسارًا والوصف يمينًا.
    pw.Widget cell(String t, {bool head = false, bool num = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          child: pw.Text(t,
              style: head ? pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: ink) : normal,
              textDirection: num ? pw.TextDirection.ltr : pw.TextDirection.rtl,
              textAlign: num ? pw.TextAlign.left : pw.TextAlign.right),
        );
    final table = pw.Directionality(
      textDirection: pw.TextDirection.ltr,
      child: pw.Table(
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: line, width: .6), bottom: pw.BorderSide(color: line, width: .6)),
        columnWidths: const {
          0: pw.FixedColumnWidth(70), 1: pw.FixedColumnWidth(56), 2: pw.FixedColumnWidth(56), 3: pw.FixedColumnWidth(62),
          4: pw.FixedColumnWidth(52), 5: pw.FlexColumnWidth(), 6: pw.FixedColumnWidth(24),
        },
        children: [
          pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F5F6)), children: [
            cell('الإجمالي', head: true, num: true), cell('الضريبة', head: true, num: true), cell('الخصم', head: true, num: true),
            cell('السعر', head: true, num: true), cell('الكمية', head: true), cell('الوصف', head: true), cell('#', head: true),
          ]),
          for (final l in lines)
            pw.TableRow(children: [
              cell(formatOmr((l['total_baisa'] as num).toInt()), num: true),
              cell(formatOmr((l['tax_baisa'] as num).toInt()), num: true),
              cell((l['discount_baisa'] as num) > 0 ? formatOmr((l['discount_baisa'] as num).toInt()) : '—', num: true),
              cell(formatOmr((l['unit_price_baisa'] as num).toInt()), num: true),
              cell('${l['qty']} ${l['unit']}'),
              cell('${l['description_ar']}'),
              cell('${l['line_no']}'),
            ]),
        ],
      ),
    );

    pw.Widget total(String k, String v, {bool big = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text(k, style: big ? pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: ink) : label),
            pw.Text(v, textDirection: pw.TextDirection.ltr, style: big ? pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: ink) : normal),
          ]),
        );

    final taxed = org['tax_registration_no'] != null && n('tax_baisa') > 0;
    return [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('${org['name_ar']}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: ink)),
            pw.Text('${branch['name_ar']}', style: normal),
            if (branch['address_ar'] != null) pw.Text('${branch['address_ar']}', style: label),
            if (branch['phone'] != null) pw.Text('هاتف: ${branch['phone']}', style: label),
            if (org['tax_registration_no'] != null) pw.Text('الرقم الضريبي: ${org['tax_registration_no']}', style: label),
          ]),
        ),
        pw.Image(_logoColor!, width: 130),
      ]),
      pw.SizedBox(height: 14),
      pw.Container(height: 2, color: const PdfColor.fromInt(0xFFFF5A26)),
      pw.SizedBox(height: 12),
      pw.Text(taxed ? 'فاتورة ضريبية' : 'فاتورة', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: ink)),
      if (inv['status'] == 'voided') pw.Text('ملغاة', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFFB42318))),
      if (reprint) pw.Text('نسخة معادة الطباعة', style: label),
      pw.SizedBox(height: 8),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(children: [
            kv('رقم الفاتورة', inv['invoice_no'] as String, ltr: true),
            kv('التاريخ', _when(inv), ltr: true),
            kv('الكاشير', (inv['cashier_name'] ?? '') as String),
          ]),
        ),
        pw.SizedBox(width: 24),
        pw.Expanded(
          child: pw.Column(children: [
            kv('العميل', customer != null ? '${customer['name']}' : '—'),
            if (customer?['phone'] != null) kv('الهاتف', '${customer!['phone']}', ltr: true),
            if (vehicle != null) kv('المركبة', [vehicle['plate'], vehicle['make'], vehicle['model']].where((e) => e != null).join(' · ')),
          ]),
        ),
      ]),
      pw.SizedBox(height: 12),
      table,
      pw.SizedBox(height: 12),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('المدفوعات', style: bold),
            for (final p in payments) total(_payLabel(p), formatOmr((p['amount_baisa'] as num).toInt())),
            if (n('change_baisa') > 0) total('الباقي للعميل', formatOmr(n('change_baisa'))),
            if (inv['note'] != null) pw.Padding(padding: const pw.EdgeInsets.only(top: 6), child: pw.Text('ملاحظة: ${inv['note']}', style: label)),
          ]),
        ),
        pw.SizedBox(width: 36),
        pw.Expanded(
          child: pw.Column(children: [
            total('إجمالي البنود', formatOmr(n('subtotal_baisa'))),
            if (n('discount_baisa') > 0) total('الخصم', formatOmr(n('discount_baisa'))),
            total('الصافي قبل الضريبة', formatOmr(n('net_baisa'))),
            if (n('tax_baisa') > 0)
              total('ضريبة القيمة المضافة ${formatQty((inv['tax_rate_bp'] as num).toInt() * 10)}%${inv['prices_include_tax'] == true ? ' (ضمن السعر)' : ''}', formatOmr(n('tax_baisa'))),
            pw.Divider(color: line, thickness: .8),
            total('الإجمالي (ر.ع)', formatOmr(n('total_baisa')), big: true),
          ]),
        ),
      ]),
      pw.SizedBox(height: 24),
      if (branch['receipt_footer_ar'] != null) pw.Center(child: pw.Text('${branch['receipt_footer_ar']}', style: label)),
      ..._warrantyCards(inv, 10),
    ];
  }

  /// بطاقة ضمان لكل بند له ضمان (مثل العازل): رقم الضمان، الصنف، المدة، تاريخ الانتهاء، العميل واللوحة.
  static List<pw.Widget> _warrantyCards(Map<String, dynamic> inv, double size) {
    final list = ((inv['warranties'] as List?) ?? const []).cast<Map>();
    if (list.isEmpty) return const [];
    final customer = inv['customer'] as Map?;
    final vehicle = inv['vehicle'] as Map?;
    final t = pw.TextStyle(fontSize: size);
    final b = pw.TextStyle(fontSize: size + 1, fontWeight: pw.FontWeight.bold);
    pw.Widget row(String k, String v) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.Text(k, style: t), pw.Text(v, style: t, textDirection: pw.TextDirection.ltr)]);
    return [
      for (final w in list)
        pw.Container(
          margin: const pw.EdgeInsets.only(top: 10),
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(border: pw.Border.all(width: .8)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
            pw.Center(child: pw.Text('بطاقة ضمان', style: b)),
            pw.SizedBox(height: 3),
            pw.Text('${w['product_name']}', style: t),
            row('رقم الضمان', '${w['warranty_no']}'),
            row('المدة', '${w['months']} شهرًا'),
            row('من', '${w['starts_on']}'),
            row('ينتهي في', '${w['expires_on']}'),
            if (customer != null) row('العميل', '${customer['name']}'),
            if (vehicle != null) row('اللوحة', '${vehicle['plate']}'),
            pw.SizedBox(height: 2),
            pw.Text('يُشترط إبراز هذه البطاقة أو رقم الفاتورة عند المطالبة بالضمان.', style: pw.TextStyle(fontSize: size - 1)),
          ]),
        ),
    ];
  }

  /// تقرير جدولي A4 (كشف حساب، تقرير إقفال، تقرير ضريبة) يُكتب في مجلد مؤقت للعرض والطباعة من عارض PDF. يعيد المسار.
  static Future<String> tempReport(String fileName, String title, List<String> header, List<List<String>> rows,
      {List<String> intro = const [], List<(String, String)> summary = const []}) async {
    await _loadAssets();
    final doc = pw.Document(title: title);
    final cell = pw.TextStyle(fontSize: 9);
    final head = pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 36, marginRight: 36, marginTop: 36, marginBottom: 36),
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: _regular!, bold: _bold!),
      build: (_) => [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(title, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Image(_logoColor!, width: 34 * PdfPageFormat.mm),
        ]),
        pw.SizedBox(height: 6),
        for (final l in intro) pw.Text(l, style: const pw.TextStyle(fontSize: 10)),
        pw.SizedBox(height: 10),
        if (rows.isNotEmpty)
          pw.Table(
            border: pw.TableBorder.all(width: .4, color: PdfColors.grey600),
            children: [
              pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                  children: [for (final h in header) pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(h, style: head))]),
              for (final r in rows) pw.TableRow(children: [for (final c in r) pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(c, style: cell))]),
            ],
          ),
        pw.SizedBox(height: 12),
        for (final (k, v) in summary)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2),
            child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text(k, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
              pw.Text(v, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold), textDirection: pw.TextDirection.ltr),
            ]),
          ),
      ],
    ));
    return _writeTemp('$fileName.pdf', await doc.save());
  }

  /// ملف CSV يفتحه Excel (بترميز UTF-8 مع BOM حتى تظهر العربية). يعيد المسار.
  static Future<String> tempCsv(String fileName, List<String> header, List<List<String>> rows) {
    String esc(String v) => '"${v.replaceAll('"', '""')}"';
    final text = [header, ...rows].map((r) => r.map(esc).join(',')).join('\r\n');
    return _writeTemp('$fileName.csv', Uint8List.fromList([0xEF, 0xBB, 0xBF, ...const Utf8Encoder().convert(text)]));
  }

  static Future<String> _writeTemp(String name, Uint8List bytes) async {
    final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}Lamsat');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${name.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_')}');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// يكتب الفاتورة PDF في مجلد مؤقت (للعرض أو السحب إلى واتساب) بالشكل المناسب لنوع الطابعة، ويعيد المسار.
  /// لا تُحفظ نسخة في النظام؛ الملف المؤقت يُستبدل عند كل عرض.
  /// يرفع فاتورة A4 بصيغة PDF إلى مخزن خاص ويعيد رابطًا موقّعًا صالحًا 30 يومًا يفتحه العميل من رسالة واتساب.
  static Future<String> uploadCustomerPdf(Map<String, dynamic> inv) async {
    final bytes = await buildPdf(inv, kind: PrinterKind.a4);
    final safe = (inv['invoice_no'] as String).replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final path = '${inv['id']}/$safe.pdf';
    final bucket = Api.client.storage.from('invoices');
    await bucket.uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'application/pdf', upsert: true)).timeout(const Duration(seconds: 25));
    return bucket.createSignedUrl(path, 30 * 24 * 3600).timeout(const Duration(seconds: 15));
  }

  static Future<String> tempPdf(Map<String, dynamic> inv, {PrinterKind? as}) async {
    final kind = as ?? await savedKind();
    final bytes = await buildPdf(inv, kind: kind, reprint: false);
    final dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}Lamsat');
    await dir.create(recursive: true);
    final safe = (inv['invoice_no'] as String).replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${dir.path}${Platform.pathSeparator}$safe.pdf');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// يفتح ملفًا أو رابطًا بالتطبيق الافتراضي في Windows (عارض PDF أو المتصفح).
  static Future<void> openFile(String path) => _shellOpen(path);
  /// يفتح رابطًا في المتصفح الافتراضي. الروابط الطويلة ذات الرموز (% و &) لا تمر سليمة عبر rundll32،
  /// فيُستخدم ShellExecute عبر url_launcher، ثم PowerShell كبديل.
  static Future<void> openUrl(String url) async {
    try {
      if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    if (Platform.isWindows) {
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', "Start-Process '${url.replaceAll("'", '%27')}'"]);
      if (r.exitCode != 0) throw PrintFailure('تعذّر فتح المتصفح.');
    } else {
      await _shellOpen(url);
    }
  }

  /// ينسخ الملف نفسه إلى الحافظة (لا نصّه) ليُلصق في محادثة واتساب ويب بـ Ctrl+V. يعيد false إن تعذّر.
  static Future<bool> copyFileToClipboard(String path) async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', "Set-Clipboard -LiteralPath '${path.replaceAll("'", "''")}'"]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
  static Future<void> _shellOpen(String target) async {
    if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', target]);
    } else {
      await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [target]);
    }
  }

  /// رقم واتساب دولي بالأرقام فقط. رقم عُماني من 8 خانات يُسبق بـ 968. يعيد null إذا كان غير صالح.
  static String? whatsappPhone(String? raw) {
    var d = (raw ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (d.startsWith('00')) d = d.substring(2);
    if (d.length == 8) d = '968$d';
    return (d.length >= 10 && d.length <= 15) ? d : null;
  }

  /// رابط محادثة واتساب ويب مع العميل برسالة جاهزة (بلا ربط API: يُفتح في حساب المحل المفتوح على هذا الجهاز).
  /// الرسالة تذكر بنود الضمان ومدتها إن وُجدت.
  static String whatsappUrl(Map<String, dynamic> inv, String phone, {String? pdfLink}) {
    final branch = (inv['branch'] as Map).cast<String, dynamic>();
    final customer = inv['customer'] as Map?;
    final text = [
      'مرحبًا${customer != null ? ' ${customer['name']}' : ''}،',
      'شكرًا لزيارتكم ${branch['receipt_header_ar'] ?? branch['name_ar']}.',
      'فاتورتكم رقم ${inv['invoice_no']} بتاريخ ${_when(inv)}',
      'الإجمالي: ${formatOmr((inv['total_baisa'] as num).toInt())} ر.ع',
      for (final w in ((inv['warranties'] as List?) ?? const []).cast<Map>())
        'ضمان ${w['product_name']}: ${w['months']} شهرًا حتى ${w['expires_on']} (رقم ${w['warranty_no']})',
      if (pdfLink != null) 'الفاتورة PDF (الرابط صالح 30 يومًا):\n$pdfLink',
      if (branch['phone'] != null) 'للاستفسار: ${branch['phone']}',
    ].join('\n');
    return 'https://web.whatsapp.com/send?phone=$phone&text=${Uri.encodeComponent(text)}';
  }

  /// يفتح مجلد الملف في مستكشف Windows مع تحديده.
  static Future<void> revealInExplorer(String path) async {
    if (!Platform.isWindows) return;
    try {
      await Process.start('explorer.exe', ['/select,', path]);
    } catch (_) {}
  }

  /// يطبع الفاتورة على الطابعة المختارة مباشرةً بالشكل المناسب لنوعها. يرمي [PrintFailure] برسالة تشغيلية عند الفشل؛
  /// الفاتورة تبقى معتمدة ويمكن إعادة طباعتها.
  static Future<void> printInvoice(Map<String, dynamic> inv, {bool reprint = false}) async {
    final kind = await savedKind();
    final Uint8List bytes;
    try {
      bytes = await buildPdf(inv, kind: kind, reprint: reprint);
    } catch (_) {
      throw PrintFailure('تعذّر تجهيز الفاتورة للطباعة.');
    }
    final name = await savedPrinterName();
    if (name == null) throw PrintFailure('لم تُحدَّد الطابعة. اخترها ونوعها من «إعداد الطابعة» (F12).');
    final List<Printer> printers;
    try {
      printers = await listPrinters();
    } catch (_) {
      throw PrintFailure('تعذّر قراءة طابعات Windows.');
    }
    final printer = printers.where((p) => p.name == name).firstOrNull;
    if (printer == null) throw PrintFailure('الطابعة «$name» غير موجودة. تأكد من توصيلها وتشغيلها أو اختر طابعة أخرى.');
    bool ok;
    try {
      ok = await Printing.directPrintPdf(printer: printer, onLayout: (_) async => bytes, name: inv['invoice_no'] as String, format: _format(kind));
    } catch (_) {
      ok = false;
    }
    if (!ok) throw PrintFailure('لم تستجب الطابعة «$name». تحقق من الورق والتوصيل ثم أعد الطباعة.');
    try {
      await Api.rpc('record_invoice_print', {'p_invoice_id': inv['id'], 'p_is_reprint': reprint}); // لا يوقف العمل إن فشل
    } catch (_) {}
  }

  /// صفحة اختبار قصيرة بالشكل المناسب لنوع الطابعة.
  static Future<void> printTest(Printer printer, PrinterKind kind) async {
    await _loadAssets();
    final doc = pw.Document()
      ..addPage(pw.Page(
        pageFormat: kind == PrinterKind.a4 ? PdfPageFormat.a4 : _roll80,
        textDirection: pw.TextDirection.rtl,
        theme: pw.ThemeData.withFont(base: _regular!, bold: _bold!),
        build: (_) => pw.Column(children: [
          pw.Image(kind == PrinterKind.a4 ? _logoColor! : _logo!, width: 42 * PdfPageFormat.mm),
          pw.SizedBox(height: 6),
          pw.Text('اختبار الطباعة — ${kind.label}', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.Text('0123456789  116.000 ر.ع', style: const pw.TextStyle(fontSize: 9)),
          pw.SizedBox(height: 8),
        ]),
      ));
    final bytes = await doc.save();
    final ok = await Printing.directPrintPdf(printer: printer, onLayout: (_) async => bytes, name: 'lamsat-test', format: _format(kind));
    if (!ok) throw PrintFailure('لم تستجب الطابعة «${printer.name}».');
  }
}
