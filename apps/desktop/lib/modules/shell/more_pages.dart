part of 'pages.dart';

// العملاء والضمان، المرتجع، اليومية، لوحة المالك، تقرير الضريبة، الإعدادات والمستخدمون، التحويل بين الفرعين.

List<Map<String, dynamic>> _maps(Object? r) => ((r as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
String _dateOf(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime _muscatNow() => DateTime.now().toUtc().add(const Duration(hours: 4));

Future<void> _info(BuildContext context, String text) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(content: SizedBox(width: 440, child: Text(text, style: const TextStyle(fontSize: 17))), actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(c), child: const Text('حسنًا'))]));

Future<void> _openTemp(BuildContext context, Future<String> Function() build) async {
  try {
    await ReceiptPrinter.openFile(await build());
  } catch (_) {
    if (context.mounted) await _info(context, 'تعذّر إنشاء الملف أو فتحه.');
  }
}

Widget _tileBox(String label, String value, {Color? color, double width = 230}) => Container(
      width: width,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: Brand.muted, fontSize: 14)),
        const SizedBox(height: 6),
        Text(value, textDirection: TextDirection.ltr, style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800, color: color ?? Brand.ink)),
      ]),
    );

Widget _sectionTitle(String t) => Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 6), child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Brand.muted)));

// ───────────────────────── العملاء والضمان ─────────────────────────
class CustomersPage extends StatefulWidget {
  final ShiftContext ctx;
  const CustomersPage({super.key, required this.ctx});
  @override
  State<CustomersPage> createState() => _CustomersState();
}

class _CustomersState extends State<CustomersPage> {
  List<Map<String, dynamic>> _customers = [];
  Map<String, dynamic>? _selected, _profile;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _search(''));
  }

  /// بحث بالاسم أو الهاتف أو رقم اللوحة.
  Future<void> _search(String raw) async {
    final q = raw.replaceAll(RegExp(r'[^0-9A-Za-z؀-ۿ ]'), '').trim();
    final seq = ++_seq;
    try {
      var query = Api.client.from('customers').select('id, name, phone');
      if (q.isNotEmpty) query = query.or('phone.ilike.%$q%,name.ilike.%$q%');
      final found = (await query.order('created_at', ascending: false).limit(50).timeout(const Duration(seconds: 12))).cast<Map<String, dynamic>>().toList();
      if (q.isNotEmpty) {
        try {
          final v = await Api.client.from('vehicles').select('customer_id, plate').ilike('plate', '%$q%').limit(20).timeout(const Duration(seconds: 12));
          final ids = v.map((x) => x['customer_id']).whereType<String>().where((id) => !found.any((c) => c['id'] == id)).toSet().toList();
          if (ids.isNotEmpty) {
            final extra = await Api.client.from('customers').select('id, name, phone').inFilter('id', ids).timeout(const Duration(seconds: 12));
            found.insertAll(0, extra.cast<Map<String, dynamic>>());
          }
        } catch (_) {}
      }
      if (mounted && seq == _seq) setState(() { _customers = found; _error = null; });
    } catch (_) {
      if (mounted && seq == _seq) setState(() => _error = 'تعذّر تحميل العملاء. تحقق من الاتصال.');
    }
  }

  Future<void> _select(Map<String, dynamic> c) async {
    setState(() { _selected = c; _profile = null; });
    try {
      final p = (await Api.rpc('customer_profile', {'p_customer_id': c['id']}) as Map).cast<String, dynamic>();
      if (mounted && _selected?['id'] == c['id']) setState(() { _profile = p; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _fail(e));
    }
  }

  Future<void> _collect() async {
    final c = _selected, p = _profile;
    if (c == null || p == null) return;
    final done = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CollectDialog(sessionId: widget.ctx.sessionId!, customerId: c['id'] as String, customerName: '${c['name']}', balanceBaisa: _i(p['balance_baisa'])));
    if (done == true && mounted) await _select(c);
  }

  Future<void> _addVehicle() async {
    final c = _selected;
    if (c == null) return;
    final done = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => AddVehicleDialog(ctx: widget.ctx, customerId: c['id'] as String));
    if (done == true && mounted) await _select(c);
  }

  /// كشف حساب العميل الآجل PDF للعرض والطباعة.
  Future<void> _statement() async {
    final c = _selected, p = _profile;
    if (c == null || p == null) return;
    var run = 0;
    final rows = <List<String>>[];
    for (final s in _maps(p['statement'])) {
      run += _i(s['debit_baisa']) - _i(s['credit_baisa']);
      rows.add([
        '${s['at']}'.substring(0, 10),
        switch (s['kind']) { 'sale' => 'بيع آجل', 'refund' => 'مرتجع', _ => 'تحصيل' },
        '${s['ref'] ?? ''}',
        _i(s['debit_baisa']) > 0 ? formatOmr(_i(s['debit_baisa'])) : '',
        _i(s['credit_baisa']) > 0 ? formatOmr(_i(s['credit_baisa'])) : '',
        formatOmr(run),
      ]);
    }
    await _openTemp(
        context,
        () => ReceiptPrinter.tempReport('statement-${'${c['id']}'.substring(0, 8)}', 'كشف حساب عميل', ['التاريخ', 'البيان', 'المرجع', 'مدين', 'دائن', 'الرصيد'], rows,
            intro: ['${c['name']}${c['phone'] != null ? ' — ${c['phone']}' : ''}', 'حتى تاريخ ${_dateOf(_muscatNow())}'],
            summary: [('الرصيد المستحق على العميل (${Currency.symbol})', formatOmr(_i(p['balance_baisa'])))]));
  }

  Future<void> _openInvoice(String id) async {
    try {
      final inv = (await Api.rpc('get_invoice', {'p_invoice_id': id}) as Map).cast<String, dynamic>();
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (_) => SaleDoneDialog(invoice: inv, reprint: true, autoPrint: false));
    } catch (e) {
      if (mounted) await _info(context, _fail(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    final balance = _i(p?['balance_baisa']);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f9): _statement,
      },
      child: _Page(
        title: 'العملاء والضمان',
        tools: [SizedBox(width: 340, child: TextField(autofocus: true, decoration: const InputDecoration(hintText: 'بحث بالاسم أو الهاتف أو رقم اللوحة', isDense: true), onChanged: _search))],
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 340,
            child: _error != null && _customers.isEmpty
                ? _note(_error!, bad: true)
                : ListView(children: [
                    for (final c in _customers)
                      ListTile(
                        selected: _selected?['id'] == c['id'],
                        selectedTileColor: const Color(0xFFFFF0EA),
                        title: Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: c['phone'] == null ? null : Text('${c['phone']}', textDirection: TextDirection.ltr),
                        onTap: () => _select(c),
                      ),
                    if (_customers.isEmpty) _note('لا يوجد عملاء مطابقون. أضف العميل من شاشة البيع (F3).'),
                  ]),
          ),
          const VerticalDivider(width: 1, color: Brand.line),
          Expanded(
            child: _selected == null
                ? _note('اختر عميلًا لعرض مركباته وضماناته وحسابه.')
                : p == null
                    ? (_error != null ? _note(_error!, bad: true) : const Center(child: CircularProgressIndicator()))
                    : ListView(children: [
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(children: [
                            Expanded(child: Text('${_selected!['name']} · ${_selected!['phone'] ?? 'بلا هاتف'}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
                            Text('الرصيد الآجل: ${money(balance)}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: balance > 0 ? Brand.bad : Brand.ok)),
                            const SizedBox(width: 10),
                            if (balance > 0 && widget.ctx.sessionId != null) FilledButton(onPressed: _collect, child: const Text('تحصيل')),
                            const SizedBox(width: 6),
                            OutlinedButton(onPressed: _statement, child: const Text('كشف حساب F9')),
                          ]),
                        ),
                        _sectionTitle('المركبات'),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                            for (final v in _maps(p['vehicles'])) Chip(label: Text([v['plate'], v['make'], v['model']].whereType<String>().join(' · '))),
                            if (widget.ctx.permissions.contains('pos.sell')) ActionChip(label: const Text('+ مركبة'), onPressed: _addVehicle),
                          ]),
                        ),
                        _sectionTitle('الضمانات'),
                        if (_maps(p['warranties']).isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 14), child: Text('لا ضمانات مسجلة.', style: TextStyle(color: Brand.muted))),
                        for (final w in _maps(p['warranties']))
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                            child: Row(children: [
                              _cell('${w['product_name']}', flex: 4, bold: true),
                              _cell('${w['warranty_no']}', flex: 3, num: true),
                              _cell('${w['plate'] ?? '—'}', flex: 2),
                              _cell('حتى ${w['expires_on']}', flex: 2),
                              _cell(w['active'] == true ? 'ساري' : 'منتهٍ', flex: 1, bold: true, color: w['active'] == true ? Brand.ok : Brand.bad),
                              TextButton(onPressed: () => _openInvoice(w['invoice_id'] as String), child: const Text('طباعة البطاقة')),
                            ]),
                          ),
                        _sectionTitle('الفواتير (انقر مرتين لعرضها أو إعادة طباعتها)'),
                        _head([('التاريخ', 2), ('الفاتورة', 3), ('اللوحة', 2), ('المبلغ', 2)]),
                        if (_maps(p['invoices']).isEmpty) _note('لا توجد فواتير لهذا العميل ضمن الفروع المتاحة لك.'),
                        for (final r in _maps(p['invoices']))
                          InkWell(
                            onDoubleTap: () => _openInvoice(r['id'] as String),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                              child: Row(children: [
                                _cell('${r['approved_at']}'.substring(0, 10), flex: 2, num: true),
                                _cell('${r['invoice_no']}${r['status'] == 'voided' ? ' (ملغاة)' : ''}', flex: 3, num: true, bold: true),
                                _cell('${r['plate'] ?? '—'}', flex: 2),
                                _cell(formatOmr(_i(r['total_baisa'])), flex: 2, num: true),
                              ]),
                            ),
                          ),
                      ]),
          ),
        ]),
      ),
    );
  }
}

class AddVehicleDialog extends StatefulWidget {
  final ShiftContext ctx;
  final String customerId;
  const AddVehicleDialog({super.key, required this.ctx, required this.customerId});
  @override
  State<AddVehicleDialog> createState() => _AddVehicleState();
}

