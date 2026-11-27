// الإعداد عند أول استخدام: ينشئ حساب المالك والمنشأة والفروع وجهاز الكاشير الأول.
// يعمل فقط ما دامت القاعدة بلا منشأة؛ بعدها يرفض كل طلب (ALREADY_INITIALIZED).
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data: st } = await admin.rpc('setup_status');
    if (st?.initialized !== false) return json({ error: 'ALREADY_INITIALIZED' });

    const b = await req.json();
    const username = String(b.username ?? '').trim().toLowerCase();
    const domain = String(b.login_domain ?? 'lamsat.test').toLowerCase();
    const password = String(b.password ?? '');
    if (!/^[a-z0-9._-]{3,30}$/.test(username) || !/^[a-z0-9.-]{3,60}$/.test(domain)) return json({ error: 'INVALID_USERNAME' });
    if (password.length < 8) return json({ error: 'WEAK_PASSWORD' });

    const { data: created, error } = await admin.auth.admin.createUser({ email: `${username}@${domain}`, password, email_confirm: true });
    if (error || !created?.user) return json({ error: 'INVALID_USERNAME' });
    const { data, error: bErr } = await admin.rpc('bootstrap_organization', { p: { ...b.setup, owner_id: created.user.id } });
    if (bErr) {
      await admin.auth.admin.deleteUser(created.user.id); // لا نترك حسابًا بلا منشأة
      return json({ error: (bErr.message ?? '').match(/[A-Z_]{4,}/)?.[0] ?? 'INVALID_REQUEST' });
    }
    return json(data);
  } catch (_) {
    return json({ error: 'INVALID_REQUEST' }, 400);
  }
});
