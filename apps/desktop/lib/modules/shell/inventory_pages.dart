part of 'pages.dart';

// المخزون وبطاقة الصنف والجرد، والمشتريات وحساب المورّد — حسب شاشات التصميم 7 و8 و9.

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
int _i(Object? v) => (v as num?)?.toInt() ?? 0;
String _qtyText(Object? v) => formatQty((_d(v) * 1000).round());
String _today() {
  final t = DateTime.now().toUtc().add(const Duration(hours: 4)); // مسقط
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

bool _validDate(String s) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s) && DateTime.tryParse(s) != null;

const _categories = <String, String>{
  'tire': 'إطار', 'accessory': 'إكسسوار', 'tint': 'عازل', 'service': 'خدمة', 'raw': 'مادة خام', 'general': 'عام',
};
const _movementLabels = <String, String>{
  'opening': 'رصيد افتتاحي', 'purchase_receipt': 'استلام مشتريات', 'sale': 'بيع', 'sale_return': 'مرتجع بيع',
  'void_reversal': 'إلغاء فاتورة', 'adjustment': 'تسوية جرد', 'transfer_out': 'تحويل صادر', 'transfer_in': 'تحويل وارد',
};
const _purchaseMethods = <String, String>{'credit': 'آجل', 'cash': 'نقدي من الصندوق', 'transfer': 'تحويل بنكي'};

Widget _labeled(String label, Widget child) => InputDecorator(
      decoration: InputDecoration(labelText: label, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
      child: DropdownButtonHideUnderline(child: child),
    );

Widget _input(TextEditingController c, String label, {bool ltr = false, bool enabled = true, ValueChanged<String>? onChanged, bool autofocus = false}) => TextField(
      controller: c,
      enabled: enabled,
      autofocus: autofocus,
      textDirection: ltr ? TextDirection.ltr : null,
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: onChanged,
    );

// ───────────────────────── المخزون ─────────────────────────
class InventoryPage extends StatefulWidget {
  final ShiftContext ctx;
  const InventoryPage({super.key, required this.ctx});
  @override
  State<InventoryPage> createState() => _InventoryState();
}

class _InventoryState extends State<InventoryPage> {
  List<Map<String, dynamic>>? _rows;
  String? _error, _selected;
  String _filter = 'all', _q = '';

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final r = await Api.rpc('stock_report', {'p_branch_id': widget.ctx.branchId});
      if (mounted) setState(() { _rows = (r as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList(); _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _fail(e));
    }
  }

  bool _low(Map<String, dynamic> r) => _d(r['qty']) > 0 && _d(r['qty']) <= (r['reorder_level'] == null ? 3 : _d(r['reorder_level']));
  bool _old(Map<String, dynamic> r) => r['tire_year'] != null && _i(r['tire_year']) <= DateTime.now().year - 2 && _d(r['qty']) > 0;

  Future<void> _card(String? productId) async {
    final changed = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => ProductCardDialog(ctx: widget.ctx, productId: productId));
    if (changed == true) await _load();
  }

  Future<void> _receive() async {
    if (!widget.ctx.permissions.contains('inventory.manage')) return _deny('استلام المشتريات لمدير الفرع أو المالك.');
    final done = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => ReceivePurchaseDialog(ctx: widget.ctx, products: _rows ?? const []));
    if (done == true) await _load();
  }

  Future<void> _count() async {
    if (!widget.ctx.permissions.contains('inventory.manage')) return _deny('الجرد والتسوية لمدير الفرع أو المالك.');
    final row = (_rows ?? const <Map<String, dynamic>>[]).where((r) => r['product_id'] == _selected).toList();
    if (row.isEmpty) return _deny('اختر صنفًا من القائمة أولًا ثم اضغط «جرد».');
    final done = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => StockCountDialog(ctx: widget.ctx, row: row.first));
    if (done == true) await _load();
  }

  Future<void> _transfer() async {
    if (!widget.ctx.permissions.contains('inventory.manage')) return _deny('التحويل بين الفروع لمدير الفرع أو المالك.');
    final row = (_rows ?? const <Map<String, dynamic>>[]).where((r) => r['product_id'] == _selected).toList();
    if (row.isEmpty) return _deny('اختر صنفًا من القائمة أولًا ثم اضغط «تحويل».');
    final done = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => TransferDialog(ctx: widget.ctx, row: row.first));
    if (done == true) await _load();
  }

  Future<void> _batches() async {
    final row = (_rows ?? const <Map<String, dynamic>>[]).where((r) => r['product_id'] == _selected).toList();
    if (row.isEmpty) return _deny('اختر صنفًا من القائمة أولًا ثم اضغط «الدفعات والرفوف».');
    final changed = await showDialog<bool>(context: context, builder: (_) => BatchesDialog(ctx: widget.ctx, row: row.first));
    if (changed == true) await _load();
  }

  Future<void> _deny(String text) => showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(content: Text(text, style: const TextStyle(fontSize: 17)), actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(c), child: const Text('حسنًا'))]));

  @override
  Widget build(BuildContext context) {
    final all = _rows ?? const <Map<String, dynamic>>[];
    final rows = all.where((r) {
      if (_filter == 'low' && !_low(r)) return false;
      if (_filter == 'out' && _d(r['qty']) > 0) return false;
      if (_filter == 'old' && !_old(r)) return false;
      return _q.isEmpty || '${r['name_ar']} ${r['sku']} ${r['brand'] ?? ''} ${r['tire_size'] ?? ''} ${r['shelves'] ?? ''}'.toLowerCase().contains(_q.toLowerCase());
    }).toList();
    final showCost = all.any((r) => r['value_baisa'] != null);
    final value = all.fold<int>(0, (s, r) => s + _i(r['value_baisa']));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f1): () => _card(null),
        const SingleActivator(LogicalKeyboardKey.f4): () {
          if (_selected != null) _card(_selected);
        },
        const SingleActivator(LogicalKeyboardKey.f5): _batches,
        const SingleActivator(LogicalKeyboardKey.f6): _receive,
        const SingleActivator(LogicalKeyboardKey.f7): _transfer,
        const SingleActivator(LogicalKeyboardKey.f9): _count,
      },
      child: _Page(
        title: 'المخزون — ${widget.ctx.branchName}',
        tools: [
          SizedBox(width: 240, child: TextField(autofocus: true, decoration: const InputDecoration(hintText: 'بحث بالاسم أو المقاس أو الماركة أو الرف', isDense: true), onChanged: (v) => setState(() => _q = v.trim()))),
          const SizedBox(width: 10),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: 'all', label: Text('الكل')),
              ButtonSegment(value: 'low', label: Text('منخفض (${all.where(_low).length})')),
              ButtonSegment(value: 'out', label: Text('نافد (${all.where((r) => _d(r['qty']) <= 0).length})')),
              ButtonSegment(value: 'old', label: Text('أقدم من سنتين (${all.where(_old).length})')),
            ],
            selected: {_filter},
            onSelectionChanged: (s) => setState(() => _filter = s.first),
          ),
          const Spacer(),
          OutlinedButton(onPressed: () => _card(null), child: const Text('صنف جديد F1')),
          const SizedBox(width: 6),
          OutlinedButton(onPressed: _selected == null ? null : () => _card(_selected), child: const Text('بطاقة الصنف F4')),
          const SizedBox(width: 6),
          OutlinedButton(onPressed: _selected == null ? null : _batches, child: const Text('الدفعات والرفوف F5')),
          const SizedBox(width: 6),
          OutlinedButton(onPressed: _receive, child: const Text('استلام مشتريات F6')),
          const SizedBox(width: 6),
          OutlinedButton(onPressed: _transfer, child: const Text('تحويل F7')),
          const SizedBox(width: 6),
          OutlinedButton(onPressed: _count, child: const Text('جرد F9')),
        ],
        child: _error != null
            ? _note(_error!, bad: true)
            : _rows == null
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    _head([('الصنف', 5), ('المقاس', 2), ('الماركة', 2), ('أقدم سنة', 2), ('الرف', 2), ('الكمية', 2), if (showCost) ('متوسط التكلفة', 2), ('سعر البيع', 2), ('الحالة', 2)]),
                    Expanded(
                      child: rows.isEmpty
                          ? _note('لا توجد أصناف مطابقة.')
                          : ListView.builder(
                              itemCount: rows.length,
                              itemBuilder: (_, i) {
                                final r = rows[i];
                                final q = _d(r['qty']);
                                final status = q <= 0 ? 'نافد' : (_low(r) ? 'منخفض' : (_old(r) ? 'قديم' : 'متوفر'));
                                final color = q <= 0 ? Brand.bad : (status == 'متوفر' ? Brand.ok : const Color(0xFF9A5B00));
                                return Material(
                                  color: r['product_id'] == _selected ? const Color(0xFFFFF0EA) : Colors.white,
                                  child: InkWell(
                                    onTap: () => setState(() => _selected = r['product_id'] as String),
                                    onDoubleTap: () {
                                      setState(() => _selected = r['product_id'] as String);
                                      _card(r['product_id'] as String);
                                    },
                                    child: Container(
                                      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                      child: Row(children: [
                                        _cell('${r['name_ar']}', flex: 5, bold: true),
                                        _cell('${r['tire_size'] ?? '—'}', flex: 2, num: true),
                                        _cell('${r['brand'] ?? '—'}', flex: 2),
                                        _cell('${r['tire_year'] ?? '—'}', flex: 2, num: true),
                                        _cell('${r['shelves'] ?? '—'}', flex: 2, num: true),
                                        _cell('${_qtyText(r['qty'])} ${r['unit']}', flex: 2),
                                        if (showCost) _cell(r['avg_cost_baisa'] == null ? '—' : formatOmr(_i(r['avg_cost_baisa'])), flex: 2, num: true),
                                        _cell(formatOmr(_i(r['price_baisa'])), flex: 2, num: true),
                                        _cell(status, flex: 2, bold: true, color: color),
                                      ]),
                                    ),
                                  ),
                                );
                              }),
                    ),
                    Container(
                      color: Brand.bg,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Row(children: [
                        Text('الأصناف: ${all.length}   ·   منخفض: ${all.where(_low).length}   ·   نافد: ${all.where((r) => _d(r['qty']) <= 0).length}', style: const TextStyle(fontSize: 15)),
                        const Spacer(),
                        if (showCost) Text('قيمة المخزون بالتكلفة: ${money(value)}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ]),
      ),
    );
  }
}

