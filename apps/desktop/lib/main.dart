import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/api.dart';
import 'core/config.dart';
import 'core/theme.dart';
import 'modules/auth/login_screen.dart';
import 'modules/auth/setup_screen.dart';
import 'modules/cash/shift_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? startupError;
  try {
    var config = AppConfig.load();
    if (config.deviceCode.isEmpty) config = config.withDevice(await _deviceCode());
    await Api.init(config);
  } on FormatException catch (e) {
    startupError = e.message;
  } catch (e) {
    startupError = 'تعذّر بدء التطبيق: $e';
  }
  runApp(LamsatApp(startupError: startupError));
}

/// رمز ثابت لهذا الجهاز يُولَّد مرة واحدة ويُحفظ عليه؛ يُسجَّل في الخادم عند الإعداد الأول أو من المالك لاحقًا.
Future<String> _deviceCode() async {
  final prefs = await SharedPreferences.getInstance();
  var code = prefs.getString('device_code');
  if (code == null || code.isEmpty) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    code = 'POS-${List.generate(6, (_) => chars[r.nextInt(chars.length)]).join()}';
    await prefs.setString('device_code', code);
  }
  return code;
}

class LamsatApp extends StatelessWidget {
  final String? startupError;
  const LamsatApp({super.key, this.startupError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'لمسات — الكاشير',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: startupError != null
          ? Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(startupError!, style: const TextStyle(fontSize: 20, color: Brand.bad)))))
          : const _Root(),
    );
  }
}

/// أول تشغيل على قاعدة فارغة يعرض معالج الإعداد؛ بعدها الدخول المعتاد.
class _Root extends StatefulWidget {
  const _Root();
  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool? _initialized; // null = جارٍ التحقق
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_check);
  }

  Future<void> _check() async {
    setState(() => _error = null);
    try {
      final r = (await Api.rpc('setup_status') as Map).cast<String, dynamic>();
      if (mounted) setState(() => _initialized = r['initialized'] == true);
    } catch (_) {
      if (mounted) setState(() => _error = 'لا يوجد اتصال بالخادم. النظام يعمل بالإنترنت فقط.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initialized == null) {
      return Scaffold(
        backgroundColor: Brand.ink,
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, style: const TextStyle(color: Colors.white, fontSize: 18)),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _check, child: const Text('إعادة المحاولة')),
                ]),
        ),
      );
    }
    if (_initialized == false) return SetupScreen(onDone: () => setState(() => _initialized = true));
    return StreamBuilder<AuthState>(
      stream: Api.client.auth.onAuthStateChange,
      builder: (context, _) {
        final session = Api.client.auth.currentSession;
        if (session == null) return const LoginScreen();
        return ShiftGate(key: ValueKey(session.user.id));
      },
    );
  }
}
