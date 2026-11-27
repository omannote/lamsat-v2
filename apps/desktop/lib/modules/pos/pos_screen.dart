import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../cash/cash_movement_dialog.dart';
import '../cash/close_shift_dialog.dart';
import '../cash/shift_gate.dart';
import '../customers/customer_lookup_dialog.dart';
import '../invoices/invoice_history_dialog.dart';
import '../printing/printer_settings_dialog.dart';
import '../shell/pages.dart';
import 'approving_dialog.dart';
import 'cart.dart';
import 'dialogs.dart';
import 'drafts_dialog.dart';
import 'payment_dialog.dart';
import 'pending_operation.dart';

/// شاشة نقطة البيع بمفاتيح التصميم: F1 فاتورة جديدة · F2 بحث صنف · F3 عميل/لوحة · F4 كمية · F5 خصم · F6 تعليق
/// F7 استرجاع · F8 نقدي · F9 بطاقة · F10 حفظ وطباعة · F11 مرتجع · F12 إغلاق اليومية · Esc رجوع.
class PosScreen extends StatefulWidget {
  final ShiftContext shift;
  final VoidCallback onShiftClosed;
  final Future<void> Function() onOpenShift;
  const PosScreen({super.key, required this.shift, required this.onShiftClosed, required this.onOpenShift});
  @override
  State<PosScreen> createState() => _State();
}

class _State extends State<PosScreen> {
  final _cart = Cart();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;
  List<Product> _results = [];
  String? _resultsFor; // نص البحث الذي تخصّه النتائج المعروضة
  int _resultIndex = 0, _lineIndex = 0, _searchSeq = 0;
  bool _searching = false, _dialogOpen = false;
  String? _searchError;
  late TaxSettings _tax = widget.shift.tax;
  bool _printNext = true; // اختيار «تأكيد بدون طباعة» في نافذة الدفع

  ShiftContext get shift => widget.shift;