// ───────────────────────── بطاقة الصنف ─────────────────────────
class ProductCardDialog extends StatefulWidget {
  final ShiftContext ctx;
  final String? productId; // null = صنف جديد
  const ProductCardDialog({super.key, required this.ctx, this.productId});
  @override
  State<ProductCardDialog> createState() => _ProductCardState();
}

class _ProductCardState extends State<ProductCardDialog> {
  final _sku = TextEditingController(), _nameAr = TextEditingController(), _nameEn = TextEditingController();
  final _barcodes = TextEditingController(), _brand = TextEditingController(), _unit = TextEditingController(text: 'قطعة');
  final _reorder = TextEditingController(), _price = TextEditingController(), _minPrice = TextEditingController();
  final _width = TextEditingController(), _aspect = TextEditingController(), _rim = TextEditingController();
  final _year = TextEditingController(), _country = TextEditingController(), _warranty = TextEditingController();
  String _category = 'tire';
  String? _supplier;
  bool _taxable = true, _active = true, _wholeUnits = true;
  bool _loading = true, _busy = false, _canEdit = true;
  String? _error;
  Map<String, dynamic>? _card;
  List<Map<String, dynamic>> _suppliers = [];

  List<TextEditingController> get _all => [_sku, _nameAr, _nameEn, _barcodes, _brand, _unit, _reorder, _price, _minPrice, _width, _aspect, _rim, _year, _country, _warranty];

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await Api.rpc('suppliers_overview', {'p_branch_id': widget.ctx.branchId});
      _suppliers = (s as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
      if (widget.productId != null) {
        final c = (await Api.rpc('product_card', {'p_branch_id': widget.ctx.branchId, 'p_product_id': widget.productId}) as Map).cast<String, dynamic>();
        final p = (c['product'] as Map).cast<String, dynamic>();
        _card = c;
        _canEdit = c['can_edit'] == true;
        _sku.text = '${p['sku']}';
        _nameAr.text = '${p['name_ar']}';
        _nameEn.text = '${p['name_en'] ?? ''}';
        _barcodes.text = (c['barcodes'] as List).join(', ');
        _brand.text = '${p['brand'] ?? ''}';
        _unit.text = '${p['unit']}';
        _reorder.text = p['reorder_level'] == null ? '' : _qtyText(p['reorder_level']);
        _price.text = formatOmr(_i(p['base_price_baisa']));
        _minPrice.text = p['min_price_baisa'] == null ? '' : formatOmr(_i(p['min_price_baisa']));
        _width.text = '${p['tire_width'] ?? ''}';
        _aspect.text = '${p['tire_aspect'] ?? ''}';
        _rim.text = '${p['tire_rim'] ?? ''}';
        _year.text = '${p['tire_year'] ?? ''}';
        _country.text = '${p['tire_country'] ?? ''}';
        _warranty.text = '${p['warranty_months'] ?? ''}';
        _category = _categories.containsKey(p['category']) ? p['category'] as String : 'general';
        _supplier = _suppliers.any((x) => x['id'] == p['default_supplier_id']) ? p['default_supplier_id'] as String? : null;
        _taxable = p['taxable'] == true;
        _active = p['is_active'] == true;
        _wholeUnits = p['whole_units_only'] == true;
      } else {
        _canEdit = widget.ctx.permissions.contains('catalog.manage');
      }
    } catch (e) {
      _error = _fail(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  int? _int(TextEditingController c) => c.text.trim().isEmpty ? null : int.tryParse(c.text.trim());

  Future<void> _save() async {
    final price = parseOmr(_price.text);
    final minPrice = _minPrice.text.trim().isEmpty ? null : parseOmr(_minPrice.text);
    final reorder = _reorder.text.trim().isEmpty ? null : parseMilli(_reorder.text);
    String? err;
    if (_sku.text.trim().isEmpty || _nameAr.text.trim().isEmpty) err = 'الرمز والاسم العربي مطلوبان.';
    if (err == null && price == null) err = 'سعر البيع غير صالح.';
    if (err == null && _minPrice.text.trim().isNotEmpty && minPrice == null) err = 'أدنى سعر غير صالح.';
    if (err == null && minPrice != null && price != null && minPrice > price) err = 'أدنى سعر للكاشير لا يتجاوز سعر البيع.';
    if (err == null && _reorder.text.trim().isNotEmpty && reorder == null) err = 'حد التنبيه غير صالح.';
    if (err == null && _warranty.text.trim().isNotEmpty && (_int(_warranty) == null || _int(_warranty)! < 0 || _int(_warranty)! > 120)) err = 'مدة الضمان بالأشهر بين 0 و120.';
    final tire = _category == 'tire';
    for (final c in [_width, _aspect, _rim, _year]) {
      if (err == null && tire && c.text.trim().isNotEmpty && _int(c) == null) err = 'بيانات الإطار أرقام صحيحة فقط.';
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() { _busy = true; _error = null; });
    final service = _category == 'service';
    try {
      await Api.rpc('save_product', {
        'p_product': {
          'organization_id': widget.ctx.organizationId,
          if (widget.productId != null) 'id': widget.productId,
          'sku': _sku.text.trim(), 'name_ar': _nameAr.text.trim(), 'name_en': _nameEn.text.trim(),
          'kind': service ? 'service' : 'item', 'category': _category, 'track_stock': !service,
          'brand': _brand.text.trim(), 'unit': _unit.text.trim(), 'whole_units_only': _wholeUnits,
          'taxable': _taxable, 'is_active': _active, 'base_price_baisa': price,
          'tire_width': tire ? _int(_width) : null, 'tire_aspect': tire ? _int(_aspect) : null, 'tire_rim': tire ? _int(_rim) : null,
          'tire_year': tire ? _int(_year) : null, 'tire_country': tire ? _country.text.trim() : null,
          'barcodes': _barcodes.text.split(RegExp(r'[,،\s]+')).where((b) => b.trim().isNotEmpty).toList(),
          'default_supplier_id': _supplier, 'min_price_baisa': minPrice, 'warranty_months': _int(_warranty),
          'reorder_level': reorder == null ? null : reorder / 1000,
        }
      });
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = _fail(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _row(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(width: 10), Expanded(child: children[i])],
        ]),
      );

  Widget _section(String t) => Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8), child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Brand.muted)));

  @override
  Widget build(BuildContext context) {
    final e = _canEdit && !_busy;
    final price = parseOmr(_price.text);
    final branches = ((_card?['branches'] as List?) ?? const []).cast<Map>();
    final here = branches.where((b) => b['branch_id'] == widget.ctx.branchId).toList();
    final avg = here.isEmpty ? null : here.first['avg_cost_baisa'];
    final moves = ((_card?['movements'] as List?) ?? const []).cast<Map>();
    return AlertDialog(
      title: Text(widget.productId == null ? 'صنف جديد' : 'بطاقة صنف'),
      content: SizedBox(
        width: 940,
        height: 600,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 6,
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (!_canEdit)
                        const Padding(padding: EdgeInsets.only(bottom: 10), child: Text('للعرض فقط: تعديل الأصناف والأسعار للمالك.', style: TextStyle(color: Color(0xFF9A5B00), fontWeight: FontWeight.w600))),
                      _row([
                        _labeled(
                            'النوع',
                            DropdownButton<String>(
                              value: _category,
                              isExpanded: true,
                              isDense: true,
                              items: [for (final c in _categories.entries) DropdownMenuItem(value: c.key, child: Text(c.value))],
                              onChanged: e ? (v) => setState(() => _category = v ?? 'general') : null,
                            )),
                        _input(_sku, 'الرمز (SKU)', ltr: true, enabled: e),
                        _input(_unit, 'الوحدة', enabled: e),
                      ]),
                      _row([_input(_nameAr, 'الاسم بالعربية', enabled: e, autofocus: widget.productId == null), _input(_nameEn, 'الاسم بالإنجليزية', ltr: true, enabled: e)]),
                      _row([
                        _input(_barcodes, 'الباركود (أكثر من واحد بفاصلة)', ltr: true, enabled: e),
                        _input(_brand, 'الماركة', enabled: e),
                      ]),
                      _row([
                        _labeled(
                            'المورّد الافتراضي',
                            DropdownButton<String?>(
                              value: _supplier,
                              isExpanded: true,
                              isDense: true,
                              items: [
                                const DropdownMenuItem<String?>(value: null, child: Text('— بلا —')),
                                for (final s in _suppliers) DropdownMenuItem<String?>(value: s['id'] as String, child: Text('${s['name']}')),
                              ],
                              onChanged: e ? (v) => setState(() => _supplier = v) : null,
                            )),
                        _input(_reorder, 'حد التنبيه (كمية)', ltr: true, enabled: e && _category != 'service'),
                      ]),
                      if (_category == 'tire') ...[
                        _section('بيانات الإطار'),
                        _row([
                          _input(_width, 'العرض', ltr: true, enabled: e),
                          _input(_aspect, 'النسبة', ltr: true, enabled: e),
                          _input(_rim, 'القطر', ltr: true, enabled: e),
                        ]),
                        const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Text('سنة الإنتاج والأسبوع (DOT) وبلد الصنع والرف تُدخل مع كل دفعة عند استلام المشتريات، وتُعرض من «الدفعات والرفوف» في المخزون.', style: TextStyle(color: Brand.muted)),
                        ),
                      ],
                      _section('التسعير'),
                      _row([
                        _input(_price, 'سعر البيع (${Currency.symbol})', ltr: true, enabled: e, onChanged: (_) => setState(() {})),
                        _input(_minPrice, 'أدنى سعر للكاشير (${Currency.symbol})', ltr: true, enabled: e),
                        _input(_warranty, 'الضمان (أشهر)', ltr: true, enabled: e),
                      ]),
                      if (avg != null && price != null && price > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('متوسط التكلفة ${money(_i(avg))}  ·  الهامش ${money(price - _i(avg))} (${((price - _i(avg)) * 100 / price).toStringAsFixed(1)}%)',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        ),
                      Row(children: [
                        Checkbox(value: _taxable, onChanged: e ? (v) => setState(() => _taxable = v ?? true) : null),
                        const Text('خاضع للضريبة'),
                        const SizedBox(width: 16),
                        Checkbox(value: _wholeUnits, onChanged: e ? (v) => setState(() => _wholeUnits = v ?? true) : null),
                        const Text('كميات صحيحة فقط'),
                        const SizedBox(width: 16),
                        Checkbox(value: _active, onChanged: e ? (v) => setState(() => _active = v ?? true) : null),
                        const Text('فعّال للبيع'),
                      ]),
                      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Brand.bad, fontSize: 16))),
                    ]),
                  ),
                ),
                if (_card != null) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 4,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(10)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const Text('الرصيد حسب الفرع', style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        for (final b in branches)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                              Text('${b['name_ar']}'),
                              Text(_qtyText(b['qty']), textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                            ]),
                          ),
                        const Divider(height: 20),
                        const Text('آخر الحركات في هذا الفرع', style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        Expanded(
                          child: moves.isEmpty
                              ? const Text('لا حركات بعد.', style: TextStyle(color: Brand.muted))
                              : ListView(children: [
                                  for (final m in moves)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 3),
                                      child: Row(children: [
                                        SizedBox(width: 84, child: Text('${m['at']}'.substring(0, 10), textDirection: TextDirection.ltr, style: const TextStyle(color: Brand.muted, fontSize: 13))),
                                        Expanded(child: Text(_movementLabels[m['type']] ?? '${m['type']}')),
                                        Text('${_d(m['qty_delta']) > 0 ? '+' : ''}${_qtyText(m['qty_delta'])}',
                                            textDirection: TextDirection.ltr, style: TextStyle(fontWeight: FontWeight.w700, color: _d(m['qty_delta']) < 0 ? Brand.bad : Brand.ok)),
                                      ]),
                                    ),
                                ]),
                        ),
                      ]),
                    ),
                  ),
                ],
              ]),
      ),
      actions: [
        OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('إغلاق (Esc)')),
        if (_canEdit) FilledButton(onPressed: _busy || _loading ? null : _save, child: Text(_busy ? 'جارٍ الحفظ…' : 'حفظ')),
      ],
    );
  }
}

