import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../pos/cart.dart';
import '../pos/pos_screen.dart';
import '../shell/pages.dart';

/// سياق المستخدم على هذا الجهاز. [sessionId] = null يعني لا وردية: الحساب يتصفح ولا يصدر فواتير.
class ShiftContext {
  final String userName, organizationId, branchId, branchName, branchCode, deviceId, deviceName;
  final String? sessionId;
  final bool canOpenShift;
  final TaxSettings tax;
  final int maxDiscountBp;
  final Set<String> permissions;
  const ShiftContext({
    required this.userName, required this.organizationId, required this.branchId, required this.branchName, required this.branchCode, required this.deviceId,
    required this.deviceName, required this.sessionId, required this.canOpenShift, required this.tax, required this.maxDiscountBp, required this.permissions,
  });
}

enum _Tab {
  sale('البيع'), inventory('المخزون'), purchases('المشتريات'), customers('العملاء'), day('اليومية'), reports('التقارير'), settings('الإعدادات');

  final String label;
  const _Tab(this.label);
}

/// الهيكل الرئيسي بعد الدخول: شريط علوي بأقسام النظام. الدخول لا يتطلب وردية؛ الوردية شرط لإصدار الفواتير فقط.
class ShiftGate extends StatefulWidget {
  const ShiftGate({super.key});
  @override
  State<ShiftGate> createState() => _State();
}

class _State extends State<ShiftGate> {
  ShiftContext? _ctx;
  String? _error;
  // جهاز غير مسجّل: يُعرض نموذج تسجيله لمن يملك الصلاحية
  List<Map<String, dynamic>> _regBranches = [];
  String? _regBranch;
  final _regName = TextEditingController(text: 'صندوق');
  bool _needsDevice = false;
  bool _loading = true;
  _Tab _tab = _Tab.sale;
  Set<String> _tabs = const {'sale', 'customers'};

