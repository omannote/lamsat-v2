import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../printing/receipt.dart';
import 'cart.dart';

Future<void> showMessage(BuildContext context, String title, String body) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 440, child: Text(body, style: const TextStyle(fontSize: 17))),
        actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(c), child: const Text('حسنًا (Enter)'))],
      ),
    );

/// رسالة تشغيلية لخطأ اعتماد، مع تفاصيل المخزون إن وُجدت.
String describeError(BusinessError e) {
  if (e.code == 'INSUFFICIENT_STOCK' && (e.detail ?? '').isNotEmpty) {
    try {
      final d = jsonDecode(e.detail!) as Map<String, dynamic>;
      return 'الكمية غير متوفرة: ${d['name_ar']}\nالمطلوب ${d['requested']} والمتاح ${d['available']}. عدّل الكمية ثم أعد الدفع.';
    } catch (_) {}
  }
  return errorMessage(e.code);
}

enum CartChoice { keep, draft, discard }

/// F1 والسلة فيها بنود: إجراء صريح — حفظ كمسودة، أو تجاهل البنود، أو متابعة الفاتورة.
Future<CartChoice> confirmDiscardCart(BuildContext context) async =>
    await showDialog<CartChoice>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('فاتورة جديدة'),
        content: const SizedBox(width: 460, child: Text('السلة تحتوي على بنود. ماذا تريد أن تفعل بها؟', style: TextStyle(fontSize: 17))),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(c, CartChoice.discard), child: const Text('تجاهل البنود')),
          OutlinedButton(onPressed: () => Navigator.pop(c, CartChoice.draft), child: const Text('حفظ كمسودة')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(c, CartChoice.keep), child: const Text('متابعة الفاتورة')),
        ],
      ),
    ) ??
    CartChoice.keep;

/// F4: تعديل كمية السطر (والخصم إن كان مسموحًا).
class LineEditDialog extends StatefulWidget {
  final CartLine line;
  final int maxDiscountBp;
  final bool focusDiscount; // F5: يبدأ المؤشر في حقل الخصم
  const LineEditDialog({super.key, required this.line, required this.maxDiscountBp, this.focusDiscount = false});
  @override
  State<LineEditDialog> createState() => _LineEditState();
}

class _LineEditState extends State<LineEditDialog> {
  late final _qty = TextEditingController(text: formatQty(widget.line.qtyMilli));
  late final _disc = TextEditingController(text: formatOmr(widget.line.discountBaisa));
  final _discFocus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _qty.selection = TextSelection(baseOffset: 0, extentOffset: _qty.text.length);
    if (widget.focusDiscount && widget.maxDiscountBp > 0) {
      _disc.selection = TextSelection(baseOffset: 0, extentOffset: _disc.text.length);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _discFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _qty.dispose();
    _disc.dispose();
    _discFocus.dispose();
    super.dispose();
  }

  void _save() {
    final l = widget.line;
    final q = parseQtyMilli(_qty.text);
    if (q == null || (l.product.wholeUnitsOnly && q % 1000 != 0)) {
      setState(() => _error = l.product.wholeUnitsOnly ? 'هذا الصنف يباع بعدد صحيح.' : 'كمية غير صالحة.');
      return;
    }
    if (l.product.trackStock && q > (l.product.stockQty ?? 0) * 1000) {
      setState(() => _error = 'المتاح في المخزون ${l.product.stockQty ?? 0} ${l.product.unit} فقط.');
      return;
    }
    final d = widget.maxDiscountBp > 0 ? parseOmr(_disc.text.isEmpty ? '0' : _disc.text) : 0;
    final gross = roundDiv(q * l.unitPriceBaisa, 1000);
    if (d == null || d > gross) {
      setState(() => _error = 'قيمة الخصم غير صالحة.');
      return;
    }
    if (d * 10000 > gross * widget.maxDiscountBp) {
      setState(() => _error = 'الخصم يتجاوز حدّك (${formatQty(widget.maxDiscountBp * 10)}%).');
      return;
    }
    l.qtyMilli = q;
    l.discountBaisa = d;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.line.product.nameAr),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _qty,
              autofocus: true,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              decoration: InputDecoration(labelText: 'الكمية (${widget.line.product.unit})'),
              onSubmitted: (_) => widget.maxDiscountBp > 0 ? _discFocus.requestFocus() : _save(),
            ),
            if (widget.maxDiscountBp > 0) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _disc,
                focusNode: _discFocus,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: 'خصم السطر (${Currency.symbol}) — الحد ${formatQty(widget.maxDiscountBp * 10)}%'),
                onTap: () => _disc.selection = TextSelection(baseOffset: 0, extentOffset: _disc.text.length),
                onSubmitted: (_) => _save(),
              ),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء (Esc)')),
          FilledButton(onPressed: _save, child: const Text('حفظ (Enter)')),
        ],
      );
}