// ───────────────────────── الجرد ─────────────────────────
/// جرد صنف: تُدخل الكمية الفعلية بعد العدّ، ويُسجَّل الفرق تسوية مخزون بسببها.
class StockCountDialog extends StatefulWidget {
  final ShiftContext ctx;
  final Map<String, dynamic> row;
  const StockCountDialog({super.key, required this.ctx, required this.row});
  @override
  State<StockCountDialog> createState() => _StockCountState();
}

class _StockCountState extends State<StockCountDialog> {
  late final _counted = TextEditingController(text: _qtyText(widget.row['qty']));
  final _cost = TextEditingController(), _reason = TextEditingController(text: 'جرد');
  String _opId = const Uuid().v4();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _counted.selection = TextSelection(baseOffset: 0, extentOffset: _counted.text.length);
  }

  @override
  void dispose() {
    _counted.dispose();
    _cost.dispose();
    _reason.dispose();
    super.dispose();
  }

  int? _delta() {
    final c = parseMilli(_counted.text); // جزء من الألف
    return c == null ? null : c - (_d(widget.row['qty']) * 1000).round();
  }

  Future<void> _save() async {
    final delta = _delta();
    if (delta == null) {
      setState(() => _error = 'الكمية الفعلية غير صالحة.');
      return;
    }
    if (delta == 0) {
      Navigator.pop(context, false);
      return;
    }
    final cost = _cost.text.trim().isEmpty ? null : parseOmr(_cost.text);
    if (_cost.text.trim().isNotEmpty && cost == null) {
      setState(() => _error = 'تكلفة الوحدة غير صالحة.');
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'اكتب سبب التسوية.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('adjust_stock', {
        'p_operation_id': _opId, 'p_branch_id': widget.ctx.branchId, 'p_product_id': widget.row['product_id'],
        'p_qty_delta': delta / 1000, 'p_unit_cost_baisa': delta > 0 ? cost : null, 'p_reason': _reason.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _opId = const Uuid().v4();
      _error = e.code == 'INVALID_AMOUNT' ? 'لا توجد تكلفة سابقة لهذا الصنف. أدخل تكلفة الوحدة للكمية الزائدة.' : errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال. اضغط «تسجيل» مجددًا للتحقق؛ لن تُسجَّل التسوية مرتين.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final delta = _delta();
    return AlertDialog(
      title: Text('جرد: ${widget.row['name_ar']}'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('الرصيد في النظام: ${_qtyText(widget.row['qty'])} ${widget.row['unit']}', style: const TextStyle(color: Brand.muted, fontSize: 16)),
          const SizedBox(height: 12),
          TextField(
            controller: _counted,
            autofocus: true,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            decoration: const InputDecoration(labelText: 'الكمية الفعلية بعد العدّ'),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 8),
          Text(
              delta == null ? '' : (delta == 0 ? 'مطابق — لا تسوية.' : (delta > 0 ? 'زيادة ${formatQty(delta)}' : 'نقص ${formatQty(-delta)}')),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: (delta ?? 0) == 0 ? Brand.ok : Brand.bad)),
          if ((delta ?? 0) > 0) ...[const SizedBox(height: 10), _input(_cost, 'تكلفة الوحدة للزيادة (اختياري — الافتراضي آخر تكلفة)', ltr: true)],
          const SizedBox(height: 10),
          _input(_reason, 'السبب'),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
        ]),
      ),
      actions: [
        OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ التسجيل…' : 'تسجيل التسوية')),
      ],
    );
  }
}