  List<_Tab> get _visible {
    final v = [for (final t in _Tab.values) if (_tabs.contains(t.name)) t];
    return v.isEmpty ? const [_Tab.customers] : v;
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; _needsDevice = false; });
    try {
      final ctx = (await Api.rpc('my_context') as Map).cast<String, dynamic>();
      final Map<String, dynamic> dev;
      try {
        dev = (await Api.rpc('resolve_device', {'p_code': Api.config.deviceCode}) as Map).cast<String, dynamic>();
      } on BusinessError catch (e) {
        if (e.code != 'DEVICE_NOT_FOUND') rethrow;
        _regBranches = ((ctx['branches'] as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        _regBranch = _regBranches.isEmpty ? null : _regBranches.first['id'] as String;
        _needsDevice = true;
        _error = 'هذا الجهاز (${Api.config.deviceCode}) غير مسجّل في أي فرع.';
        if (mounted) setState(() => _loading = false);
        return;
      }
      final device = (dev['device'] as Map).cast<String, dynamic>();
      final user = (ctx['user'] as Map?)?.cast<String, dynamic>();
      if (user == null) throw BusinessError('FORBIDDEN');
      final b = (ctx['branches'] as List).cast<Map>().firstWhere((x) => x['id'] == device['branch_id']).cast<String, dynamic>();
      final session = (dev['open_session'] as Map?)?.cast<String, dynamic>();
      // الأدوار المسموح لها بفتح وردية في هذا الفرع تُضبط من إعدادات النظام (الكاشير افتراضيًا)
      final settings = await Api.client.from('branch_settings').select('shift_roles').eq('branch_id', b['id'] as String).maybeSingle().timeout(const Duration(seconds: 10));
      final allowed = ((settings?['shift_roles'] as List?) ?? const ['cashier']).cast<String>();
      final perms = (b['permissions'] as List).cast<String>().toSet();
      final roles = ((b['roles'] as List?) ?? const []).cast<String>().toSet();
      // الأقسام الظاهرة لهذا الحساب والعملة تأتي من إعدادات المنشأة. عند تعذّرها: الافتراضي حسب الدور.
      try {
        final st = (await Api.rpc('app_settings', {'p_branch_id': b['id']}) as Map).cast<String, dynamic>();
        Currency.apply(st);
        _tabs = ((st['my_tabs'] as List?) ?? const []).cast<String>().toSet();
      } on NoResponseError {
        rethrow;
      } catch (_) {
        _tabs = roles.contains('owner') || roles.contains('branch_manager')
            ? {for (final t in _Tab.values) t.name}
            : roles.contains('accountant') ? {'customers', 'inventory', 'purchases', 'day', 'reports'} : {'sale', 'customers'};
      }
      if (!_visible.contains(_tab)) _tab = _visible.first;
      _ctx = ShiftContext(
        userName: user['full_name'] as String, organizationId: b['organization_id'] as String, branchId: b['id'] as String, branchName: b['name_ar'] as String, branchCode: b['code'] as String,
        deviceId: device['id'] as String, deviceName: device['name'] as String, sessionId: session?['id'] as String?,
        canOpenShift: perms.contains('cash.open') && ((b['roles'] as List?) ?? const []).cast<String>().any(allowed.contains),
        tax: TaxSettings(enabled: b['tax_enabled'] as bool, rateBp: (b['tax_rate_bp'] as num).toInt(), pricesIncludeTax: b['prices_include_tax'] as bool),
        maxDiscountBp: (b['max_discount_bp'] as num?)?.toInt() ?? 0, permissions: perms,
      );
    } on BusinessError catch (e) {
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'لا يوجد اتصال بالخادم. النظام يعمل بالاتصال فقط.';
    } catch (_) {
      _error = 'هذا الجهاز غير مرتبط بفرع ضمن صلاحياتك.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _registerDevice() async {
    if (_regBranch == null) return;
    setState(() { _loading = true; });
    try {
      await Api.rpc('register_device', {'p_code': Api.config.deviceCode, 'p_name': _regName.text.trim(), 'p_branch_id': _regBranch});
      await _load();
      return;
    } on BusinessError catch (e) {
      _error = e.code == 'FORBIDDEN' ? 'تسجيل الجهاز للمالك أو مدير الفرع. اطلب منه الدخول بحسابه على هذا الجهاز.' : errorMessage(e.code);
    } on NoResponseError {
      _error = 'لا يوجد اتصال بالخادم.';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _regName.dispose();
    super.dispose();
  }

  Future<void> _openShift() async {
    final c = _ctx!;
    final opened = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => OpenShiftDialog(ctx: c));
    if (opened == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctx;
    if (c == null) {
      return Scaffold(
        backgroundColor: Brand.ink,
        body: Center(
          child: Container(
            width: 440,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: _loading
                ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
                : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(_error ?? '', style: const TextStyle(color: Brand.bad, fontSize: 17)),
                    const SizedBox(height: 16),
                    if (_needsDevice && _regBranches.isNotEmpty) ...[
                      const Text('سجّل هذا الجهاز في فرع:', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      DropdownButton<String>(
                        value: _regBranch,
                        isExpanded: true,
                        items: [for (final b in _regBranches) DropdownMenuItem(value: b['id'] as String, child: Text('${b['name_ar']}'))],
                        onChanged: (v) => setState(() => _regBranch = v),
                      ),
                      TextField(controller: _regName, decoration: const InputDecoration(labelText: 'اسم الصندوق')),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _registerDevice, child: const Text('تسجيل الجهاز')),
                      const SizedBox(height: 8),
                    ],
                    OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة')),
                    TextButton(onPressed: () => Api.client.auth.signOut(), child: const Text('تسجيل الخروج')),
                  ]),
          ),
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {
        for (final (i, t) in _visible.indexed)
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), alt: true): () => setState(() => _tab = t),
      },
      child: Scaffold(
        body: Column(children: [
          Container(
            color: Brand.ink,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                child: Image.asset('assets/brand/lamsat-logo.png', height: 26),
              ),
              const SizedBox(width: 14),
              for (final t in _visible)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: TextButton(
                    focusNode: FocusNode(skipTraversal: true),
                    style: TextButton.styleFrom(
                      backgroundColor: t == _tab ? Brand.orange : Colors.transparent,
                      foregroundColor: t == _tab ? Brand.ink : Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      textStyle: TextStyle(fontSize: 16, fontWeight: t == _tab ? FontWeight.w700 : FontWeight.w500, fontFamily: 'Segoe UI'),
                    ),
                    onPressed: () => setState(() => _tab = t),
                    child: Text(t.label),
                  ),
                ),
              const Spacer(),
              ValueListenableBuilder<bool?>(valueListenable: Api.online, builder: (_, v, __) => ConnectionBadge(online: v)),
              const SizedBox(width: 16),
              Text('${c.branchName} · ${c.userName}', style: const TextStyle(color: Color(0xFF9AD4CF), fontSize: 14)),
              IconButton(
                tooltip: 'تسجيل الخروج (الوردية تبقى مفتوحة)',
                focusNode: FocusNode(skipTraversal: true),
                icon: const Icon(Icons.logout, color: Colors.white70),
                onPressed: () => Api.client.auth.signOut(),
              ),
            ]),
          ),
          Expanded(
            child: switch (_tab) {
              _Tab.sale => PosScreen(key: ValueKey('pos-${c.sessionId}'), shift: c, onShiftClosed: _load, onOpenShift: _openShift),
              _Tab.inventory => InventoryPage(ctx: c),
              _Tab.purchases => PurchasesPage(ctx: c),
              _Tab.customers => CustomersPage(ctx: c),
              _Tab.day => DayPage(key: ValueKey('day-${c.sessionId}'), ctx: c, onChanged: _load, onOpenShift: _openShift),
              _Tab.reports => ReportsPage(ctx: c),
              _Tab.settings => SettingsPage(ctx: c, onChanged: _load),
            },
          ),
        ]),
      ),
    );
  }
}