class _AddVehicleState extends State<AddVehicleDialog> {
  final _plate = TextEditingController(), _make = TextEditingController(), _model = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _plate.dispose();
    _make.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_plate.text.trim().isEmpty) {
      setState(() => _error = 'رقم اللوحة مطلوب.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('add_vehicle', {'p_branch_id': widget.ctx.branchId, 'p_customer_id': widget.customerId, 'p_plate': _plate.text.trim(), 'p_make': _make.text.trim(), 'p_model': _model.text.trim()});
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = _fail(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('مركبة جديدة'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _input(_plate, 'رقم اللوحة', autofocus: true),
            const SizedBox(height: 10),
            _input(_make, 'الصانع (اختياري)'),
            const SizedBox(height: 10),
            _input(_model, 'الطراز (اختياري)'),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('حفظ')),
        ],
      );
}

// ───────────────────────── المرتجع (إشعار دائن) ─────────────────────────
const _refundReasons = ['عيب في المنتج', 'مقاس أو صنف غير مناسب', 'العميل غيّر رأيه', 'خطأ في الفاتورة', 'سبب آخر'];
const _refundMethods = <String, String>{'cash': 'نقدي من الدرج', 'card': 'نفس البطاقة', 'transfer': 'تحويل بنكي', 'credit': 'رصيد للعميل'};

class _RLine {
  final Map<String, dynamic> line;
  final qty = TextEditingController(text: '0');
  bool restock;
  _RLine(this.line) : restock = line['track_stock'] == true;
}

/// مرتجع جزئي أو كلي لفاتورة معتمدة: اختيار الفاتورة ثم الكميات والسبب وطريقة رد المبلغ.
class RefundDialog extends StatefulWidget {
  final ShiftContext ctx;
  const RefundDialog({super.key, required this.ctx});
  @override
  State<RefundDialog> createState() => _RefundState();
}

class _RefundState extends State<RefundDialog> {
  final _q = TextEditingController(), _remark = TextEditingController();
  List<Map<String, dynamic>> _invoices = [];
  Map<String, dynamic>? _invoice;
  List<_RLine> _lines = [];
  String _reason = _refundReasons.first, _method = 'cash';
  String _opId = const Uuid().v4();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_find);
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.qty.dispose();
    }
    _q.dispose();
    _remark.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final now = _muscatNow();
    final searching = _q.text.trim().isNotEmpty;
    try {
      final r = await Api.rpc('list_invoices', {
        'p_branch_id': widget.ctx.branchId, 'p_from': _dateOf(now.subtract(Duration(days: searching ? 365 : 2))), 'p_to': _dateOf(now.add(const Duration(days: 1))),
        'p_search': searching ? _q.text.trim() : null, 'p_limit': 30,
      });
      if (mounted) setState(() { _invoices = _maps(r).where((x) => x['status'] == 'approved').toList(); _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _fail(e));
    }
  }

  Future<void> _pick(Map<String, dynamic> inv) async {
    setState(() { _busy = true; _error = null; });
    try {
      final st = (await Api.rpc('invoice_refund_state', {'p_invoice_id': inv['id']}) as Map).cast<String, dynamic>();
      for (final l in _lines) {
        l.qty.dispose();
      }
      _lines = _maps(st['lines']).map(_RLine.new).toList();
      _invoice = inv;
    } catch (e) {
      _error = _fail(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _submit() async {
    final inv = _invoice;
    if (inv == null) return;
    final lines = <Map<String, dynamic>>[];
    String? err;
    for (final l in _lines) {
      final q = parseMilli(l.qty.text.trim().isEmpty ? '0' : l.qty.text);
      if (q == null) err ??= 'كمية غير صالحة: ${l.line['description_ar']}';
      if (q != null && q > (_d(l.line['remaining_qty']) * 1000).round()) err ??= 'الكمية أكبر من المتبقي: ${l.line['description_ar']}';
      if (q != null && q > 0) lines.add({'line_no': l.line['line_no'], 'qty': q / 1000, 'restock': l.restock});
    }
    if (err == null && lines.isEmpty) err = 'حدّد كمية مرتجعة لبند واحد على الأقل.';
    if (err == null && _method == 'cash' && widget.ctx.sessionId == null) err = 'الرد النقدي يتطلب وردية مفتوحة لحسابك يخرج منها النقد.';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final r = (await Api.rpc('refund_invoice', {
        'p_operation_id': _opId,
        'p_payload': {
          'invoice_id': inv['id'], 'kind': 'refund', 'method': _method,
          'reason': _remark.text.trim().isEmpty ? _reason : '$_reason — ${_remark.text.trim()}',
          if (_method == 'cash') 'cash_session_id': widget.ctx.sessionId,
          'lines': lines,
        }
      }) as Map)
          .cast<String, dynamic>();
      if (!mounted) return;
      await _info(context, 'سُجّل المرتجع ${r['refund_no']}\nالمبلغ المردود: ${money(_i(r['amount_baisa']))} — ${_refundMethods[_method]}');
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _opId = const Uuid().v4();
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال. اضغط «تنفيذ المرتجع» مجددًا للتحقق؛ لن يُسجَّل مرتين.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final inv = _invoice;
    return AlertDialog(
      title: Text(inv == null ? 'مرتجع — اختر الفاتورة' : 'مرتجع من الفاتورة ${inv['invoice_no']}'),
      content: SizedBox(
        width: 860,
        height: 560,
        child: inv == null
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(
                  controller: _q,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'رقم الفاتورة أو هاتف العميل أو اللوحة ثم Enter (فارغ = فواتير آخر يومين)', isDense: true, prefixIcon: Icon(Icons.search)),
                  onSubmitted: (_) => _find(),
                ),
                const SizedBox(height: 8),
                _head([('التاريخ', 2), ('الفاتورة', 3), ('العميل', 3), ('المبلغ', 2)]),
                Expanded(
                  child: _invoices.isEmpty
                      ? _note(_error ?? 'لا توجد فواتير مطابقة.', bad: _error != null)
                      : ListView(children: [
                          for (final r in _invoices)
                            InkWell(
                              onTap: _busy ? null : () => _pick(r),
                              child: Container(
                                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                child: Row(children: [
                                  _cell('${r['business_date']}', flex: 2, num: true),
                                  _cell('${r['invoice_no']}', flex: 3, num: true, bold: true),
                                  _cell('${r['customer_name'] ?? r['plate'] ?? '—'}', flex: 3),
                                  _cell(formatOmr(_i(r['total_baisa'])), flex: 2, num: true),
                                ]),
                              ),
                            ),
                        ]),
                ),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _head([('البند', 5), ('المباع', 2), ('المتبقي للإرجاع', 2), ('الكمية المرتجعة', 2), ('يعود للمخزون', 2)]),
                Expanded(
                  child: ListView(children: [
                    for (final l in _lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                        child: Row(children: [
                          _cell('${l.line['description_ar']}${l.line['kind'] == 'service' ? '  (خدمة — لا تُرجع بعد التنفيذ)' : ''}', flex: 5, bold: true),
                          _cell(_qtyText(l.line['qty']), flex: 2, num: true),
                          _cell(_qtyText(l.line['remaining_qty']), flex: 2, num: true),
                          Expanded(
                            flex: 2,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              child: TextField(
                                controller: l.qty,
                                enabled: l.line['kind'] != 'service' && _d(l.line['remaining_qty']) > 0,
                                textDirection: TextDirection.ltr,
                                decoration: const InputDecoration(isDense: true),
                                onTap: () => l.qty.selection = TextSelection(baseOffset: 0, extentOffset: l.qty.text.length),
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: l.line['track_stock'] == true
                                ? Checkbox(value: l.restock, onChanged: (v) => setState(() => l.restock = v ?? true))
                                : const Text('—', textAlign: TextAlign.center),
                          ),
                        ]),
                      ),
                  ]),
                ),
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: _labeled(
                        'سبب المرتجع',
                        DropdownButton<String>(
                          value: _reason,
                          isExpanded: true,
                          isDense: true,
                          items: [for (final r in _refundReasons) DropdownMenuItem(value: r, child: Text(r))],
                          onChanged: (v) => setState(() => _reason = v ?? _refundReasons.first),
                        )),
                  ),
                  const SizedBox(width: 10),
                  Expanded(flex: 4, child: _input(_remark, 'ملاحظة (اختياري)')),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  const Text('رد المبلغ: '),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [for (final m in _refundMethods.entries) ButtonSegment(value: m.key, label: Text(m.value))],
                    selected: {_method},
                    onSelectionChanged: (s) => setState(() => _method = s.first),
                  ),
                ]),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: Brand.bad, fontSize: 16))),
              ]),
      ),
      actions: [
        if (inv != null) OutlinedButton(onPressed: _busy ? null : () => setState(() { _invoice = null; _error = null; }), child: const Text('فاتورة أخرى')),
        OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('إغلاق (Esc)')),
        if (inv != null) FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'جارٍ التنفيذ…' : 'تنفيذ المرتجع')),
      ],
    );
  }
}

// ───────────────────────── اليومية ─────────────────────────
const _expenseCategories = ['إيجار', 'كهرباء وماء', 'رواتب وسلف', 'صيانة', 'ضيافة', 'مواصلات ووقود', 'مشتريات نثرية', 'أخرى'];

/// مصروف من الدرج بتصنيف، أو قبض نقدي إليه.
class ExpenseDialog extends StatefulWidget {
  final String sessionId;
  const ExpenseDialog({super.key, required this.sessionId});
  @override
  State<ExpenseDialog> createState() => _ExpenseState();
}

class _ExpenseState extends State<ExpenseDialog> {
  final _amount = TextEditingController(), _note = TextEditingController();
  String _type = 'cash_out', _category = _expenseCategories.first;
  String _opId = const Uuid().v4();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseOmr(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'أدخل مبلغًا صحيحًا.');
      return;
    }
    if (_type == 'cash_in' && _note.text.trim().isEmpty) {
      setState(() => _error = 'اكتب بيان القبض.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('record_cash_movement_cat', {
        'p_operation_id': _opId, 'p_cash_session_id': widget.sessionId, 'p_type': _type, 'p_amount_baisa': amount,
        'p_note': _note.text.trim().isEmpty ? _category : _note.text.trim(), 'p_category': _type == 'cash_out' ? _category : 'قبض',
      });
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _opId = const Uuid().v4();
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال. اضغط «تسجيل» مجددًا للتحقق؛ لن يُسجَّل المبلغ مرتين.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('مصروف أو قبض نقدي'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: 'cash_out', label: Text('مصروف من الدرج')), ButtonSegment(value: 'cash_in', label: Text('قبض إلى الدرج'))],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 12),
            if (_type == 'cash_out')
              _labeled(
                  'التصنيف',
                  DropdownButton<String>(
                    value: _category,
                    isExpanded: true,
                    isDense: true,
                    items: [for (final c in _expenseCategories) DropdownMenuItem(value: c, child: Text(c))],
                    onChanged: (v) => setState(() => _category = v ?? _expenseCategories.first),
                  )),
            const SizedBox(height: 10),
            TextField(
              controller: _amount,
              autofocus: true,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
              decoration: InputDecoration(labelText: 'المبلغ (${Currency.symbol})'),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 10),
            _input(_note, _type == 'cash_out' ? 'البيان (اختياري)' : 'البيان'),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ التسجيل…' : 'تسجيل')),
        ],
      );
}

