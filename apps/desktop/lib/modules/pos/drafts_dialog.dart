import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import 'cart.dart';

/// F6 والسلة فيها بنود: حفظ السلة كمسودة في الخادم (تظهر لكل كاشير في الفرع).
class SaveDraftDialog extends StatefulWidget {
  final String sessionId;
  final Cart cart;
  final int totalBaisa;
  const SaveDraftDialog({super.key, required this.sessionId, required this.cart, required this.totalBaisa});
  @override
  State<SaveDraftDialog> createState() => _SaveState();
}

class _SaveState extends State<SaveDraftDialog> {
  late final _title = TextEditingController(
      text: [widget.cart.customer?.plate, widget.cart.customer?.name].whereType<String>().join(' — '));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'اكتب اسمًا للمسودة، مثل رقم اللوحة أو اسم العميل.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('save_draft', {
        'p_id': null,
        'p_cash_session_id': widget.sessionId,
        'p_title': title,
        'p_total_baisa': widget.totalBaisa,
        'p_payload': widget.cart.toDraft(),
      });
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'لا يوجد اتصال. لم تُحفظ المسودة والسلة كما هي.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('حفظ كمسودة'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${widget.cart.lines.length} بنود — ${money(widget.totalBaisa)}', style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 12),
            TextField(controller: _title, autofocus: true, decoration: const InputDecoration(labelText: 'اسم المسودة (اللوحة أو العميل)'), onSubmitted: (_) => _save()),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'جارٍ الحفظ…' : 'حفظ (Enter)')),
        ],
      );
}

/// F6 والسلة فارغة: فتح مسودة محفوظة. يعيد حمولة المسودة المختارة بعد حذفها من الخادم.
class DraftListDialog extends StatefulWidget {
  final String branchId;
  const DraftListDialog({super.key, required this.branchId});
  @override
  State<DraftListDialog> createState() => _ListState();
}

class _ListState extends State<DraftListDialog> {
  List<Map<String, dynamic>>? _rows;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final r = await Api.rpc('list_drafts', {'p_branch_id': widget.branchId});
      if (mounted) setState(() { _rows = (r as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList(); _error = null; });
    } on BusinessError catch (e) {
      if (mounted) setState(() => _error = errorMessage(e.code));
    } on NoResponseError {
      if (mounted) setState(() => _error = 'لا يوجد اتصال بالخادم.');
    }
  }

  Future<void> _open(Map<String, dynamic> row) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // تُحذف المسودة عند فتحها حتى لا تُباع مرتين من جهازين
      await Api.rpc('delete_draft', {'p_id': row['id'], 'p_reason': 'opened'});
      if (mounted) Navigator.pop(context, (row['payload'] as Map).cast<String, dynamic>());
      return;
    } on BusinessError catch (e) {
      _error = e.code == 'NOT_FOUND' ? 'فُتحت هذه المسودة من جهاز آخر.' : errorMessage(e.code);
      await _load();
    } on NoResponseError {
      _error = 'لا يوجد اتصال. لم تُفتح المسودة.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('المسودات المحفوظة'),
        content: SizedBox(
          width: 560,
          height: 380,
          child: Column(children: [
            if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
            Expanded(
              child: _rows == null
                  ? const Center(child: CircularProgressIndicator())
                  : _rows!.isEmpty
                      ? const Center(child: Text('لا توجد مسودات. أضف بنودًا ثم اضغط F6 لحفظها.', style: TextStyle(color: Brand.muted)))
                      : ListView(children: [
                          for (final (i, r) in _rows!.indexed)
                            ListTile(
                              autofocus: i == 0,
                              title: Text(r['title'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text('${r['created_by_name']}'),
                              trailing: Text(formatOmr((r['total_baisa'] as num).toInt()), textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                              onTap: () => _open(r),
                            ),
                        ]),
            ),
          ]),
        ),
        actions: [OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق (Esc)'))],
      );
}
