import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';

/// F5: قبض أو صرف نقدي من الدرج بسبب مكتوب. يدخل في النقد المتوقع عند الإقفال.
class CashMovementDialog extends StatefulWidget {
  final String sessionId;
  const CashMovementDialog({super.key, required this.sessionId});
  @override
  State<CashMovementDialog> createState() => _State();
}

class _State extends State<CashMovementDialog> {
  String _type = 'cash_out';
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _noteFocus = FocusNode();
  String _opId = const Uuid().v4();
  String? _opInputs, _error, _done;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _noteFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final amount = parseOmr(_amount.text);
    final note = _note.text.trim();
    if (amount == null || amount <= 0) {
      setState(() => _error = 'أدخل المبلغ، مثل 5 أو 2.500');
      return;
    }
    if (note.isEmpty) {
      setState(() => _error = 'اكتب سبب ${_type == 'cash_out' ? 'الصرف' : 'القبض'}.');
      _noteFocus.requestFocus();
      return;
    }
    final inputs = '$_type|$amount|$note';
    if (_opInputs != inputs) {
      _opId = const Uuid().v4();
      _opInputs = inputs;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final r = (await Api.rpc('record_cash_movement', {
        'p_operation_id': _opId, 'p_cash_session_id': widget.sessionId, 'p_type': _type, 'p_amount_baisa': amount, 'p_note': note,
      }) as Map).cast<String, dynamic>();
      if (mounted) setState(() => _done = 'سُجّل ${_type == 'cash_out' ? 'الصرف' : 'القبض'}. النقد المتوقع في الدرج الآن ${money((r['drawer_baisa'] as num).toInt())}');
    } on BusinessError catch (e) {
      _opInputs = null;
      if (mounted) setState(() => _error = e.code == 'INSUFFICIENT_CASH' ? 'المبلغ أكبر من النقد الموجود في الدرج.' : errorMessage(e.code));
    } on NoResponseError {
      if (mounted) setState(() => _error = 'انقطع الاتصال. اضغط «تسجيل» مجددًا للتحقق؛ لن تُسجَّل الحركة مرتين.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_done != null) {
      return AlertDialog(
        title: const Text('قبض وصرف نقدي'),
        content: SizedBox(width: 420, child: Text(_done!, style: const TextStyle(fontSize: 17, color: Brand.ok))),
        actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('تم (Enter)'))],
      );
    }
    return AlertDialog(
      title: const Text('قبض وصرف نقدي'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'cash_out', label: Text('صرف من الدرج')), ButtonSegment(value: 'cash_in', label: Text('قبض إلى الدرج'))],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.first),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _amount,
            autofocus: true,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            decoration: InputDecoration(labelText: 'المبلغ (${Currency.symbol})'),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _noteFocus.requestFocus(),
          ),
          const SizedBox(height: 12),
          TextField(controller: _note, focusNode: _noteFocus, decoration: const InputDecoration(labelText: 'السبب (إلزامي)'), onSubmitted: (_) => _save()),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
        ]),
      ),
      actions: [
        OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('رجوع (Esc)')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ التسجيل…' : 'تسجيل (Enter)')),
      ],
    );
  }
}