class DayPage extends StatefulWidget {
  final ShiftContext ctx;
  final VoidCallback onChanged;
  final Future<void> Function() onOpenShift;
  const DayPage({super.key, required this.ctx, required this.onChanged, required this.onOpenShift});
  @override
  State<DayPage> createState() => _DayState();
}

class _DayState extends State<DayPage> {
  Map<String, dynamic>? _s;
  List<Map<String, dynamic>> _moves = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    final sid = widget.ctx.sessionId;
    if (sid == null) return;
    try {
      final r = (await Api.rpc('cash_session_summary', {'p_cash_session_id': sid}) as Map).cast<String, dynamic>();
      final m = _maps(await Api.rpc('session_movements', {'p_cash_session_id': sid}));
      if (mounted) setState(() { _s = r; _moves = m; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _fail(e));
    }
  }

  int _n(String k) => _i(_s?[k]);

  String _moveLabel(Map<String, dynamic> m) => switch (m['source_type']) {
        'purchase_receipt' => 'مشتريات نقدية',
        'supplier_payment' => 'سداد مورّد',
        'customer_receipt' => 'تحصيل آجل',
        _ => m['type'] == 'refund' ? 'مرتجع نقدي' : ('${m['category'] ?? (m['type'] == 'cash_in' ? 'قبض' : 'مصروف')}'),
      };

  Future<void> _expense() async {
    final sid = widget.ctx.sessionId;
    if (sid == null || !widget.ctx.permissions.contains('cash.movement')) return;
    final done = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => ExpenseDialog(sessionId: sid));
    if (done == true) await _load();
  }

  Future<void> _close() async {
    final sid = widget.ctx.sessionId;
    if (sid == null || !widget.ctx.permissions.contains('cash.close')) return;
    final closed = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => CloseShiftDialog(sessionId: sid));
    if (closed == true) {
      // تقرير الإقفال يُعرض بعد الإقفال بأرقامه النهائية
      try {
        final r = (await Api.rpc('cash_session_summary', {'p_cash_session_id': sid}) as Map).cast<String, dynamic>();
        if (mounted) setState(() => _s = r);
        await _report();
      } catch (_) {}
      widget.onChanged();
    }
  }

  /// تقرير اليومية PDF للعرض والطباعة.
  Future<void> _report() async {
    final s = _s;
    if (s == null) return;
    await _openTemp(
        context,
        () => ReceiptPrinter.tempReport(
              'day-${'${s['session_id']}'.substring(0, 8)}',
              'تقرير اليومية',
              ['الوقت', 'النوع', 'البيان', 'المبلغ'],
              [
                for (final m in _moves)
                  ['${m['at']}'.substring(11, 16), _moveLabel(m), '${m['note'] ?? ''}', formatOmr(_i(m['amount_baisa']))],
              ],
              intro: [
                '${widget.ctx.branchName} — ${widget.ctx.deviceName} — ${s['opened_by_name'] ?? widget.ctx.userName}',
                'اليوم المحاسبي ${s['business_date']} — ${s['status'] == 'closed' ? 'وردية مقفلة' : 'وردية مفتوحة (تقرير مبدئي)'}',
                'عدد الفواتير ${_n('invoice_count')} — إجمالي المبيعات ${formatOmr(_n('total_sales_baisa'))}',
                'نقدي ${formatOmr(_n('cash_sales_baisa'))} · بطاقة ${formatOmr(_n('card_baisa'))} · تحويل ${formatOmr(_n('transfer_baisa'))} · آجل ${formatOmr(_n('credit_baisa'))}',
              ],
              summary: [
                ('الرصيد الافتتاحي', formatOmr(_n('opening_cash_baisa'))),
                ('المبيعات النقدية', formatOmr(_n('cash_sales_baisa'))),
                ('مصروفات وقبض ومرتجعات', formatOmr(_n('cash_other_baisa'))),
                ('المتوقع في الصندوق', formatOmr(_n('expected_cash_baisa'))),
                if (s['counted_cash_baisa'] != null) ('النقد الفعلي بعد العدّ', formatOmr(_n('counted_cash_baisa'))),
                if (s['difference_baisa'] != null) (_n('difference_baisa') == 0 ? 'مطابق' : (_n('difference_baisa') < 0 ? 'عجز' : 'زيادة'), formatOmr(_n('difference_baisa'))),
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.ctx;
    final sid = c.sessionId;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f5): _expense,
        const SingleActivator(LogicalKeyboardKey.f10): _report,
        const SingleActivator(LogicalKeyboardKey.f12): _close,
      },
      child: Focus(
        autofocus: true,
        child: _Page(
          title: 'اليومية — وردية ${c.userName}',
          tools: sid == null
              ? []
              : [
                  const Spacer(),
                  if (c.permissions.contains('cash.movement')) OutlinedButton(onPressed: _expense, child: const Text('مصروف جديد F5')),
                  const SizedBox(width: 6),
                  OutlinedButton(onPressed: _s == null ? null : _report, child: const Text('طباعة التقرير F10')),
                  const SizedBox(width: 6),
                  if (c.permissions.contains('cash.close')) FilledButton(onPressed: _close, child: const Text('إغلاق اليومية F12')),
                ],
          child: sid == null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(c.canOpenShift ? 'لا توجد وردية مفتوحة لحسابك.' : 'الورديات غير مفعّلة لدور هذا الحساب. يفعّلها المالك من الإعدادات.', style: const TextStyle(fontSize: 18, color: Brand.muted)),
                    const SizedBox(height: 14),
                    if (c.canOpenShift) FilledButton(onPressed: widget.onOpenShift, child: const Text('فتح وردية')),
                  ]),
                )
              : _error != null
                  ? _note(_error!, bad: true)
                  : _s == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(padding: const EdgeInsets.all(14), children: [
                          Wrap(spacing: 10, runSpacing: 10, children: [
                            _tileBox('نقدي', formatOmr(_n('cash_sales_baisa')), width: 200),
                            _tileBox('بطاقة', formatOmr(_n('card_baisa')), width: 200),
                            _tileBox('تحويل بنكي', formatOmr(_n('transfer_baisa')), width: 200),
                            _tileBox('آجل', formatOmr(_n('credit_baisa')), width: 200),
                            _tileBox('إجمالي المبيعات (${_n('invoice_count')} فاتورة)', formatOmr(_n('total_sales_baisa')), width: 250),
                          ]),
                          const SizedBox(height: 14),
                          Wrap(spacing: 10, runSpacing: 10, children: [
                            _tileBox('الرصيد الافتتاحي', formatOmr(_n('opening_cash_baisa')), width: 200),
                            _tileBox('± مصروفات وقبض ومرتجعات', formatOmr(_n('cash_other_baisa')), color: _n('cash_other_baisa') < 0 ? Brand.bad : null, width: 250),
                            _tileBox('المتوقع في الصندوق', formatOmr(_n('expected_cash_baisa')), color: Brand.ok, width: 250),
                          ]),
                          _sectionTitle('حركات الدرج غير البيع'),
                          _head([('الوقت', 1), ('النوع', 3), ('البيان', 5), ('المبلغ', 2)]),
                          if (_moves.isEmpty) _note('لا مصروفات ولا قبض في هذه الوردية.'),
                          for (final m in _moves)
                            Container(
                              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                              child: Row(children: [
                                _cell('${m['at']}'.substring(11, 16), flex: 1, num: true),
                                _cell(_moveLabel(m), flex: 3, bold: true),
                                _cell('${m['note'] ?? ''}', flex: 5),
                                _cell(formatOmr(_i(m['amount_baisa'])), flex: 2, num: true, color: _i(m['amount_baisa']) < 0 ? Brand.bad : Brand.ok),
                              ]),
                            ),
                          const SizedBox(height: 12),
                          const Text('عند الإغلاق تُدخل المبلغ الفعلي بعد العدّ ويُسجَّل العجز أو الزيادة، ثم يُعرض تقرير اليومية للطباعة.', style: TextStyle(color: Brand.muted)),
                        ]),
        ),
      ),
    );
  }
}

// ───────────────────────── التقارير: لوحة المالك وتقرير الضريبة ─────────────────────────
class ReportsPage extends StatefulWidget {
  final ShiftContext ctx;
  const ReportsPage({super.key, required this.ctx});
  @override
  State<ReportsPage> createState() => _ReportsState();
}

class _ReportsState extends State<ReportsPage> {
  String _view = 'owner';
  int _days = 0; // 0 اليوم، 6 الأسبوع، 29 الشهر
  int _quarterBack = 0; // 0 = الربع الحالي
  Map<String, dynamic>? _d0, _vat;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  (DateTime, DateTime) _quarter() {
    final now = _muscatNow();
    var y = now.year, q = (now.month - 1) ~/ 3 - _quarterBack;
    while (q < 0) {
      q += 4;
      y -= 1;
    }
    return (DateTime(y, q * 3 + 1, 1), DateTime(y, q * 3 + 4, 0));
  }