// ───────────────────────── المشتريات والموردون ─────────────────────────
class PurchasesPage extends StatefulWidget {
  final ShiftContext ctx;
  const PurchasesPage({super.key, required this.ctx});
  @override
  State<PurchasesPage> createState() => _PurchasesState();
}

class _PurchasesState extends State<PurchasesPage> {
  List<Map<String, dynamic>>? _receipts;
  List<Map<String, dynamic>> _suppliers = [], _products = [];
  String? _error, _selected;

  bool get _manage => widget.ctx.permissions.contains('inventory.manage');

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  List<Map<String, dynamic>> _list(Object? r) => (r as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();

  Future<void> _load() async {
    try {
      final b = {'p_branch_id': widget.ctx.branchId};
      final r = _list(await Api.rpc('list_purchases', b));
      final s = _list(await Api.rpc('suppliers_overview', b));
      final p = _list(await Api.rpc('stock_report', b));
      if (mounted) setState(() { _receipts = r; _suppliers = s; _products = p; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = _fail(e));
    }
  }

  Future<void> _receive() async {
    if (!_manage) return;
    final done = await showDialog<bool>(
        context: context, barrierDismissible: false, builder: (_) => ReceivePurchaseDialog(ctx: widget.ctx, products: _products, supplierId: _selected));
    if (done == true) await _load();
  }

  Future<void> _newSupplier() async {
    if (!_manage) return;
    final done = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => SupplierDialog(ctx: widget.ctx));
    if (done == true) await _load();
  }

  Future<void> _pay() async {
    final s = _suppliers.where((x) => x['id'] == _selected).toList();
    if (!_manage || s.isEmpty || _i(s.first['balance_baisa']) <= 0) return;
    final done = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => PaySupplierDialog(ctx: widget.ctx, supplier: s.first));
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final sel = _suppliers.where((x) => x['id'] == _selected).toList();
    final canPay = _manage && sel.isNotEmpty && _i(sel.first['balance_baisa']) > 0;
    final payable = _suppliers.fold<int>(0, (s, x) => s + _i(x['balance_baisa']));
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f6): _receive,
        const SingleActivator(LogicalKeyboardKey.f9): _pay,
      },
      child: Focus(
        autofocus: true,
        child: _Page(
          title: 'المشتريات — ${widget.ctx.branchName}',
          tools: [
            const Spacer(),
            OutlinedButton(onPressed: _manage ? _newSupplier : null, child: const Text('مورّد جديد')),
            const SizedBox(width: 6),
            OutlinedButton(onPressed: canPay ? _pay : null, child: const Text('سداد للمورّد F9')),
            const SizedBox(width: 6),
            FilledButton(onPressed: _manage ? _receive : null, child: const Text('استلام مشتريات F6')),
          ],
          child: !widget.ctx.permissions.contains('inventory.cost.view')
              ? _note('المشتريات وحسابات الموردين لمدير الفرع والمحاسب والمالك.')
              : _error != null
                  ? _note(_error!, bad: true)
                  : _receipts == null
                      ? const Center(child: CircularProgressIndicator())
                      : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Expanded(
                            flex: 7,
                            child: Column(children: [
                              _head([('التاريخ', 2), ('المورّد', 3), ('فاتورة المورّد', 2), ('الدفع', 2), ('الإجمالي مع الضريبة', 3)]),
                              Expanded(
                                child: _receipts!.isEmpty
                                    ? _note('لا توجد مشتريات مستلمة بعد. اضغط «استلام مشتريات».')
                                    : ListView(children: [
                                        for (final r in _receipts!)
                                          Container(
                                            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
                                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                            child: Row(children: [
                                              _cell('${r['supplier_invoice_date'] ?? '${r['created_at']}'.substring(0, 10)}', flex: 2, num: true),
                                              _cell('${r['supplier_name'] ?? '—'}', flex: 3, bold: true),
                                              _cell('${r['reference'] ?? '—'}', flex: 2),
                                              _cell('${_purchaseMethods[r['payment_method']] ?? r['payment_method']}${r['due_date'] != null ? ' · ${r['due_date']}' : ''}', flex: 2),
                                              _cell(formatOmr(_i(r['total_cost_baisa']) + _i(r['tax_baisa'])), flex: 3, num: true, bold: true),
                                            ]),
                                          ),
                                      ]),
                              ),
                            ]),
                          ),
                          const VerticalDivider(width: 1, color: Brand.line),
                          Expanded(
                            flex: 4,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              _head([('المورّد', 3), ('المستحق له', 2)]),
                              Expanded(
                                child: _suppliers.isEmpty
                                    ? _note('لا يوجد موردون. أضف مورّدًا.')
                                    : ListView(children: [
                                        for (final s in _suppliers)
                                          Material(
                                            color: s['id'] == _selected ? const Color(0xFFFFF0EA) : Colors.white,
                                            child: InkWell(
                                              onTap: () => setState(() => _selected = s['id'] as String),
                                              child: Container(
                                                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
                                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                                child: Row(children: [
                                                  _cell('${s['name']}${s['phone'] != null ? '  ${s['phone']}' : ''}', flex: 3, bold: true),
                                                  _cell(formatOmr(_i(s['balance_baisa'])), flex: 2, num: true, color: _i(s['balance_baisa']) > 0 ? Brand.bad : Brand.muted),
                                                ]),
                                              ),
                                            ),
                                          ),
                                      ]),
                              ),
                              Container(
                                color: Brand.bg,
                                padding: const EdgeInsets.all(12),
                                child: Text('إجمالي المستحق للموردين: ${money(payable)}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                              ),
                            ]),
                          ),
                        ]),
        ),
      ),
    );
  }
}

