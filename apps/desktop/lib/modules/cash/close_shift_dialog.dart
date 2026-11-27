import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';

/// F10: مراجعة وإقفال الوردية. يعيد true إذا أُقفلت الوردية.
/// النقد المتوقع = الافتتاحي + المبيعات النقدية. إجمالي البطاقة يُعرض منفصلًا ولا يدخل في عدّ الدرج.
class CloseShiftDialog extends StatefulWidget {
  final String sessionId;
  const CloseShiftDialog({super.key, required this.sessionId});
  @override
  State<CloseShiftDialog> createState() => _State();
}

class _State extends State<CloseShiftDialog> {
  Map<String, dynamic>? _summary; // قبل الإقفال
  Map<String, dynamic>? _closed; // بعد الإقفال
  final _counted = TextEditingController();
  final _note = TextEditingController();
  final _noteFocus = FocusNode();
  // المعرّف نفسه يُعاد استخدامه عند إعادة المحاولة ما دامت المدخلات لم تتغير
  String _opId = const Uuid().v4();
  String? _opInputs;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _counted.addListener(() => setState(() => _error = null));
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _counted.dispose();
    _note.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  int _n(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;

  Future<void> _load() async {
    setState(() { _busy = true; _error = null; });
    try {
      final s = (await Api.rpc('cash_session_summary', {'p_cash_session_id': widget.sessionId}) as Map).cast<String, dynamic>();
      if (mounted) setState(() => _summary = s);
    } on BusinessError catch (e) {
      if (mounted) setState(() => _error = errorMessage(e.code));
    } on NoResponseError {
      if (mounted) setState(() => _error = 'لا يوجد اتصال بالخادم. لا يمكن مراجعة الإقفال الآن.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _close() async {
    if (_busy || _summary == null) return;
    final counted = parseOmr(_counted.text);
    if (counted == null) {
      setState(() => _error = 'أدخل النقد الفعلي المعدود في الدرج، مثل 55 أو 55.500');
      return;
    }
    final diff = counted - _n(_summary!, 'expected_cash_baisa');
    final note = _note.text.trim();
    if (diff != 0 && note.isEmpty) {
      setState(() => _error = 'يوجد فرق ${formatOmr(diff)}. اكتب سبب الفرق قبل الإقفال.');
      _noteFocus.requestFocus();
      return;
    }
    if (Api.online.value == false) {
      setState(() => _error = 'لا يوجد اتصال بالخادم. الإقفال متوقف حتى يعود الاتصال.');
      return;
    }
    final inputs = '$counted|$note';
    if (_opInputs != inputs) {
      _opId = const Uuid().v4();
      _opInputs = inputs;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final r = (await Api.rpc('close_cash_session', {
        'p_operation_id': _opId,
        'p_cash_session_id': widget.sessionId,
        'p_counted_cash_baisa': counted,
        'p_note': note.isEmpty ? null : note,
      }) as Map).cast<String, dynamic>();
      if (mounted) setState(() => _closed = (r['summary'] as Map).cast<String, dynamic>());
    } on BusinessError catch (e) {
      _opInputs = null;
      if (e.code == 'CLOSE_NOTE_REQUIRED') {
        // بيع سُجّل بعد عرض المراجعة فتغيّر المتوقع: نحدّث الأرقام ونطلب السبب
        var d = 0;
        try {
          d = ((jsonDecode(e.detail ?? '{}') as Map)['difference_baisa'] as num).toInt();
        } catch (_) {}
        await _load();
        if (mounted) setState(() => _error = 'تغيّر النقد المتوقع. الفرق الآن ${formatOmr(d)}. اكتب السبب ثم أعد الإقفال.');
      } else if (mounted) {
        setState(() => _error = errorMessage(e.code));
      }
    } on NoResponseError {
      // لم يصل رد: المعرّف يبقى كما هو، وإعادة الضغط تعيد النتيجة نفسها إن كان الإقفال قد تم
      if (mounted) setState(() => _error = 'انقطع الاتصال أثناء الإقفال. اضغط «إقفال الوردية» مجددًا للتحقق من النتيجة.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_closed != null) return _doneView(_closed!);
    final s = _summary;
    final counted = parseOmr(_counted.text);
    final diff = (s != null && counted != null) ? counted - _n(s, 'expected_cash_baisa') : null;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.f9): _close},
      child: AlertDialog(
        title: const Text('إقفال الوردية'),
        content: SizedBox(
          width: 520,
          child: s == null
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad, fontSize: 16))),
                ])
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _row('عدد الفواتير', '${_n(s, 'invoice_count')}'),
                  _row('إجمالي المبيعات', formatOmr(_n(s, 'total_sales_baisa'))),
                  _row('مدفوعات البطاقة (خارج الدرج)', formatOmr(_n(s, 'card_baisa'))),
                  _row('تحويلات بنكية (خارج الدرج)', formatOmr(_n(s, 'transfer_baisa'))),
                  _row('مبيعات آجلة (على حساب العملاء)', formatOmr(_n(s, 'credit_baisa'))),
                  const Divider(height: 20),
                  _row('النقد الافتتاحي', formatOmr(_n(s, 'opening_cash_baisa'))),
                  _row('المبيعات النقدية', formatOmr(_n(s, 'cash_sales_baisa'))),
                  if (_n(s, 'cash_other_baisa') != 0) _row('قبض وصرف نقدي', formatOmr(_n(s, 'cash_other_baisa'))),
                  _row('النقد المتوقع في الدرج', formatOmr(_n(s, 'expected_cash_baisa')), big: true),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _counted,
                    autofocus: true,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                    decoration: InputDecoration(labelText: 'النقد الفعلي المعدود (${Currency.symbol})'),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => (diff != null && diff != 0) ? _noteFocus.requestFocus() : _close(),
                  ),
                  const SizedBox(height: 10),
                  if (diff != null)
                    _row(
                      diff == 0 ? 'مطابق' : (diff < 0 ? 'عجز في الصندوق' : 'زيادة في الصندوق'),
                      formatOmr(diff),
                      big: true,
                      color: diff == 0 ? Brand.ok : Brand.bad,
                    ),
                  if (diff != null && diff != 0) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _note,
                      focusNode: _noteFocus,
                      decoration: const InputDecoration(labelText: 'سبب الفرق (مطلوب)'),
                      onSubmitted: (_) => _close(),
                    ),
                  ],
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad, fontSize: 16))),
                  if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
                ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          if (s != null) FilledButton(onPressed: _busy ? null : _close, child: const Text('إقفال الوردية (F9)')),
        ],
      ),
    );
  }

  Widget _doneView(Map<String, dynamic> s) {
    final diff = _n(s, 'difference_baisa');
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('أُقفلت الوردية'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _row('النقد المتوقع', formatOmr(_n(s, 'expected_cash_baisa'))),
            _row('النقد الفعلي', formatOmr(_n(s, 'counted_cash_baisa'))),
            _row(diff == 0 ? 'مطابق' : (diff < 0 ? 'عجز' : 'زيادة'), formatOmr(diff), big: true, color: diff == 0 ? Brand.ok : Brand.bad),
            const Divider(height: 20),
            _row('مدفوعات البطاقة', formatOmr(_n(s, 'card_baisa'))),
            _row('تحويلات بنكية', formatOmr(_n(s, 'transfer_baisa'))),
            _row('مبيعات آجلة', formatOmr(_n(s, 'credit_baisa'))),
            _row('عدد الفواتير', '${_n(s, 'invoice_count')}'),
          ]),
        ),
        actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(context, true), child: const Text('تم (Enter)'))],
      ),
    );
  }

  Widget _row(String k, String v, {bool big = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: TextStyle(fontSize: big ? 18 : 16, color: color ?? (big ? Brand.ink : Brand.muted), fontWeight: big ? FontWeight.w700 : FontWeight.w400)),
          Text(v, textDirection: TextDirection.ltr, style: TextStyle(fontSize: big ? 26 : 17, fontWeight: big ? FontWeight.w800 : FontWeight.w600, color: color ?? Brand.ink)),
        ]),
      );
}
