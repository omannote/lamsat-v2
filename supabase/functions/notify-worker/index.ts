// عامل إشعارات العملاء: يعالج الأحداث المعلّقة في notification_events.
// القناة الأولى واتساب Cloud API (قالب معتمد)، وعند فشل مؤكد يُجرَّب iSmartSMS إن كان مفعّلًا.
// بيانات الربط تُقرأ من إعدادات المنشأة (جدول لا تصله التطبيقات) ثم من أسرار الخادم كبديل.
// بلا بيانات ربط أو والإشعارات غير مفعّلة: تُسجَّل الرسالة بحالة mock ولا يُرسل شيء لأي عميل.
// الاستدعاء: مالك المنشأة من التطبيق (JWT)، أو مهمة مجدولة بترويسة x-worker-secret.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-worker-secret',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
type Creds = { whatsapp_token?: string | null; whatsapp_phone_id?: string | null; sms_user?: string | null; sms_password?: string | null; sms_header?: string | null;
  bridge_url?: string | null; bridge_api_key?: string | null };
type Sent = { configured: boolean; ok: boolean; error: string | null; id?: string | null };
function money(baisa: number, decimals: number, group: boolean) {
  const d = Math.min(3, Math.max(0, decimals)), unit = 10 ** (3 - d), v = Math.round(baisa / unit);
  let whole = String(Math.floor(v / 10 ** d));
  if (group) whole = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return d === 0 ? whole : `${whole}.${String(v % 10 ** d).padStart(d, '0')}`;
}

function phoneIntl(raw: string | null, cc = '968'): string | null {
  let d = (raw ?? '').replace(/[^0-9]/g, '');
  if (d.startsWith('00')) d = d.slice(2);
  if (d.length === 8) d = cc + d;
  return d.length >= 10 && d.length <= 15 ? d : null;
}

// الإرسال عبر Smart WhatsApp Bridge: قالب معتمد ومتغيراته بالترتيب. الـ Bridge يتولى الاتصال بـ Meta.
async function sendBridge(k: Creds, to: string, template: string, params: string[]): Promise<Sent> {
  if (!k.bridge_url || !k.bridge_api_key || !/^https:\/\//.test(k.bridge_url)) return { configured: false, ok: false, error: 'not_configured' };
  try {
    const res = await fetch(`${k.bridge_url.replace(/\/+$/, '')}/messages/send-notification`, {
      method: 'POST',
      headers: { 'X-API-Key': k.bridge_api_key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ to, template_name: template, params }),
      signal: AbortSignal.timeout(15000),
    });
    const text = await res.text();
    let body: Record<string, unknown> = {};
    try { body = JSON.parse(text); } catch { /* ردّ غير JSON */ }
    const data = (body.data ?? {}) as Record<string, unknown>;
    const failed = !res.ok || body.success === false || body.ok === false || (typeof body.error === 'string' && body.error !== '');
    const id = [body.wa_message_id, data.wa_message_id, body.message_id, data.message_id].find((x) => typeof x === 'string') as string | undefined;
    const why = typeof body.error === 'string' ? body.error : typeof body.message === 'string' ? body.message : '';
    return { configured: true, ok: !failed, error: failed ? `bridge_${res.status}${why ? ': ' + why.slice(0, 160) : ''}` : null, id: id ?? null };
  } catch (e) {
    return { configured: true, ok: false, error: `bridge_unreachable: ${String(e).slice(0, 80)}` };
  }
}

async function sendWhatsApp(k: Creds, to: string, template: string, lang: string, params: string[]) {
  const token = k.whatsapp_token || Deno.env.get('WHATSAPP_TOKEN'), phoneId = k.whatsapp_phone_id || Deno.env.get('WHATSAPP_PHONE_ID');
  if (!token || !phoneId) return { configured: false, ok: false, error: 'not_configured' };
  const res = await fetch(`https://graph.facebook.com/v21.0/${phoneId}/messages`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      messaging_product: 'whatsapp', to, type: 'template',
      template: { name: template, language: { code: lang }, components: [{ type: 'body', parameters: params.map((text) => ({ type: 'text', text })) }] },
    }),
  });
  return { configured: true, ok: res.ok, error: res.ok ? null : `whatsapp_${res.status}` };
}