class _PLine {
  final Map<String, dynamic> product;
  final qty = TextEditingController(text: '1');
  final cost = TextEditingController();
  // بيانات الدفعة: تُحفظ على الدفعة المستلمة لا على الصنف
  final dot = TextEditingController(), year = TextEditingController(), week = TextEditingController();
  final country = TextEditingController(), shelf = TextEditingController(), note = TextEditingController();
  _PLine(this.product);
  bool get isTire => product['category'] == 'tire';
  void dispose() {
    for (final c in [qty, cost, dot, year, week, country, shelf, note]) {
      c.dispose();
    }
  }
}

/// استلام مشتريات: المورّد ورقم فاتورته وتاريخها، طريقة الدفع، ضريبة المدخلات، والبنود بالكمية وتكلفة الوحدة (غير شاملة الضريبة).
class ReceivePurchaseDialog extends StatefulWidget {
  final ShiftContext ctx;
  final List<Map<String, dynamic>> products; // من stock_report
  final String? supplierId;
  const ReceivePurchaseDialog({super.key, required this.ctx, required this.products, this.supplierId});
  @override
  State<ReceivePurchaseDialog> createState() => _ReceiveState();
}

class _ReceiveState extends State<ReceivePurchaseDialog> {
  final _reference = TextEditingController(), _date = TextEditingController(text: _today()), _due = TextEditingController(), _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _lines = <_PLine>[];
  List<Map<String, dynamic>> _suppliers = [];
  String? _supplier;
  String _method = 'credit';
  bool _vat = true, _busy = false;
  String _opId = const Uuid().v4();
  String? _error;

