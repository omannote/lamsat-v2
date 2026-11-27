import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/money.dart';
import '../../core/theme.dart';

/// معالج الإعداد عند أول استخدام: المنشأة، الفرعان، الضريبة، حساب المالك، وهذا الجهاز.
/// يظهر مرة واحدة فقط ما دامت قاعدة البيانات بلا منشأة؛ كل ما فيه يُعدَّل لاحقًا من الإعدادات.
class SetupScreen extends StatefulWidget {
  final VoidCallback onDone;
  const SetupScreen({super.key, required this.onDone});
  @override
  State<SetupScreen> createState() => _State();
}

class _State extends State<SetupScreen> {
  final _org = TextEditingController(text: 'لمسات'), _taxNo = TextEditingController();
  final _b1Name = TextEditingController(text: 'فرع الزينة والعازل'), _b1Code = TextEditingController(text: 'TNT'), _b1Phone = TextEditingController();
  final _b2Name = TextEditingController(text: 'فرع الإطارات'), _b2Code = TextEditingController(text: 'TYR'), _b2Phone = TextEditingController();
  final _rate = TextEditingController(text: '5');
  final _ownerName = TextEditingController(), _username = TextEditingController(), _password = TextEditingController(), _password2 = TextEditingController();
  final _deviceName = TextEditingController(text: 'الصندوق 1');
  bool _taxEnabled = false, _inclusive = true, _busy = false;
  int _deviceBranch = 0;
  String? _error;

  List<TextEditingController> get _all =>
      [_org, _taxNo, _b1Name, _b1Code, _b1Phone, _b2Name, _b2Code, _b2Phone, _rate, _ownerName, _username, _password, _password2, _deviceName];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _hasSecond => _b2Name.text.trim().isNotEmpty;

