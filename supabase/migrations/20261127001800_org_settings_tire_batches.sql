-- (1) إعدادات المنشأة: العملة وصيغة عرضها، وأي الأقسام يراها كل دور.
-- (2) دفعات الإطارات: بيانات كل دفعة مستلمة (السنة، الأسبوع، بلد الصنع، الرف) تُحفظ على الدفعة لا على الصنف.
-- (3) بيانات ربط واتساب والرسائل النصية تُدخل من الإعدادات وتُحفظ في جدول لا يقرؤه أي تطبيق؛ يقرؤه عامل الإشعارات في الخادم فقط.

-- ───────────── (1) إعدادات المنشأة ─────────────
create table public.org_settings (
  organization_id     uuid primary key references public.organizations(id),
  currency_code       text not null default 'OMR' check (currency_code ~ '^[A-Z]{3}$'),
  currency_symbol     text not null default 'ر.ع' check (char_length(currency_symbol) between 1 and 8),
  -- المبالغ تُخزَّن دائمًا بجزء من الألف من وحدة العملة؛ هذا الحقل يحدد عدد الخانات المعروضة والمقبولة في الإدخال.
  currency_decimals   int not null default 3 check (currency_decimals between 0 and 3),
  symbol_before       boolean not null default false,
  thousands_separator boolean not null default false,
  phone_country_code  text not null default '968' check (phone_country_code ~ '^[0-9]{1,4}$'),
  whatsapp_message_ar text check (whatsapp_message_ar is null or char_length(whatsapp_message_ar) <= 600),
  tab_roles           jsonb not null default '{
    "sale": ["cashier", "branch_manager", "owner"],
    "customers": ["cashier", "branch_manager", "accountant", "owner"],
    "inventory": ["branch_manager", "accountant", "owner"],
    "purchases": ["branch_manager", "accountant", "owner"],
    "day": ["branch_manager", "accountant", "owner"],
    "reports": ["branch_manager", "accountant", "owner"],
    "settings": ["branch_manager", "owner"]}'::jsonb,
  updated_at          timestamptz not null default now()
);
alter table public.org_settings enable row level security;
create policy org_settings_read on public.org_settings for select to authenticated using (app.has_org(organization_id));
insert into public.org_settings (organization_id) select id from public.organizations on conflict do nothing;

-- المنشآت الجديدة تحصل على صف الإعدادات تلقائيًا
create or replace function app.org_settings_seed() returns trigger language plpgsql security definer set search_path = '' as $$
begin insert into public.org_settings (organization_id) values (new.id) on conflict do nothing; return new; end $$;
create trigger organizations_settings_seed after insert on public.organizations for each row execute function app.org_settings_seed();

