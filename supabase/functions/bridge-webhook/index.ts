// يستقبل حالة التسليم من Smart WhatsApp Bridge ويحدّث سجل الإشعارات.
// العنوان المسجَّل في الـ Bridge: …/functions/v1/bridge-webhook?org=<معرّف المنشأة>
// كل طلب يُتحقق من توقيعه (X-Bridge-Signature = sha256=HMAC(body, secret)) بسر المنشأة المحفوظ في الخادم؛ بلا توقيع صحيح لا يُقبل شيء.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
function sameText(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const org = new URL(req.url).searchParams.get('org') ?? '';
  if (!/^[0-9a-f-]{36}$/i.test(org)) return new Response('bad request', { status: 400 });
  const raw = await req.text();
  if (raw.length > 100_000) return new Response('too large', { status: 413 });

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: k } = await admin.from('notification_credentials').select('bridge_webhook_secret').eq('organization_id', org).maybeSingle();
  const secret = k?.bridge_webhook_secret;
  if (!secret) return new Response('Invalid signature', { status: 403 });
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const expected = 'sha256=' + hex(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw)));
  if (!sameText(expected, req.headers.get('x-bridge-signature') ?? '')) return new Response('Invalid signature', { status: 403 });

  let event: { event?: string; data?: { status?: string; wa_message_id?: string } };
  try { event = JSON.parse(raw); } catch { return new Response('bad json', { status: 400 }); }
  const status = event.data?.status, id = event.data?.wa_message_id;
  if (event.event === 'message.status' && id && ['sent', 'delivered', 'read', 'failed'].includes(status ?? '')) {
    // لا ترجع الحالة إلى الوراء: «قُرئت» لا تُستبدل بـ«وصلت» إن وصل الحدثان بترتيب معكوس
    const lower = status === 'sent' ? [] : status === 'delivered' ? ['sent'] : ['sent', 'delivered'];
    let q = admin.from('notification_events').update({ delivery_status: status, delivery_at: new Date().toISOString() })
      .eq('organization_id', org).eq('provider_message_id', id);
    q = lower.length ? q.or(`delivery_status.is.null,delivery_status.in.(${lower.join(',')})`) : q.is('delivery_status', null);
    await q;
  }
  // الرسائل الواردة (message.received) تُدار من لوحة الـ Bridge نفسها؛ لا تُخزَّن هنا.
  return new Response('ok', { status: 200 });
});