/// بعد الاعتماد: رقم الفاتورة والباقي وحالة الطباعة. فشل الطباعة لا يمس الفاتورة ويمكن إعادة طباعتها.
class SaleDoneDialog extends StatefulWidget {
  final Map<String, dynamic> invoice;
  final bool reprint;
  final bool autoPrint; // false = «تأكيد بدون طباعة»؛ تبقى الطباعة متاحة من الأزرار
  const SaleDoneDialog({super.key, required this.invoice, this.reprint = false, this.autoPrint = true});
  @override
  State<SaleDoneDialog> createState() => _SaleDoneState();
}

class _SaleDoneState extends State<SaleDoneDialog> {
  late bool _printing = widget.autoPrint;
  bool _attempted = false; // هل أُرسلت للطابعة مرة على الأقل
  String? _printError;
  String? _pdfNote, _pdfError;

  @override
  void initState() {
    super.initState();
    if (widget.autoPrint) Future.microtask(() => _print(widget.reprint));
  }

  Future<void> _print(bool reprint) async {
    setState(() { _printing = true; _printError = null; _attempted = true; });
    try {
      await ReceiptPrinter.printInvoice(widget.invoice, reprint: reprint);
    } on PrintFailure catch (e) {
      _printError = e.message;
    } catch (_) {
      _printError = 'فشلت الطباعة لسبب غير متوقع.';
    }
    if (mounted) setState(() => _printing = false);
  }

  /// عرض الفاتورة PDF في عارض الجهاز (ملف مؤقت، لا تُحفظ في النظام).
  Future<void> _viewPdf() async {
    try {
      await ReceiptPrinter.openFile(await ReceiptPrinter.tempPdf(widget.invoice));
      if (mounted) setState(() { _pdfNote = 'فُتحت الفاتورة PDF للعرض.'; _pdfError = null; });
    } catch (_) {
      if (mounted) setState(() => _pdfError = 'تعذّر عرض ملف PDF.');
    }
  }

