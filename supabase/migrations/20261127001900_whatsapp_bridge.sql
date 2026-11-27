-- ربط الإرسال الآلي عبر Smart WhatsApp Bridge (بديل للاتصال المباشر بـ Meta)، مع استقبال حالة التسليم.

alter table public.notification_credentials
  add column bridge_url            text check (bridge_url is null or bridge_url ~ '^https://[^[:space:]]+$'),
  add column bridge_api_key        text,
  add column bridge_webhook_secret text;

alter table public.notification_settings
  add column whatsapp_provider text not null default 'cloud' check (whatsapp_provider in ('cloud', 'bridge')),
  -- متغيرات القالب بالترتيب، من: customer, invoice, total, currency, branch, date
  add column whatsapp_params   text not null default 'customer,invoice,total'
    check (whatsapp_params ~ '^(customer|invoice|total|currency|branch|date)(,(customer|invoice|total|currency|branch|date)){0,9}$');

alter table public.notification_events
  add column provider_message_id text,
  add column delivery_status     text check (delivery_status in ('sent', 'delivered', 'read', 'failed')),
  add column delivery_at         timestamptz;
create index notification_events_provider_msg_idx on public.notification_events (provider_message_id) where provider_message_id is not null;

create or replace function public.set_notification_credentials(p_organization_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.notification_credentials; k text;
  c_fields constant text[] := array['whatsapp_token', 'whatsapp_phone_id', 'sms_user', 'sms_password', 'sms_header', 'bridge_url', 'bridge_api_key', 'bridge_webhook_secret'];
begin
  if not (app.has_org_perm(p_organization_id, 'notifications.manage') and app.has_org_perm(p_organization_id, 'users.manage')) then perform app.fail('FORBIDDEN'); end if;
  if nullif(btrim(p->>'bridge_url'), '') is not null and btrim(p->>'bridge_url') !~ '^https://[^[:space:]]+$' then perform app.fail('INVALID_REQUEST'); end if;
  insert into public.notification_credentials (organization_id) values (p_organization_id) on conflict do nothing;
  select * into v from public.notification_credentials where organization_id = p_organization_id for update;
  -- الحقل المرسل يُستبدل (الفارغ يمسحه)، وغير المرسل يبقى
  foreach k in array c_fields loop
    if p ? k then v := jsonb_populate_record(v, jsonb_build_object(k, nullif(btrim(p->>k), ''))); end if;
  end loop;
  v.bridge_url := rtrim(v.bridge_url, '/');
  update public.notification_credentials set whatsapp_token = v.whatsapp_token, whatsapp_phone_id = v.whatsapp_phone_id,
    sms_user = v.sms_user, sms_password = v.sms_password, sms_header = v.sms_header,
    bridge_url = v.bridge_url, bridge_api_key = v.bridge_api_key, bridge_webhook_secret = v.bridge_webhook_secret,
    updated_at = now(), updated_by = (select auth.uid())
  where organization_id = p_organization_id;
  perform app.audit(p_organization_id, null, 'notifications.credentials', 'organization', p_organization_id, null, null,
    jsonb_build_object('fields', (select jsonb_agg(f) from jsonb_object_keys(p) f)));
  return jsonb_build_object('has_whatsapp', v.whatsapp_token is not null and v.whatsapp_phone_id is not null,
    'has_sms', v.sms_user is not null and v.sms_password is not null and v.sms_header is not null,
    'has_bridge', v.bridge_url is not null and v.bridge_api_key is not null);
end $$;

create or replace function public.notification_overview(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c public.notification_credentials;
begin
  if not app.has_org_perm(p_organization_id, 'notifications.manage') then perform app.fail('FORBIDDEN'); end if;
  select * into c from public.notification_credentials where organization_id = p_organization_id;
  return jsonb_build_object(
    'settings', (select to_jsonb(s) from public.notification_settings s where s.organization_id = p_organization_id),
    'link', jsonb_build_object(
      'has_whatsapp', c.whatsapp_token is not null and c.whatsapp_phone_id is not null, 'whatsapp_phone_id', c.whatsapp_phone_id,
      'has_sms', c.sms_user is not null and c.sms_password is not null and c.sms_header is not null, 'sms_user', c.sms_user, 'sms_header', c.sms_header,
      'has_bridge', c.bridge_url is not null and c.bridge_api_key is not null, 'bridge_url', c.bridge_url,
      'has_bridge_webhook', c.bridge_webhook_secret is not null,
      'can_edit', app.has_org_perm(p_organization_id, 'users.manage')),
    'pending', (select count(*) from public.notification_events where organization_id = p_organization_id and status = 'pending'),
    'events', coalesce((select jsonb_agg(jsonb_build_object('created_at', e.created_at, 'event_type', e.event_type, 'status', e.status, 'channel', e.channel,
        'attempts', e.attempts, 'last_error', e.last_error, 'delivery_status', e.delivery_status,
        'customer', (select name from public.customers where id = e.customer_id),
        'invoice_no', e.payload->>'invoice_no') order by e.created_at desc)
      from (select * from public.notification_events where organization_id = p_organization_id order by created_at desc limit 50) e), '[]'::jsonb));
end $$;

create or replace function public.update_notification_settings(p_organization_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.notification_settings; v_params text := nullif(replace(lower(coalesce(p->>'whatsapp_params', '')), ' ', ''), '');
begin
  if not app.has_org_perm(p_organization_id, 'notifications.manage') then perform app.fail('FORBIDDEN'); end if;
  if char_length(coalesce(p->>'sms_text_ar', '')) > 300 or coalesce(p->>'whatsapp_provider', 'cloud') not in ('cloud', 'bridge')
    or v_params !~ '^(customer|invoice|total|currency|branch|date)(,(customer|invoice|total|currency|branch|date)){0,9}$' then
    perform app.fail('INVALID_REQUEST');
  end if;
  insert into public.notification_settings (organization_id) values (p_organization_id) on conflict do nothing;
  update public.notification_settings set
    enabled = coalesce((p->>'enabled')::boolean, enabled),
    whatsapp_enabled = coalesce((p->>'whatsapp_enabled')::boolean, whatsapp_enabled),
    whatsapp_provider = coalesce(p->>'whatsapp_provider', whatsapp_provider),
    whatsapp_params = coalesce(v_params, whatsapp_params),
    sms_fallback = coalesce((p->>'sms_fallback')::boolean, sms_fallback),
    whatsapp_template = coalesce(nullif(btrim(p->>'whatsapp_template'), ''), whatsapp_template),
    whatsapp_lang = coalesce(nullif(btrim(p->>'whatsapp_lang'), ''), whatsapp_lang),
    sms_text_ar = case when p ? 'sms_text_ar' then nullif(btrim(p->>'sms_text_ar'), '') else sms_text_ar end,
    updated_at = now()
  where organization_id = p_organization_id returning * into v;
  perform app.audit(p_organization_id, null, 'notifications.settings', 'organization', p_organization_id, null, null, to_jsonb(v));
  return to_jsonb(v);
end $$;