-- إعدادات يحتاجها التطبيق عند الدخول، مع الأقسام المتاحة للمستخدم الحالي في هذا الفرع
create or replace function public.app_settings(p_branch_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid; s public.org_settings; o public.organizations; v_roles text[];
begin
  select organization_id into v_org from public.branches where id = p_branch_id;
  if v_org is null or not app.has_branch(p_branch_id) then perform app.fail('FORBIDDEN'); end if;
  select * into s from public.org_settings where organization_id = v_org;
  select * into o from public.organizations where id = v_org;
  select coalesce(array_agg(distinct m.role_code), '{}') into v_roles from public.memberships m
    where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = v_org and (m.branch_id is null or m.branch_id = p_branch_id);
  return jsonb_build_object(
    'organization', jsonb_build_object('id', o.id, 'name_ar', o.name_ar, 'name_en', o.name_en, 'tax_registration_no', o.tax_registration_no),
    'currency', jsonb_build_object('code', s.currency_code, 'symbol', s.currency_symbol, 'decimals', s.currency_decimals,
      'symbol_before', s.symbol_before, 'thousands_separator', s.thousands_separator),
    'phone_country_code', s.phone_country_code, 'whatsapp_message_ar', s.whatsapp_message_ar,
    'tab_roles', s.tab_roles, 'my_roles', to_jsonb(v_roles),
    'my_tabs', coalesce((select jsonb_agg(t.key) from jsonb_each(s.tab_roles) t
        where 'owner' = any(v_roles) or exists (select 1 from jsonb_array_elements_text(t.value) r where r = any(v_roles))), '[]'::jsonb),
    'can_manage', app.has_org_perm(v_org, 'users.manage'));
end $$;

-- تعديل إعدادات المنشأة: للمالك وحده. المالك يرى كل الأقسام دائمًا مهما كان الإعداد.
create or replace function public.update_org_settings(p_organization_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old public.org_settings; v public.org_settings; v_tabs jsonb; k text; v_val jsonb;
  c_tabs constant text[] := array['sale', 'customers', 'inventory', 'purchases', 'day', 'reports', 'settings'];
begin
  if not app.has_org_perm(p_organization_id, 'users.manage') then perform app.fail('FORBIDDEN'); end if;
  insert into public.org_settings (organization_id) values (p_organization_id) on conflict do nothing;
  select * into v_old from public.org_settings where organization_id = p_organization_id for update;
  v_tabs := v_old.tab_roles;
  if p ? 'tab_roles' then
    if jsonb_typeof(p->'tab_roles') <> 'object' then perform app.fail('INVALID_REQUEST'); end if;
    foreach k in array c_tabs loop
      v_val := p->'tab_roles'->k;
      if v_val is null then continue; end if;
      if jsonb_typeof(v_val) <> 'array' then perform app.fail('INVALID_REQUEST'); end if;
      -- تُهمل الأدوار المجهولة، ويبقى المالك دائمًا
      v_tabs := jsonb_set(v_tabs, array[k], (select coalesce(jsonb_agg(distinct r), '[]'::jsonb)
        from (select jsonb_array_elements_text(v_val) r union select 'owner') x where r in (select code from public.roles)));
    end loop;
  end if;
  if p ? 'currency_code' and coalesce(p->>'currency_code', '') !~ '^[A-Z]{3}$' then perform app.fail('INVALID_REQUEST'); end if;
  if p ? 'currency_symbol' and char_length(btrim(coalesce(p->>'currency_symbol', ''))) not between 1 and 8 then perform app.fail('INVALID_REQUEST'); end if;
  if p ? 'currency_decimals' and coalesce((p->>'currency_decimals')::int, -1) not between 0 and 3 then perform app.fail('INVALID_REQUEST'); end if;
  if p ? 'phone_country_code' and coalesce(p->>'phone_country_code', '') !~ '^[0-9]{1,4}$' then perform app.fail('INVALID_REQUEST'); end if;
  if char_length(coalesce(p->>'whatsapp_message_ar', '')) > 600 then perform app.fail('INVALID_REQUEST'); end if;
  update public.org_settings set
    currency_code = coalesce(p->>'currency_code', currency_code),
    currency_symbol = coalesce(btrim(p->>'currency_symbol'), currency_symbol),
    currency_decimals = coalesce((p->>'currency_decimals')::int, currency_decimals),
    symbol_before = coalesce((p->>'symbol_before')::boolean, symbol_before),
    thousands_separator = coalesce((p->>'thousands_separator')::boolean, thousands_separator),
    phone_country_code = coalesce(p->>'phone_country_code', phone_country_code),
    whatsapp_message_ar = case when p ? 'whatsapp_message_ar' then nullif(btrim(p->>'whatsapp_message_ar'), '') else whatsapp_message_ar end,
    tab_roles = v_tabs, updated_at = now()
  where organization_id = p_organization_id returning * into v;
  if p ? 'name_ar' or p ? 'name_en' or p ? 'tax_registration_no' then
    if p ? 'name_ar' and nullif(btrim(p->>'name_ar'), '') is null then perform app.fail('INVALID_REQUEST'); end if;
    update public.organizations set
      name_ar = coalesce(nullif(btrim(p->>'name_ar'), ''), name_ar),
      name_en = case when p ? 'name_en' then nullif(btrim(p->>'name_en'), '') else name_en end,
      tax_registration_no = case when p ? 'tax_registration_no' then nullif(btrim(p->>'tax_registration_no'), '') else tax_registration_no end
    where id = p_organization_id;
  end if;
  perform app.audit(p_organization_id, null, 'org_settings.update', 'organization', p_organization_id, null, to_jsonb(v_old), to_jsonb(v));
  return to_jsonb(v);
end $$;

revoke all on function public.app_settings(uuid), public.update_org_settings(uuid, jsonb) from public, anon;
grant execute on function public.app_settings(uuid), public.update_org_settings(uuid, jsonb) to authenticated, service_role;

-- ───────────── (2) دفعات الإطارات ─────────────
alter table public.inventory_lots
  add column tire_year int check (tire_year between 2000 and 2100),
  add column tire_week int check (tire_week between 1 and 53),
  add column country   text,
  add column shelf     text,
  add column note      text;
create index inventory_lots_shelf_idx on public.inventory_lots (branch_id, shelf) where qty_on_hand > 0 and shelf is not null;

-- رمز DOT من أربعة أرقام (أسبوع ثم سنة، مثل 2325) يُستخرج منه الأسبوع والسنة إن لم يُدخلا
create or replace function app.lot_fill_dot() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.dot_code ~ '^[0-9]{4}$' and substr(new.dot_code, 1, 2)::int between 1 and 53 then
    new.tire_week := coalesce(new.tire_week, substr(new.dot_code, 1, 2)::int);
    new.tire_year := coalesce(new.tire_year, 2000 + substr(new.dot_code, 3, 2)::int);
  end if;
  new.shelf := nullif(upper(btrim(new.shelf)), '');
  new.country := nullif(btrim(new.country), '');
  new.note := nullif(btrim(new.note), '');
  return new;
end $$;
create trigger inventory_lots_fill_dot before insert or update of dot_code, shelf, country, note on public.inventory_lots
  for each row execute function app.lot_fill_dot();

do $$
declare d text; r record;
begin
  for r in select * from (values
    ('public.receive_purchase(uuid,jsonb)',
     'insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand, purchase_receipt_id)
    values (v_org, v_branch, v_prod.id, nullif(btrim(l->>''lot_code''), ''''), nullif(btrim(l->>''dot_code''), ''''), v_cost, v_qty, v_qty, v_id)',
     'if (l->>''tire_year'')::int not between 2000 and 2100 or (l->>''tire_week'')::int not between 1 and 53 then perform app.fail(''INVALID_REQUEST'', jsonb_build_object(''line_no'', v_n)); end if;
    insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand, purchase_receipt_id,
      tire_year, tire_week, country, shelf, note)
    values (v_org, v_branch, v_prod.id, nullif(btrim(l->>''lot_code''), ''''), nullif(btrim(l->>''dot_code''), ''''), v_cost, v_qty, v_qty, v_id,
      (l->>''tire_year'')::int, (l->>''tire_week'')::int, l->>''country'', l->>''shelf'', l->>''note'')'),
    ('public.transfer_stock(uuid,uuid,uuid,uuid,numeric,text)',
     'select id, qty_on_hand, unit_cost_baisa, lot_code, dot_code from public.inventory_lots',
     'select id, qty_on_hand, unit_cost_baisa, lot_code, dot_code, tire_year, tire_week, country from public.inventory_lots'),
    ('public.transfer_stock(uuid,uuid,uuid,uuid,numeric,text)',
     'insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand)
    values (v_org, p_to_branch, p_product_id, coalesce(v_lot.lot_code, ''TRF''), v_lot.dot_code, v_lot.unit_cost_baisa, v_take, v_take)',
     'insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand, tire_year, tire_week, country)
    values (v_org, p_to_branch, p_product_id, coalesce(v_lot.lot_code, ''TRF''), v_lot.dot_code, v_lot.unit_cost_baisa, v_take, v_take, v_lot.tire_year, v_lot.tire_week, v_lot.country)')
  ) as t(fn, target, repl) loop
    d := pg_get_functiondef(r.fn::regprocedure);
    if position(r.target in d) = 0 then raise exception 'patch target missing in %: %', r.fn, r.target; end if;
    execute replace(d, r.target, r.repl);
  end loop;
end $$;

-- تقرير المخزون: الدفعات ظاهرة لكل من يرى المخزون (التكلفة لمن يملك صلاحيتها فقط)، وسنة الإطار من أقدم دفعة فيها رصيد.
create or replace function public.stock_report(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(p_branch_id, 'inventory.view') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('product_id', p.id, 'sku', p.sku, 'name_ar', p.name_ar, 'category', p.category, 'unit', p.unit,
        'brand', p.brand, 'tire_year', coalesce(s.oldest_year, p.tire_year), 'reorder_level', p.reorder_level, 'whole_units_only', p.whole_units_only,
        'tire_size', case when p.tire_size_key is not null then p.tire_width || '/' || p.tire_aspect || 'R' || p.tire_rim end,
        'is_active', p.is_active, 'price_baisa', app.effective_price(p_branch_id, p.id), 'qty', coalesce(s.qty, 0),
        'shelves', s.shelves,
        'value_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') then coalesce(s.val, 0) end,
        'avg_cost_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') and coalesce(s.qty, 0) > 0 then round(s.val / s.qty) end,
        'lots', coalesce(s.lots, '[]'::jsonb)) order by p.category, p.name_ar)
    from public.products p
    left join lateral (select sum(l.qty_on_hand) qty, sum(round(l.qty_on_hand * l.unit_cost_baisa)) val,
        min(l.tire_year) filter (where l.qty_on_hand > 0) oldest_year,
        string_agg(distinct l.shelf, '، ') filter (where l.qty_on_hand > 0 and l.shelf is not null) shelves,
        jsonb_agg(jsonb_build_object('lot_id', l.id, 'lot_code', l.lot_code, 'dot_code', l.dot_code, 'qty', l.qty_on_hand, 'qty_received', l.qty_received,
          'unit_cost_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') then l.unit_cost_baisa end,
          'tire_year', l.tire_year, 'tire_week', l.tire_week, 'country', l.country, 'shelf', l.shelf, 'note', l.note,
          'reference', (select r.reference from public.purchase_receipts r where r.id = l.purchase_receipt_id),
          'received_at', l.received_at) order by l.received_at, l.id) filter (where l.qty_on_hand > 0) lots
      from public.inventory_lots l where l.branch_id = p_branch_id and l.product_id = p.id) s on true
    where p.organization_id = (select organization_id from public.branches where id = p_branch_id) and p.track_stock), '[]'::jsonb) end;
$$;

-- تعديل بيانات دفعة بعد الاستلام (نقلها إلى رف آخر أو تصحيح بياناتها). لا يغيّر الكمية ولا التكلفة.
create or replace function public.update_lot(p_lot_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old public.inventory_lots; v public.inventory_lots;
begin
  select * into v_old from public.inventory_lots where id = p_lot_id for update;
  if not found or not app.has_perm(v_old.branch_id, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  if (p->>'tire_year')::int not between 2000 and 2100 or (p->>'tire_week')::int not between 1 and 53 then perform app.fail('INVALID_REQUEST'); end if;
  update public.inventory_lots set
    shelf = case when p ? 'shelf' then p->>'shelf' else shelf end,
    country = case when p ? 'country' then p->>'country' else country end,
    note = case when p ? 'note' then p->>'note' else note end,
    dot_code = case when p ? 'dot_code' then nullif(btrim(p->>'dot_code'), '') else dot_code end,
    tire_year = case when p ? 'tire_year' then (p->>'tire_year')::int else tire_year end,
    tire_week = case when p ? 'tire_week' then (p->>'tire_week')::int else tire_week end
  where id = p_lot_id returning * into v;
  perform app.audit(v.organization_id, v.branch_id, 'stock.lot_update', 'inventory_lot', v.id, null,
    jsonb_build_object('shelf', v_old.shelf, 'tire_year', v_old.tire_year, 'tire_week', v_old.tire_week, 'country', v_old.country),
    jsonb_build_object('shelf', v.shelf, 'tire_year', v.tire_year, 'tire_week', v.tire_week, 'country', v.country));
  return jsonb_build_object('lot_id', v.id, 'shelf', v.shelf, 'tire_year', v.tire_year, 'tire_week', v.tire_week, 'country', v.country, 'dot_code', v.dot_code, 'note', v.note);
end $$;
revoke all on function public.update_lot(uuid, jsonb) from public, anon;
grant execute on function public.update_lot(uuid, jsonb) to authenticated, service_role;

-- ───────────── (3) ربط واتساب والرسائل النصية من الإعدادات ─────────────
-- لا سياسة قراءة ولا صلاحيات للتطبيقات: القيم تُكتب عبر الدالة أدناه ويقرؤها عامل الإشعارات بمفتاح الخدمة فقط.
create table public.notification_credentials (
  organization_id   uuid primary key references public.organizations(id),
  whatsapp_token    text,
  whatsapp_phone_id text,
  sms_user          text,
  sms_password      text,
  sms_header        text,
  updated_at        timestamptz not null default now(),
  updated_by        uuid
);
alter table public.notification_credentials enable row level security;
revoke all on public.notification_credentials from public, anon, authenticated;

alter table public.notification_settings
  add column whatsapp_enabled boolean not null default true,
  add column sms_text_ar text check (sms_text_ar is null or char_length(sms_text_ar) <= 300);

-- كتابة فقط: الحقل المرسل يُستبدل (النص الفارغ يمسحه)، والحقل غير المرسل يبقى. لا تُعاد القيم السرية أبدًا.
create or replace function public.set_notification_credentials(p_organization_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.notification_credentials;
begin
  if not (app.has_org_perm(p_organization_id, 'notifications.manage') and app.has_org_perm(p_organization_id, 'users.manage')) then perform app.fail('FORBIDDEN'); end if;
  insert into public.notification_credentials (organization_id) values (p_organization_id) on conflict do nothing;
  update public.notification_credentials set
    whatsapp_token = case when p ? 'whatsapp_token' then nullif(btrim(p->>'whatsapp_token'), '') else whatsapp_token end,
    whatsapp_phone_id = case when p ? 'whatsapp_phone_id' then nullif(btrim(p->>'whatsapp_phone_id'), '') else whatsapp_phone_id end,
    sms_user = case when p ? 'sms_user' then nullif(btrim(p->>'sms_user'), '') else sms_user end,
    sms_password = case when p ? 'sms_password' then nullif(btrim(p->>'sms_password'), '') else sms_password end,
    sms_header = case when p ? 'sms_header' then nullif(btrim(p->>'sms_header'), '') else sms_header end,
    updated_at = now(), updated_by = (select auth.uid())
  where organization_id = p_organization_id returning * into v;
  perform app.audit(p_organization_id, null, 'notifications.credentials', 'organization', p_organization_id, null, null,
    jsonb_build_object('fields', (select jsonb_agg(k) from jsonb_object_keys(p) k)));
  return jsonb_build_object('has_whatsapp', v.whatsapp_token is not null and v.whatsapp_phone_id is not null,
    'has_sms', v.sms_user is not null and v.sms_password is not null and v.sms_header is not null);
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
      'can_edit', app.has_org_perm(p_organization_id, 'users.manage')),
    'pending', (select count(*) from public.notification_events where organization_id = p_organization_id and status = 'pending'),
    'events', coalesce((select jsonb_agg(jsonb_build_object('created_at', e.created_at, 'event_type', e.event_type, 'status', e.status, 'channel', e.channel,
        'attempts', e.attempts, 'last_error', e.last_error, 'customer', (select name from public.customers where id = e.customer_id),
        'invoice_no', e.payload->>'invoice_no') order by e.created_at desc)
      from (select * from public.notification_events where organization_id = p_organization_id order by created_at desc limit 50) e), '[]'::jsonb));
end $$;

create or replace function public.update_notification_settings(p_organization_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.notification_settings;
begin
  if not app.has_org_perm(p_organization_id, 'notifications.manage') then perform app.fail('FORBIDDEN'); end if;
  if char_length(coalesce(p->>'sms_text_ar', '')) > 300 then perform app.fail('INVALID_REQUEST'); end if;
  insert into public.notification_settings (organization_id) values (p_organization_id) on conflict do nothing;
  update public.notification_settings set
    enabled = coalesce((p->>'enabled')::boolean, enabled),
    whatsapp_enabled = coalesce((p->>'whatsapp_enabled')::boolean, whatsapp_enabled),
    sms_fallback = coalesce((p->>'sms_fallback')::boolean, sms_fallback),
    whatsapp_template = coalesce(nullif(btrim(p->>'whatsapp_template'), ''), whatsapp_template),
    whatsapp_lang = coalesce(nullif(btrim(p->>'whatsapp_lang'), ''), whatsapp_lang),
    sms_text_ar = case when p ? 'sms_text_ar' then nullif(btrim(p->>'sms_text_ar'), '') else sms_text_ar end,
    updated_at = now()
  where organization_id = p_organization_id returning * into v;
  perform app.audit(p_organization_id, null, 'notifications.settings', 'organization', p_organization_id, null, null, to_jsonb(v));
  return to_jsonb(v);
end $$;

revoke all on function public.set_notification_credentials(uuid, jsonb), public.notification_overview(uuid), public.update_notification_settings(uuid, jsonb) from public, anon;
grant execute on function public.set_notification_credentials(uuid, jsonb), public.notification_overview(uuid), public.update_notification_settings(uuid, jsonb) to authenticated, service_role;