  /// إرسال للعميل بالطريقة التقليدية: يفتح محادثة واتساب مع رقم العميل برسالة جاهزة،
  /// ويُظهر ملف PDF في مجلده ليُسحب إلى المحادثة. الإرسال يتم من واتساب المحل المفتوح على هذا الجهاز.
  Future<void> _whatsapp() async {
    var phone = ReceiptPrinter.whatsappPhone((widget.invoice['customer'] as Map?)?['phone'] as String?);
    if (phone == null) {
      final typed = await showDialog<String>(context: context, builder: (_) => const _PhoneDialog());
      phone = ReceiptPrinter.whatsappPhone(typed);
      if (phone == null) {
        if (mounted && typed != null) setState(() => _pdfError = 'رقم الهاتف غير صالح.');
        return;
      }
    }
    try {
      if (mounted) setState(() { _pdfNote = 'جارٍ تجهيز الفاتورة PDF…'; _pdfError = null; });
      // رابط الفاتورة داخل الرسالة نفسها؛ وإن تعذّر الرفع يبقى الملف منسوخًا للصقه يدويًا
      String? link;
      try {
        link = await ReceiptPrinter.uploadCustomerPdf(widget.invoice);
      } catch (_) {}
      final path = await ReceiptPrinter.tempPdf(widget.invoice, as: PrinterKind.a4);
      final copied = await ReceiptPrinter.copyFileToClipboard(path);
      await ReceiptPrinter.openUrl(ReceiptPrinter.whatsappUrl(widget.invoice, phone, pdfLink: link));
      if (link == null && !copied) await ReceiptPrinter.revealInExplorer(path);
      if (mounted) {
        setState(() {
          _pdfNote = link != null
              ? 'فُتح واتساب ويب على محادثة $phone والرسالة تحمل رابط الفاتورة PDF. اضغط Enter للإرسال.${copied ? ' ولإرفاق الملف نفسه أيضًا اضغط Ctrl+V أولًا.' : ''}'
              : 'تعذّر رفع الفاتورة فلم يُضف رابطها. ${copied ? 'اضغط Ctrl+V داخل المحادثة لإرفاق الملف ثم Enter.' : 'اسحب ملف PDF الظاهر في المجلد إلى المحادثة.'}';
          _pdfError = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _pdfError = 'تعذّر فتح واتساب ويب. تأكد من وجود متصفح على الجهاز.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.invoice;
    final change = (inv['change_baisa'] as num).toInt();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP, control: true): () => _print(widget.reprint || _attempted),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _viewPdf,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): _whatsapp,
      },
      child: AlertDialog(
        title: Text(widget.reprint ? 'إعادة طباعة الفاتورة' : 'تم اعتماد الفاتورة'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(inv['invoice_no'] as String, textDirection: TextDirection.ltr, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            Text('الإجمالي ${money((inv['total_baisa'] as num).toInt())}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
            if (change > 0 && !widget.reprint) ...[
              const SizedBox(height: 12),
              Text('الباقي للعميل ${formatOmr(change)}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Brand.ok)),
            ],
            const SizedBox(height: 16),
            if (_printing)
              const Text('جارٍ الطباعة…', textAlign: TextAlign.center)
            else if (_printError != null)
              Text('الفاتورة معتمدة ومحفوظة، لكن تعذّرت الطباعة:\n$_printError', textAlign: TextAlign.center, style: const TextStyle(color: Brand.bad, fontSize: 16))
            else if (!_attempted)
              const Text('اعتُمدت بدون طباعة. للطباعة اضغط Ctrl+P.', textAlign: TextAlign.center, style: TextStyle(color: Brand.muted))
            else
              const Text('أُرسلت الفاتورة إلى الطابعة.', textAlign: TextAlign.center, style: TextStyle(color: Brand.ok)),
            if (_pdfNote != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_pdfNote!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.ok, fontSize: 14))),
            if (_pdfError != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_pdfError!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _whatsapp, child: const Text('واتساب للعميل (Ctrl+W)')),
          OutlinedButton(onPressed: _viewPdf, child: const Text('عرض PDF (Ctrl+O)')),
          OutlinedButton(onPressed: _printing ? null : () => _print(widget.reprint || _attempted), child: Text(_attempted ? 'إعادة الطباعة (Ctrl+P)' : 'طباعة (Ctrl+P)')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(context), child: Text(widget.reprint ? 'إغلاق (Enter)' : 'فاتورة جديدة (Enter)')),
        ],
      ),
    );
  }
}

/// إدخال رقم واتساب عندما لا يكون للفاتورة عميل برقم هاتف.
class _PhoneDialog extends StatefulWidget {
  const _PhoneDialog();
  @override
  State<_PhoneDialog> createState() => _PhoneState();
}

class _PhoneState extends State<_PhoneDialog> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('رقم واتساب العميل'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: _c,
            autofocus: true,
            textDirection: TextDirection.ltr,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'مثال: 91234567 أو 96891234567'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: const Text('متابعة (Enter)')),
        ],
      );
}