  String _quarterLabel() {
    final (from, _) = _quarter();
    return 'الربع ${(from.month - 1) ~/ 3 + 1} / ${from.year}';
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      if (_view == 'owner') {
        final today = _muscatNow();
        final r = (await Api.rpc('owner_dashboard', {'p_from': _dateOf(today.subtract(Duration(days: _days))), 'p_to': _dateOf(today)}) as Map).cast<String, dynamic>();
        if (mounted) setState(() => _d0 = r);
      } else {
        final (from, to) = _quarter();
        final r = (await Api.rpc('vat_report', {'p_branch_id': null, 'p_from': _dateOf(from), 'p_to': _dateOf(to)}) as Map).cast<String, dynamic>();
        if (mounted) setState(() => _vat = r);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _fail(e));
    }
  }

  List<List<String>> _vatRows() => [
        for (final m in _maps(_vat?['months']))
          ['${m['month']}', formatOmr(_i(m['sales_net_baisa'])), formatOmr(_i(m['output_tax_baisa'])), formatOmr(_i(m['purchases_net_baisa'])), formatOmr(_i(m['input_tax_baisa'])),
            formatOmr(_i(m['output_tax_baisa']) - _i(m['input_tax_baisa']))],
      ];

  static const _vatHeader = ['الشهر', 'المبيعات قبل الضريبة', 'ضريبة المخرجات', 'المشتريات قبل الضريبة', 'ضريبة المدخلات', 'الصافي المستحق'];

  Future<void> _vatCsv() async {
    if (_vat == null) return;
    await _openTemp(context, () => ReceiptPrinter.tempCsv('vat-${_dateOf(_quarter().$1)}', _vatHeader, [
          ..._vatRows(),
          ['الإجمالي', formatOmr(_i(_vat!['sales_net_baisa'])), formatOmr(_i(_vat!['output_tax_baisa'])), formatOmr(_i(_vat!['purchases_net_baisa'])), formatOmr(_i(_vat!['input_tax_baisa'])),
            formatOmr(_i(_vat!['net_tax_baisa']))],
        ]));
  }

  Future<void> _vatPdf() async {
    if (_vat == null) return;
    final (from, to) = _quarter();
    await _openTemp(
        context,
        () => ReceiptPrinter.tempReport('vat-${_dateOf(from)}', 'تقرير ضريبة القيمة المضافة', _vatHeader, _vatRows(),
            intro: ['${_quarterLabel()} — من ${_dateOf(from)} إلى ${_dateOf(to)}', 'تقرير داخلي للمراجعة؛ الإقرار الرسمي يُعدّه المحاسب.'],
            summary: [
              ('ضريبة المخرجات (${Currency.symbol})', formatOmr(_i(_vat!['output_tax_baisa']))),
              ('ضريبة المدخلات (${Currency.symbol})', formatOmr(_i(_vat!['input_tax_baisa']))),
              ('صافي الضريبة المستحقة (${Currency.symbol})', formatOmr(_i(_vat!['net_tax_baisa']))),
            ]));
  }

  Widget _owner() {
    final d = _d0!;
    final branches = _maps(d['branches']);
    if (branches.isEmpty) return _note('التقارير متاحة لمدير الفرع والمحاسب والمالك.');
    final total = branches.fold<int>(0, (s, b) => s + _i(b['total_baisa']));
    final net = branches.fold<int>(0, (s, b) => s + _i(b['net_baisa']));
    final count = branches.fold<int>(0, (s, b) => s + _i(b['invoice_count']));
    final profitKnown = branches.every((b) => b['gross_profit_baisa'] != null);
    final profit = branches.fold<int>(0, (s, b) => s + _i(b['gross_profit_baisa']));
    final series = _maps(d['series']);
    final maxDay = series.fold<int>(1, (m, x) => _i(x['total_baisa']) > m ? _i(x['total_baisa']) : m);
    final low = branches.fold<int>(0, (s, b) => s + _i(b['low_stock']));
    return ListView(padding: const EdgeInsets.all(14), children: [
      Wrap(spacing: 10, runSpacing: 10, children: [
        _tileBox('المبيعات شاملة الضريبة', formatOmr(total)),
        _tileBox('صافي المبيعات بعد المرتجعات', formatOmr(net)),
        _tileBox('عدد الفواتير', '$count', width: 160),
        _tileBox('مجمل الربح', profitKnown ? formatOmr(profit) : '—', color: Brand.ok),
        _tileBox('ذمم العملاء (آجل)', formatOmr(_i(d['receivables_baisa'])), color: _i(d['receivables_baisa']) > 0 ? Brand.bad : null),
        _tileBox('مستحق للموردين', formatOmr(_i(d['payables_baisa']))),
      ]),
      _sectionTitle('الفروع'),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final b in branches)
          Container(
            width: 360,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(border: Border.all(color: Brand.line), borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${b['name_ar']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text('المبيعات ${money(_i(b['total_baisa']))}  ·  ${_i(b['invoice_count'])} فاتورة'),
              Text('مجمل الربح ${b['gross_profit_baisa'] == null ? '—' : formatOmr(_i(b['gross_profit_baisa']))}'),
              Text('أصناف منخفضة أو نافدة: ${_i(b['low_stock'])}', style: TextStyle(color: _i(b['low_stock']) > 0 ? const Color(0xFF9A5B00) : Brand.muted)),
            ]),
          ),
      ]),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _sectionTitle('آخر 7 أيام'),
            SizedBox(
              height: 170,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (final x in series)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                        Text(formatOmr(_i(x['total_baisa'])).split('.').first, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12)),
                        Container(height: 4 + 110 * _i(x['total_baisa']) / maxDay, decoration: BoxDecoration(color: Brand.orange, borderRadius: BorderRadius.circular(4))),
                        const SizedBox(height: 4),
                        Text('${x['date']}'.substring(5), textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 12, color: Brand.muted)),
                      ]),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _sectionTitle('الأكثر مبيعًا'),
            for (final t in _maps(d['top_products']))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: Row(children: [
                  _cell('${t['name_ar']}', flex: 5),
                  _cell(_qtyText(t['qty']), flex: 1, num: true),
                  _cell(formatOmr(_i(t['net_baisa'])), flex: 2, num: true, bold: true),
                ]),
              ),
            if (_maps(d['top_products']).isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 14), child: Text('لا مبيعات في الفترة.', style: TextStyle(color: Brand.muted))),
          ]),
        ),
      ]),
      _sectionTitle('تنبيهات'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Text(
            [
              if (low > 0) '• $low صنفًا منخفضًا أو نافدًا — راجع قسم المخزون.',
              if (_i(d['receivables_baisa']) > 0) '• ذمم عملاء آجلة بقيمة ${money(_i(d['receivables_baisa']))}.',
              if (_i(d['payables_baisa']) > 0) '• مستحقات موردين بقيمة ${money(_i(d['payables_baisa']))}.',
              if (low == 0 && _i(d['receivables_baisa']) == 0 && _i(d['payables_baisa']) == 0) 'لا تنبيهات.',
            ].join('\n'),
            style: const TextStyle(fontSize: 15)),
      ),
    ]);
  }

  Widget _vatView() {
    final v = _vat!;
    return Column(children: [
      _head([for (final h in _vatHeader) (h, 2)]),
      Expanded(
        child: ListView(children: [
          if (_vatRows().isEmpty) _note('لا حركة في هذا الربع.'),
          for (final r in _vatRows())
            Container(
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [for (var i = 0; i < r.length; i++) _cell(r[i], flex: 2, num: true, bold: i == 0 || i == 5)]),
            ),
        ]),
      ),
      Container(
        color: Brand.bg,
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Text('ضريبة المخرجات ${formatOmr(_i(v['output_tax_baisa']))}   −   ضريبة المدخلات ${formatOmr(_i(v['input_tax_baisa']))}', style: const TextStyle(fontSize: 15)),
          const Spacer(),
          Text('الصافي المستحق ${money(_i(v['net_tax_baisa']))}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final owner = _view == 'owner';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f9): _vatCsv,
        const SingleActivator(LogicalKeyboardKey.f10): _vatPdf,
      },
      child: Focus(
        autofocus: true,
        child: _Page(
          title: owner ? 'لوحة المالك' : 'ضريبة القيمة المضافة — ${_quarterLabel()}',
          tools: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: 'owner', label: Text('لوحة المالك')), ButtonSegment(value: 'vat', label: Text('تقرير الضريبة'))],
              selected: {_view},
              onSelectionChanged: (s) {
                setState(() => _view = s.first);
                _load();
              },
            ),
            const SizedBox(width: 10),
            if (owner)
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [ButtonSegment(value: 0, label: Text('اليوم')), ButtonSegment(value: 6, label: Text('الأسبوع')), ButtonSegment(value: 29, label: Text('الشهر'))],
                selected: {_days},
                onSelectionChanged: (s) {
                  setState(() { _days = s.first; _d0 = null; });
                  _load();
                },
              )
            else ...[
              OutlinedButton(
                  onPressed: () {
                    setState(() { _quarterBack += 1; _vat = null; });
                    _load();
                  },
                  child: const Text('الربع السابق')),
              const SizedBox(width: 6),
              OutlinedButton(
                  onPressed: _quarterBack == 0
                      ? null
                      : () {
                          setState(() { _quarterBack -= 1; _vat = null; });
                          _load();
                        },
                  child: const Text('الربع التالي')),
              const Spacer(),
              OutlinedButton(onPressed: _vat == null ? null : _vatCsv, child: const Text('تصدير Excel F9')),
              const SizedBox(width: 6),
              FilledButton(onPressed: _vat == null ? null : _vatPdf, child: const Text('طباعة PDF F10')),
            ],
          ],
          child: !widget.ctx.permissions.contains('reports.view')
              ? _note('التقارير متاحة لمدير الفرع والمحاسب والمالك.')
              : _error != null
                  ? _note(_error!, bad: true)
                  : owner
                      ? (_d0 == null ? const Center(child: CircularProgressIndicator()) : _owner())
                      : (_vat == null ? const Center(child: CircularProgressIndicator()) : _vatView()),
        ),
      ),
    );
  }
}

// ───────────────────────── التحويل بين الفرعين ─────────────────────────
class TransferDialog extends StatefulWidget {
  final ShiftContext ctx;
  final Map<String, dynamic> row;
  const TransferDialog({super.key, required this.ctx, required this.row});
  @override
  State<TransferDialog> createState() => _TransferState();
}

class _TransferState extends State<TransferDialog> {
  final _qty = TextEditingController(text: '1'), _note = TextEditingController();
  List<Map<String, dynamic>> _branches = [];
  String? _to, _error;
  String _opId = const Uuid().v4();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      try {
        final r = await Api.client.from('branches').select('id, name_ar').eq('organization_id', widget.ctx.organizationId).neq('id', widget.ctx.branchId).timeout(const Duration(seconds: 12));
        if (mounted) setState(() { _branches = r.cast<Map<String, dynamic>>(); _to = _branches.isEmpty ? null : _branches.first['id'] as String; });
      } catch (_) {
        if (mounted) setState(() => _error = 'تعذّر تحميل الفروع.');
      }
    });
  }

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final q = parseMilli(_qty.text);
    if (q == null || q <= 0) {
      setState(() => _error = 'كمية غير صالحة.');
      return;
    }
    if (_to == null) {
      setState(() => _error = 'اختر الفرع المستلم.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('transfer_stock', {
        'p_operation_id': _opId, 'p_from_branch': widget.ctx.branchId, 'p_to_branch': _to, 'p_product_id': widget.row['product_id'],
        'p_qty': q / 1000, 'p_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _opId = const Uuid().v4();
      _error = e.code == 'INSUFFICIENT_STOCK' ? 'الكمية أكبر من المتوفر في هذا الفرع.' : errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال. اضغط «تحويل» مجددًا للتحقق؛ لن يُسجَّل التحويل مرتين.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('تحويل: ${widget.row['name_ar']}'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('من ${widget.ctx.branchName} — المتوفر ${_qtyText(widget.row['qty'])} ${widget.row['unit']}', style: const TextStyle(color: Brand.muted, fontSize: 16)),
            const SizedBox(height: 12),
            _labeled(
                'إلى الفرع',
                DropdownButton<String?>(
                  value: _to,
                  isExpanded: true,
                  isDense: true,
                  items: [for (final b in _branches) DropdownMenuItem<String?>(value: b['id'] as String, child: Text('${b['name_ar']}'))],
                  onChanged: (v) => setState(() => _to = v),
                )),
            const SizedBox(height: 10),
            _input(_qty, 'الكمية', ltr: true, autofocus: true),
            const SizedBox(height: 10),
            _input(_note, 'ملاحظة (اختياري)'),
            const SizedBox(height: 8),
            const Text('يُخصم من هذا الفرع ويُضاف للفرع المستلم فورًا بالتكلفة نفسها.', style: TextStyle(color: Brand.muted)),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ التحويل…' : 'تحويل')),
        ],
      );
}