  @override
  void initState() {
    super.initState();
    _supplier = widget.supplierId;
    _vat = widget.ctx.tax.enabled;
    Future.microtask(() async {
      try {
        final s = await Api.rpc('suppliers_overview', {'p_branch_id': widget.ctx.branchId});
        if (mounted) {
          setState(() {
            _suppliers = (s as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
            if (!_suppliers.any((x) => x['id'] == _supplier)) _supplier = null;
          });
        }
      } catch (e) {
        if (mounted) setState(() => _error = _fail(e));
      }
    });
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _reference.dispose();
    _date.dispose();
    _due.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _matches() {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return widget.products
        .where((p) => '${p['name_ar']} ${p['sku']} ${p['brand'] ?? ''} ${p['tire_size'] ?? ''}'.toLowerCase().contains(q))
        .take(6)
        .toList();
  }

  void _add(Map<String, dynamic> p) {
    setState(() {
      // الإطار نفسه قد يُستلم بعدة دفعات (سنة أو رف مختلف): كل إضافة سطر مستقل. غير الإطارات سطر واحد لكل صنف.
      if (p['category'] == 'tire' || !_lines.any((l) => l.product['product_id'] == p['product_id'])) {
        final l = _PLine(p);
        final same = _lines.where((x) => x.product['product_id'] == p['product_id']).toList();
        if (same.isNotEmpty) {
          l.cost.text = same.last.cost.text;
          l.country.text = same.last.country.text;
        } else if (p['avg_cost_baisa'] != null) {
          l.cost.text = formatOmr(_i(p['avg_cost_baisa']));
        }
        _lines.add(l);
      }
      _search.clear();
      _error = null;
    });
    _searchFocus.requestFocus();
  }

  Widget _batchField(TextEditingController c, String label, {String? hint, bool ltr = true}) => Padding(
        padding: const EdgeInsets.only(left: 8),
        child: TextField(
          controller: c,
          textDirection: ltr ? TextDirection.ltr : null,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(labelText: label, hintText: hint, isDense: true),
          onChanged: (_) => setState(() {}),
        ),
      );

  int _subtotal() {
    var t = 0;
    for (final l in _lines) {
      final q = parseMilli(l.qty.text), c = parseOmr(l.cost.text);
      if (q != null && c != null) t += roundDiv(q * c, 1000);
    }
    return t;
  }

  int get _rateBp => _vat ? (widget.ctx.tax.rateBp > 0 ? widget.ctx.tax.rateBp : 500) : 0;

  Future<void> _save() async {
    String? err;
    if (_lines.isEmpty) err = 'أضف صنفًا واحدًا على الأقل.';
    for (final l in _lines) {
      final q = parseMilli(l.qty.text), c = parseOmr(l.cost.text);
      if (err == null && (q == null || q <= 0)) err = 'كمية غير صالحة: ${l.product['name_ar']}';
      if (err == null && c == null) err = 'أدخل تكلفة الوحدة: ${l.product['name_ar']}';
      if (err == null && l.isTire) {
        final dot = l.dot.text.trim(), y = int.tryParse(l.year.text.trim()), w = int.tryParse(l.week.text.trim());
        final dotOk = RegExp(r'^[0-9]{4}$').hasMatch(dot) && int.parse(dot.substring(0, 2)) >= 1 && int.parse(dot.substring(0, 2)) <= 53;
        if (dot.isNotEmpty && !dotOk) err = 'رمز DOT أربعة أرقام: الأسبوع ثم السنة، مثل 2325 — ${l.product['name_ar']}';
        if (err == null && l.year.text.trim().isNotEmpty && (y == null || y < 2000 || y > 2100)) err = 'سنة الصنع غير صالحة: ${l.product['name_ar']}';
        if (err == null && l.week.text.trim().isNotEmpty && (w == null || w < 1 || w > 53)) err = 'أسبوع الصنع بين 1 و53: ${l.product['name_ar']}';
        if (err == null && !dotOk && y == null) err = 'أدخل رمز DOT أو سنة الصنع لدفعة: ${l.product['name_ar']}';
        if (err == null && l.shelf.text.trim().isEmpty) err = 'حدّد الرف الذي تُخزَّن فيه دفعة: ${l.product['name_ar']}';
      }
    }
    if (err == null && !_validDate(_date.text.trim())) err = 'تاريخ الفاتورة بصيغة 2026-11-27.';
    if (err == null && _method == 'credit' && _supplier == null) err = 'الشراء الآجل يتطلب اختيار المورّد.';
    if (err == null && _method == 'credit' && _due.text.trim().isNotEmpty && !_validDate(_due.text.trim())) err = 'تاريخ الاستحقاق بصيغة 2026-12-31.';
    if (err == null && _method == 'cash' && widget.ctx.sessionId == null) err = 'الدفع النقدي من الصندوق يتطلب وردية مفتوحة لحسابك.';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('receive_purchase', {
        'p_operation_id': _opId,
        'p_payload': {
          'branch_id': widget.ctx.branchId,
          if (_supplier != null) 'supplier_id': _supplier,
          'reference': _reference.text.trim(),
          'supplier_invoice_date': _date.text.trim(),
          'payment_method': _method,
          if (_method == 'credit' && _due.text.trim().isNotEmpty) 'due_date': _due.text.trim(),
          if (_method == 'cash') 'cash_session_id': widget.ctx.sessionId,
          'tax_rate_bp': _rateBp,
          'lines': [
            for (final l in _lines)
              {
                'product_id': l.product['product_id'], 'qty': parseMilli(l.qty.text)! / 1000, 'unit_cost_baisa': parseOmr(l.cost.text),
                if (l.dot.text.trim().isNotEmpty) 'dot_code': l.dot.text.trim(),
                if (int.tryParse(l.year.text.trim()) != null) 'tire_year': int.parse(l.year.text.trim()),
                if (int.tryParse(l.week.text.trim()) != null) 'tire_week': int.parse(l.week.text.trim()),
                if (l.country.text.trim().isNotEmpty) 'country': l.country.text.trim(),
                if (l.shelf.text.trim().isNotEmpty) 'shelf': l.shelf.text.trim(),
                if (l.note.text.trim().isNotEmpty) 'note': l.note.text.trim(),
              },
          ],
        }
      });
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _opId = const Uuid().v4();
      _error = e.code == 'INSUFFICIENT_CASH' ? 'النقد في درج ورديتك لا يكفي لهذا الشراء.' : errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال. اضغط «استلام» مجددًا للتحقق؛ لن يُسجَّل الاستلام مرتين.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final sub = _subtotal();
    final tax = roundDiv(sub * _rateBp, 10000);
    final matches = _matches();
    final sup = _suppliers.where((s) => s['id'] == _supplier).toList();
    return AlertDialog(
      title: const Text('استلام مشتريات'),
      content: SizedBox(
        width: 1060,
        height: 660,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 3,
              child: _labeled(
                  'المورّد',
                  DropdownButton<String?>(
                    value: _supplier,
                    isExpanded: true,
                    isDense: true,
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('— بلا مورّد —')),
                      for (final s in _suppliers) DropdownMenuItem<String?>(value: s['id'] as String, child: Text('${s['name']}')),
                    ],
                    onChanged: (v) => setState(() => _supplier = v),
                  )),
            ),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: _input(_reference, 'رقم فاتورة المورّد', ltr: true)),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: _input(_date, 'تاريخ الفاتورة', ltr: true)),
          ]),
          if (sup.isNotEmpty && sup.first['balance_baisa'] != null)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text('رصيد حساب المورّد (مستحق له): ${money(_i(sup.first['balance_baisa']))}', style: const TextStyle(color: Brand.muted))),
          const SizedBox(height: 10),
          Row(children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [for (final m in _purchaseMethods.entries) ButtonSegment(value: m.key, label: Text(m.value))],
              selected: {_method},
              onSelectionChanged: (s) => setState(() => _method = s.first),
            ),
            const SizedBox(width: 10),
            if (_method == 'credit') SizedBox(width: 190, child: _input(_due, 'تاريخ الاستحقاق (اختياري)', ltr: true)),
            const Spacer(),
            Checkbox(value: _vat, onChanged: (v) => setState(() => _vat = v ?? false)),
            Text('ضريبة مدخلات ${formatQty((widget.ctx.tax.rateBp > 0 ? widget.ctx.tax.rateBp : 500) * 10)}%'),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _search,
            focusNode: _searchFocus,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'أضف صنفًا: اكتب الاسم أو المقاس أو الماركة ثم Enter', isDense: true, prefixIcon: Icon(Icons.search)),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              final m = _matches();
              if (m.isNotEmpty) _add(m.first);
            },
          ),
          if (matches.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 150),
              decoration: BoxDecoration(border: Border.all(color: Brand.line), borderRadius: BorderRadius.circular(8)),
              child: ListView(shrinkWrap: true, children: [
                for (final p in matches)
                  InkWell(
                    onTap: () => _add(p),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      child: Row(children: [
                        Expanded(child: Text('${p['name_ar']}${p['tire_size'] != null ? '  ${p['tire_size']}' : ''}')),
                        Text('الرصيد ${_qtyText(p['qty'])}', style: const TextStyle(color: Brand.muted)),
                      ]),
                    ),
                  ),
              ]),
            ),
          const SizedBox(height: 8),
          _head([('الصنف', 5), ('الكمية', 2), ('تكلفة الوحدة (بلا ضريبة)', 3), ('الإجمالي', 2), ('', 1)]),
          Expanded(
            child: _lines.isEmpty
                ? _note('لم تُضف أصناف بعد.')
                : ListView(children: [
                    for (final l in _lines)
                      Container(
                        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        child: Column(children: [
                         Row(children: [
                          _cell('${l.product['name_ar']}${l.product['tire_size'] != null ? '  ${l.product['tire_size']}' : ''}', flex: 5, bold: true),
                          Expanded(flex: 2, child: Padding(padding: const EdgeInsets.only(left: 8), child: TextField(controller: l.qty, textDirection: TextDirection.ltr, decoration: const InputDecoration(isDense: true), onChanged: (_) => setState(() {})))),
                          Expanded(flex: 3, child: Padding(padding: const EdgeInsets.only(left: 8), child: TextField(controller: l.cost, textDirection: TextDirection.ltr, decoration: const InputDecoration(isDense: true), onChanged: (_) => setState(() {})))),
                          _cell(
                              parseMilli(l.qty.text) != null && parseOmr(l.cost.text) != null ? formatOmr(roundDiv(parseMilli(l.qty.text)! * parseOmr(l.cost.text)!, 1000)) : '—',
                              flex: 2,
                              num: true),
                          Expanded(
                            flex: 1,
                            child: IconButton(
                              tooltip: 'حذف السطر',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => setState(() {
                                _lines.remove(l);
                                l.dispose();
                              }),
                            ),
                          ),
                         ]),
                         const SizedBox(height: 6),
                         Row(children: [
                          if (l.isTire) ...[
                            Expanded(flex: 2, child: _batchField(l.dot, 'DOT (أسبوع+سنة)', hint: '2325')),
                            Expanded(flex: 2, child: _batchField(l.year, 'سنة الصنع', hint: '2025')),
                            Expanded(flex: 2, child: _batchField(l.week, 'الأسبوع')),
                            Expanded(flex: 3, child: _batchField(l.country, 'بلد الصنع', ltr: false)),
                          ],
                          Expanded(flex: 2, child: _batchField(l.shelf, l.isTire ? 'الرف *' : 'الرف', hint: 'A-3')),
                          Expanded(flex: 4, child: _batchField(l.note, 'ملاحظة الدفعة', ltr: false)),
                          if (l.isTire)
                            TextButton(onPressed: () => _add(l.product), child: const Text('+ دفعة أخرى'))
                          else
                            const Spacer(flex: 9),
                         ]),
                        ]),
                      ),
                  ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Text('قبل الضريبة ${formatOmr(sub)}   ·   الضريبة ${formatOmr(tax)}', style: const TextStyle(fontSize: 15)),
              const Spacer(),
              Text('المستحق ${money(sub + tax)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            ]),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Brand.bad, fontSize: 16))),
        ]),
      ),
      actions: [
        OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ الاستلام…' : 'استلام وإضافة للمخزون')),
      ],
    );
  }
}