async function sendSms(k: Creds, to: string, message: string, arabic: boolean) {
  const user = k.sms_user || Deno.env.get('ISMART_USER'), pass = k.sms_password || Deno.env.get('ISMART_PASSWORD'), header = k.sms_header || Deno.env.get('ISMART_HEADER');
  if (!user || !pass || !header) return { configured: false, ok: false, error: 'not_configured' };
  const body = new URLSearchParams({ UserId: user, Password: pass, MobileNo: to, Message: message, Lang: arabic ? '64' : '0', Header: header });
  const res = await fetch('https://www.ismartsms.net/iBulkSMS/HttpWS/SMSDynamicRefIntlAPI.aspx', { method: 'POST', body });
  const text = (await res.text()).trim();
  return { configured: true, ok: res.ok && text === '1', error: res.ok && text === '1' ? null : `sms_${text.slice(0, 20) || res.status}` };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const url = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const body = await req.json().catch(() => ({}));

  // التفويض
  let orgFilter: string | null = null;
  const secret = Deno.env.get('WORKER_SECRET');
  if (secret && req.headers.get('x-worker-secret') === secret) {
    orgFilter = null; // المهمة المجدولة تعالج كل المنشآت المفعّلة
  } else {
    const auth = req.headers.get('Authorization') ?? '';
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
    const { error } = await caller.rpc('notification_overview', { p_organization_id: body.organization_id });
    if (error) return json({ error: 'FORBIDDEN' });
    orgFilter = String(body.organization_id);
  }

  let q = admin.from('notification_events').select('*').eq('status', 'pending').lt('attempts', 3).order('created_at').limit(20);
  if (orgFilter) q = q.eq('organization_id', orgFilter);
  const { data: events, error } = await q;
  if (error) return json({ error: 'INVALID_REQUEST' }, 500);

  const result = { processed: 0, sent: 0, mock: 0, failed: 0 };
  for (const e of events ?? []) {
    result.processed++;
    const { data: s } = await admin.from('notification_settings').select('*').eq('organization_id', e.organization_id).maybeSingle();
    const { data: c } = await admin.from('customers').select('name, phone').eq('id', e.customer_id).maybeSingle();
    const { data: b } = await admin.from('branches').select('name_ar').eq('id', e.branch_id).maybeSingle();
    const { data: o } = await admin.from('org_settings').select('*').eq('organization_id', e.organization_id).maybeSingle();
    const { data: k0 } = await admin.from('notification_credentials').select('*').eq('organization_id', e.organization_id).maybeSingle();
    const k: Creds = k0 ?? {};
    const to = phoneIntl(c?.phone ?? null, o?.phone_country_code ?? '968');
    const invoiceNo = String(e.payload?.invoice_no ?? '');
    const total = money(Number(e.payload?.total_baisa ?? 0), o?.currency_decimals ?? 3, o?.thousands_separator ?? false);
    const fill = (t: string) => t.replaceAll('{customer}', c?.name ?? '').replaceAll('{branch}', b?.name_ar ?? '').replaceAll('{invoice}', invoiceNo)
      .replaceAll('{total}', total).replaceAll('{currency}', o?.currency_symbol ?? 'ر.ع');
    const message = e.lang === 'en'
      ? `Thank you for visiting ${b?.name_ar ?? ''}. Invoice ${invoiceNo}, total ${total} ${o?.currency_code ?? 'OMR'}.`
      : fill(s?.sms_text_ar || 'شكرًا لزيارتكم {branch}. فاتورتكم {invoice} بإجمالي {total} {currency}');
    const patch: Record<string, unknown> = { attempts: (e.attempts ?? 0) + 1, message };

    if (!to) {
      Object.assign(patch, { status: 'failed', last_error: 'invalid_phone' }); result.failed++;
    } else if (!s?.enabled) {
      Object.assign(patch, { status: 'mock', channel: 'mock', last_error: 'notifications_disabled', sent_at: new Date().toISOString() }); result.mock++;
    } else {
      const values: Record<string, string> = { customer: c?.name ?? '', invoice: invoiceNo, total, currency: o?.currency_symbol ?? 'ر.ع',
        branch: b?.name_ar ?? '', date: String(e.created_at ?? '').slice(0, 10) };
      const params = String(s.whatsapp_params ?? 'customer,invoice,total').split(',').map((p) => values[p.trim()] ?? '');
      const wa: Sent = s.whatsapp_enabled === false ? { configured: false, ok: false, error: 'whatsapp_disabled' }
        : s.whatsapp_provider === 'bridge' ? await sendBridge(k, to, s.whatsapp_template, params)
        : await sendWhatsApp(k, to, s.whatsapp_template, s.whatsapp_lang, params);
      if (wa.ok) {
        Object.assign(patch, { status: 'sent', channel: s.whatsapp_provider === 'bridge' ? 'bridge' : 'whatsapp', last_error: null,
          provider_message_id: wa.id ?? null, sent_at: new Date().toISOString() }); result.sent++;
      } else {
        const sms = s.sms_fallback ? await sendSms(k, to, message, e.lang !== 'en') : { configured: false, ok: false, error: 'sms_disabled' };
        if (sms.ok) {
          Object.assign(patch, { status: 'sent', channel: 'sms', last_error: wa.error, sent_at: new Date().toISOString() }); result.sent++;
        } else if (!wa.configured && !sms.configured) {
          Object.assign(patch, { status: 'mock', channel: 'mock', last_error: 'no_provider_secrets', sent_at: new Date().toISOString() }); result.mock++;
        } else {
          const final = (e.attempts ?? 0) + 1 >= 3;
          Object.assign(patch, { status: final ? 'failed' : 'pending', last_error: [wa.error, sms.error].filter(Boolean).join(' / ') });
          if (final) result.failed++;
        }
      }
    }
    await admin.from('notification_events').update(patch).eq('id', e.id);
  }
  return json(result);
});
