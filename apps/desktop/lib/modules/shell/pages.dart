import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../cash/close_shift_dialog.dart';
import '../cash/shift_gate.dart';
import '../pos/dialogs.dart';
import '../printing/printer_settings_dialog.dart';
import '../printing/receipt.dart';

part 'inventory_pages.dart';
part 'more_pages.dart';

/// هيكل صفحة: عنوان، أدوات، ومحتوى داخل بطاقة بيضاء.
class _Page extends StatelessWidget {
  final String title;
  final List<Widget> tools;
  final Widget child;
  const _Page({required this.title, this.tools = const [], required this.child});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), const SizedBox(width: 16), ...tools]),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Brand.line), borderRadius: BorderRadius.circular(12)),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        ]),
      );
}

Widget _note(String text, {bool bad = false}) =>
    Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: bad ? Brand.bad : Brand.muted))));

Widget _cell(String t, {int flex = 1, bool num = false, bool bold = false, Color? color}) => Expanded(
      flex: flex,
      child: Text(t,
          overflow: TextOverflow.ellipsis,
          textDirection: num ? TextDirection.ltr : null,
          textAlign: num ? TextAlign.right : null,
          style: TextStyle(fontSize: 16, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color)),
    );

Widget _head(List<(String, int)> cols) => Container(
      color: Brand.ink,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [for (final (t, f) in cols) Expanded(flex: f, child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)))]),
    );

String _fail(Object e) => e is BusinessError ? errorMessage(e.code) : 'لا يوجد اتصال بالخادم.';

/// تحصيل من رصيد العميل الآجل: نقدي (يدخل درج الوردية) أو بطاقة أو تحويل بنكي.
class CollectDialog extends StatefulWidget {
  final String sessionId, customerId, customerName;
  final int balanceBaisa;
  const CollectDialog({super.key, required this.sessionId, required this.customerId, required this.customerName, required this.balanceBaisa});
  @override
  State<CollectDialog> createState() => _CollectState();
}

class _CollectState extends State<CollectDialog> {
  late final _amount = TextEditingController(text: formatOmr(widget.balanceBaisa));
  final _ref = TextEditingController();
  String _method = 'cash';
  String _opId = const Uuid().v4(); // يُعاد استخدامه عند إعادة المحاولة حتى لا يُحصَّل مرتين
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _amount.selection = TextSelection(baseOffset: 0, extentOffset: _amount.text.length);
  }

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseOmr(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'أدخل مبلغًا صحيحًا.');
      return;
    }
    if (amount > widget.balanceBaisa) {
      setState(() => _error = 'المبلغ أكبر من الرصيد (${formatOmr(widget.balanceBaisa)}).');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('collect_customer_payment', {
        'p_operation_id': _opId, 'p_cash_session_id': widget.sessionId, 'p_customer_id': widget.customerId,
        'p_method': _method, 'p_amount_baisa': amount, 'p_reference': _ref.text.trim().isEmpty ? null : _ref.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _opId = const Uuid().v4();
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال. اضغط «تحصيل» مجددًا للتحقق؛ لن يُسجَّل المبلغ مرتين.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('تحصيل من ${widget.customerName}'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('الرصيد الآجل: ${money(widget.balanceBaisa)}', style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'cash', label: Text('نقدي')), ButtonSegment(value: 'card', label: Text('بطاقة')), ButtonSegment(value: 'transfer', label: Text('تحويل بنكي'))],
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
              decoration: InputDecoration(labelText: 'المبلغ المحصَّل (${Currency.symbol})'),
              onSubmitted: (_) => _save(),
            ),
            if (_method != 'cash')
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextField(controller: _ref, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'المرجع (اختياري)'), onSubmitted: (_) => _save()),
              ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ التسجيل…' : 'تحصيل (Enter)')),
        ],
      );
}