class SupplierDialog extends StatefulWidget {
  final ShiftContext ctx;
  const SupplierDialog({super.key, required this.ctx});
  @override
  State<SupplierDialog> createState() => _SupplierState();
}

class _SupplierState extends State<SupplierDialog> {
  final _name = TextEditingController(), _phone = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'اسم المورّد مطلوب.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('save_supplier', {'p_supplier': {'organization_id': widget.ctx.organizationId, 'name': _name.text.trim(), 'phone': _phone.text.trim()}});
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = _fail(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('مورّد جديد'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _input(_name, 'اسم المورّد', autofocus: true),
            const SizedBox(height: 10),
            _input(_phone, 'الهاتف (اختياري)', ltr: true),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('حفظ')),
        ],
      );
}

/// سداد للمورّد من المستحق له: نقدي من درج الوردية أو تحويل بنكي.
class PaySupplierDialog extends StatefulWidget {
  final ShiftContext ctx;
  final Map<String, dynamic> supplier;
  const PaySupplierDialog({super.key, required this.ctx, required this.supplier});
  @override
  State<PaySupplierDialog> createState() => _PaySupplierState();
}

class _PaySupplierState extends State<PaySupplierDialog> {
  late final _amount = TextEditingController(text: formatOmr(_i(widget.supplier['balance_baisa'])));
  final _ref = TextEditingController();
  String _method = 'transfer';
  String _opId = const Uuid().v4();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseOmr(_amount.text);
    String? err;
    if (amount == null || amount <= 0) err = 'أدخل مبلغًا صحيحًا.';
    if (err == null && amount! > _i(widget.supplier['balance_baisa'])) err = 'المبلغ أكبر من المستحق للمورّد.';
    if (err == null && _method == 'cash' && widget.ctx.sessionId == null) err = 'السداد النقدي يتطلب وردية مفتوحة لحسابك.';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('pay_supplier', {
        'p_operation_id': _opId, 'p_branch_id': widget.ctx.branchId, 'p_supplier_id': widget.supplier['id'], 'p_method': _method,
        'p_amount_baisa': amount, 'p_reference': _ref.text.trim().isEmpty ? null : _ref.text.trim(),
        'p_cash_session_id': _method == 'cash' ? widget.ctx.sessionId : null,
      });
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _opId = const Uuid().v4();
      _error = e.code == 'INSUFFICIENT_CASH' ? 'النقد في درج ورديتك لا يكفي.' : errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال. اضغط «سداد» مجددًا للتحقق؛ لن يُسجَّل المبلغ مرتين.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('سداد للمورّد ${widget.supplier['name']}'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('المستحق له: ${money(_i(widget.supplier['balance_baisa']))}', style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: 'transfer', label: Text('تحويل بنكي')), ButtonSegment(value: 'cash', label: Text('نقدي من الصندوق'))],
              selected: {_method},
              onSelectionChanged: (s) => setState(() => _method = s.first),
            ),
            const SizedBox(height: 12),
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
            _input(_ref, 'المرجع (اختياري)', ltr: true),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ التسجيل…' : 'سداد')),
        ],
      );
}


