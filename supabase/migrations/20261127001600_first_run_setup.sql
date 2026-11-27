-- الإعداد عند أول استخدام: القاعدة تبدأ فارغة، والتطبيق يعرض معالج التهيئة مرة واحدة.
-- بعد إنشاء المنشأة الأولى يُقفل المعالج نهائيًا، وتُسجَّل الأجهزة الإضافية بصلاحية الإدارة.

create or replace function public.setup_status() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('initialized', exists (select 1 from public.organizations));
$$;
revoke all on function public.setup_status() from public;
grant execute on function public.setup_status() to anon, authenticated, service_role;

-- p: { owner_id, owner_name, org_name_ar, org_name_en?, tax_registration_no?, tax_enabled, tax_rate_bp, prices_include_tax,
--      branches:[{code, name_ar, phone?, address_ar?}], device:{code, name, branch_index} }
-- تستدعيها دالة الخادم first-setup بمفتاح الخدمة فقط، بعد إنشاء حساب المالك.
create or replace function public.bootstrap_organization(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_owner uuid := (p->>'owner_id')::uuid; b jsonb; v_branch uuid; v_ids uuid[] := '{}'; v_code text; v_i int := 0;
  v_rate int := coalesce((p->>'tax_rate_bp')::int, 500); v_dev_branch uuid;
begin
  perform pg_advisory_xact_lock(hashtext('lamsat.bootstrap'));
  if exists (select 1 from public.organizations) then perform app.fail('ALREADY_INITIALIZED'); end if;
  if v_owner is null or btrim(coalesce(p->>'owner_name', '')) = '' or btrim(coalesce(p->>'org_name_ar', '')) = ''
     or jsonb_typeof(p->'branches') <> 'array' or jsonb_array_length(p->'branches') not between 1 and 10 or v_rate not between 0 and 10000 then
    perform app.fail('INVALID_REQUEST'); end if;

  insert into public.organizations (name_ar, name_en, tax_registration_no)
  values (btrim(p->>'org_name_ar'), nullif(btrim(p->>'org_name_en'), ''), nullif(btrim(p->>'tax_registration_no'), '')) returning id into v_org;

  for b in select * from jsonb_array_elements(p->'branches') loop
    v_code := upper(regexp_replace(coalesce(b->>'code', ''), '[^A-Za-z0-9]', '', 'g'));
    if length(v_code) not between 2 and 6 or btrim(coalesce(b->>'name_ar', '')) = '' then perform app.fail('INVALID_REQUEST', jsonb_build_object('branch', v_i)); end if;
    insert into public.branches (organization_id, code, name_ar, phone, address_ar)
    values (v_org, v_code, btrim(b->>'name_ar'), nullif(btrim(b->>'phone'), ''), nullif(btrim(b->>'address_ar'), '')) returning id into v_branch;
    insert into public.branch_settings (branch_id, organization_id, tax_enabled, tax_rate_bp, prices_include_tax, invoice_prefix, receipt_header_ar)
    values (v_branch, v_org, coalesce((p->>'tax_enabled')::boolean, false), v_rate, coalesce((p->>'prices_include_tax')::boolean, true), v_code, btrim(p->>'org_name_ar'));
    v_ids := v_ids || v_branch; v_i := v_i + 1;
  end loop;

  insert into public.profiles (id, full_name) values (v_owner, btrim(p->>'owner_name'));
  insert into public.memberships (organization_id, user_id, branch_id, role_code, max_discount_bp) values (v_org, v_owner, null, 'owner', 10000);

  insert into public.accounts (organization_id, code, name_ar, name_en, account_type, system_key) values
    (v_org, '1110', 'النقد في الصندوق', 'Cash on hand', 'asset', 'cash_on_hand'),
    (v_org, '1120', 'مقبوضات البطاقات تحت التسوية', 'Card clearing', 'asset', 'card_clearing'),
    (v_org, '1310', 'المخزون', 'Inventory', 'asset', 'inventory'),
    (v_org, '2210', 'ضريبة القيمة المضافة — مخرجات', 'VAT output', 'liability', 'vat_output'),
    (v_org, '2310', 'عربون العملاء', 'Customer deposits', 'liability', 'customer_deposits'),
    (v_org, '4110', 'مبيعات البضائع', 'Sales — goods', 'revenue', 'sales_goods'),
    (v_org, '4120', 'إيرادات الخدمات', 'Sales — services', 'revenue', 'sales_services'),
    (v_org, '5110', 'تكلفة البضاعة المباعة', 'Cost of goods sold', 'expense', 'cogs'),
    (v_org, '5910', 'فروقات الصندوق', 'Cash over/short', 'expense', 'cash_over_short');
  perform app.ensure_system_accounts(v_org);
  insert into public.notification_settings (organization_id) values (v_org) on conflict do nothing;

  if p ? 'device' and btrim(coalesce(p->'device'->>'code', '')) <> '' then
    v_dev_branch := v_ids[coalesce((p->'device'->>'branch_index')::int, 0) + 1];
    if v_dev_branch is null then perform app.fail('INVALID_REQUEST'); end if;
    insert into public.devices (organization_id, branch_id, code, name)
    values (v_org, v_dev_branch, btrim(p->'device'->>'code'), coalesce(nullif(btrim(p->'device'->>'name'), ''), 'الصندوق 1'));
  end if;
  return jsonb_build_object('status', 'initialized', 'organization_id', v_org, 'branch_ids', to_jsonb(v_ids));
end $$;
revoke all on function public.bootstrap_organization(jsonb) from public, anon, authenticated;
grant execute on function public.bootstrap_organization(jsonb) to service_role;

-- تسجيل جهاز كاشير جديد أو نقله لفرع: للمالك، أو لمدير الفرع في فرعه.
create or replace function public.register_device(p_code text, p_name text, p_branch_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_dev public.devices; v_code text := btrim(coalesce(p_code, ''));
begin
  select organization_id into v_org from public.branches where id = p_branch_id and is_active;
  if v_org is null or not app.has_perm(p_branch_id, 'settings.manage') then perform app.fail('FORBIDDEN'); end if;
  if length(v_code) not between 3 and 40 then perform app.fail('INVALID_REQUEST'); end if;
  select * into v_dev from public.devices where organization_id = v_org and code = v_code for update;
  if found then
    if v_dev.branch_id <> p_branch_id and not app.has_perm(v_dev.branch_id, 'settings.manage') then perform app.fail('FORBIDDEN'); end if;
    if exists (select 1 from public.cash_sessions where device_id = v_dev.id and status = 'open') and v_dev.branch_id <> p_branch_id then perform app.fail('SESSION_ALREADY_OPEN'); end if;
    update public.devices set branch_id = p_branch_id, name = coalesce(nullif(btrim(p_name), ''), name), is_active = true where id = v_dev.id returning * into v_dev;
  else
    insert into public.devices (organization_id, branch_id, code, name)
    values (v_org, p_branch_id, v_code, coalesce(nullif(btrim(p_name), ''), 'صندوق')) returning * into v_dev;
  end if;
  perform app.audit(v_org, p_branch_id, 'device.register', 'device', v_dev.id, null, null, to_jsonb(v_dev));
  return to_jsonb(v_dev);
end $$;
revoke all on function public.register_device(text, text, uuid) from public, anon;
grant execute on function public.register_device(text, text, uuid) to authenticated;