  Future<void> _submit() async {
    final rate = parseMilli(_rate.text.trim().isEmpty ? '0' : _rate.text);
    final code = RegExp(r'^[A-Za-z0-9]{2,6}$');
    String? err;
    if (_org.text.trim().isEmpty) err = 'اسم المنشأة مطلوب.';
    if (err == null && (_b1Name.text.trim().isEmpty || !code.hasMatch(_b1Code.text.trim()))) err = 'الفرع الأول: الاسم مطلوب والرمز من 2 إلى 6 أحرف إنجليزية أو أرقام.';
    if (err == null && _hasSecond && !code.hasMatch(_b2Code.text.trim())) err = 'الفرع الثاني: الرمز من 2 إلى 6 أحرف إنجليزية أو أرقام.';
    if (err == null && _hasSecond && _b2Code.text.trim().toUpperCase() == _b1Code.text.trim().toUpperCase()) err = 'رمزا الفرعين يجب أن يختلفا.';
    if (err == null && (rate == null || rate > 100000)) err = 'نسبة الضريبة غير صالحة.';
    if (err == null && _ownerName.text.trim().isEmpty) err = 'اسم المالك مطلوب.';
    if (err == null && !RegExp(r'^[a-z0-9._-]{3,30}$').hasMatch(_username.text.trim().toLowerCase())) err = 'اسم المستخدم بحروف إنجليزية وأرقام، 3 خانات على الأقل، مثل owner';
    if (err == null && _password.text.length < 8) err = 'الرقم السري ثماني خانات على الأقل.';
    if (err == null && _password.text != _password2.text) err = 'الرقم السري وتأكيده غير متطابقين.';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() { _busy = true; _error = null; });
    final username = _username.text.trim().toLowerCase();
    try {
      final res = await Api.client.functions.invoke('first-setup', body: {
        'username': username,
        'password': _password.text,
        'login_domain': Api.config.loginDomain,
        'setup': {
          'owner_name': _ownerName.text.trim(),
          'org_name_ar': _org.text.trim(),
          'tax_registration_no': _taxNo.text.trim(),
          'tax_enabled': _taxEnabled,
          'tax_rate_bp': rate! ~/ 10,
          'prices_include_tax': _inclusive,
          'branches': [
            {'code': _b1Code.text.trim(), 'name_ar': _b1Name.text.trim(), 'phone': _b1Phone.text.trim()},
            if (_hasSecond) {'code': _b2Code.text.trim(), 'name_ar': _b2Name.text.trim(), 'phone': _b2Phone.text.trim()},
          ],
          'device': {'code': Api.config.deviceCode, 'name': _deviceName.text.trim(), 'branch_index': _hasSecond ? _deviceBranch : 0},
        },
      }).timeout(const Duration(seconds: 40));
      final data = res.data;
      if (data is Map && data['error'] != null) {
        _error = switch ('${data['error']}') {
          'ALREADY_INITIALIZED' => 'تم إعداد النظام من قبل. أعد تشغيل التطبيق وسجّل الدخول.',
          'INVALID_USERNAME' => 'اسم المستخدم غير صالح أو مستخدَم.',
          'WEAK_PASSWORD' => 'الرقم السري ثماني خانات على الأقل.',
          _ => 'تعذّر إكمال الإعداد. راجع البيانات وحاول مجددًا.',
        };
      } else {
        // الدخول مباشرة بحساب المالك الجديد
        try {
          await Api.client.auth.signInWithPassword(email: Api.config.loginId(username), password: _password.text);
        } catch (_) {}
        widget.onDone();
        return;
      }
    } catch (_) {
      _error = 'تعذّر الوصول إلى الخادم. تحقق من الاتصال ثم حاول مجددًا.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _field(TextEditingController c, String label, {bool ltr = false, bool obscure = false, int flex = 1}) => Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          child: TextField(
            controller: c,
            obscureText: obscure,
            enabled: !_busy,
            textDirection: ltr ? TextDirection.ltr : null,
            decoration: InputDecoration(labelText: label, isDense: true),
            onChanged: (_) => setState(() {}),
          ),
        ),
      );

  Widget _title(String t) => Padding(padding: const EdgeInsets.fromLTRB(5, 16, 5, 4), child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)));

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Brand.ink,
        body: Center(
          child: Container(
            width: 820,
            margin: const EdgeInsets.symmetric(vertical: 20),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Image.asset('assets/brand/lamsat-logo.png', height: 44),
                  const SizedBox(width: 14),
                  const Expanded(child: Text('إعداد النظام لأول مرة', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800))),
                ]),
                const Padding(
                  padding: EdgeInsets.fromLTRB(5, 8, 5, 0),
                  child: Text('تُملأ هذه البيانات مرة واحدة، وكلها تُعدَّل لاحقًا من الإعدادات. الأصناف والمستخدمون والأجهزة الأخرى تُضاف بعد الدخول.', style: TextStyle(color: Brand.muted)),
                ),
                _title('المنشأة'),
                Row(children: [_field(_org, 'اسم المنشأة كما يُطبع على الفاتورة', flex: 2), _field(_taxNo, 'الرقم الضريبي (إن وُجد)', ltr: true)]),
                _title('الفروع'),
                Row(children: [_field(_b1Name, 'اسم الفرع الأول', flex: 3), _field(_b1Code, 'رمزه في رقم الفاتورة', ltr: true), _field(_b1Phone, 'الهاتف', ltr: true, flex: 2)]),
                Row(children: [_field(_b2Name, 'اسم الفرع الثاني (اتركه فارغًا إن لم يوجد)', flex: 3), _field(_b2Code, 'رمزه', ltr: true), _field(_b2Phone, 'الهاتف', ltr: true, flex: 2)]),
                _title('الضريبة'),
                Row(children: [
                  Checkbox(value: _taxEnabled, onChanged: _busy ? null : (v) => setState(() => _taxEnabled = v ?? false)),
                  const Text('المنشأة مسجلة في ضريبة القيمة المضافة'),
                  const SizedBox(width: 16),
                  SizedBox(width: 130, child: TextField(controller: _rate, enabled: !_busy && _taxEnabled, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'النسبة %', isDense: true))),
                  const SizedBox(width: 16),
                  Checkbox(value: _inclusive, onChanged: _busy || !_taxEnabled ? null : (v) => setState(() => _inclusive = v ?? true)),
                  const Text('الأسعار شاملة الضريبة'),
                ]),
                _title('حساب المالك'),
                Row(children: [_field(_ownerName, 'الاسم الكامل', flex: 2), _field(_username, 'اسم المستخدم للدخول', ltr: true)]),
                Row(children: [_field(_password, 'الرقم السري (8 خانات على الأقل)', ltr: true, obscure: true), _field(_password2, 'تأكيد الرقم السري', ltr: true, obscure: true)]),
                _title('هذا الجهاز'),
                Row(children: [
                  _field(_deviceName, 'اسم الصندوق'),
                  if (_hasSecond)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: SegmentedButton<int>(
                          showSelectedIcon: false,
                          segments: [ButtonSegment(value: 0, label: Text(_b1Name.text.trim())), ButtonSegment(value: 1, label: Text(_b2Name.text.trim()))],
                          selected: {_deviceBranch},
                          onSelectionChanged: _busy ? null : (s) => setState(() => _deviceBranch = s.first),
                        ),
                      ),
                    ),
                ]),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 5), child: Text('رمز الجهاز: ${Api.config.deviceCode}', textDirection: TextDirection.ltr, style: const TextStyle(color: Brand.muted))),
                if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(5, 14, 5, 0), child: Text(_error!, style: const TextStyle(color: Brand.bad, fontSize: 16))),
                const SizedBox(height: 18),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16)),
                    child: Text(_busy ? 'جارٍ الإعداد…' : 'إنشاء المنشأة والدخول', style: const TextStyle(fontSize: 17)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}
