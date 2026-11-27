import 'dart:convert';
import 'dart:io';

/// إعدادات الجهاز: تُقرأ من ملف lamsat-v2.config.json بجوار الملف التنفيذي،
/// أو من --dart-define أثناء التطوير. المفتاح هنا هو المفتاح العلني فقط.
class AppConfig {
  final String supabaseUrl;
  final String publishableKey;
  final String deviceCode;

  /// نطاق داخلي يُلحق باسم المستخدم عند الدخول (المستخدم يكتب الاسم فقط).
  final String loginDomain;
  const AppConfig({required this.supabaseUrl, required this.publishableKey, required this.deviceCode, this.loginDomain = 'lamsat.test'});

  /// نسخة برمز جهاز آخر (يُولَّد عند أول تشغيل إن لم يُحدَّد في ملف الإعدادات).
  AppConfig withDevice(String code) => AppConfig(supabaseUrl: supabaseUrl, publishableKey: publishableKey, deviceCode: code, loginDomain: loginDomain);

  /// اسم المستخدم ← معرّف الدخول. يُقبل البريد الكامل أيضًا.
  String loginId(String username) {
    final u = username.trim().toLowerCase();
    return u.contains('@') ? u : '$u@$loginDomain';
  }

  // مشروع الإصدار 2. المفتاح القابل للنشر عام بطبيعته (الصلاحيات تُفرض في الخادم)؛ ملف lamsat-v2.config.json يتجاوزهما إن وُجد.
  static const _url = String.fromEnvironment('SUPABASE_URL', defaultValue: 'https://aadhppkwtmhyagljopcv.supabase.co');
  static const _key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY', defaultValue: 'sb_publishable_l7qzmVoiXjd0Ozet43CWdw_Tkp7PrpH');
  static const _device = String.fromEnvironment('DEVICE_CODE');

  static AppConfig load() {
    var url = _url, key = _key, device = _device, domain = 'lamsat.test';
    // اسم الملف يخص الإصدار 2 عمدًا: ملف lamsat.config.json القديم يوجّه إلى قاعدة النسخة السابقة فيُتجاهل.
    final candidates = [
      File('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}lamsat-v2.config.json'),
      File('lamsat-v2.config.json'),
    ];
    for (final f in candidates) {
      if (!f.existsSync()) continue;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      url = (j['supabase_url'] as String?) ?? url;
      key = (j['supabase_publishable_key'] as String?) ?? key;
      device = (j['device_code'] as String?) ?? device;
      domain = (j['login_domain'] as String?) ?? domain;
      break;
    }
    if (url.isEmpty || key.isEmpty) {
      throw const FormatException('ملف الإعدادات lamsat-v2.config.json ناقص: supabase_url و supabase_publishable_key مطلوبان.');
    }
    return AppConfig(supabaseUrl: url, publishableKey: key, deviceCode: device, loginDomain: domain);
  }
}