/// دفعات الصنف في هذا الفرع: كل دفعة بكميتها وسنتها وبلد صنعها ورفّها. من يملك إدارة المخزون يعدّل الرف وبيانات الدفعة.
class BatchesDialog extends StatefulWidget {
  final ShiftContext ctx;
  final Map<String, dynamic> row;
  const BatchesDialog({super.key, required this.ctx, required this.row});
  @override
  State<BatchesDialog> createState() => _BatchesState();
}

class _BatchesState extends State<BatchesDialog> {
  late List<Map<String, dynamic>> _lots = _maps(widget.row['lots']);
  bool _changed = false, _busy = false;
  String? _error;

  bool get _canEdit => widget.ctx.permissions.contains('inventory.manage');

  Future<void> _edit(Map<String, dynamic> lot) async {
    final shelf = TextEditingController(text: '${lot['shelf'] ?? ''}'), year = TextEditingController(text: '${lot['tire_year'] ?? ''}');
    final week = TextEditingController(text: '${lot['tire_week'] ?? ''}'), country = TextEditingController(text: '${lot['country'] ?? ''}');
    final note = TextEditingController(text: '${lot['note'] ?? ''}');
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('بيانات الدفعة'),
              content: SizedBox(
                width: 460,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  _input(shelf, 'الرف', ltr: true, autofocus: true),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: _input(year, 'سنة الصنع', ltr: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _input(week, 'الأسبوع', ltr: true)),
                    const SizedBox(width: 10),
                    Expanded(flex: 2, child: _input(country, 'بلد الصنع')),
                  ]),
                  const SizedBox(height: 10),
                  _input(note, 'ملاحظة'),
                ]),
              ),
              actions: [
                OutlinedButton(onPressed: () => Navigator.pop(c, false), child: const Text('رجوع')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('حفظ')),
              ],
            ));
    final y = int.tryParse(year.text.trim()), w = int.tryParse(week.text.trim());
    final patch = <String, dynamic>{'shelf': shelf.text.trim(), 'country': country.text.trim(), 'note': note.text.trim(), 'tire_year': y, 'tire_week': w};
    final bad = (year.text.trim().isNotEmpty && (y == null || y < 2000 || y > 2100)) || (week.text.trim().isNotEmpty && (w == null || w < 1 || w > 53));
    if (ok != true || !mounted) return;
    if (bad) {
      setState(() => _error = 'سنة الصنع أو الأسبوع غير صالح.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final r = (await Api.rpc('update_lot', {'p_lot_id': lot['lot_id'], 'p': patch}) as Map).cast<String, dynamic>();
      _lots = [for (final l in _lots) l['lot_id'] == lot['lot_id'] ? {...l, ...r} : l];
      _changed = true;
    } catch (e) {
      _error = _fail(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final showCost = _lots.any((l) => l['unit_cost_baisa'] != null);
    return AlertDialog(
      title: Text('الدفعات والرفوف — ${r['name_ar']}${r['tire_size'] != null ? '  ${r['tire_size']}' : ''}'),
      content: SizedBox(
        width: 980,
        height: 460,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _head([('تاريخ الاستلام', 2), ('فاتورة المورّد', 2), ('DOT', 1), ('السنة', 1), ('الأسبوع', 1), ('بلد الصنع', 2), ('الرف', 2), ('المتبقي', 2), if (showCost) ('التكلفة', 2), ('ملاحظة', 3), ('', 1)]),
          Expanded(
            child: _lots.isEmpty
                ? _note('لا توجد دفعات فيها رصيد لهذا الصنف في هذا الفرع.')
                : ListView(children: [
                    for (final l in _lots)
                      Container(
                        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Brand.line))),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        child: Row(children: [
                          _cell('${l['received_at']}'.substring(0, 10), flex: 2, num: true),
                          _cell('${l['reference'] ?? l['lot_code'] ?? '—'}', flex: 2, num: true),
                          _cell('${l['dot_code'] ?? '—'}', flex: 1, num: true),
                          _cell('${l['tire_year'] ?? '—'}', flex: 1, num: true),
                          _cell('${l['tire_week'] ?? '—'}', flex: 1, num: true),
                          _cell('${l['country'] ?? '—'}', flex: 2),
                          _cell('${l['shelf'] ?? '—'}', flex: 2, num: true, bold: true, color: l['shelf'] == null ? Brand.bad : null),
                          _cell('${_qtyText(l['qty'])} من ${_qtyText(l['qty_received'])}', flex: 2),
                          if (showCost) _cell(l['unit_cost_baisa'] == null ? '—' : formatOmr(_i(l['unit_cost_baisa'])), flex: 2, num: true),
                          _cell('${l['note'] ?? ''}', flex: 3),
                          Expanded(flex: 1, child: _canEdit ? TextButton(onPressed: _busy ? null : () => _edit(l), child: const Text('تعديل')) : const SizedBox.shrink()),
                        ]),
                      ),
                  ]),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('البيع يسحب من الدفعة الأقدم استلامًا أولًا. عند نقل الإطارات إلى رف آخر عدّل الرف هنا.', style: TextStyle(color: Brand.muted)),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Brand.bad, fontSize: 16))),
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context, _changed), child: const Text('إغلاق (Esc)'))],
    );
  }
}