/// فتح وردية لهذا الحساب على هذا الصندوق. كل موظف له ورديته حتى لو كانت لغيره وردية مفتوحة على الجهاز نفسه.
class OpenShiftDialog extends StatefulWidget {
  final ShiftContext ctx;
  const OpenShiftDialog({super.key, required this.ctx});
  @override
  State<OpenShiftDialog> createState() => _OpenState();
}

class _OpenState extends State<OpenShiftDialog> {
  final _cash = TextEditingController(text: '0');
  String _opId = const Uuid().v4(); // يُعاد استخدامه عند إعادة المحاولة حتى لا تُفتح ورديتان
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _cash.selection = TextSelection(baseOffset: 0, extentOffset: _cash.text.length);
  }

  @override
  void dispose() {
    _cash.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final amount = parseOmr(_cash.text);
    if (amount == null) {
      setState(() => _error = 'أدخل الرصيد الافتتاحي بصيغة صحيحة، مثل 20 أو 20.500');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await Api.rpc('open_cash_session', {'p_operation_id': _opId, 'p_device_id': widget.ctx.deviceId, 'p_opening_cash_baisa': amount});
      if (mounted) Navigator.pop(context, true);
      return;
    } on BusinessError catch (e) {
      _opId = const Uuid().v4();
      if (e.code == 'SESSION_ALREADY_OPEN') {
        if (mounted) Navigator.pop(context, true); // ورديتك مفتوحة أصلًا: نستأنفها
        return;
      }
      _error = errorMessage(e.code);
    } on NoResponseError {
      _error = 'انقطع الاتصال أثناء فتح الوردية. اضغط «فتح الصندوق» مجددًا للتحقق وإكمال الفتح.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('بدء الوردية'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${widget.ctx.branchName} · ${widget.ctx.deviceName}\n${widget.ctx.userName}', style: const TextStyle(color: Brand.muted)),
            const SizedBox(height: 14),
            TextField(
              controller: _cash,
              autofocus: true,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              decoration: InputDecoration(labelText: 'رصيد الصندوق الافتتاحي (${Currency.symbol})'),
              onSubmitted: (_) => _open(),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.bad))),
          ]),
        ),
        actions: [
          OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('رجوع (Esc)')),
          FilledButton(onPressed: _busy ? null : _open, child: Text(_busy ? 'جارٍ الفتح…' : 'فتح الصندوق (Enter)')),
        ],
      );
}