  @override
  void initState() {
    super.initState();
    Future.microtask(_resumePending);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// إصدار الفواتير يتطلب وردية مفتوحة لهذا الحساب. بدونها يبقى الحساب للاطلاع فقط.
  Future<String?> _needShift() async {
    if (shift.sessionId != null) return shift.sessionId;
    if (shift.canOpenShift) {
      await widget.onOpenShift();
    } else {
      await _open<void>(const _MessageDialog('لا توجد وردية', 'هذا الحساب للاطلاع فقط: إصدار الفواتير يتطلب وردية، والورديات غير مفعّلة لدوره. يفعّلها المالك من الإعدادات.'));
    }
    return null;
  }

  // ───────── البحث وإضافة الأصناف ─────────

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() { _results = []; _resultsFor = null; _searchError = null; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 220), () => _runSearch(text));
  }

  Future<List<Product>?> _runSearch(String text) async {
    final seq = ++_searchSeq;
    setState(() { _searching = true; _searchError = null; });
    try {
      final r = await Api.rpc('pos_search', {'p_branch_id': shift.branchId, 'p_query': text.trim(), 'p_limit': 30});
      final list = (r as List).cast<Map>().map((m) => Product.fromJson(m.cast<String, dynamic>())).toList();
      if (seq != _searchSeq || !mounted) return null; // وصل رد أقدم بعد كتابة نص جديد
      setState(() { _results = list; _resultsFor = text; _resultIndex = 0; _searching = false; });
      return list;
    } on BusinessError catch (e) {
      if (mounted && seq == _searchSeq) setState(() { _searching = false; _searchError = errorMessage(e.code); });
    } on NoResponseError {
      if (mounted && seq == _searchSeq) setState(() { _searching = false; _searchError = 'لا يوجد اتصال. تعذّر البحث.'; });
    }
    return null;
  }

  /// Enter في حقل البحث — يدعم قارئ الباركود (يكتب الرقم ثم Enter قبل انتهاء مهلة البحث).
  Future<void> _onSearchSubmitted(String text) async {
    _debounce?.cancel();
    _searchFocus.requestFocus();
    if (text.trim().isEmpty) return;
    if (_resultsFor == text && _results.isNotEmpty) return _addProduct(_results[_resultIndex]);
    final list = await _runSearch(text);
    if (list == null || _search.text != text) return;
    final exact = list.where((p) => p.exactBarcode).toList();
    if (exact.length == 1) return _addProduct(exact.first);
    if (list.length == 1) return _addProduct(list.first);
    if (list.isEmpty) setState(() => _searchError = 'لا يوجد صنف مطابق «${text.trim()}».');
  }

  /// صنف مخزني بلا رصيد كافٍ لا يُضاف للبيع: يظهر تنبيه ويبقى خارج السلة. (الخادم يتحقق مجددًا عند الاعتماد.)
  Future<void> _addProduct(Product p) async {
    if (p.trackStock) {
      final available = (p.stockQty ?? 0) * 1000;
      final inCart = _cart.lines.where((l) => l.product.id == p.id).fold<int>(0, (s, l) => s + l.qtyMilli);
      if (available <= 0 || inCart + 1000 > available) {
        setState(() {
          _search.clear();
          _results = [];
          _resultsFor = null;
          _searchError = null;
        });
        await _open<void>(_MessageDialog(
            'لا يوجد مخزون',
            available <= 0
                ? 'المنتج «${p.nameAr}» لا يوجد به مخزون في هذا الفرع، ولم يُضف إلى الفاتورة.'
                : 'المتاح من «${p.nameAr}» هو ${p.stockQty} ${p.unit} فقط وكلها في الفاتورة. لم تُضف كمية أخرى.'));
        return;
      }
    }
    setState(() {
      _lineIndex = _cart.add(p);
      _search.clear();
      _results = [];
      _resultsFor = null;
      _searchError = null;
    });
    _searchFocus.requestFocus();
  }

  KeyEventResult _onSearchKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final down = k == LogicalKeyboardKey.arrowDown, up = k == LogicalKeyboardKey.arrowUp;
    if (down || up) {
      setState(() {
        if (_results.isNotEmpty) {
          _resultIndex = (_resultIndex + (down ? 1 : -1)).clamp(0, _results.length - 1).toInt();
        } else if (_cart.lines.isNotEmpty) {
          _lineIndex = (_lineIndex + (down ? 1 : -1)).clamp(0, _cart.lines.length - 1).toInt();
        }
      });
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete && _search.text.isEmpty && _cart.lines.isNotEmpty) {
      setState(() {
        _cart.lines.removeAt(_lineIndex);
        _lineIndex = _lineIndex.clamp(0, _cart.lines.isEmpty ? 0 : _cart.lines.length - 1).toInt();
      });
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && (_search.text.isNotEmpty || _results.isNotEmpty)) {
      _search.clear();
      _onSearchChanged('');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ───────── النوافذ الفرعية ─────────

  /// يفتح نافذة فرعية ثم يعيد التركيز إلى حقل البحث عند إغلاقها.
  Future<T?> _open<T>(Widget dialog, {bool dismissible = true}) async {
    if (_dialogOpen) return null;
    _dialogOpen = true;
    try {
      return await showDialog<T>(context: context, barrierDismissible: dismissible, builder: (_) => dialog);
    } finally {
      _dialogOpen = false;
      if (mounted) {
        setState(() {});
        _searchFocus.requestFocus();
      }
    }
  }

  Future<void> _newInvoice() async {
    if (_dialogOpen) return;
    if (!_cart.isEmpty) {
      _dialogOpen = true;
      final choice = await confirmDiscardCart(context);
      _dialogOpen = false;
      if (!mounted) return;
      if (choice == CartChoice.keep) return _searchFocus.requestFocus();
      if (choice == CartChoice.draft) return _drafts();
    }
    setState(() {
      _cart.clear();
      _search.clear();
      _results = [];
      _resultsFor = null;
      _searchError = null;
      _lineIndex = 0;
    });
    _searchFocus.requestFocus();
  }

  Future<void> _editLine({bool discount = false}) async {
    if (_cart.lines.isEmpty) return;
    if (discount && shift.maxDiscountBp <= 0) {
      await _open<void>(const _MessageDialog('الخصم', 'لا تملك صلاحية الخصم. حدّ الخصم يضبطه المالك لكل مستخدم.'));
      return;
    }
    await _open<bool>(LineEditDialog(line: _cart.lines[_lineIndex], maxDiscountBp: shift.maxDiscountBp, focusDiscount: discount));
  }

  Future<void> _pickCustomer() async {
    final c = await _open<CustomerRef>(CustomerLookupDialog(branchId: shift.branchId));
    if (c != null && mounted) setState(() => _cart.customer = c);
  }

  /// F6 تعليق: حفظ الفاتورة الحالية كفاتورة معلّقة وتفريغ السلة.
  Future<void> _drafts() async {
    if (_dialogOpen) return;
    if (_cart.isEmpty) return _recall();
    final sid = await _needShift();
    if (sid == null) return;
    final saved = await _open<bool>(SaveDraftDialog(sessionId: sid, cart: _cart, totalBaisa: _cart.total(_tax)), dismissible: false);
    if (saved == true && mounted) setState(() { _cart.clear(); _lineIndex = 0; });
  }

  /// F7 استرجاع: فتح فاتورة معلّقة. السلة يجب أن تكون فارغة حتى لا تضيع بنودها.
  Future<void> _recall() async {
    if (_dialogOpen) return;
    if (!_cart.isEmpty) {
      await _open<void>(const _MessageDialog('فواتير معلّقة', 'في السلة بنود. علّق الفاتورة الحالية (F6) أو ابدأ فاتورة جديدة (F1) ثم استرجع.'));
      return;
    }
    final payload = await _open<Map<String, dynamic>>(DraftListDialog(branchId: shift.branchId));
    if (payload != null && mounted) setState(() { _cart.loadDraft(payload); _lineIndex = 0; });
  }

  /// F12: مراجعة إقفال الوردية حسب الصلاحية. السلة يجب أن تكون فارغة.
  Future<void> _closeShift() async {
    if (_dialogOpen) return;
    if (!shift.permissions.contains('cash.close')) {
      await _open<void>(const _MessageDialog('إقفال الوردية', 'لا تملك صلاحية إقفال الوردية.'));
      return;
    }
    if (!_cart.isEmpty) {
      await _open<void>(const _MessageDialog('إقفال الوردية', 'في السلة بنود لم تُعتمد. أكمل الفاتورة أو ابدأ فاتورة جديدة (F1) ثم أقفل الوردية.'));
      return;
    }
    final sid = await _needShift();
    if (sid == null) return;
    final closed = await _open<bool>(CloseShiftDialog(sessionId: sid), dismissible: false);
    if (closed == true) widget.onShiftClosed();
  }

  /// F11: مرتجع لفاتورة معتمدة — لمن يملك صلاحية المرتجع (مدير الفرع والمالك).
  Future<void> _refund() async {
    if (_dialogOpen) return;
    if (!shift.permissions.contains('invoice.refund')) {
      await _open<void>(const _MessageDialog('المرتجع', 'المرتجع ينفذه مدير الفرع أو المالك. اطلب منه الدخول بحسابه.'));
      return;
    }
    await _open<bool>(RefundDialog(ctx: shift), dismissible: false);
  }

  // ───────── الدفع والاعتماد ─────────

  Future<void> _pay([PayMethod method = PayMethod.cash]) async {
    if (_cart.isEmpty || _dialogOpen) return;
    final sid = await _needShift();
    if (sid == null || !mounted) return;
    final pay = await _open<PaymentResult>(PaymentDialog(totalBaisa: _cart.total(_tax), initial: method, customerName: _cart.customer?.name));
    if (pay == null || !mounted) return;
    _printNext = pay.print;
    // معرّف العملية يُولَّد قبل الإرسال ويُحفظ مع الحمولة؛ إعادة المحاولة تستخدمهما كما هما.
    final opId = const Uuid().v4();
    final payload = _cart.toPayload(
      cashSessionId: sid, tax: _tax, cashBaisa: pay.split.cash, cardBaisa: pay.split.card,
      transferBaisa: pay.split.transfer, creditBaisa: pay.split.credit,
      cashTenderedBaisa: pay.split.cash > 0 ? pay.split.tendered : null, cardReference: pay.reference,
    );
    await PendingOperation.save(opId, payload);
    if (!mounted) return;
    final outcome = await _open<ApproveOutcome>(
      ApprovingDialog(operationId: opId, cashSessionId: sid, payload: payload), dismissible: false);
    if (outcome != null) await _handleOutcome(outcome, fromCart: true);
  }

  /// عند بدء الشاشة: إن وُجدت عملية لم تُعرف نتيجتها (انقطاع أو إعادة تشغيل) نتحقق منها أولًا.
  Future<void> _resumePending() async {
    final p = await PendingOperation.load();
    if (p == null || !mounted) return;
    if (p.payload['cash_session_id'] != shift.sessionId) {
      // عملية من وردية أخرى: نتحقق من نتيجتها دون إعادة إرسالها
      try {
        final r = (await Api.rpc('get_operation', {'p_operation_id': p.operationId}) as Map).cast<String, dynamic>();
        await PendingOperation.clear();
        if (r['found'] == true && (r['result'] as Map)['status'] == 'approved' && mounted) {
          await _handleOutcome(ApproveOutcome(ApproveStatus.approved, data: ((r['result'] as Map)['invoice'] as Map).cast<String, dynamic>()), fromCart: false);
        }
      } catch (_) {}
      return;
    }
    final outcome = await _open<ApproveOutcome>(
      ApprovingDialog(operationId: p.operationId, cashSessionId: shift.sessionId!, payload: p.payload, verifyOnly: true), dismissible: false);
    if (outcome != null) await _handleOutcome(outcome, fromCart: false);
  }

  Future<void> _handleOutcome(ApproveOutcome o, {required bool fromCart}) async {
    switch (o.status) {
      case ApproveStatus.approved:
        if (fromCart) setState(() { _cart.clear(); _lineIndex = 0; });
        final auto = fromCart ? _printNext : true;
        _printNext = true;
        await _open<void>(SaleDoneDialog(invoice: o.data!, autoPrint: auto), dismissible: false);
      case ApproveStatus.needsConfirm:
        await _confirmServerChange(o.data!);
      case ApproveStatus.error:
        if (o.error!.code == 'NOT_AUTHENTICATED') {
          await Api.client.auth.signOut();
          return;
        }
        if (mounted) await _open<void>(_MessageDialog('لم تُعتمد الفاتورة', '${describeError(o.error!)}\n\nلم يُحفظ شيء في الخادم.'));
      case ApproveStatus.abandoned:
        if (mounted) await _open<void>(const _MessageDialog('لم تُعتمد الفاتورة', 'أُلغيت المحاولة ولم يُحفظ شيء. السلة كما هي ويمكنك إعادة الدفع.'));
    }
  }

  /// السعر أو الضريبة تغيّرا في الخادم منذ الإضافة للسلة: نعرض الفرق ولا نعتمد إلا بعد تأكيد الكاشير.
  Future<void> _confirmServerChange(Map<String, dynamic> r) async {
    if (r['status'] == 'price_changed') {
      final changes = (r['changes'] as List).cast<Map>();
      final body = StringBuffer('تغيّرت أسعار في النظام منذ إضافتها للسلة:\n\n');
      for (final c in changes) {
        body.writeln('${c['name_ar']}: ${formatOmr((c['expected_baisa'] as num).toInt())} ← ${formatOmr((c['current_baisa'] as num).toInt())}');
      }
      body.write('\nالإجمالي الجديد: ${money((r['server_total_baisa'] as num).toInt())}');
      final ok = await _open<bool>(_ConfirmDialog('تأكيد تغيّر السعر', body.toString(), 'اعتماد الأسعار الجديدة والعودة للدفع'));
      if (ok != true || !mounted) return;
      setState(() {
        for (final c in changes) {
          for (final l in _cart.lines.where((l) => l.product.id == c['product_id'])) {
            l.unitPriceBaisa = (c['current_baisa'] as num).toInt();
            if (l.discountBaisa > l.gross) l.discountBaisa = 0;
          }
        }
      });
      return _pay();
    }
    // total_changed: إعدادات الضريبة تغيّرت
    setState(() => _tax = TaxSettings(
        enabled: r['tax_enabled'] as bool, rateBp: (r['tax_rate_bp'] as num).toInt(), pricesIncludeTax: r['prices_include_tax'] as bool));
    final ok = await _open<bool>(_ConfirmDialog('تغيّر الإجمالي',
        'تغيّرت إعدادات الضريبة في النظام. الإجمالي الجديد: ${money(_cart.total(_tax))}', 'متابعة إلى الدفع'));
    if (ok == true && mounted) return _pay();
  }

  // ───────── الواجهة ─────────

  @override
  Widget build(BuildContext context) {
    final total = _cart.total(_tax);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f1): _newInvoice,
        const SingleActivator(LogicalKeyboardKey.f2): () {
          _searchFocus.requestFocus();
          _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
        },
        const SingleActivator(LogicalKeyboardKey.f3): _pickCustomer,
        const SingleActivator(LogicalKeyboardKey.f4): _editLine,
        const SingleActivator(LogicalKeyboardKey.f5): () => _editLine(discount: true),
        const SingleActivator(LogicalKeyboardKey.f6): _drafts,
        const SingleActivator(LogicalKeyboardKey.f7): _recall,
        const SingleActivator(LogicalKeyboardKey.f8): () => _pay(PayMethod.cash),
        const SingleActivator(LogicalKeyboardKey.f9): () => _pay(PayMethod.card),
        const SingleActivator(LogicalKeyboardKey.f10): () => _pay(PayMethod.cash),
        const SingleActivator(LogicalKeyboardKey.f11): _refund,
        const SingleActivator(LogicalKeyboardKey.f12): _closeShift,
        const SingleActivator(LogicalKeyboardKey.keyH, control: true): () =>
            _open<void>(InvoiceHistoryDialog(branchId: shift.branchId, canReprint: shift.permissions.contains('invoice.reprint'))),
        const SingleActivator(LogicalKeyboardKey.keyM, control: true): () {
          if (shift.permissions.contains('cash.movement') && shift.sessionId != null) _open<void>(CashMovementDialog(sessionId: shift.sessionId!), dismissible: false);
        },
        const SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true): () => _open<void>(const PrinterSettingsDialog()),
      },
      child: Scaffold(
        body: Column(children: [
          if (shift.sessionId == null)
            Container(
              width: double.infinity,
              color: const Color(0xFFFFF4E5),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Expanded(
                  child: Text(
                      shift.canOpenShift
                          ? 'لا توجد وردية مفتوحة لحسابك. يمكنك التصفح، ولإصدار الفواتير افتح وردية.'
                          : 'حسابك للاطلاع فقط: الورديات غير مفعّلة لدوره، فلا يمكنه إصدار الفواتير. يفعّلها المالك من الإعدادات.',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF9A5B00))),
                ),
                if (shift.canOpenShift) FilledButton(focusNode: FocusNode(skipTraversal: true), onPressed: widget.onOpenShift, child: const Text('فتح وردية')),
              ]),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(flex: 5, child: _searchPane()),
                const SizedBox(width: 12),
                Expanded(flex: 6, child: _cartPane(total)),
              ]),
            ),
          ),
          _hintBar(),
        ]),
      ),
    );
  }

  Widget _searchPane() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Focus(
          onKeyEvent: _onSearchKey,
          child: TextField(
            controller: _search,
            focusNode: _searchFocus,
            autofocus: true,
            style: const TextStyle(fontSize: 20),
            decoration: InputDecoration(
              hintText: 'بحث بالاسم، الباركود، أو مقاس الإطار (مثال 205/55R16) — F2',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searching ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))) : null,
            ),
            onChanged: _onSearchChanged,
            onSubmitted: _onSearchSubmitted,
          ),
        ),
        if (_searchError != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_searchError!, style: const TextStyle(color: Brand.bad, fontSize: 16))),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Brand.line), borderRadius: BorderRadius.circular(10)),
            child: _results.isEmpty
                ? const Center(child: Text('اكتب للبحث أو امسح الباركود', style: TextStyle(color: Brand.muted)))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final p = _results[i];
                      final out = p.trackStock && (p.stockQty ?? 0) <= 0;
                      return Material(
                        color: i == _resultIndex ? const Color(0xFFFFF0EA) : Colors.white,
                        child: InkWell(
                          onTap: () => _addProduct(p),
                          mouseCursor: out ? SystemMouseCursors.forbidden : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            child: Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(p.nameAr, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                                  Text(p.sku, textDirection: TextDirection.ltr, style: const TextStyle(color: Brand.muted, fontSize: 13)),
                                ]),
                              ),
                              if (p.trackStock)
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Text(out ? 'غير متوفر' : 'الرصيد ${p.stockQty}', style: TextStyle(color: out ? Brand.bad : Brand.muted)),
                                ),
                              Text(formatOmr(p.unitPriceBaisa), textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ]);

  Widget _cartPane(int total) => Container(
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Brand.line), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(children: [
              const Text('الفاتورة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_cart.customer != null)
                InputChip(
                  label: Text([_cart.customer!.plate, _cart.customer!.name].whereType<String>().join(' — ')),
                  onDeleted: () => setState(() => _cart.customer = null),
                  focusNode: FocusNode(skipTraversal: true),
                )
              else
                const Text('بدون عميل — F3 للربط', style: TextStyle(color: Brand.muted)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: _cart.isEmpty
                ? const Center(child: Text('السلة فارغة', style: TextStyle(color: Brand.muted, fontSize: 18)))
                : ListView.builder(
                    itemCount: _cart.lines.length,
                    itemBuilder: (_, i) {
                      final l = _cart.lines[i];
                      return Material(
                        color: i == _lineIndex ? const Color(0xFFFFF0EA) : Colors.white,
                        child: InkWell(
                          onTap: () => setState(() => _lineIndex = i),
                          onDoubleTap: () {
                            setState(() => _lineIndex = i);
                            _editLine();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                            child: Row(children: [
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(l.product.nameAr, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                                  Text(
                                    '${formatQty(l.qtyMilli)} ${l.product.unit} × ${formatOmr(l.unitPriceBaisa)}'
                                    '${l.discountBaisa > 0 ? '   خصم ${formatOmr(l.discountBaisa)}' : ''}',
                                    style: const TextStyle(color: Brand.muted),
                                  ),
                                ]),
                              ),
                              Text(formatOmr(l.total(_tax)), textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              if (_cart.discount() > 0) _sumRow('الخصم', formatOmr(_cart.discount())),
              if (_tax.effectiveRateBp > 0)
                _sumRow('ضريبة ${formatQty(_tax.rateBp * 10)}%${_tax.pricesIncludeTax ? ' (ضمن السعر)' : ''}', formatOmr(_cart.tax(_tax))),
              const SizedBox(height: 4),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('الإجمالي (${Currency.symbol})', style: const TextStyle(fontSize: 20, color: Brand.muted)),
                Text(formatOmr(total), textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w800, color: Brand.ink)),
              ]),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 60,
                child: FilledButton(
                  focusNode: FocusNode(skipTraversal: true),
                  onPressed: _cart.isEmpty ? null : _pay,
                  child: const Text('الدفع  (F10)', style: TextStyle(fontSize: 22)),
                ),
              ),
            ]),
          ),
        ]),
      );

  Widget _sumRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: const TextStyle(color: Brand.muted)),
          Text(v, textDirection: TextDirection.ltr),
        ]),
      );

  /// شريط الاختصارات كما في التصميم: كل مفتاح زر يُضغط بالفأرة أيضًا.
  Widget _hintBar() {
    Widget key(String k, String label, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: InkWell(
            onTap: onTap,
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(color: const Color(0x22FFFFFF), borderRadius: BorderRadius.circular(6)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(k, textDirection: TextDirection.ltr, style: const TextStyle(color: Brand.orange, fontSize: 13, fontWeight: FontWeight.w800)),
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ]),
            ),
          ),
        );
    return Container(
      color: Brand.ink2,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          key('F1', 'فاتورة جديدة', _newInvoice),
          key('F2', 'بحث صنف', () => _searchFocus.requestFocus()),
          key('F3', 'عميل / لوحة', _pickCustomer),
          key('F4', 'كمية', _editLine),
          key('F5', 'خصم', () => _editLine(discount: true)),
          key('F6', 'تعليق', _drafts),
          key('F7', 'استرجاع', _recall),
          key('F8', 'نقدي', () => _pay(PayMethod.cash)),
          key('F9', 'بطاقة', () => _pay(PayMethod.card)),
          key('F10', 'حفظ وطباعة', () => _pay(PayMethod.cash)),
          key('F11', 'مرتجع', _refund),
          key('F12', 'إغلاق اليومية', _closeShift),
          key('Ctrl+H', 'سجل الفواتير', () => _open<void>(InvoiceHistoryDialog(branchId: shift.branchId, canReprint: shift.permissions.contains('invoice.reprint')))),
          key('Ctrl+M', 'مصروف / قبض', () {
            if (shift.permissions.contains('cash.movement') && shift.sessionId != null) _open<void>(CashMovementDialog(sessionId: shift.sessionId!), dismissible: false);
          }),
          key('Del', 'حذف سطر', () {
            if (_cart.lines.isEmpty) return;
            setState(() {
              _cart.lines.removeAt(_lineIndex);
              _lineIndex = _lineIndex.clamp(0, _cart.lines.isEmpty ? 0 : _cart.lines.length - 1).toInt();
            });
          }),
        ]),
      ),
    );
  }
}

class _MessageDialog extends StatelessWidget {
  final String title, body;
  const _MessageDialog(this.title, this.body);
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 460, child: Text(body, style: const TextStyle(fontSize: 17))),
        actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('حسنًا (Enter)'))],
      );
}

class _ConfirmDialog extends StatelessWidget {
  final String title, body, confirmLabel;
  const _ConfirmDialog(this.title, this.body, this.confirmLabel);
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 480, child: Text(body, style: const TextStyle(fontSize: 17))),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('رجوع للسلة (Esc)')),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(context, true), child: Text(confirmLabel)),
        ],
      );
}