// ───────────────────────── الإعدادات ─────────────────────────
const _roleLabels = <String, String>{'owner': 'المالك', 'branch_manager': 'مدير فرع', 'accountant': 'محاسب', 'cashier': 'كاشير'};

class SettingsPage extends StatefulWidget {
  final ShiftContext ctx;
  final VoidCallback? onChanged;
  const SettingsPage({super.key, required this.ctx, this.onChanged});
  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  String _view = 'device';
  // إعدادات الفرع
  final _rate = TextEditingController(), _header = TextEditingController(), _footer = TextEditingController();
  Set<String> _shiftRoles = {'cashier'};
  bool _taxEnabled = false, _inclusive = true, _loaded = false, _busy = false;
  String? _msg;
  bool _msgOk = true;
  // المستخدمون
  List<Map<String, dynamic>>? _users;
  List<Map<String, dynamic>> _branches = [];

  bool get _canSettings => widget.ctx.permissions.contains('settings.manage');
  bool get _canUsers => widget.ctx.permissions.contains('users.manage');
  bool get _canNotify => widget.ctx.permissions.contains('notifications.manage');

  // المنشأة والعملة وصلاحيات الأقسام
  Map<String, dynamic>? _org;
  final _orgName = TextEditingController(), _orgNameEn = TextEditingController(), _taxNo = TextEditingController();
  final _curCode = TextEditingController(), _curSymbol = TextEditingController(), _phoneCode = TextEditingController(), _waMsg = TextEditingController();
  int _decimals = 3;
  bool _symBefore = false, _group = false;
  Map<String, Set<String>> _tabRoles = {};
  bool get _canOrg => _org?['can_manage'] == true;

  Future<void> _loadOrg() async {
    try {
      final r = (await Api.rpc('app_settings', {'p_branch_id': widget.ctx.branchId}) as Map).cast<String, dynamic>();
      final o = ((r['organization'] as Map?) ?? const {}).cast<String, dynamic>();
      final c = ((r['currency'] as Map?) ?? const {}).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _org = r;
        _orgName.text = '${o['name_ar'] ?? ''}';
        _orgNameEn.text = '${o['name_en'] ?? ''}';
        _taxNo.text = '${o['tax_registration_no'] ?? ''}';
        _curCode.text = '${c['code'] ?? 'OMR'}';
        _curSymbol.text = '${c['symbol'] ?? ''}';
        _decimals = _i(c['decimals'] ?? 3);
        _symBefore = c['symbol_before'] == true;
        _group = c['thousands_separator'] == true;
        _phoneCode.text = '${r['phone_country_code'] ?? '968'}';
        _waMsg.text = '${r['whatsapp_message_ar'] ?? ''}';
        _tabRoles = {
          for (final e in ((r['tab_roles'] as Map?) ?? const {}).entries) '${e.key}': ((e.value as List?) ?? const []).map((x) => '$x').toSet(),
        };
      });
    } catch (e) {
      if (mounted) setState(() { _msg = _fail(e); _msgOk = false; _org = const {}; });
    }
  }

  Future<void> _saveOrg(Map<String, dynamic> patch, String done) async {
    setState(() { _busy = true; _msg = null; });
    try {
      await Api.rpc('update_org_settings', {'p_organization_id': widget.ctx.organizationId, 'p': patch});
      await _loadOrg();
      _msg = done;
      _msgOk = true;
      widget.onChanged?.call(); // يعيد تحميل العملة والأقسام الظاهرة
    } catch (e) {
      _msg = _fail(e);
      _msgOk = false;
    }
    if (mounted) setState(() => _busy = false);
  }

  void _saveOrgIdentity() {
    final code = _curCode.text.trim().toUpperCase(), symbol = _curSymbol.text.trim(), phone = _phoneCode.text.trim();
    if (_orgName.text.trim().isEmpty || !RegExp(r'^[A-Z]{3}$').hasMatch(code) || symbol.isEmpty || symbol.length > 8 || !RegExp(r'^[0-9]{1,4}$').hasMatch(phone)) {
      setState(() { _msg = 'تحقق من الاسم، ورمز العملة الدولي (ثلاثة أحرف مثل OMR)، ورمز العرض (حتى 8 أحرف)، ومفتاح الدولة (أرقام فقط).'; _msgOk = false; });
      return;
    }
    _saveOrg({
      'name_ar': _orgName.text.trim(), 'name_en': _orgNameEn.text.trim(), 'tax_registration_no': _taxNo.text.trim(),
      'currency_code': code, 'currency_symbol': symbol, 'currency_decimals': _decimals, 'symbol_before': _symBefore, 'thousands_separator': _group,
      'phone_country_code': phone, 'whatsapp_message_ar': _waMsg.text.trim(),
    }, 'حُفظت إعدادات المنشأة والعملة.');
  }

  String _sample(int baisa) {
    final unit = const [1000, 100, 10, 1][_decimals], pow = 1000 ~/ unit, scaled = (baisa * 2 + unit) ~/ (unit * 2);
    var whole = '${scaled ~/ pow}';
    if (_group) whole = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    final n = _decimals == 0 ? whole : '$whole.${(scaled % pow).toString().padLeft(_decimals, '0')}';
    final sym = _curSymbol.text.trim();
    return _symBefore ? '$sym $n' : '$n $sym';
  }

  Widget _section(String t) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)));
  Widget _fields(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (i, w) in children.indexed) ...[if (i > 0) const SizedBox(width: 12), Expanded(child: w)],
        ]),
      );
  Widget _check(String label, bool value, ValueChanged<bool>? onChanged) => Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(value: value, onChanged: onChanged == null ? null : (v) => onChanged(v ?? false)),
        Flexible(child: Text(label)),
      ]);
  Widget _status() => _msg == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg!, style: TextStyle(color: _msgOk ? Brand.ok : Brand.bad, fontSize: 16)));

  Widget _orgView() {
    if (_org == null) return const Center(child: CircularProgressIndicator());
    final e = _canOrg && !_busy;
    return ListView(padding: const EdgeInsets.all(18), children: [
      if (!_canOrg) const Padding(padding: EdgeInsets.only(bottom: 10), child: Text('للعرض فقط: بيانات المنشأة والعملة يغيّرها المالك.', style: TextStyle(color: Color(0xFF9A5B00), fontWeight: FontWeight.w600))),
      _section('بيانات المنشأة'),
      _fields([_input(_orgName, 'اسم المنشأة بالعربية', enabled: e), _input(_orgNameEn, 'الاسم بالإنجليزية', ltr: true, enabled: e), _input(_taxNo, 'الرقم الضريبي', ltr: true, enabled: e)]),
      const Divider(height: 28),
      _section('العملة وصيغة المبالغ'),
      _fields([
        _input(_curCode, 'رمز العملة الدولي (مثل OMR)', ltr: true, enabled: e),
        _input(_curSymbol, 'الرمز الظاهر في الشاشات والفواتير', enabled: e, onChanged: (_) => setState(() {})),
        _labeled(
            'الخانات العشرية',
            DropdownButton<int>(
              value: _decimals,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 3, child: Text('3 خانات — 12.500')),
                DropdownMenuItem(value: 2, child: Text('خانتان — 12.50')),
                DropdownMenuItem(value: 1, child: Text('خانة واحدة — 12.5')),
                DropdownMenuItem(value: 0, child: Text('بلا كسور — 13')),
              ],
              onChanged: e ? (v) => setState(() => _decimals = v ?? 3) : null,
            )),
      ]),
      Wrap(spacing: 22, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _check('فاصل الآلاف (1,250)', _group, e ? (v) => setState(() => _group = v) : null),
        _check('الرمز قبل المبلغ', _symBefore, e ? (v) => setState(() => _symBefore = v) : null),
        Text('مثال: ${_sample(1250500)}', textDirection: TextDirection.rtl, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 6),
      const Text('المبالغ تُحفظ وتُحسب دائمًا بثلاث خانات؛ هذا الإعداد يحدد ما يُعرض ويُطبع وما يُقبل في الإدخال. تقليل الخانات يقرّب المعروض فقط، فأبقِ ثلاث خانات للريال العُماني.', style: TextStyle(color: Brand.muted)),
      const Divider(height: 28),
      _section('الهاتف وواتساب'),
      _fields([
        _input(_phoneCode, 'مفتاح الدولة للأرقام المحلية (968)', ltr: true, enabled: e),
        const SizedBox.shrink(),
        const SizedBox.shrink(),
      ]),
      TextField(
        controller: _waMsg,
        enabled: e,
        minLines: 3,
        maxLines: 6,
        maxLength: 600,
        decoration: const InputDecoration(
          labelText: 'نص رسالة واتساب عند إرسال الفاتورة (اتركه فارغًا للنص الافتراضي)',
          helperText: 'الرموز المتاحة: {customer} {branch} {invoice} {date} {total} {currency} {warranty} {pdf} {phone}',
          alignLabelWithHint: true,
        ),
      ),
      const SizedBox(height: 12),
      if (_canOrg) Align(alignment: AlignmentDirectional.centerStart, child: FilledButton(onPressed: _busy ? null : _saveOrgIdentity, child: Text(_busy ? 'جارٍ الحفظ…' : 'حفظ'))),
      _status(),
    ]);
  }

  static const _tabLabels = <String, String>{
    'sale': 'البيع', 'customers': 'العملاء', 'inventory': 'المخزون', 'purchases': 'المشتريات', 'day': 'اليومية', 'reports': 'التقارير', 'settings': 'الإعدادات',
  };

  Widget _accessView() {
    if (_org == null) return const Center(child: CircularProgressIndicator());
    final e = _canOrg && !_busy;
    return ListView(padding: const EdgeInsets.all(18), children: [
      Text(_canOrg ? 'حدّد الأقسام التي تظهر لكل دور. المالك يرى كل الأقسام دائمًا.' : 'للعرض فقط: صلاحيات الأقسام يحددها المالك.', style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Table(
        border: const TableBorder(horizontalInside: BorderSide(color: Brand.line)),
        columnWidths: const {0: FixedColumnWidth(190)},
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(children: [
            const Padding(padding: EdgeInsets.all(8), child: Text('القسم', style: TextStyle(fontWeight: FontWeight.w800))),
            for (final r in _roleLabels.values) Padding(padding: const EdgeInsets.all(8), child: Text(r, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800))),
          ]),
          for (final t in _tabLabels.entries)
            TableRow(children: [
              Padding(padding: const EdgeInsets.all(8), child: Text(t.value, style: const TextStyle(fontSize: 16))),
              for (final r in _roleLabels.keys)
                Center(
                  child: Checkbox(
                    value: r == 'owner' || (_tabRoles[t.key]?.contains(r) ?? false),
                    onChanged: e && r != 'owner'
                        ? (v) => setState(() {
                              final set = _tabRoles.putIfAbsent(t.key, () => <String>{});
                              v == true ? set.add(r) : set.remove(r);
                            })
                        : null,
                  ),
                ),
            ]),
        ],
      ),
      const SizedBox(height: 10),
      const Text('هذا الإعداد يحدد ما يظهر في الشريط العلوي. العمليات نفسها (الخصم، الاستلام، المرتجع…) تبقى محكومة بصلاحيات الدور في الخادم، ودور كل مستخدم يُضبط من «المستخدمون».', style: TextStyle(color: Brand.muted)),
      const SizedBox(height: 14),
      if (_canOrg)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            onPressed: _busy ? null : () => _saveOrg({'tab_roles': {for (final t in _tabLabels.keys) t: (_tabRoles[t] ?? const <String>{}).toList()}}, 'حُفظت صلاحيات الأقسام. تُطبَّق عند دخول كل مستخدم.'),
            child: Text(_busy ? 'جارٍ الحفظ…' : 'حفظ صلاحيات الأقسام'),
          ),
        ),
      _status(),
    ]);
  }

  // الإشعارات والربط
  Map<String, dynamic>? _notify;
  final _waPhoneId = TextEditingController(), _waToken = TextEditingController(), _waTemplate = TextEditingController(), _waLang = TextEditingController();
  final _smsUser = TextEditingController(), _smsPass = TextEditingController(), _smsHeader = TextEditingController(), _smsText = TextEditingController();
  final _brUrl = TextEditingController(), _brKey = TextEditingController(), _brHook = TextEditingController(), _waParams = TextEditingController();
  String _provider = 'cloud';

  Future<void> _loadNotify() async {
    try {
      final r = (await Api.rpc('notification_overview', {'p_organization_id': widget.ctx.organizationId}) as Map).cast<String, dynamic>();
      final st = ((r['settings'] as Map?) ?? const {}).cast<String, dynamic>();
      final link = ((r['link'] as Map?) ?? const {}).cast<String, dynamic>();
      _waPhoneId.text = '${link['whatsapp_phone_id'] ?? ''}';
      _waTemplate.text = '${st['whatsapp_template'] ?? ''}';
      _waLang.text = '${st['whatsapp_lang'] ?? ''}';
      _smsUser.text = '${link['sms_user'] ?? ''}';
      _smsHeader.text = '${link['sms_header'] ?? ''}';
      _smsText.text = '${st['sms_text_ar'] ?? ''}';
      _waToken.clear();
      _smsPass.clear();
      _brKey.clear();
      _brHook.clear();
      _brUrl.text = '${link['bridge_url'] ?? ''}';
      _waParams.text = '${st['whatsapp_params'] ?? 'customer,invoice,total'}';
      _provider = st['whatsapp_provider'] == 'bridge' ? 'bridge' : 'cloud';
      if (mounted) setState(() => _notify = r);
    } catch (e) {
      if (mounted) setState(() { _msg = _fail(e); _msgOk = false; _notify = const {}; });
    }
  }

  Future<void> _setNotify(Map<String, dynamic> patch) async {
    try {
      await Api.rpc('update_notification_settings', {'p_organization_id': widget.ctx.organizationId, 'p': patch});
      await _loadNotify();
    } catch (e) {
      if (mounted) setState(() { _msg = _fail(e); _msgOk = false; });
    }
  }

  Future<void> _runWorker() async {
    setState(() { _busy = true; _msg = null; });
    try {
      final res = await Api.client.functions.invoke('notify-worker', body: {'organization_id': widget.ctx.organizationId}).timeout(const Duration(seconds: 60));
      final d = res.data;
      if (d is Map && d['error'] == null) {
        _msg = 'عولج ${d['processed']}: أُرسل ${d['sent']} · تجريبي بلا إرسال ${d['mock']} · فشل ${d['failed']}';
        _msgOk = true;
      } else {
        _msg = 'رفض الخادم الطلب.';
        _msgOk = false;
      }
    } catch (_) {
      _msg = 'تعذّر تشغيل عامل الإشعارات. تحقق من الاتصال ومن نشر دالة notify-worker.';
      _msgOk = false;
    }
    if (mounted) setState(() => _busy = false);
    await _loadNotify();
  }

  /// يحفظ بيانات الربط. الحقول السرية (الرمز وكلمة المرور) تُرسل فقط إذا كُتبت؛ الفارغ يعني «أبقِ المحفوظ».
  Future<void> _saveLink() async {
    final params = _waParams.text.replaceAll(' ', '').toLowerCase();
    String? bad;
    if (_brUrl.text.trim().isNotEmpty && !_brUrl.text.trim().startsWith('https://')) bad = 'رابط الـ Bridge يبدأ بـ https://';
    if (!RegExp(r'^(customer|invoice|total|currency|branch|date)(,(customer|invoice|total|currency|branch|date)){0,9}$').hasMatch(params)) {
      bad = 'متغيرات القالب: أسماء مفصولة بفواصل من customer, invoice, total, currency, branch, date';
    }
    if (bad != null) {
      setState(() { _msg = bad; _msgOk = false; });
      return;
    }
    setState(() { _busy = true; _msg = null; });
    try {
      await Api.rpc('set_notification_credentials', {
        'p_organization_id': widget.ctx.organizationId,
        'p': {
          'whatsapp_phone_id': _waPhoneId.text.trim(), 'sms_user': _smsUser.text.trim(), 'sms_header': _smsHeader.text.trim(),
          'bridge_url': _brUrl.text.trim(),
          if (_brKey.text.trim().isNotEmpty) 'bridge_api_key': _brKey.text.trim(),
          if (_brHook.text.trim().isNotEmpty) 'bridge_webhook_secret': _brHook.text.trim(),
          if (_waToken.text.trim().isNotEmpty) 'whatsapp_token': _waToken.text.trim(),
          if (_smsPass.text.trim().isNotEmpty) 'sms_password': _smsPass.text.trim(),
        }
      });
      await Api.rpc('update_notification_settings', {
        'p_organization_id': widget.ctx.organizationId,
        'p': {'whatsapp_template': _waTemplate.text.trim(), 'whatsapp_lang': _waLang.text.trim(), 'sms_text_ar': _smsText.text.trim(), 'whatsapp_provider': _provider, 'whatsapp_params': params}
      });
      await _loadNotify();
      _msg = 'حُفظت بيانات الربط.';
      _msgOk = true;
    } catch (e) {
      _msg = _fail(e);
      _msgOk = false;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _unlink(String what) async {
    setState(() { _busy = true; _msg = null; });
    try {
      await Api.rpc('set_notification_credentials', {
        'p_organization_id': widget.ctx.organizationId,
        'p': switch (what) {
          'whatsapp' => {'whatsapp_token': '', 'whatsapp_phone_id': ''},
          'bridge' => {'bridge_url': '', 'bridge_api_key': '', 'bridge_webhook_secret': ''},
          _ => {'sms_user': '', 'sms_password': '', 'sms_header': ''},
        }
      });
      await _loadNotify();
      _msg = 'أُلغي الربط.';
      _msgOk = true;
    } catch (e) {
      _msg = _fail(e);
      _msgOk = false;
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _badge(bool ok, String yes, String no) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: (ok ? Brand.ok : Brand.muted).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(ok ? yes : no, style: TextStyle(color: ok ? Brand.ok : Brand.muted, fontWeight: FontWeight.w700)),
      );

  Widget _secret(TextEditingController c, String label, bool saved, bool enabled) => TextField(
        controller: c,
        enabled: enabled,
        obscureText: true,
        textDirection: TextDirection.ltr,
        decoration: InputDecoration(labelText: label, isDense: true, hintText: saved ? 'محفوظ — اتركه فارغًا للإبقاء عليه' : null),
      );

  Widget _notifyView() {
    if (!_canNotify) return _note('إعدادات واتساب والرسائل للمالك.');
    final n = _notify;
    if (n == null) return const Center(child: CircularProgressIndicator());
    final st = ((n['settings'] as Map?) ?? const {}).cast<String, dynamic>();
    final link = ((n['link'] as Map?) ?? const {}).cast<String, dynamic>();
    final e = link['can_edit'] == true && !_busy;
    final hasWa = link['has_whatsapp'] == true, hasSms = link['has_sms'] == true, hasBridge = link['has_bridge'] == true;
    final hookUrl = '${Api.config.supabaseUrl}/functions/v1/bridge-webhook?org=${widget.ctx.organizationId}';
    const statusLabels = {'pending': 'معلّق', 'sent': 'أُرسل', 'mock': 'تجريبي (لم يُرسل)', 'failed': 'فشل'};
    const deliveryLabels = {'sent': 'أُرسل', 'delivered': 'وصل', 'read': 'قُرئ', 'failed': 'فشل التسليم'};
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _section('زر واتساب في شاشة البيع'),
          const Text('يعمل بلا ربط: يفتح محادثة العميل في واتساب ويب المفتوح على هذا الجهاز بحساب المحل، ومعه رابط الفاتورة PDF. نص الرسالة يُعدَّل من «المنشأة والعملة».', style: TextStyle(color: Brand.muted)),
          const Divider(height: 28),
          _section('الإرسال الآلي عبر واتساب'),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'bridge', label: Text('Smart WhatsApp Bridge')),
                ButtonSegment(value: 'cloud', label: Text('WhatsApp Cloud API مباشرة')),
              ],
              selected: {_provider},
              onSelectionChanged: e ? (v) => setState(() => _provider = v.first) : null,
            ),
          ),
          const SizedBox(height: 12),
          if (_provider == 'bridge') ...[
            Row(children: [const Expanded(child: Text('بيانات الـ Bridge', style: TextStyle(fontWeight: FontWeight.w700))), _badge(hasBridge, 'مربوط', 'غير مربوط')]),
            const SizedBox(height: 8),
            _fields([
              _input(_brUrl, 'رابط الـ API الأساسي (Base URL)', ltr: true, enabled: e),
              _secret(_brKey, 'مفتاح الـ API (X-API-Key)', hasBridge, e),
            ]),
            _fields([
              _labeled('عنوان استقبال حالة التسليم — سجّله في الـ Bridge', SelectableText(hookUrl, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 13))),
              _secret(_brHook, 'سر الـ Webhook (يظهر مرة واحدة عند تسجيل العنوان)', link['has_bridge_webhook'] == true, e),
            ]),
          ] else ...[
            Row(children: [const Expanded(child: Text('بيانات Meta', style: TextStyle(fontWeight: FontWeight.w700))), _badge(hasWa, 'مربوط', 'غير مربوط')]),
            const SizedBox(height: 8),
            _fields([
              _input(_waPhoneId, 'معرّف رقم الهاتف (Phone number ID)', ltr: true, enabled: e),
              _secret(_waToken, 'رمز الوصول الدائم (Access token)', hasWa, e),
            ]),
          ],
          _fields([
            _input(_waTemplate, 'اسم القالب المعتمد', ltr: true, enabled: e),
            if (_provider == 'cloud') _input(_waLang, 'لغة القالب (ar أو en)', ltr: true, enabled: e),
            _input(_waParams, 'متغيرات القالب بالترتيب', ltr: true, enabled: e),
          ]),
          const Text('القالب يُنشأ ويُعتمد من Meta (من قسم القوالب في الـ Bridge). متغيراته {{1}} {{2}}… تُملأ بالترتيب المكتوب أعلاه، من: customer (العميل)، invoice (رقم الفاتورة)، total (الإجمالي)، currency (العملة)، branch (الفرع)، date (التاريخ).', style: TextStyle(color: Brand.muted)),
          const Divider(height: 28),
          Row(children: [Expanded(child: _section('الرسائل النصية القصيرة (iSmartSMS)')), _badge(hasSms, 'مربوط', 'غير مربوط')]),
          _fields([
            _input(_smsUser, 'اسم المستخدم', ltr: true, enabled: e),
            _secret(_smsPass, 'كلمة المرور', hasSms, e),
            _input(_smsHeader, 'اسم المرسل المعتمد (Sender ID)', ltr: true, enabled: e),
          ]),
          TextField(
            controller: _smsText,
            enabled: e,
            maxLength: 300,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'نص الرسالة النصية (فارغ = النص الافتراضي)',
              helperText: 'الرموز: {customer} {branch} {invoice} {total} {currency}',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          if (link['can_edit'] == true)
            Wrap(spacing: 10, runSpacing: 8, children: [
              FilledButton(onPressed: _busy ? null : _saveLink, child: Text(_busy ? 'جارٍ الحفظ…' : 'حفظ بيانات الربط')),
              if (hasBridge) OutlinedButton(onPressed: _busy ? null : () => _unlink('bridge'), child: const Text('إلغاء ربط الـ Bridge')),
              if (hasWa) OutlinedButton(onPressed: _busy ? null : () => _unlink('whatsapp'), child: const Text('إلغاء ربط Meta')),
              if (hasSms) OutlinedButton(onPressed: _busy ? null : () => _unlink('sms'), child: const Text('إلغاء ربط الرسائل')),
            ])
          else
            const Text('بيانات الربط يدخلها المالك.', style: TextStyle(color: Color(0xFF9A5B00), fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('الرموز وكلمات المرور تُحفظ في الخادم ولا تُعرض بعد الحفظ ولا تصل إلى أي جهاز.', style: TextStyle(color: Brand.muted)),
          const Divider(height: 28),
          _section('التشغيل'),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: st['enabled'] == true, onChanged: (v) => _setNotify({'enabled': v ?? false})),
            const Text('إرسال إشعار الفاتورة للعميل آليًا'),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: st['whatsapp_enabled'] != false, onChanged: (v) => _setNotify({'whatsapp_enabled': v ?? false})),
            const Text('عبر واتساب'),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: st['sms_fallback'] == true, onChanged: (v) => _setNotify({'sms_fallback': v ?? false})),
            const Text('رسالة نصية عند تعذّر واتساب أو إيقافه'),
          ]),
          Text('معلّق: ${_i(n['pending'])}', style: const TextStyle(fontWeight: FontWeight.w700)),
          FilledButton(onPressed: _busy ? null : _runWorker, child: Text(_busy ? 'جارٍ المعالجة…' : 'معالجة المعلّق الآن')),
        ]),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: Text('الإرسال الفعلي يتطلب التفعيل هنا ووجود ربط واتساب (الـ Bridge أو Meta) أو الرسائل أعلاه. بدونهما تُسجَّل الرسائل «تجريبي» ولا يصل شيء لأي عميل.', style: TextStyle(color: Brand.muted)),
      ),
      if (_msg != null) Padding(padding: const EdgeInsets.all(14), child: Text(_msg!, style: TextStyle(color: _msgOk ? Brand.ok : Brand.bad, fontSize: 16))),
      const SizedBox(height: 8),
      _head([('الوقت', 2), ('العميل', 3), ('الفاتورة', 3), ('الحالة', 2), ('القناة', 1), ('ملاحظة', 3)]),
      for (final ev in _maps(n['events']))
        Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [
            _cell('${ev['created_at']}'.substring(0, 16).replaceFirst('T', ' '), flex: 2, num: true),
            _cell('${ev['customer'] ?? ''}', flex: 3),
            _cell('${ev['invoice_no'] ?? ''}', flex: 3, num: true),
            _cell(deliveryLabels[ev['delivery_status']] ?? statusLabels[ev['status']] ?? '${ev['status']}', flex: 2, bold: true),
            _cell('${ev['channel'] ?? '—'}', flex: 1),
            _cell('${ev['last_error'] ?? ''}', flex: 3),
          ]),
        ),
    ]);
  }

  @override
  void dispose() {
    for (final c in [_rate, _header, _footer, _orgName, _orgNameEn, _taxNo, _curCode, _curSymbol, _phoneCode, _waMsg,
      _waPhoneId, _waToken, _waTemplate, _waLang, _smsUser, _smsPass, _smsHeader, _smsText, _brUrl, _brKey, _brHook, _waParams]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadBranch() async {
    try {
      final s = await Api.client.from('branch_settings').select().eq('branch_id', widget.ctx.branchId).maybeSingle().timeout(const Duration(seconds: 12));
      if (s == null || !mounted) return;
      setState(() {
        _shiftRoles = ((s['shift_roles'] as List?) ?? const ['cashier']).cast<String>().toSet();
        _taxEnabled = s['tax_enabled'] == true;
        _inclusive = s['prices_include_tax'] == true;
        _rate.text = formatQty(_i(s['tax_rate_bp']) * 10);
        _header.text = '${s['receipt_header_ar'] ?? ''}';
        _footer.text = '${s['receipt_footer_ar'] ?? ''}';
        _loaded = true;
        _msg = null;
      });
    } catch (_) {
      if (mounted) setState(() { _msg = 'تعذّر تحميل إعدادات الفرع.'; _msgOk = false; });
    }
  }

  Future<void> _saveBranch() async {
    final rate = parseMilli(_rate.text); // نسبة مئوية بثلاث خانات → جزء من عشرة آلاف
    if (rate == null || rate > 100000) {
      setState(() { _msg = 'نسبة الضريبة غير صالحة.'; _msgOk = false; });
      return;
    }
    setState(() { _busy = true; _msg = null; });
    try {
      await Api.rpc('update_branch_settings', {
        'p_branch_id': widget.ctx.branchId,
        'p_settings': {
          if (_canUsers) 'shift_roles': _shiftRoles.toList(), 'tax_enabled': _taxEnabled, 'tax_rate_bp': rate ~/ 10, 'prices_include_tax': _inclusive,
          'receipt_header_ar': _header.text.trim(), 'receipt_footer_ar': _footer.text.trim(),
        }
      });
      _msg = 'حُفظت إعدادات الفرع. تُطبَّق على الفواتير التالية.';
      _msgOk = true;
      widget.onChanged?.call();
    } catch (e) {
      _msg = _fail(e);
      _msgOk = false;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _loadUsers() async {
    try {
      final u = _maps(await Api.rpc('list_users', {'p_organization_id': widget.ctx.organizationId}));
      final b = await Api.client.from('branches').select('id, name_ar').eq('organization_id', widget.ctx.organizationId).timeout(const Duration(seconds: 12));
      if (mounted) setState(() { _users = u; _branches = b.cast<Map<String, dynamic>>(); _msg = null; });
    } catch (e) {
      if (mounted) setState(() { _msg = _fail(e); _msgOk = false; _users = const []; });
    }
  }

  Future<void> _editUser(Map<String, dynamic>? user) async {
    final done = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => UserDialog(ctx: widget.ctx, branches: _branches, user: user));
    if (done == true) await _loadUsers();
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [SizedBox(width: 220, child: Text(k, style: const TextStyle(color: Brand.muted, fontSize: 16))), Expanded(child: Text(v, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)))]),
      );

  Widget _device() {
    final c = widget.ctx;
    return ListView(padding: const EdgeInsets.all(18), children: [
      _kv('الفرع', c.branchName),
      _kv('الصندوق', '${c.deviceName} (${Api.config.deviceCode})'),
      _kv('المستخدم', c.userName),
      _kv('الورديات لهذا الحساب', c.canOpenShift ? 'مفعّلة' : 'غير مفعّلة — للاطلاع فقط'),
      _kv('الاتصال', 'النظام يعمل بالإنترنت فقط'),
      const SizedBox(height: 14),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton(onPressed: () => showDialog<void>(context: context, builder: (_) => const PrinterSettingsDialog()), child: const Text('الطابعة ونوعها (حرارية 80 مم أو A4)')),
      ),
      const SizedBox(height: 18),
      const Text('الاختصارات: Alt+1 إلى Alt+7 للتنقل بين الأقسام. مفاتيح كل شاشة مكتوبة على أزرارها وفي الشريط السفلي لشاشة البيع.', style: TextStyle(color: Brand.muted)),
    ]);
  }

  Widget _branch() {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final e = _canSettings && !_busy;
    return ListView(padding: const EdgeInsets.all(18), children: [
      if (!_canSettings) const Padding(padding: EdgeInsets.only(bottom: 10), child: Text('للعرض فقط: إعدادات الفرع يغيّرها المالك أو مدير الفرع.', style: TextStyle(color: Color(0xFF9A5B00), fontWeight: FontWeight.w600))),
      Text('من يفتح الورديات (ويصدر الفواتير) في هذا الفرع${_canUsers ? '' : ' — يحدده المالك'}', style: const TextStyle(fontWeight: FontWeight.w800)),
      Wrap(spacing: 14, children: [
        for (final r in _roleLabels.entries)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(
                value: _shiftRoles.contains(r.key),
                onChanged: e && _canUsers && r.key != 'cashier' ? (v) => setState(() => v == true ? _shiftRoles.add(r.key) : _shiftRoles.remove(r.key)) : null),
            Text(r.value),
          ]),
      ]),
      const Divider(height: 28),
      const Text('الضريبة', style: TextStyle(fontWeight: FontWeight.w800)),
      Row(children: [
        Checkbox(value: _taxEnabled, onChanged: e ? (v) => setState(() => _taxEnabled = v ?? false) : null),
        const Text('ضريبة القيمة المضافة مفعّلة'),
        const SizedBox(width: 20),
        SizedBox(width: 130, child: _input(_rate, 'النسبة %', ltr: true, enabled: e)),
        const SizedBox(width: 20),
        Checkbox(value: _inclusive, onChanged: e ? (v) => setState(() => _inclusive = v ?? true) : null),
        const Text('الأسعار شاملة الضريبة'),
      ]),
      const Divider(height: 28),
      const Text('الفاتورة', style: TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      _input(_header, 'عنوان الفاتورة (اسم المحل كما يُطبع)', enabled: e),
      const SizedBox(height: 10),
      _input(_footer, 'تذييل الفاتورة (شكر، سياسة الاسترجاع…)', enabled: e),
      const SizedBox(height: 16),
      if (_canSettings) Align(alignment: AlignmentDirectional.centerStart, child: FilledButton(onPressed: _busy ? null : _saveBranch, child: Text(_busy ? 'جارٍ الحفظ…' : 'حفظ إعدادات الفرع'))),
      if (_msg != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg!, style: TextStyle(color: _msgOk ? Brand.ok : Brand.bad, fontSize: 16))),
    ]);
  }

  Widget _usersView() {
    if (!_canUsers) return _note('إدارة المستخدمين والصلاحيات للمالك.');
    if (_users == null) return const Center(child: CircularProgressIndicator());
    return Column(children: [
      _head([('الاسم', 3), ('اسم المستخدم', 2), ('الدور', 2), ('الفرع', 2), ('حد الخصم', 1), ('الحالة', 1), ('', 1)]),
      Expanded(
        child: ListView(children: [
          if (_msg != null && !_msgOk) _note(_msg!, bad: true),
          for (final u in _users!)
            Container(
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Builder(builder: (_) {
                final ms = _maps(u['memberships']);
                final m = ms.isEmpty ? const <String, dynamic>{} : ms.first;
                return Row(children: [
                  _cell('${u['full_name']}', flex: 3, bold: true),
                  _cell('${u['username'] ?? ''}', flex: 2, num: true),
                  _cell(_roleLabels[m['role_code']] ?? '${m['role_code'] ?? '—'}', flex: 2),
                  _cell('${m['branch_name'] ?? 'كل الفروع'}', flex: 2),
                  _cell('${formatQty(_i(m['max_discount_bp']) * 10)}%', flex: 1, num: true),
                  _cell(u['is_active'] == true ? 'فعّال' : 'موقوف', flex: 1, color: u['is_active'] == true ? Brand.ok : Brand.bad),
                  Expanded(flex: 1, child: TextButton(onPressed: () => _editUser(u), child: const Text('تعديل'))),
                ]);
              }),
            ),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => _Page(
        title: 'الإعدادات',
        tools: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'device', label: Text('الجهاز والطباعة')),
              ButtonSegment(value: 'org', label: Text('المنشأة والعملة')),
              ButtonSegment(value: 'branch', label: Text('الفرع والضريبة والفاتورة')),
              ButtonSegment(value: 'users', label: Text('المستخدمون')),
              ButtonSegment(value: 'access', label: Text('صلاحيات الأقسام')),
              ButtonSegment(value: 'notify', label: Text('واتساب والرسائل')),
            ],
            selected: {_view},
            onSelectionChanged: (s) {
              setState(() { _view = s.first; _msg = null; });
              if (_view == 'branch' && !_loaded) _loadBranch();
              if (_view == 'org' || _view == 'access') _loadOrg();
              if (_view == 'users' && _canUsers) _loadUsers();
              if (_view == 'notify' && _canNotify) _loadNotify();
            },
          ),
          const Spacer(),
          if (_view == 'users' && _canUsers) FilledButton(onPressed: () => _editUser(null), child: const Text('مستخدم جديد')),
        ],
        child: switch (_view) { 'org' => _orgView(), 'access' => _accessView(), 'branch' => _branch(), 'users' => _usersView(), 'notify' => _notifyView(), _ => _device() },
      );
}

/// مستخدم جديد (اسم مستخدم ورقم سري 8 خانات على الأقل) أو تعديل دور مستخدم قائم وفرعه وحدّ خصمه وحالته.
class UserDialog extends StatefulWidget {
  final ShiftContext ctx;
  final List<Map<String, dynamic>> branches;
  final Map<String, dynamic>? user;
  const UserDialog({super.key, required this.ctx, required this.branches, this.user});
  @override
  State<UserDialog> createState() => _UserState();
}

class _UserState extends State<UserDialog> {
  final _name = TextEditingController(), _username = TextEditingController(), _password = TextEditingController(), _disc = TextEditingController(text: '0');
  String _role = 'cashier';
  String? _branch, _error;
  bool _active = true, _busy = false;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _branch = widget.ctx.branchId;
    if (u != null) {
      final ms = _maps(u['memberships']);
      _name.text = '${u['full_name']}';
      _username.text = '${u['username'] ?? ''}';
      _active = u['is_active'] == true;
      if (ms.isNotEmpty) {
        _role = _roleLabels.containsKey(ms.first['role_code']) ? ms.first['role_code'] as String : 'cashier';
        _branch = ms.first['branch_id'] as String?;
        _disc.text = formatQty(_i(ms.first['max_discount_bp']) * 10);
      }
    }
    if (_branch != null && !widget.branches.any((b) => b['id'] == _branch)) _branch = null;
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    _disc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final isNew = widget.user == null;
    final disc = parseMilli(_disc.text.trim().isEmpty ? '0' : _disc.text);
    String? err;
    if (_name.text.trim().isEmpty) err = 'الاسم مطلوب.';
    if (err == null && isNew && !RegExp(r'^[a-z0-9._-]{3,30}$').hasMatch(_username.text.trim().toLowerCase())) err = 'اسم المستخدم بحروف إنجليزية وأرقام (3 خانات على الأقل)، مثل cashier.2';
    if (err == null && (isNew || _password.text.isNotEmpty) && _password.text.length < 8) err = 'الرقم السري ثماني خانات على الأقل.';
    if (err == null && (disc == null || disc > 100000)) err = 'حد الخصم نسبة بين 0 و100.';
    if (err == null && (_role == 'cashier' || _role == 'branch_manager') && _branch == null) err = 'اختر فرع الكاشير أو مدير الفرع.';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() { _busy = true; _error = null; });
    final role = {
      'organization_id': widget.ctx.organizationId, 'full_name': _name.text.trim(), 'role_code': _role,
      'branch_id': (_role == 'owner' || _role == 'accountant') ? null : _branch, 'max_discount_bp': disc! ~/ 10, 'is_active': _active,
    };
    try {
      if (isNew || _password.text.isNotEmpty) {
        // إنشاء الحساب أو تغيير الرقم السري يمر بدالة خادم بصلاحية المالك؛ المفتاح السري لا يوجد في التطبيق
        final res = await Api.client.functions.invoke('admin-users', body: {
          'action': isNew ? 'create' : 'set_password', 'username': _username.text.trim().toLowerCase(), 'password': _password.text,
          'login_domain': Api.config.loginDomain, if (!isNew) 'user_id': widget.user!['user_id'], ...role,
        }).timeout(const Duration(seconds: 25));
        final data = res.data;
        if (data is Map && data['error'] != null) throw BusinessError('${data['error']}');
      }
      if (!isNew) await Api.rpc('save_user_role', {'p': {...role, 'user_id': widget.user!['user_id']}});
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _error = switch (e.code) {
        'USERNAME_EXISTS' => 'اسم المستخدم مستخدَم من قبل.',
        'CANNOT_CHANGE_SELF' => 'لا يمكنك تغيير دورك أو إيقاف حسابك بنفسك.',
        'BRANCH_REQUIRED' => 'اختر فرع الكاشير أو مدير الفرع.',
        _ => errorMessage(e.code),
      };
    } catch (_) {
      _error = 'تعذّر تنفيذ الطلب على الخادم. تحقق من الاتصال ومن نشر دالة admin-users.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.user == null;
    final needsBranch = _role == 'cashier' || _role == 'branch_manager';
    return AlertDialog(
      title: Text(isNew ? 'مستخدم جديد' : 'تعديل مستخدم'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _input(_name, 'الاسم الكامل', autofocus: true),
          const SizedBox(height: 10),
          _input(_username, 'اسم المستخدم للدخول', ltr: true, enabled: isNew),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            obscureText: true,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(labelText: isNew ? 'الرقم السري (8 خانات على الأقل)' : 'رقم سري جديد (اتركه فارغًا لإبقائه)', isDense: true),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: _labeled(
                  'الدور',
                  DropdownButton<String>(
                    value: _role,
                    isExpanded: true,
                    isDense: true,
                    items: [for (final r in _roleLabels.entries) DropdownMenuItem(value: r.key, child: Text(r.value))],
                    onChanged: (v) => setState(() => _role = v ?? 'cashier'),
                  )),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _labeled(
                  'الفرع',
                  DropdownButton<String?>(
                    value: needsBranch ? _branch : null,
                    isExpanded: true,
                    isDense: true,
                    items: [
                      if (!needsBranch) const DropdownMenuItem<String?>(value: null, child: Text('كل الفروع')),
                      if (needsBranch && _branch == null) const DropdownMenuItem<String?>(value: null, child: Text('— اختر —')),
                      if (needsBranch) for (final b in widget.branches) DropdownMenuItem<String?>(value: b['id'] as String, child: Text('${b['name_ar']}')),
                    ],
                    onChanged: needsBranch ? (v) => setState(() => _branch = v) : null,
                  )),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(width: 170, child: _input(_disc, 'حد الخصم %', ltr: true)),
            const SizedBox(width: 16),
            Checkbox(value: _active, onChanged: (v) => setState(() => _active = v ?? true)),
            const Text('الحساب فعّال'),
          ]),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
        ]),
      ),
      actions: [
        OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ الحفظ…' : 'حفظ')),
      ],
    );
  }
}
