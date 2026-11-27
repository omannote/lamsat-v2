-- لمسات | المرحلة 1 — التأسيس: المنشآت، الفروع، الأجهزة، المستخدمون، الأدوار والصلاحيات
-- كل المبالغ بالبيسة (bigint). 1 ر.ع = 1000 بيسة.

create schema if not exists app;            -- دوال داخلية غير معروضة عبر API
revoke all on schema app from public;
grant usage on schema app to authenticated, service_role;

-- ───────────── المنشآت والفروع ─────────────
create table public.organizations (
  id          uuid primary key default gen_random_uuid(),
  name_ar     text not null,
  name_en     text,
  tax_registration_no text,
  timezone    text not null default 'Asia/Muscat',
  created_at  timestamptz not null default now()
);

create table public.branches (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  code            text not null,
  name_ar         text not null,
  name_en         text,
  phone           text,
  address_ar      text,
  latitude        numeric(9,6),
  longitude       numeric(9,6),
  geofence_radius_m int,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (organization_id, code),
  unique (id, organization_id)
);

create table public.branch_settings (
  branch_id          uuid primary key references public.branches(id),
  organization_id    uuid not null references public.organizations(id),
  tax_enabled        boolean not null default false,
  tax_rate_bp        int not null default 500 check (tax_rate_bp between 0 and 10000),
  prices_include_tax boolean not null default true,
  invoice_prefix     text not null,
  receipt_header_ar  text,
  receipt_footer_ar  text,
  updated_at         timestamptz not null default now()
);

create table public.branch_counters (
  branch_id   uuid not null references public.branches(id),
  counter_key text not null,
  last_value  bigint not null default 0,
  primary key (branch_id, counter_key)
);

create table public.devices (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  branch_id       uuid not null,
  code            text not null,
  name            text not null,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (organization_id, code),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);

-- ───────────── المستخدمون والأدوار ─────────────
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  phone      text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.roles (
  code    text primary key,
  name_ar text not null,
  name_en text not null
);

create table public.permissions (
  code           text primary key,
  description_ar text not null
);

create table public.role_permissions (
  role_code       text not null references public.roles(code) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  primary key (role_code, permission_code)
);

-- branch_id = null يعني جميع فروع المنشأة
create table public.memberships (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  branch_id       uuid,
  role_code       text not null references public.roles(code),
  max_discount_bp int not null default 0 check (max_discount_bp between 0 and 10000),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);
create unique index memberships_uniq on public.memberships
  (user_id, organization_id, coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid), role_code);
create index memberships_user_idx on public.memberships (user_id) where is_active;

-- ───────────── سجل التدقيق ─────────────
create table public.audit_log (
  id              bigint generated always as identity primary key,
  organization_id uuid not null references public.organizations(id),
  branch_id       uuid references public.branches(id),
  user_id         uuid,
  action          text not null,
  entity_type     text not null,
  entity_id       uuid,
  reason          text,
  old_values      jsonb,
  new_values      jsonb,
  created_at      timestamptz not null default now()
);
create index audit_log_branch_time_idx on public.audit_log (organization_id, branch_id, created_at desc);
create index audit_log_entity_idx on public.audit_log (entity_type, entity_id);

-- ───────────── دوال التحقق من الصلاحيات ─────────────
create or replace function app.has_org(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = p_org);
$$;

create or replace function app.has_branch(p_branch uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    join public.branches b on b.id = p_branch and b.organization_id = m.organization_id
    where m.user_id = (select auth.uid()) and m.is_active
      and (m.branch_id is null or m.branch_id = p_branch));
$$;

create or replace function app.has_perm(p_branch uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    join public.branches b on b.id = p_branch and b.organization_id = m.organization_id
    join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = p_perm
    where m.user_id = (select auth.uid()) and m.is_active
      and (m.branch_id is null or m.branch_id = p_branch));
$$;

-- صلاحية على مستوى المنشأة (في أي فرع من فروعها)
create or replace function app.has_org_perm(p_org uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = p_perm
    where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = p_org);
$$;

-- صلاحية تشمل كل فروع المنشأة (عضوية بلا فرع محدد)
create or replace function app.has_orgwide_perm(p_org uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    join public.profiles p on p.id = m.user_id and p.is_active
    join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = p_perm
    where m.user_id = (select auth.uid()) and m.is_active
      and m.organization_id = p_org and m.branch_id is null);
$$;

create or replace function app.fail(p_code text, p_detail jsonb default null) returns void
language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = p_code, detail = coalesce(p_detail::text, '');
end $$;

create or replace function app.round_baisa(p numeric) returns bigint
language sql immutable as $$ select round(p)::bigint $$;   -- نصف فأكثر يُقرّب لأعلى (بعيدًا عن الصفر)

create or replace function app.audit(p_org uuid, p_branch uuid, p_action text, p_entity_type text,
  p_entity_id uuid, p_reason text default null, p_old jsonb default null, p_new jsonb default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_log (organization_id, branch_id, user_id, action, entity_type, entity_id, reason, old_values, new_values)
  values (p_org, p_branch, (select auth.uid()), p_action, p_entity_type, p_entity_id, p_reason, p_old, p_new);
$$;

revoke all on all functions in schema app from public;
grant execute on all functions in schema app to authenticated, service_role;

-- ───────────── بيانات مرجعية: الأدوار والصلاحيات ─────────────
insert into public.roles (code, name_ar, name_en) values
  ('owner', 'المالك', 'Owner'),
  ('branch_manager', 'مدير الفرع', 'Branch manager'),
  ('accountant', 'المحاسب', 'Accountant'),
  ('cashier', 'الكاشير', 'Cashier');

insert into public.permissions (code, description_ar) values
  ('pos.sell', 'إنشاء واعتماد فواتير البيع'),
  ('pos.discount', 'منح خصم ضمن الحد المسموح'),
  ('cash.open', 'فتح وردية صندوق'),
  ('cash.close', 'إقفال وردية صندوق'),
  ('cash.movement', 'تسجيل قبض وصرف نقدي'),
  ('invoice.view', 'عرض الفواتير'),
  ('invoice.reprint', 'إعادة طباعة الفاتورة'),
  ('invoice.adjust', 'تصحيح فاتورة معتمدة'),
  ('invoice.void', 'إلغاء فاتورة معتمدة'),
  ('invoice.refund', 'تنفيذ مرتجع'),
  ('draft.delete', 'حذف مسودة'),
  ('catalog.view', 'عرض الكتالوج والأسعار'),
  ('catalog.manage', 'إدارة الأصناف والأسعار'),
  ('inventory.view', 'عرض أرصدة المخزون'),
  ('inventory.cost.view', 'عرض التكلفة والهوامش'),
  ('inventory.manage', 'استلام وتسوية وتحويل المخزون'),
  ('reports.view', 'عرض التقارير والمؤشرات'),
  ('reports.export', 'تصدير التقارير'),
  ('accounting.view', 'عرض القيود ودليل الحسابات'),
  ('accounting.manage', 'إدارة القيود والحسابات'),
  ('users.manage', 'إدارة المستخدمين والأدوار'),
  ('settings.manage', 'إدارة إعدادات النظام والفروع'),
  ('notifications.manage', 'إدارة الإشعارات'),
  ('audit.view', 'عرض سجل التدقيق');

insert into public.role_permissions (role_code, permission_code)
select 'owner', code from public.permissions;

insert into public.role_permissions (role_code, permission_code)
select 'branch_manager', unnest(array[
  'pos.sell','pos.discount','cash.open','cash.close','cash.movement','invoice.view','invoice.reprint',
  'invoice.adjust','invoice.void','invoice.refund','draft.delete','catalog.view','inventory.view',
  'inventory.cost.view','inventory.manage','reports.view','reports.export','audit.view']);

insert into public.role_permissions (role_code, permission_code)
select 'accountant', unnest(array[
  'invoice.view','invoice.adjust','catalog.view','inventory.view','inventory.cost.view','reports.view',
  'reports.export','accounting.view','accounting.manage','audit.view']);

insert into public.role_permissions (role_code, permission_code)
select 'cashier', unnest(array[
  'pos.sell','cash.open','cash.close','cash.movement','invoice.view','invoice.reprint','catalog.view','inventory.view']);
-- لمسات | الكتالوج والمخزون والعملاء

create table public.products (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  sku             text not null,
  kind            text not null check (kind in ('item','service')),
  category        text not null default 'general' check (category in ('tire','tint','accessory','service','general')),
  name_ar         text not null,
  name_en         text,
  brand           text,
  unit            text not null default 'قطعة',
  whole_units_only boolean not null default true,
  track_stock     boolean not null default true,
  taxable         boolean not null default true,
  base_price_baisa bigint not null check (base_price_baisa >= 0),
  tire_width      int,
  tire_aspect     int,
  tire_rim        int,
  -- مفتاح بحث المقاس: 205/55R16 → 2055516
  tire_size_key   text generated always as (
    case when tire_width is not null and tire_aspect is not null and tire_rim is not null
         then tire_width::text || tire_aspect::text || tire_rim::text end) stored,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (organization_id, sku),
  unique (id, organization_id),
  check (kind = 'item' or track_stock = false)
);
create index products_org_name_idx on public.products (organization_id, name_ar);
create index products_tire_size_idx on public.products (organization_id, tire_size_key) where tire_size_key is not null;

create table public.product_barcodes (
  organization_id uuid not null,
  barcode         text not null,
  product_id      uuid not null,
  primary key (organization_id, barcode),
  foreign key (product_id, organization_id) references public.products(id, organization_id) on delete cascade
);

-- سعر خاص بالفرع يتقدّم على سعر المنشأة
create table public.branch_prices (
  branch_id       uuid not null,
  product_id      uuid not null,
  organization_id uuid not null,
  price_baisa     bigint not null check (price_baisa >= 0),
  updated_at      timestamptz not null default now(),
  primary key (branch_id, product_id),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id)
);

-- دفعات المخزون (FIFO). الرصيد = مجموع qty_on_hand، وكل تغيير له حركة في stock_movements.
create table public.inventory_lots (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  product_id      uuid not null,
  lot_code        text,
  dot_code        text,
  received_at     timestamptz not null default now(),
  unit_cost_baisa bigint not null check (unit_cost_baisa >= 0),
  qty_received    numeric(12,3) not null check (qty_received > 0),
  qty_on_hand     numeric(12,3) not null check (qty_on_hand >= 0),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id),
  check (qty_on_hand <= qty_received)
);
create index inventory_lots_fifo_idx on public.inventory_lots (branch_id, product_id, received_at, id) where qty_on_hand > 0;

create table public.stock_movements (
  id              bigint generated always as identity primary key,
  organization_id uuid not null,
  branch_id       uuid not null,
  product_id      uuid not null,
  lot_id          uuid not null references public.inventory_lots(id),
  movement_type   text not null check (movement_type in
    ('opening','purchase_receipt','sale','sale_return','void_reversal','adjustment','transfer_out','transfer_in')),
  qty_delta       numeric(12,3) not null check (qty_delta <> 0),
  unit_cost_baisa bigint not null,
  source_type     text,
  source_id       uuid,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (product_id, organization_id) references public.products(id, organization_id)
);
create index stock_movements_product_idx on public.stock_movements (branch_id, product_id, created_at);
create index stock_movements_source_idx on public.stock_movements (source_type, source_id);

create table public.customers (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name            text not null,
  phone           text,
  preferred_lang  text not null default 'ar' check (preferred_lang in ('ar','en')),
  notes           text,
  created_at      timestamptz not null default now(),
  unique (id, organization_id)
);
create unique index customers_phone_uniq on public.customers (organization_id, phone) where phone is not null;

create table public.vehicles (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  customer_id     uuid,
  plate           text not null,
  make            text,
  model           text,
  created_at      timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (customer_id, organization_id) references public.customers(id, organization_id)
);
create index vehicles_plate_idx on public.vehicles (organization_id, plate);
-- لمسات | اليوم المحاسبي، الورديات، الفواتير، المدفوعات، القيود، طلبات العمليات، أحداث الإشعار

create table public.business_days (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  business_date   date not null,
  status          text not null default 'open' check (status in ('open','closed')),
  opened_at       timestamptz not null default now(),
  opened_by       uuid,
  closed_at       timestamptz,
  closed_by       uuid,
  unique (branch_id, business_date),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);
create unique index business_days_one_open on public.business_days (branch_id) where status = 'open';

create table public.cash_sessions (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  device_id       uuid not null references public.devices(id),
  business_day_id uuid not null references public.business_days(id),
  opened_by       uuid not null references public.profiles(id),
  opened_at       timestamptz not null default now(),
  opening_cash_baisa bigint not null check (opening_cash_baisa >= 0),
  status          text not null default 'open' check (status in ('open','closed')),
  closed_at       timestamptz,
  closed_by       uuid,
  expected_cash_baisa bigint,
  counted_cash_baisa  bigint,
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);
create unique index cash_sessions_one_open_per_device on public.cash_sessions (device_id) where status = 'open';
create index cash_sessions_branch_idx on public.cash_sessions (branch_id, opened_at desc);

create table public.invoices (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  invoice_no      text not null,
  seq             bigint not null,
  status          text not null default 'approved' check (status in ('approved','voided')),
  business_day_id uuid not null references public.business_days(id),
  cash_session_id uuid not null references public.cash_sessions(id),
  device_id       uuid not null references public.devices(id),
  cashier_id      uuid not null references public.profiles(id),
  customer_id     uuid,
  vehicle_id      uuid,
  tax_rate_bp     int not null,
  prices_include_tax boolean not null,
  subtotal_baisa  bigint not null,          -- إجمالي البنود قبل الخصم
  discount_baisa  bigint not null,
  net_baisa       bigint not null,          -- الصافي قبل الضريبة
  tax_baisa       bigint not null,
  total_baisa     bigint not null,          -- المستحق شاملًا الضريبة
  paid_baisa      bigint not null,
  change_baisa    bigint not null default 0,
  note            text,
  operation_id    uuid not null unique,
  version         int not null default 1,
  print_count     int not null default 0,
  approved_at     timestamptz not null default now(),
  unique (organization_id, invoice_no),
  unique (branch_id, seq),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (customer_id, organization_id) references public.customers(id, organization_id),
  foreign key (vehicle_id, organization_id) references public.vehicles(id, organization_id),
  check (total_baisa = net_baisa + tax_baisa),
  check (paid_baisa = total_baisa)
);
create index invoices_branch_time_idx on public.invoices (branch_id, approved_at desc);
create index invoices_day_idx on public.invoices (business_day_id);
create index invoices_customer_idx on public.invoices (customer_id) where customer_id is not null;

create table public.invoice_lines (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  invoice_id      uuid not null references public.invoices(id),
  line_no         int not null,
  product_id      uuid not null references public.products(id),
  kind            text not null,
  sku             text not null,
  description_ar  text not null,
  unit            text not null,
  qty             numeric(12,3) not null check (qty > 0),
  unit_price_baisa bigint not null,
  gross_baisa     bigint not null,
  discount_baisa  bigint not null default 0 check (discount_baisa >= 0),
  taxable         boolean not null,
  tax_rate_bp     int not null,
  net_baisa       bigint not null,
  tax_baisa       bigint not null,
  total_baisa     bigint not null,
  unique (invoice_id, line_no),
  check (discount_baisa <= gross_baisa),
  check (total_baisa = net_baisa + tax_baisa)
);

-- التكلفة في جدول مستقل حتى لا تُعرض للكاشير
create table public.invoice_line_costs (
  invoice_line_id uuid primary key references public.invoice_lines(id),
  organization_id uuid not null,
  branch_id       uuid not null,
  cost_baisa      bigint not null default 0
);

create table public.payments (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  invoice_id      uuid not null references public.invoices(id),
  cash_session_id uuid not null references public.cash_sessions(id),
  method          text not null check (method in ('cash','card')),
  amount_baisa    bigint not null check (amount_baisa > 0),
  tendered_baisa  bigint,
  card_reference  text,
  created_at      timestamptz not null default now()
);
create index payments_invoice_idx on public.payments (invoice_id);
create index payments_session_idx on public.payments (cash_session_id, method);

create table public.cash_movements (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  cash_session_id uuid not null references public.cash_sessions(id),
  movement_type   text not null check (movement_type in ('opening','sale','refund','cash_in','cash_out','closing')),
  amount_baisa    bigint not null,           -- موجب = دخول للدرج، سالب = خروج
  source_type     text,
  source_id       uuid,
  note            text,
  created_by      uuid,
  created_at      timestamptz not null default now()
);
create index cash_movements_session_idx on public.cash_movements (cash_session_id);

-- ───────────── المحاسبة ─────────────
create table public.accounts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  code            text not null,
  name_ar         text not null,
  name_en         text,
  account_type    text not null check (account_type in ('asset','liability','equity','revenue','expense')),
  system_key      text,
  is_active       boolean not null default true,
  unique (organization_id, code)
);
create unique index accounts_system_key_uniq on public.accounts (organization_id, system_key) where system_key is not null;

create table public.journal_entries (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  business_day_id uuid references public.business_days(id),
  entry_no        bigint generated always as identity,
  source_type     text not null,
  source_id       uuid not null,
  description     text,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id)
);
create index journal_entries_source_idx on public.journal_entries (source_type, source_id);
create index journal_entries_branch_idx on public.journal_entries (branch_id, created_at desc);

create table public.journal_lines (
  id              bigint generated always as identity primary key,
  entry_id        uuid not null references public.journal_entries(id),
  organization_id uuid not null,
  branch_id       uuid not null,
  account_id      uuid not null references public.accounts(id),
  debit_baisa     bigint not null default 0 check (debit_baisa >= 0),
  credit_baisa    bigint not null default 0 check (credit_baisa >= 0),
  check ((debit_baisa = 0) <> (credit_baisa = 0))
);
create index journal_lines_entry_idx on public.journal_lines (entry_id);
create index journal_lines_account_idx on public.journal_lines (account_id);

-- القيد يجب أن يتوازن عند نهاية المعاملة
create or replace function app.check_journal_balanced() returns trigger
language plpgsql set search_path = '' as $$
declare v_d bigint; v_c bigint;
begin
  select coalesce(sum(debit_baisa),0), coalesce(sum(credit_baisa),0) into v_d, v_c
  from public.journal_lines where entry_id = new.entry_id;
  if v_d <> v_c then
    raise exception using errcode = 'P0001', message = 'JOURNAL_UNBALANCED',
      detail = format('entry %s debit %s credit %s', new.entry_id, v_d, v_c);
  end if;
  return null;
end $$;
create constraint trigger journal_lines_balanced after insert or update on public.journal_lines
  deferrable initially deferred for each row execute function app.check_journal_balanced();

-- ───────────── طلبات العمليات (منع التكرار) ─────────────
create table public.operation_requests (
  operation_id    uuid primary key,
  organization_id uuid not null,
  branch_id       uuid not null,
  device_id       uuid,
  cash_session_id uuid,
  user_id         uuid not null,
  op_type         text not null,
  request_hash    text not null,
  result          jsonb not null,
  created_at      timestamptz not null default now()
);
create index operation_requests_session_idx on public.operation_requests (cash_session_id, created_at desc);

-- ───────────── أحداث الإشعار (الطابور يُنفَّذ في المرحلة 4) ─────────────
create table public.notification_events (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  event_type      text not null check (event_type in
    ('invoice_issued','deposit_recorded','vehicle_ready','invoice_voided','invoice_adjusted')),
  customer_id     uuid not null,
  invoice_id      uuid references public.invoices(id),
  lang            text not null default 'ar',
  payload         jsonb not null default '{}',
  status          text not null default 'pending',
  created_at      timestamptz not null default now(),
  foreign key (customer_id, organization_id) references public.customers(id, organization_id)
);
create index notification_events_pending_idx on public.notification_events (created_at) where status = 'pending';

-- منع التعديل والحذف المباشر على السجلات المالية حتى لمالك الجدول عبر الدوال الخاطئة
create or replace function app.forbid_change() returns trigger language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = 'IMMUTABLE_RECORD', detail = tg_table_name;
end $$;
create trigger invoice_lines_immutable before update or delete on public.invoice_lines for each row execute function app.forbid_change();
create trigger payments_immutable      before update or delete on public.payments      for each row execute function app.forbid_change();
create trigger journal_lines_immutable before update or delete on public.journal_lines for each row execute function app.forbid_change();
create trigger stock_movements_immutable before update or delete on public.stock_movements for each row execute function app.forbid_change();
create trigger audit_log_immutable     before update or delete on public.audit_log     for each row execute function app.forbid_change();
-- لمسات | RLS: القراءة عبر السياسات، والكتابة المالية عبر دوال RPC فقط

create or replace function app.shares_org(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships mine
    join public.memberships theirs on theirs.organization_id = mine.organization_id
    where mine.user_id = (select auth.uid()) and mine.is_active and theirs.user_id = p_user);
$$;
revoke all on function app.shares_org(uuid) from public;
grant execute on function app.shares_org(uuid) to authenticated, service_role;

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated, public', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;
-- جداول داخلية لا تُقرأ مباشرة
revoke select on public.branch_counters, public.operation_requests from authenticated;

create policy org_read on public.organizations for select to authenticated using (app.has_org(id));
create policy branch_read on public.branches for select to authenticated using (app.has_branch(id));
create policy branch_settings_read on public.branch_settings for select to authenticated using (app.has_branch(branch_id));
create policy devices_read on public.devices for select to authenticated using (app.has_branch(branch_id));

create policy profiles_read on public.profiles for select to authenticated
  using (id = (select auth.uid()) or app.shares_org(id));
create policy roles_read on public.roles for select to authenticated using (true);
create policy permissions_read on public.permissions for select to authenticated using (true);
create policy role_permissions_read on public.role_permissions for select to authenticated using (true);
create policy memberships_read on public.memberships for select to authenticated
  using (user_id = (select auth.uid()) or app.has_org_perm(organization_id, 'users.manage'));

create policy audit_read on public.audit_log for select to authenticated
  using (case when branch_id is null then app.has_orgwide_perm(organization_id, 'audit.view')
              else app.has_perm(branch_id, 'audit.view') end);

create policy products_read on public.products for select to authenticated
  using (app.has_org_perm(organization_id, 'catalog.view'));
create policy barcodes_read on public.product_barcodes for select to authenticated
  using (app.has_org_perm(organization_id, 'catalog.view'));
create policy branch_prices_read on public.branch_prices for select to authenticated
  using (app.has_perm(branch_id, 'catalog.view'));
create policy lots_read on public.inventory_lots for select to authenticated
  using (app.has_perm(branch_id, 'inventory.cost.view'));
create policy stock_movements_read on public.stock_movements for select to authenticated
  using (app.has_perm(branch_id, 'inventory.cost.view'));

create policy customers_read on public.customers for select to authenticated using (app.has_org(organization_id));
create policy vehicles_read on public.vehicles for select to authenticated using (app.has_org(organization_id));

create policy business_days_read on public.business_days for select to authenticated using (app.has_branch(branch_id));
create policy cash_sessions_read on public.cash_sessions for select to authenticated using (app.has_branch(branch_id));
create policy cash_movements_read on public.cash_movements for select to authenticated using (app.has_branch(branch_id));

create policy invoices_read on public.invoices for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create policy invoice_lines_read on public.invoice_lines for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create policy payments_read on public.payments for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create policy invoice_line_costs_read on public.invoice_line_costs for select to authenticated
  using (app.has_perm(branch_id, 'inventory.cost.view'));

create policy accounts_read on public.accounts for select to authenticated
  using (app.has_org_perm(organization_id, 'accounting.view'));
create policy journal_entries_read on public.journal_entries for select to authenticated
  using (app.has_perm(branch_id, 'accounting.view'));
create policy journal_lines_read on public.journal_lines for select to authenticated
  using (app.has_perm(branch_id, 'accounting.view'));

create policy notification_events_read on public.notification_events for select to authenticated
  using (app.has_perm(branch_id, 'notifications.manage'));

-- ظهور الفاتورة فورًا في لوحة الويب (Supabase Realtime)
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.invoices;
  end if;
end $$;
-- لمسات | دوال RPC: السياق، البحث، فتح الوردية، اعتماد البيع، التحقق من العملية، المؤشرات

-- ───────────── سياق المستخدم ─────────────
create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'user', (select jsonb_build_object('id', p.id, 'full_name', p.full_name)
             from public.profiles p where p.id = (select auth.uid()) and p.is_active),
    'branches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'organization_id', b.organization_id, 'code', b.code,
        'name_ar', b.name_ar, 'name_en', b.name_en,
        'tax_enabled', s.tax_enabled, 'tax_rate_bp', s.tax_rate_bp, 'prices_include_tax', s.prices_include_tax,
        'roles', (select jsonb_agg(distinct m.role_code) from public.memberships m
                  where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = b.organization_id
                    and (m.branch_id is null or m.branch_id = b.id)),
        'max_discount_bp', (select coalesce(max(m.max_discount_bp), 0) from public.memberships m
                  join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = 'pos.discount'
                  where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = b.organization_id
                    and (m.branch_id is null or m.branch_id = b.id)),
        'permissions', (select coalesce(jsonb_agg(distinct rp.permission_code), '[]'::jsonb)
                  from public.memberships m join public.role_permissions rp on rp.role_code = m.role_code
                  where m.user_id = (select auth.uid()) and m.is_active and m.organization_id = b.organization_id
                    and (m.branch_id is null or m.branch_id = b.id))
      ) order by b.code)
      from public.branches b join public.branch_settings s on s.branch_id = b.id
      where b.is_active and app.has_branch(b.id)), '[]'::jsonb));
$$;

-- ───────────── الجهاز والوردية الحالية ─────────────
create or replace function public.resolve_device(p_code text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_dev public.devices; v_sess public.cash_sessions;
begin
  select d.* into v_dev from public.devices d
  where d.code = p_code and d.is_active and app.has_branch(d.branch_id);
  if not found then perform app.fail('DEVICE_NOT_FOUND'); end if;
  select * into v_sess from public.cash_sessions where device_id = v_dev.id and status = 'open';
  return jsonb_build_object(
    'device', jsonb_build_object('id', v_dev.id, 'code', v_dev.code, 'name', v_dev.name, 'branch_id', v_dev.branch_id),
    'open_session', case when v_sess.id is null then null else jsonb_build_object(
        'id', v_sess.id, 'opened_by', v_sess.opened_by, 'opened_at', v_sess.opened_at,
        'opening_cash_baisa', v_sess.opening_cash_baisa, 'mine', v_sess.opened_by = (select auth.uid()),
        'opened_by_name', (select full_name from public.profiles where id = v_sess.opened_by)) end);
end $$;

create or replace function public.open_cash_session(p_operation_id uuid, p_device_id uuid, p_opening_cash_baisa bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_dev public.devices; v_day public.business_days; v_sess public.cash_sessions;
  v_op public.operation_requests; v_hash text; v_result jsonb; v_tz text;
begin
  if v_uid is null then perform app.fail('NOT_AUTHENTICATED'); end if;
  if p_operation_id is null then perform app.fail('INVALID_REQUEST'); end if;
  v_hash := md5(jsonb_build_object('device_id', p_device_id, 'opening', p_opening_cash_baisa)::text);

  select * into v_op from public.operation_requests where operation_id = p_operation_id;
  if found then
    if v_op.user_id <> v_uid or v_op.op_type <> 'open_session' or v_op.request_hash <> v_hash then
      perform app.fail('OPERATION_MISMATCH'); end if;
    return v_op.result || jsonb_build_object('replayed', true);
  end if;

  if p_opening_cash_baisa is null or p_opening_cash_baisa < 0 then perform app.fail('INVALID_AMOUNT'); end if;
  select * into v_dev from public.devices where id = p_device_id and is_active for update;
  if not found then perform app.fail('DEVICE_NOT_FOUND'); end if;
  if not app.has_perm(v_dev.branch_id, 'cash.open') then perform app.fail('FORBIDDEN'); end if;

  select * into v_sess from public.cash_sessions where device_id = v_dev.id and status = 'open';
  if found then
    perform app.fail('SESSION_ALREADY_OPEN', jsonb_build_object('session_id', v_sess.id, 'mine', v_sess.opened_by = v_uid));
  end if;

  -- اليوم المحاسبي: يُستخدم اليوم المفتوح إن وُجد (حتى بعد منتصف الليل)، وإلا يُفتح يوم بتاريخ مسقط
  select * into v_day from public.business_days where branch_id = v_dev.branch_id and status = 'open';
  if not found then
    select timezone into v_tz from public.organizations where id = v_dev.organization_id;
    insert into public.business_days (organization_id, branch_id, business_date, opened_by)
    values (v_dev.organization_id, v_dev.branch_id, (now() at time zone v_tz)::date, v_uid)
    on conflict (branch_id, business_date) do nothing
    returning * into v_day;
    if v_day.id is null then
      select * into v_day from public.business_days where branch_id = v_dev.branch_id and status = 'open';
      if not found then perform app.fail('BUSINESS_DAY_CLOSED'); end if;
    end if;
  end if;

  insert into public.cash_sessions (organization_id, branch_id, device_id, business_day_id, opened_by, opening_cash_baisa)
  values (v_dev.organization_id, v_dev.branch_id, v_dev.id, v_day.id, v_uid, p_opening_cash_baisa)
  returning * into v_sess;

  insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, created_by)
  values (v_sess.organization_id, v_sess.branch_id, v_sess.id, 'opening', p_opening_cash_baisa, v_uid);

  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'cash_session.open', 'cash_session', v_sess.id, null, null,
    jsonb_build_object('opening_cash_baisa', p_opening_cash_baisa, 'device', v_dev.code, 'business_date', v_day.business_date));

  v_result := jsonb_build_object('status', 'opened', 'session', jsonb_build_object(
    'id', v_sess.id, 'branch_id', v_sess.branch_id, 'device_id', v_sess.device_id, 'opened_at', v_sess.opened_at,
    'opening_cash_baisa', v_sess.opening_cash_baisa, 'business_day_id', v_day.id, 'business_date', v_day.business_date));

  insert into public.operation_requests (operation_id, organization_id, branch_id, device_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_operation_id, v_sess.organization_id, v_sess.branch_id, v_dev.id, v_sess.id, v_uid, 'open_session', v_hash, v_result);
  return v_result || jsonb_build_object('replayed', false);
end $$;

-- ───────────── السعر النافذ والبحث ─────────────
create or replace function app.effective_price(p_branch uuid, p_product uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select coalesce((select bp.price_baisa from public.branch_prices bp where bp.branch_id = p_branch and bp.product_id = p_product),
                  (select pr.base_price_baisa from public.products pr where pr.id = p_product));
$$;
revoke all on function app.effective_price(uuid, uuid) from public;
grant execute on function app.effective_price(uuid, uuid) to authenticated, service_role;

create or replace function public.pos_search(p_branch_id uuid, p_query text, p_limit int default 30)
returns table (product_id uuid, sku text, kind text, category text, name_ar text, name_en text, brand text,
               unit text, whole_units_only boolean, track_stock boolean, taxable boolean,
               tire_size text, unit_price_baisa bigint, stock_qty numeric, exact_barcode boolean)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_q text := btrim(coalesce(p_query, ''));
  v_digits text := regexp_replace(v_q, '[^0-9]', '', 'g');
  v_org uuid;
begin
  if not app.has_perm(p_branch_id, 'catalog.view') then perform app.fail('FORBIDDEN'); end if;
  select organization_id into v_org from public.branches where id = p_branch_id;
  return query
  select p.id, p.sku, p.kind, p.category, p.name_ar, p.name_en, p.brand, p.unit, p.whole_units_only,
         p.track_stock, p.taxable,
         case when p.tire_size_key is not null then p.tire_width || '/' || p.tire_aspect || 'R' || p.tire_rim end,
         app.effective_price(p_branch_id, p.id),
         case when p.track_stock then coalesce((select sum(l.qty_on_hand) from public.inventory_lots l
              where l.branch_id = p_branch_id and l.product_id = p.id), 0) end,
         exists (select 1 from public.product_barcodes pb where pb.organization_id = v_org and pb.product_id = p.id and pb.barcode = v_q)
  from public.products p
  where p.organization_id = v_org and p.is_active
    and (v_q = ''
      or exists (select 1 from public.product_barcodes pb where pb.organization_id = v_org and pb.product_id = p.id and pb.barcode = v_q)
      or p.sku ilike v_q || '%'
      or p.name_ar ilike '%' || v_q || '%'
      or p.name_en ilike '%' || v_q || '%'
      or p.brand ilike '%' || v_q || '%'
      or (length(v_digits) >= 3 and p.tire_size_key like v_digits || '%'))
  order by 15 desc, (p.sku ilike v_q) desc, p.category, p.name_ar
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

-- ───────────── تمثيل الفاتورة (للإيصال وإعادة الطباعة) ─────────────
create or replace function app.invoice_json(p_invoice_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', i.id, 'invoice_no', i.invoice_no, 'status', i.status, 'approved_at', i.approved_at,
    'business_date', d.business_date, 'branch_id', i.branch_id,
    'branch', jsonb_build_object('code', b.code, 'name_ar', b.name_ar, 'phone', b.phone, 'address_ar', b.address_ar,
       'receipt_header_ar', s.receipt_header_ar, 'receipt_footer_ar', s.receipt_footer_ar),
    'organization', jsonb_build_object('name_ar', o.name_ar, 'tax_registration_no', o.tax_registration_no),
    'cashier_name', (select full_name from public.profiles where id = i.cashier_id),
    'customer', (select jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone) from public.customers c where c.id = i.customer_id),
    'vehicle', (select jsonb_build_object('id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model) from public.vehicles v where v.id = i.vehicle_id),
    'tax_rate_bp', i.tax_rate_bp, 'prices_include_tax', i.prices_include_tax,
    'subtotal_baisa', i.subtotal_baisa, 'discount_baisa', i.discount_baisa, 'net_baisa', i.net_baisa,
    'tax_baisa', i.tax_baisa, 'total_baisa', i.total_baisa, 'paid_baisa', i.paid_baisa, 'change_baisa', i.change_baisa,
    'note', i.note, 'print_count', i.print_count,
    'lines', (select jsonb_agg(jsonb_build_object(
        'line_no', l.line_no, 'product_id', l.product_id, 'sku', l.sku, 'kind', l.kind, 'description_ar', l.description_ar,
        'unit', l.unit, 'qty', l.qty, 'unit_price_baisa', l.unit_price_baisa, 'gross_baisa', l.gross_baisa,
        'discount_baisa', l.discount_baisa, 'net_baisa', l.net_baisa, 'tax_baisa', l.tax_baisa, 'total_baisa', l.total_baisa)
        order by l.line_no) from public.invoice_lines l where l.invoice_id = i.id),
    'payments', (select jsonb_agg(jsonb_build_object('method', p.method, 'amount_baisa', p.amount_baisa,
        'tendered_baisa', p.tendered_baisa, 'card_reference', p.card_reference) order by p.method, p.created_at)
        from public.payments p where p.invoice_id = i.id))
  from public.invoices i
  join public.branches b on b.id = i.branch_id
  join public.branch_settings s on s.branch_id = i.branch_id
  join public.organizations o on o.id = i.organization_id
  join public.business_days d on d.id = i.business_day_id
  where i.id = p_invoice_id;
$$;
revoke all on function app.invoice_json(uuid) from public;
grant execute on function app.invoice_json(uuid) to service_role;

create or replace function public.get_invoice(p_invoice_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_branch uuid;
begin
  select branch_id into v_branch from public.invoices where id = p_invoice_id;
  if v_branch is null or not app.has_perm(v_branch, 'invoice.view') then perform app.fail('NOT_FOUND'); end if;
  return app.invoice_json(p_invoice_id);
end $$;

create or replace function public.record_invoice_print(p_invoice_id uuid, p_is_reprint boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_inv public.invoices;
begin
  select * into v_inv from public.invoices where id = p_invoice_id;
  if not found or not app.has_perm(v_inv.branch_id, case when p_is_reprint then 'invoice.reprint' else 'invoice.view' end) then
    perform app.fail('FORBIDDEN'); end if;
  update public.invoices set print_count = print_count + 1 where id = p_invoice_id;
  if p_is_reprint then
    perform app.audit(v_inv.organization_id, v_inv.branch_id, 'invoice.reprint', 'invoice', v_inv.id, null, null,
      jsonb_build_object('invoice_no', v_inv.invoice_no, 'print_count', v_inv.print_count + 1));
  end if;
end $$;

-- ───────────── اعتماد البيع ─────────────
-- p_payload: { cash_session_id, customer_id?, vehicle_id?, note?, expected_total_baisa,
--              lines:[{product_id, qty, unit_price_baisa, discount_baisa?}],
--              payments:[{method:'cash'|'card', amount_baisa, card_reference?}], cash_tendered_baisa? }
create or replace function public.approve_sale(p_operation_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_hash text;
  v_op public.operation_requests;
  v_sess public.cash_sessions;
  v_day public.business_days;
  v_set public.branch_settings;
  v_prod public.products;
  v_line jsonb; v_pay jsonb; v_lot record;
  v_lines jsonb := '[]'::jsonb;
  v_changes jsonb := '[]'::jsonb;
  v_idx int := 0;
  v_qty numeric(12,3); v_price bigint; v_expected bigint; v_gross bigint; v_disc bigint;
  v_base bigint; v_tax bigint; v_net bigint; v_ltotal bigint; v_rate int;
  v_subtotal bigint := 0; v_discount bigint := 0; v_net_total bigint := 0; v_tax_total bigint := 0; v_total bigint := 0;
  v_net_goods bigint := 0; v_net_services bigint := 0;
  v_max_disc int;
  v_cash bigint := 0; v_card bigint := 0; v_tendered bigint; v_change bigint := 0; v_amt bigint;
  v_customer uuid; v_vehicle uuid; v_cust public.customers;
  v_seq bigint; v_invoice_no text; v_invoice_id uuid := gen_random_uuid(); v_line_id uuid;
  v_need numeric(12,3); v_take numeric(12,3); v_line_cost bigint; v_cost_total bigint := 0; v_avail numeric;
  v_entry uuid; v_result jsonb; v_inserted int;
begin
  if v_uid is null then perform app.fail('NOT_AUTHENTICATED'); end if;
  if p_operation_id is null or p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    perform app.fail('INVALID_REQUEST'); end if;
  v_hash := md5(p_payload::text);

  -- 1) طلب مُعاد: أعِد النتيجة الأصلية بعد مطابقة الطلب
  select * into v_op from public.operation_requests where operation_id = p_operation_id;
  if found then
    if v_op.op_type = 'cancelled' then perform app.fail('OPERATION_CANCELLED'); end if;
    if v_op.user_id <> v_uid or v_op.op_type <> 'sale' or v_op.request_hash <> v_hash then
      perform app.fail('OPERATION_MISMATCH'); end if;
    return v_op.result || jsonb_build_object('replayed', true);
  end if;

  -- 2) الوردية والصلاحية
  select * into v_sess from public.cash_sessions where id = (p_payload->>'cash_session_id')::uuid;
  if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
  if not app.has_perm(v_sess.branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
  if v_sess.opened_by <> v_uid then perform app.fail('SESSION_NOT_YOURS'); end if;
  select * into v_day from public.business_days where id = v_sess.business_day_id;
  if v_day.status <> 'open' then perform app.fail('BUSINESS_DAY_CLOSED'); end if;
  select * into v_set from public.branch_settings where branch_id = v_sess.branch_id;
  v_rate := case when v_set.tax_enabled then v_set.tax_rate_bp else 0 end;

  select coalesce(max(m.max_discount_bp), 0) into v_max_disc
  from public.memberships m
  join public.role_permissions rp on rp.role_code = m.role_code and rp.permission_code = 'pos.discount'
  where m.user_id = v_uid and m.is_active and m.organization_id = v_sess.organization_id
    and (m.branch_id is null or m.branch_id = v_sess.branch_id);

  -- 3) تسعير البنود من السجل المركزي
  if jsonb_typeof(p_payload->'lines') <> 'array' or jsonb_array_length(p_payload->'lines') not between 1 and 200 then
    perform app.fail('EMPTY_CART'); end if;

  for v_line in select * from jsonb_array_elements(p_payload->'lines') loop
    v_idx := v_idx + 1;
    select * into v_prod from public.products
    where id = (v_line->>'product_id')::uuid and organization_id = v_sess.organization_id and is_active;
    if not found then perform app.fail('PRODUCT_NOT_FOUND', jsonb_build_object('line_no', v_idx)); end if;

    v_qty := (v_line->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 or (v_prod.whole_units_only and v_qty <> trunc(v_qty)) then
      perform app.fail('INVALID_QUANTITY', jsonb_build_object('line_no', v_idx, 'sku', v_prod.sku)); end if;

    v_price := app.effective_price(v_sess.branch_id, v_prod.id);
    v_expected := (v_line->>'unit_price_baisa')::bigint;
    if v_expected is distinct from v_price then
      v_changes := v_changes || jsonb_build_object('line_no', v_idx, 'product_id', v_prod.id, 'sku', v_prod.sku,
        'name_ar', v_prod.name_ar, 'expected_baisa', v_expected, 'current_baisa', v_price);
    end if;

    v_gross := app.round_baisa(v_qty * v_price);
    v_disc := coalesce((v_line->>'discount_baisa')::bigint, 0);
    if v_disc < 0 or v_disc > v_gross then perform app.fail('INVALID_DISCOUNT', jsonb_build_object('line_no', v_idx)); end if;
    if v_disc > 0 and v_disc * 10000 > v_gross * v_max_disc then
      perform app.fail('DISCOUNT_LIMIT_EXCEEDED', jsonb_build_object('line_no', v_idx, 'max_discount_bp', v_max_disc)); end if;

    v_base := v_gross - v_disc;
    if v_prod.taxable and v_rate > 0 then
      if v_set.prices_include_tax then
        v_tax := app.round_baisa(v_base::numeric * v_rate / (10000 + v_rate));
        v_net := v_base - v_tax;
      else
        v_tax := app.round_baisa(v_base::numeric * v_rate / 10000);
        v_net := v_base;
      end if;
    else
      v_tax := 0; v_net := v_base;
    end if;
    v_ltotal := v_net + v_tax;

    v_subtotal := v_subtotal + v_gross; v_discount := v_discount + v_disc;
    v_net_total := v_net_total + v_net; v_tax_total := v_tax_total + v_tax; v_total := v_total + v_ltotal;
    if v_prod.kind = 'service' then v_net_services := v_net_services + v_net; else v_net_goods := v_net_goods + v_net; end if;

    v_lines := v_lines || jsonb_build_object('line_no', v_idx, 'product_id', v_prod.id, 'kind', v_prod.kind, 'sku', v_prod.sku,
      'description_ar', v_prod.name_ar, 'unit', v_prod.unit, 'qty', v_qty, 'unit_price_baisa', v_price, 'gross_baisa', v_gross,
      'discount_baisa', v_disc, 'taxable', (v_prod.taxable and v_rate > 0), 'tax_rate_bp', case when v_prod.taxable then v_rate else 0 end,
      'net_baisa', v_net, 'tax_baisa', v_tax, 'total_baisa', v_ltotal, 'track_stock', v_prod.track_stock);
  end loop;

  -- تغيّر السعر أو الإجمالي منذ الإضافة للسلة: لا يُحفظ شيء، ويُعرض الفرق للكاشير ليؤكده
  if jsonb_array_length(v_changes) > 0 then
    return jsonb_build_object('status', 'price_changed', 'changes', v_changes, 'server_total_baisa', v_total);
  end if;
  if (p_payload->>'expected_total_baisa')::bigint is distinct from v_total then
    return jsonb_build_object('status', 'total_changed', 'server_total_baisa', v_total,
      'tax_enabled', v_set.tax_enabled, 'tax_rate_bp', v_set.tax_rate_bp, 'prices_include_tax', v_set.prices_include_tax);
  end if;

  -- 4) المدفوعات
  if jsonb_typeof(p_payload->'payments') <> 'array' or jsonb_array_length(p_payload->'payments') not between 1 and 10 then
    perform app.fail('PAYMENT_REQUIRED'); end if;
  for v_pay in select * from jsonb_array_elements(p_payload->'payments') loop
    v_amt := (v_pay->>'amount_baisa')::bigint;
    if v_amt is null or v_amt <= 0 then perform app.fail('INVALID_PAYMENT'); end if;
    if v_pay->>'method' = 'cash' then v_cash := v_cash + v_amt;
    elsif v_pay->>'method' = 'card' then v_card := v_card + v_amt;
    else perform app.fail('INVALID_PAYMENT'); end if;
  end loop;
  if v_cash + v_card <> v_total then
    perform app.fail('PAYMENT_MISMATCH', jsonb_build_object('total_baisa', v_total, 'paid_baisa', v_cash + v_card)); end if;
  if v_cash > 0 then
    v_tendered := coalesce((p_payload->>'cash_tendered_baisa')::bigint, v_cash);
    if v_tendered < v_cash then perform app.fail('INVALID_PAYMENT'); end if;
    v_change := v_tendered - v_cash;
  end if;

  -- 5) العميل والمركبة
  v_customer := (p_payload->>'customer_id')::uuid;
  v_vehicle := (p_payload->>'vehicle_id')::uuid;
  if v_customer is not null then
    select * into v_cust from public.customers where id = v_customer and organization_id = v_sess.organization_id;
    if not found then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  end if;
  if v_vehicle is not null and not exists (select 1 from public.vehicles where id = v_vehicle and organization_id = v_sess.organization_id) then
    perform app.fail('VEHICLE_NOT_FOUND'); end if;

  -- 6) حجز معرّف العملية. إن سبقنا طلب مطابق في الوقت نفسه ننتظره ثم نعيد نتيجته.
  insert into public.operation_requests (operation_id, organization_id, branch_id, device_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.device_id, v_sess.id, v_uid, 'sale', v_hash, '{}'::jsonb)
  on conflict (operation_id) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    select * into v_op from public.operation_requests where operation_id = p_operation_id;
    if v_op.op_type = 'cancelled' then perform app.fail('OPERATION_CANCELLED'); end if;
    if v_op.user_id <> v_uid or v_op.op_type <> 'sale' or v_op.request_hash <> v_hash then
      perform app.fail('OPERATION_MISMATCH'); end if;
    return v_op.result || jsonb_build_object('replayed', true);
  end if;

  -- 7) رقم الفاتورة: تسلسل مركزي لكل فرع (قفل صف العدّاد يرتّب اعتمادات الفرع)
  insert into public.branch_counters (branch_id, counter_key, last_value) values (v_sess.branch_id, 'invoice', 1)
  on conflict (branch_id, counter_key) do update set last_value = public.branch_counters.last_value + 1
  returning last_value into v_seq;
  v_invoice_no := v_set.invoice_prefix || '-' || to_char(v_day.business_date, 'YY') || '-' || lpad(v_seq::text, 6, '0');

  insert into public.invoices (id, organization_id, branch_id, invoice_no, seq, business_day_id, cash_session_id, device_id,
    cashier_id, customer_id, vehicle_id, tax_rate_bp, prices_include_tax, subtotal_baisa, discount_baisa, net_baisa,
    tax_baisa, total_baisa, paid_baisa, change_baisa, note, operation_id)
  values (v_invoice_id, v_sess.organization_id, v_sess.branch_id, v_invoice_no, v_seq, v_day.id, v_sess.id, v_sess.device_id,
    v_uid, v_customer, v_vehicle, v_rate, v_set.prices_include_tax, v_subtotal, v_discount, v_net_total,
    v_tax_total, v_total, v_cash + v_card, v_change, nullif(btrim(p_payload->>'note'), ''), p_operation_id);

  -- 8) البنود وخصم المخزون FIFO مع قفل الدفعات والتحقق من الكمية
  for v_line in select * from jsonb_array_elements(v_lines) loop
    insert into public.invoice_lines (organization_id, branch_id, invoice_id, line_no, product_id, kind, sku, description_ar, unit,
      qty, unit_price_baisa, gross_baisa, discount_baisa, taxable, tax_rate_bp, net_baisa, tax_baisa, total_baisa)
    values (v_sess.organization_id, v_sess.branch_id, v_invoice_id, (v_line->>'line_no')::int, (v_line->>'product_id')::uuid,
      v_line->>'kind', v_line->>'sku', v_line->>'description_ar', v_line->>'unit', (v_line->>'qty')::numeric,
      (v_line->>'unit_price_baisa')::bigint, (v_line->>'gross_baisa')::bigint, (v_line->>'discount_baisa')::bigint,
      (v_line->>'taxable')::boolean, (v_line->>'tax_rate_bp')::int, (v_line->>'net_baisa')::bigint,
      (v_line->>'tax_baisa')::bigint, (v_line->>'total_baisa')::bigint)
    returning id into v_line_id;

    v_line_cost := 0;
    if (v_line->>'track_stock')::boolean then
      v_need := (v_line->>'qty')::numeric;
      for v_lot in
        select id, qty_on_hand, unit_cost_baisa from public.inventory_lots
        where branch_id = v_sess.branch_id and product_id = (v_line->>'product_id')::uuid and qty_on_hand > 0
        order by received_at, id for update
      loop
        v_take := least(v_need, v_lot.qty_on_hand);
        update public.inventory_lots set qty_on_hand = qty_on_hand - v_take where id = v_lot.id;
        insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta,
          unit_cost_baisa, source_type, source_id, created_by)
        values (v_sess.organization_id, v_sess.branch_id, (v_line->>'product_id')::uuid, v_lot.id, 'sale', -v_take,
          v_lot.unit_cost_baisa, 'invoice', v_invoice_id, v_uid);
        v_line_cost := v_line_cost + app.round_baisa(v_take * v_lot.unit_cost_baisa);
        v_need := v_need - v_take;
        exit when v_need = 0;
      end loop;
      if v_need > 0 then
        select coalesce(sum(qty_on_hand), 0) + ((v_line->>'qty')::numeric - v_need) into v_avail
        from public.inventory_lots where branch_id = v_sess.branch_id and product_id = (v_line->>'product_id')::uuid;
        perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('line_no', (v_line->>'line_no')::int, 'sku', v_line->>'sku',
          'name_ar', v_line->>'description_ar', 'requested', (v_line->>'qty')::numeric, 'available', v_avail));
      end if;
    end if;
    insert into public.invoice_line_costs (invoice_line_id, organization_id, branch_id, cost_baisa)
    values (v_line_id, v_sess.organization_id, v_sess.branch_id, v_line_cost);
    v_cost_total := v_cost_total + v_line_cost;
  end loop;

  -- 9) المدفوعات وحركة الصندوق
  for v_pay in select * from jsonb_array_elements(p_payload->'payments') loop
    insert into public.payments (organization_id, branch_id, invoice_id, cash_session_id, method, amount_baisa, tendered_baisa, card_reference)
    values (v_sess.organization_id, v_sess.branch_id, v_invoice_id, v_sess.id, v_pay->>'method', (v_pay->>'amount_baisa')::bigint,
      case when v_pay->>'method' = 'cash' then v_tendered end,
      case when v_pay->>'method' = 'card' then nullif(btrim(v_pay->>'card_reference'), '') end);
  end loop;
  if v_cash > 0 then
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, created_by)
    values (v_sess.organization_id, v_sess.branch_id, v_sess.id, 'sale', v_cash, 'invoice', v_invoice_id, v_uid);
  end if;

  -- 10) القيد المحاسبي المزدوج
  insert into public.journal_entries (organization_id, branch_id, business_day_id, source_type, source_id, description, created_by)
  values (v_sess.organization_id, v_sess.branch_id, v_day.id, 'invoice', v_invoice_id, 'فاتورة بيع ' || v_invoice_no, v_uid)
  returning id into v_entry;

  insert into public.journal_lines (entry_id, organization_id, branch_id, account_id, debit_baisa, credit_baisa)
  select v_entry, v_sess.organization_id, v_sess.branch_id, a.id, x.debit, x.credit
  from (values ('cash_on_hand', v_cash, 0::bigint), ('card_clearing', v_card, 0),
               ('sales_goods', 0, v_net_goods), ('sales_services', 0, v_net_services), ('vat_output', 0, v_tax_total),
               ('cogs', v_cost_total, 0), ('inventory', 0, v_cost_total)) as x(system_key, debit, credit)
  join public.accounts a on a.organization_id = v_sess.organization_id and a.system_key = x.system_key
  where x.debit > 0 or x.credit > 0;
  -- غياب حساب نظامي يُخلّ بالتوازن فيُرفض القيد عند نهاية المعاملة (JOURNAL_UNBALANCED)

  -- 11) حدث الإشعار المؤهل (الإرسال في المرحلة 4)
  if v_customer is not null and v_cust.phone is not null then
    insert into public.notification_events (organization_id, branch_id, event_type, customer_id, invoice_id, lang, payload)
    values (v_sess.organization_id, v_sess.branch_id, 'invoice_issued', v_customer, v_invoice_id, v_cust.preferred_lang,
      jsonb_build_object('invoice_no', v_invoice_no, 'total_baisa', v_total));
  end if;

  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'invoice.approve', 'invoice', v_invoice_id, null, null,
    jsonb_build_object('invoice_no', v_invoice_no, 'total_baisa', v_total, 'cash_baisa', v_cash, 'card_baisa', v_card));

  v_result := jsonb_build_object('status', 'approved', 'invoice', app.invoice_json(v_invoice_id));
  update public.operation_requests set result = v_result where operation_id = p_operation_id;
  return v_result || jsonb_build_object('replayed', false);
end $$;

-- التخلي عن عملية لم تُعرف نتيجتها: يحجز المعرّف كملغى حتى لا يُعتمد طلب متأخر ما زال في الطريق.
-- إن كانت العملية قد اعتُمدت فعلًا تُعاد نتيجتها ولا يُلغى شيء.
create or replace function public.cancel_operation(p_operation_id uuid, p_cash_session_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_sess public.cash_sessions; v_op public.operation_requests;
begin
  if v_uid is null then perform app.fail('NOT_AUTHENTICATED'); end if;
  select * into v_sess from public.cash_sessions where id = p_cash_session_id;
  if not found or v_sess.opened_by <> v_uid or not app.has_perm(v_sess.branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  insert into public.operation_requests (operation_id, organization_id, branch_id, device_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.device_id, v_sess.id, v_uid, 'cancelled', '', jsonb_build_object('status', 'cancelled'))
  on conflict (operation_id) do nothing;
  select * into v_op from public.operation_requests where operation_id = p_operation_id;
  if v_op.user_id <> v_uid then perform app.fail('OPERATION_MISMATCH'); end if;
  return v_op.result;
end $$;

-- ───────────── التحقق من نتيجة عملية (بعد انقطاع الرد أو إعادة التشغيل) ─────────────
create or replace function public.get_operation(p_operation_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object('found', true, 'op_type', o.op_type, 'created_at', o.created_at, 'result', o.result)
     from public.operation_requests o
     where o.operation_id = p_operation_id and (o.user_id = (select auth.uid()) or app.has_perm(o.branch_id, 'invoice.view'))),
    jsonb_build_object('found', false));
$$;

create or replace function public.recent_operations(p_cash_session_id uuid, p_limit int default 20) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('operation_id', o.operation_id, 'op_type', o.op_type, 'created_at', o.created_at,
      'invoice_id', o.result->'invoice'->>'id', 'invoice_no', o.result->'invoice'->>'invoice_no',
      'total_baisa', (o.result->'invoice'->>'total_baisa')::bigint) as x
    from public.operation_requests o
    where o.cash_session_id = p_cash_session_id and app.has_branch(o.branch_id)
      and (o.user_id = (select auth.uid()) or app.has_perm(o.branch_id, 'invoice.view'))
    order by o.created_at desc limit least(greatest(coalesce(p_limit, 20), 1), 100)) s;
$$;

-- ───────────── مؤشرات لوحة الإدارة ─────────────
create or replace function public.dashboard_summary(p_branch_id uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with inv as (
    select i.*, app.has_perm(i.branch_id, 'inventory.cost.view') as can_cost
    from public.invoices i join public.business_days d on d.id = i.business_day_id
    where d.business_date between p_from and p_to and i.status = 'approved'
      and (p_branch_id is null or i.branch_id = p_branch_id)
      and app.has_perm(i.branch_id, 'reports.view')
  )
  select jsonb_build_object(
    'invoice_count', (select count(*) from inv),
    'net_sales_baisa', (select coalesce(sum(net_baisa), 0) from inv),
    'tax_baisa', (select coalesce(sum(tax_baisa), 0) from inv),
    'total_baisa', (select coalesce(sum(total_baisa), 0) from inv),
    'discount_baisa', (select coalesce(sum(discount_baisa), 0) from inv),
    'cash_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = 'cash'),
    'card_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = 'card'),
    'gross_profit_baisa', case when (select bool_and(can_cost) from inv) then
        (select coalesce(sum(net_baisa), 0) from inv)
        - (select coalesce(sum(c.cost_baisa), 0) from public.invoice_line_costs c
           join public.invoice_lines l on l.id = c.invoice_line_id join inv on inv.id = l.invoice_id) end);
$$;

-- ───────────── قائمة الفواتير (لوحة الإدارة وسجل الكاشير) ─────────────
create or replace function public.list_invoices(p_branch_id uuid, p_from date, p_to date, p_search text default null, p_limit int default 100)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(s.j order by s.approved_at desc), '[]'::jsonb) from (
    select i.approved_at, jsonb_build_object(
      'id', i.id, 'invoice_no', i.invoice_no, 'status', i.status, 'approved_at', i.approved_at, 'business_date', d.business_date,
      'branch_id', i.branch_id, 'branch_code', b.code, 'branch_name_ar', b.name_ar,
      'total_baisa', i.total_baisa, 'tax_baisa', i.tax_baisa, 'discount_baisa', i.discount_baisa,
      'cashier_name', pr.full_name, 'customer_name', c.name, 'customer_phone', c.phone, 'plate', v.plate,
      'cash_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p where p.invoice_id = i.id and p.method = 'cash'),
      'card_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p where p.invoice_id = i.id and p.method = 'card')) as j
    from public.invoices i
    join public.business_days d on d.id = i.business_day_id
    join public.branches b on b.id = i.branch_id
    join public.profiles pr on pr.id = i.cashier_id
    left join public.customers c on c.id = i.customer_id
    left join public.vehicles v on v.id = i.vehicle_id
    where app.has_perm(i.branch_id, 'invoice.view')
      and (p_branch_id is null or i.branch_id = p_branch_id)
      and d.business_date between p_from and p_to
      and (coalesce(btrim(p_search), '') = ''
        or i.invoice_no ilike '%' || btrim(p_search) || '%'
        or c.phone like '%' || btrim(p_search) || '%'
        or v.plate ilike '%' || btrim(p_search) || '%')
    order by i.approved_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500)) s;
$$;

-- ───────────── صلاحيات التنفيذ ─────────────
revoke all on all functions in schema public from public, anon;
grant execute on function
  public.my_context(), public.resolve_device(text), public.open_cash_session(uuid, uuid, bigint),
  public.pos_search(uuid, text, int), public.get_invoice(uuid), public.record_invoice_print(uuid, boolean),
  public.approve_sale(uuid, jsonb), public.get_operation(uuid), public.recent_operations(uuid, int),
  public.dashboard_summary(uuid, date, date), public.list_invoices(uuid, date, date, text, int),
  public.cancel_operation(uuid, uuid)
to authenticated, service_role;
-- لمسات | تثبيت search_path للدوال المساعدة (توصية فاحص الأمان في Supabase)
alter function app.fail(text, jsonb) set search_path = '';
alter function app.round_baisa(numeric) set search_path = '';
alter function app.forbid_change() set search_path = '';
-- لمسات | إقفال الوردية: النقد المتوقع والفعلي، فرق الصندوق، إجمالي البطاقة منفصلًا، وتدوير اليوم المحاسبي

alter table public.cash_sessions
  add column card_total_baisa bigint,
  add column difference_baisa bigint,
  add column close_note text;

insert into public.permissions (code, description_ar) values
  ('cash.close.any', 'إقفال وردية موظف آخر في الفرع');
insert into public.role_permissions (role_code, permission_code) values
  ('owner', 'cash.close.any'), ('branch_manager', 'cash.close.any');

-- لا تُدرج فاتورة في وردية مقفلة. القفل المشترك هنا مع قفل الإقفال الحصري يضمن أن الإقفال
-- ينتظر أي بيع جارٍ فيحسبه، وأن أي بيع يصل بعد الإقفال يُرفض.
create or replace function app.invoice_session_open() returns trigger
language plpgsql set search_path = '' as $$
declare v_status text;
begin
  select status into v_status from public.cash_sessions where id = new.cash_session_id for share;
  if v_status is distinct from 'open' then
    raise exception using errcode = 'P0001', message = 'SESSION_CLOSED', detail = '';
  end if;
  return new;
end $$;
create trigger invoices_session_open before insert on public.invoices
  for each row execute function app.invoice_session_open();

create or replace function app.can_close_session(p_branch uuid, p_opened_by uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.has_perm(p_branch, 'cash.close.any')
      or (p_opened_by = (select auth.uid()) and app.has_perm(p_branch, 'cash.close'));
$$;
revoke all on function app.can_close_session(uuid, uuid) from public;
grant execute on function app.can_close_session(uuid, uuid) to authenticated, service_role;

create or replace function app.session_summary_json(p_session public.cash_sessions) returns jsonb
language sql stable security definer set search_path = '' as $$
  with m as (
    select coalesce(sum(amount_baisa) filter (where movement_type = 'sale'), 0) as cash_sales,
           coalesce(sum(amount_baisa) filter (where movement_type not in ('opening', 'sale')), 0) as cash_other,
           coalesce(sum(amount_baisa), 0) as expected
    from public.cash_movements where cash_session_id = p_session.id),
  i as (
    select count(*) as n, coalesce(sum(total_baisa), 0) as total
    from public.invoices where cash_session_id = p_session.id and status = 'approved'),
  c as (
    select coalesce(sum(amount_baisa), 0) as card
    from public.payments where cash_session_id = p_session.id and method = 'card')
  select jsonb_build_object(
    'session_id', p_session.id, 'status', p_session.status, 'branch_id', p_session.branch_id,
    'opened_at', p_session.opened_at, 'closed_at', p_session.closed_at,
    'opened_by_name', (select full_name from public.profiles where id = p_session.opened_by),
    'business_date', (select business_date from public.business_days where id = p_session.business_day_id),
    'opening_cash_baisa', p_session.opening_cash_baisa,
    'cash_sales_baisa', m.cash_sales, 'cash_other_baisa', m.cash_other,
    'expected_cash_baisa', coalesce(p_session.expected_cash_baisa, m.expected),
    'card_baisa', coalesce(p_session.card_total_baisa, c.card),
    'invoice_count', i.n, 'total_sales_baisa', i.total,
    'counted_cash_baisa', p_session.counted_cash_baisa, 'difference_baisa', p_session.difference_baisa,
    'close_note', p_session.close_note)
  from m, i, c;
$$;
revoke all on function app.session_summary_json(public.cash_sessions) from public;
grant execute on function app.session_summary_json(public.cash_sessions) to service_role;

-- مراجعة الإقفال (F10) قبل التأكيد
create or replace function public.cash_session_summary(p_cash_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_sess public.cash_sessions;
begin
  select * into v_sess from public.cash_sessions where id = p_cash_session_id;
  if not found or not (app.can_close_session(v_sess.branch_id, v_sess.opened_by) or app.has_perm(v_sess.branch_id, 'reports.view')) then
    perform app.fail('NOT_FOUND'); end if;
  return app.session_summary_json(v_sess);
end $$;

create or replace function public.close_cash_session(p_operation_id uuid, p_cash_session_id uuid,
  p_counted_cash_baisa bigint, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_sess public.cash_sessions; v_op public.operation_requests;
  v_hash text; v_expected bigint; v_card bigint; v_diff bigint; v_entry uuid; v_result jsonb;
  v_cash_acc uuid; v_diff_acc uuid;
begin
  if v_uid is null then perform app.fail('NOT_AUTHENTICATED'); end if;
  if p_operation_id is null then perform app.fail('INVALID_REQUEST'); end if;
  v_hash := md5(jsonb_build_object('session', p_cash_session_id, 'counted', p_counted_cash_baisa, 'note', coalesce(btrim(p_note), ''))::text);

  select * into v_op from public.operation_requests where operation_id = p_operation_id;
  if found then
    if v_op.user_id <> v_uid or v_op.op_type <> 'close_session' or v_op.request_hash <> v_hash then
      perform app.fail('OPERATION_MISMATCH'); end if;
    return v_op.result || jsonb_build_object('replayed', true);
  end if;

  if p_counted_cash_baisa is null or p_counted_cash_baisa < 0 then perform app.fail('INVALID_AMOUNT'); end if;
  -- القفل الحصري ينتظر أي بيع جارٍ على هذه الوردية
  select * into v_sess from public.cash_sessions where id = p_cash_session_id for update;
  if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
  if not app.can_close_session(v_sess.branch_id, v_sess.opened_by) then perform app.fail('FORBIDDEN'); end if;
  if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;

  select coalesce(sum(amount_baisa), 0) into v_expected from public.cash_movements where cash_session_id = v_sess.id;
  select coalesce(sum(amount_baisa), 0) into v_card from public.payments where cash_session_id = v_sess.id and method = 'card';
  v_diff := p_counted_cash_baisa - v_expected;
  if v_diff <> 0 and coalesce(btrim(p_note), '') = '' then perform app.fail('CLOSE_NOTE_REQUIRED', jsonb_build_object('difference_baisa', v_diff)); end if;

  update public.cash_sessions set status = 'closed', closed_at = now(), closed_by = v_uid,
    expected_cash_baisa = v_expected, counted_cash_baisa = p_counted_cash_baisa, card_total_baisa = v_card,
    difference_baisa = v_diff, close_note = nullif(btrim(p_note), '')
  where id = v_sess.id returning * into v_sess;

  -- فرق الصندوق: عجز = مدين فروقات الصندوق / دائن النقد. زيادة = العكس.
  if v_diff <> 0 then
    select id into v_cash_acc from public.accounts where organization_id = v_sess.organization_id and system_key = 'cash_on_hand';
    select id into v_diff_acc from public.accounts where organization_id = v_sess.organization_id and system_key = 'cash_over_short';
    if v_cash_acc is null or v_diff_acc is null then perform app.fail('ACCOUNT_MAPPING_MISSING'); end if;
    insert into public.journal_entries (organization_id, branch_id, business_day_id, source_type, source_id, description, created_by)
    values (v_sess.organization_id, v_sess.branch_id, v_sess.business_day_id, 'cash_session', v_sess.id,
      case when v_diff < 0 then 'عجز صندوق عند إقفال الوردية' else 'زيادة صندوق عند إقفال الوردية' end, v_uid)
    returning id into v_entry;
    insert into public.journal_lines (entry_id, organization_id, branch_id, account_id, debit_baisa, credit_baisa) values
      (v_entry, v_sess.organization_id, v_sess.branch_id, case when v_diff < 0 then v_diff_acc else v_cash_acc end, abs(v_diff), 0),
      (v_entry, v_sess.organization_id, v_sess.branch_id, case when v_diff < 0 then v_cash_acc else v_diff_acc end, 0, abs(v_diff));
  end if;

  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'cash_session.close', 'cash_session', v_sess.id, v_sess.close_note, null,
    jsonb_build_object('expected_cash_baisa', v_expected, 'counted_cash_baisa', p_counted_cash_baisa,
      'difference_baisa', v_diff, 'card_total_baisa', v_card));

  v_result := jsonb_build_object('status', 'closed', 'summary', app.session_summary_json(v_sess));
  insert into public.operation_requests (operation_id, organization_id, branch_id, device_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.device_id, v_sess.id, v_uid, 'close_session', v_hash, v_result);
  return v_result || jsonb_build_object('replayed', false);
end $$;

-- فتح الوردية مع تدوير اليوم المحاسبي: يوم مفتوح بتاريخ سابق وبلا ورديات مفتوحة يُقفل تلقائيًا ويُفتح يوم جديد.
-- الوردية العابرة لمنتصف الليل تبقى على يومها حتى تُقفل.
create or replace function public.open_cash_session(p_operation_id uuid, p_device_id uuid, p_opening_cash_baisa bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_dev public.devices; v_day public.business_days; v_sess public.cash_sessions;
  v_op public.operation_requests; v_hash text; v_result jsonb; v_tz text; v_today date;
begin
  if v_uid is null then perform app.fail('NOT_AUTHENTICATED'); end if;
  if p_operation_id is null then perform app.fail('INVALID_REQUEST'); end if;
  v_hash := md5(jsonb_build_object('device_id', p_device_id, 'opening', p_opening_cash_baisa)::text);

  select * into v_op from public.operation_requests where operation_id = p_operation_id;
  if found then
    if v_op.user_id <> v_uid or v_op.op_type <> 'open_session' or v_op.request_hash <> v_hash then
      perform app.fail('OPERATION_MISMATCH'); end if;
    return v_op.result || jsonb_build_object('replayed', true);
  end if;

  if p_opening_cash_baisa is null or p_opening_cash_baisa < 0 then perform app.fail('INVALID_AMOUNT'); end if;
  select * into v_dev from public.devices where id = p_device_id and is_active for update;
  if not found then perform app.fail('DEVICE_NOT_FOUND'); end if;
  if not app.has_perm(v_dev.branch_id, 'cash.open') then perform app.fail('FORBIDDEN'); end if;

  select * into v_sess from public.cash_sessions where device_id = v_dev.id and status = 'open';
  if found then
    perform app.fail('SESSION_ALREADY_OPEN', jsonb_build_object('session_id', v_sess.id, 'mine', v_sess.opened_by = v_uid));
  end if;

  select timezone into v_tz from public.organizations where id = v_dev.organization_id;
  v_today := (now() at time zone v_tz)::date;
  -- قفل صف الفرع يرتّب فتح الورديات المتزامن على أجهزة الفرع
  perform 1 from public.branches where id = v_dev.branch_id for update;

  select * into v_day from public.business_days where branch_id = v_dev.branch_id and status = 'open';
  if found and v_day.business_date < v_today
     and not exists (select 1 from public.cash_sessions where business_day_id = v_day.id and status = 'open') then
    update public.business_days set status = 'closed', closed_at = now() where id = v_day.id;
    perform app.audit(v_dev.organization_id, v_dev.branch_id, 'business_day.auto_close', 'business_day', v_day.id, null, null,
      jsonb_build_object('business_date', v_day.business_date));
    v_day := null;
  end if;
  if v_day.id is null then
    insert into public.business_days (organization_id, branch_id, business_date, opened_by)
    values (v_dev.organization_id, v_dev.branch_id, v_today, v_uid)
    on conflict (branch_id, business_date) do nothing
    returning * into v_day;
    if v_day.id is null then perform app.fail('BUSINESS_DAY_CLOSED'); end if;
  end if;

  insert into public.cash_sessions (organization_id, branch_id, device_id, business_day_id, opened_by, opening_cash_baisa)
  values (v_dev.organization_id, v_dev.branch_id, v_dev.id, v_day.id, v_uid, p_opening_cash_baisa)
  returning * into v_sess;

  insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, created_by)
  values (v_sess.organization_id, v_sess.branch_id, v_sess.id, 'opening', p_opening_cash_baisa, v_uid);

  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'cash_session.open', 'cash_session', v_sess.id, null, null,
    jsonb_build_object('opening_cash_baisa', p_opening_cash_baisa, 'device', v_dev.code, 'business_date', v_day.business_date));

  v_result := jsonb_build_object('status', 'opened', 'session', jsonb_build_object(
    'id', v_sess.id, 'branch_id', v_sess.branch_id, 'device_id', v_sess.device_id, 'opened_at', v_sess.opened_at,
    'opening_cash_baisa', v_sess.opening_cash_baisa, 'business_day_id', v_day.id, 'business_date', v_day.business_date));

  insert into public.operation_requests (operation_id, organization_id, branch_id, device_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_operation_id, v_sess.organization_id, v_sess.branch_id, v_dev.id, v_sess.id, v_uid, 'open_session', v_hash, v_result);
  return v_result || jsonb_build_object('replayed', false);
end $$;

-- قائمة الورديات للوحة الإدارة
create or replace function public.list_cash_sessions(p_branch_id uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x.j order by x.opened_at desc), '[]'::jsonb) from (
    select s.opened_at, app.session_summary_json(s) || jsonb_build_object(
      'branch_code', b.code, 'device_name', dv.name,
      'closed_by_name', (select full_name from public.profiles where id = s.closed_by)) as j
    from public.cash_sessions s
    join public.business_days d on d.id = s.business_day_id
    join public.branches b on b.id = s.branch_id
    join public.devices dv on dv.id = s.device_id
    where app.has_perm(s.branch_id, 'reports.view')
      and (p_branch_id is null or s.branch_id = p_branch_id)
      and d.business_date between p_from and p_to
    order by s.opened_at desc limit 300) x;
$$;

revoke all on function public.cash_session_summary(uuid), public.close_cash_session(uuid, uuid, bigint, text),
  public.list_cash_sessions(uuid, date, date) from public, anon;
grant execute on function public.cash_session_summary(uuid), public.close_cash_session(uuid, uuid, bigint, text),
  public.list_cash_sessions(uuid, date, date) to authenticated, service_role;
-- لمسات | العمليات اليومية: الكتالوج، الموردون والمشتريات، تسوية المخزون، العملاء، المسودات، القبض والصرف، المرتجع والإلغاء

-- ───────────── جداول ─────────────
create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null, phone text, notes text, is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, organization_id));

create table public.purchase_receipts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null, supplier_id uuid,
  reference text, note text, total_cost_baisa bigint not null,
  created_by uuid, created_at timestamptz not null default now(), operation_id uuid not null unique,
  foreign key (branch_id, organization_id) references public.branches(id, organization_id),
  foreign key (supplier_id, organization_id) references public.suppliers(id, organization_id));
alter table public.inventory_lots add column purchase_receipt_id uuid references public.purchase_receipts(id);

create table public.invoice_drafts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null, device_id uuid references public.devices(id),
  created_by uuid not null references public.profiles(id),
  title text not null, total_baisa bigint not null default 0, payload jsonb not null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id));
create index invoice_drafts_branch_idx on public.invoice_drafts (branch_id, updated_at desc);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null,
  invoice_id uuid not null references public.invoices(id),
  refund_no text not null, kind text not null check (kind in ('refund','void')),
  business_day_id uuid not null references public.business_days(id),
  cash_session_id uuid references public.cash_sessions(id),
  method text not null check (method in ('cash','card')),
  reason text not null,
  net_baisa bigint not null, tax_baisa bigint not null, amount_baisa bigint not null check (amount_baisa >= 0),
  created_by uuid not null, created_at timestamptz not null default now(), operation_id uuid not null unique,
  unique (organization_id, refund_no),
  check (amount_baisa = net_baisa + tax_baisa), check (method <> 'cash' or cash_session_id is not null),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id));
create index refunds_invoice_idx on public.refunds (invoice_id);
create index refunds_day_idx on public.refunds (business_day_id);

create table public.refund_lines (
  id uuid primary key default gen_random_uuid(),
  refund_id uuid not null references public.refunds(id),
  organization_id uuid not null, branch_id uuid not null,
  invoice_line_id uuid not null references public.invoice_lines(id),
  qty numeric(12,3) not null check (qty > 0),
  net_baisa bigint not null, tax_baisa bigint not null, amount_baisa bigint not null,
  restocked boolean not null default false, cost_baisa bigint not null default 0);
create index refund_lines_line_idx on public.refund_lines (invoice_line_id);

create trigger refunds_immutable before update or delete on public.refunds for each row execute function app.forbid_change();
create trigger refund_lines_immutable before update or delete on public.refund_lines for each row execute function app.forbid_change();

do $$
declare t text;
begin
  foreach t in array array['suppliers','purchase_receipts','invoice_drafts','refunds','refund_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated, public', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;
create policy suppliers_read on public.suppliers for select to authenticated using (app.has_org_perm(organization_id, 'inventory.view'));
create policy purchase_receipts_read on public.purchase_receipts for select to authenticated using (app.has_perm(branch_id, 'inventory.cost.view'));
create policy invoice_drafts_read on public.invoice_drafts for select to authenticated using (app.has_perm(branch_id, 'pos.sell') or app.has_perm(branch_id, 'draft.delete'));
create policy refunds_read on public.refunds for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create policy refund_lines_read on public.refund_lines for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));

-- حسابات نظامية إضافية (مبدئية — يراجعها المحاسب)
create or replace function app.ensure_system_accounts(p_org uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.accounts (organization_id, code, name_ar, name_en, account_type, system_key)
  select p_org, v.code, v.name_ar, v.name_en, v.t, v.k from (values
    ('2110', 'الموردون — ذمم دائنة', 'Accounts payable', 'liability', 'accounts_payable'),
    ('4910', 'إيرادات أخرى', 'Other income', 'revenue', 'misc_income'),
    ('5120', 'تسويات المخزون', 'Inventory adjustments', 'expense', 'inventory_adjustment'),
    ('5210', 'مصروفات نثرية', 'Petty expenses', 'expense', 'misc_expense')) as v(code, name_ar, name_en, t, k)
  where not exists (select 1 from public.accounts a where a.organization_id = p_org and (a.system_key = v.k or a.code = v.code));
$$;
revoke all on function app.ensure_system_accounts(uuid) from public;
select app.ensure_system_accounts(id) from public.organizations;

-- قيد من سطور (system_key, debit, credit)؛ يتجاهل الأصفار ويرفض غياب الحساب.
create or replace function app.post_journal(p_org uuid, p_branch uuid, p_day uuid, p_source_type text, p_source_id uuid, p_desc text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_entry uuid; l jsonb; v_acc uuid;
begin
  if not exists (select 1 from jsonb_array_elements(p_lines) x where (x->>1)::bigint > 0 or (x->>2)::bigint > 0) then return null; end if;
  insert into public.journal_entries (organization_id, branch_id, business_day_id, source_type, source_id, description, created_by)
  values (p_org, p_branch, p_day, p_source_type, p_source_id, p_desc, (select auth.uid())) returning id into v_entry;
  for l in select * from jsonb_array_elements(p_lines) loop
    continue when (l->>1)::bigint = 0 and (l->>2)::bigint = 0;
    select id into v_acc from public.accounts where organization_id = p_org and system_key = l->>0;
    if v_acc is null then perform app.fail('ACCOUNT_MAPPING_MISSING', jsonb_build_object('system_key', l->>0)); end if;
    insert into public.journal_lines (entry_id, organization_id, branch_id, account_id, debit_baisa, credit_baisa)
    values (v_entry, p_org, p_branch, v_acc, (l->>1)::bigint, (l->>2)::bigint);
  end loop;
  return v_entry;
end $$;
revoke all on function app.post_journal(uuid, uuid, uuid, text, uuid, text, jsonb) from public;

-- حجز معرّف عملية: يعيد النتيجة المخزنة إن كان الطلب معادًا، وإلا null.
create or replace function app.op_replay(p_op uuid, p_type text, p_hash text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.operation_requests;
begin
  if p_op is null then perform app.fail('INVALID_REQUEST'); end if;
  select * into v from public.operation_requests where operation_id = p_op;
  if not found then return null; end if;
  if v.user_id <> (select auth.uid()) or v.op_type <> p_type or v.request_hash <> p_hash then perform app.fail('OPERATION_MISMATCH'); end if;
  return v.result || jsonb_build_object('replayed', true);
end $$;
create or replace function app.op_store(p_op uuid, p_org uuid, p_branch uuid, p_session uuid, p_type text, p_hash text, p_result jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.operation_requests (operation_id, organization_id, branch_id, cash_session_id, user_id, op_type, request_hash, result)
  values (p_op, p_org, p_branch, p_session, (select auth.uid()), p_type, p_hash, p_result);
  return p_result || jsonb_build_object('replayed', false);
end $$;
revoke all on function app.op_replay(uuid, text, text), app.op_store(uuid, uuid, uuid, uuid, text, text, jsonb) from public;

-- ───────────── الكتالوج ─────────────
create or replace function public.save_product(p_product jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := (p_product->>'organization_id')::uuid; v_id uuid := (p_product->>'id')::uuid; v_old public.products; v_new public.products;
begin
  if v_org is null or not app.has_org_perm(v_org, 'catalog.manage') then perform app.fail('FORBIDDEN'); end if;
  if coalesce(btrim(p_product->>'sku'), '') = '' or coalesce(btrim(p_product->>'name_ar'), '') = '' or (p_product->>'base_price_baisa')::bigint is null
     or (p_product->>'base_price_baisa')::bigint < 0 then perform app.fail('INVALID_REQUEST'); end if;
  if exists (select 1 from public.products where organization_id = v_org and sku = btrim(p_product->>'sku') and id is distinct from v_id) then
    perform app.fail('SKU_EXISTS'); end if;
  if v_id is not null then
    select * into v_old from public.products where id = v_id and organization_id = v_org for update;
    if not found then perform app.fail('NOT_FOUND'); end if;
  else v_id := gen_random_uuid(); end if;
  insert into public.products (id, organization_id, sku, kind, category, name_ar, name_en, brand, unit, whole_units_only, track_stock, taxable,
    base_price_baisa, tire_width, tire_aspect, tire_rim, is_active)
  values (v_id, v_org, btrim(p_product->>'sku'), coalesce(p_product->>'kind', 'item'), coalesce(p_product->>'category', 'general'),
    btrim(p_product->>'name_ar'), nullif(btrim(p_product->>'name_en'), ''), nullif(btrim(p_product->>'brand'), ''),
    coalesce(nullif(btrim(p_product->>'unit'), ''), 'قطعة'), coalesce((p_product->>'whole_units_only')::boolean, true),
    coalesce((p_product->>'track_stock')::boolean, (coalesce(p_product->>'kind', 'item') = 'item')) and coalesce(p_product->>'kind', 'item') = 'item',
    coalesce((p_product->>'taxable')::boolean, true), (p_product->>'base_price_baisa')::bigint,
    (p_product->>'tire_width')::int, (p_product->>'tire_aspect')::int, (p_product->>'tire_rim')::int, coalesce((p_product->>'is_active')::boolean, true))
  on conflict (id) do update set sku = excluded.sku, kind = excluded.kind, category = excluded.category, name_ar = excluded.name_ar,
    name_en = excluded.name_en, brand = excluded.brand, unit = excluded.unit, whole_units_only = excluded.whole_units_only,
    track_stock = excluded.track_stock, taxable = excluded.taxable, base_price_baisa = excluded.base_price_baisa,
    tire_width = excluded.tire_width, tire_aspect = excluded.tire_aspect, tire_rim = excluded.tire_rim, is_active = excluded.is_active, updated_at = now()
  returning * into v_new;
  if p_product ? 'barcodes' then
    delete from public.product_barcodes where organization_id = v_org and product_id = v_id;
    begin
      insert into public.product_barcodes (organization_id, barcode, product_id)
      select distinct v_org, btrim(b), v_id from jsonb_array_elements_text(p_product->'barcodes') b where btrim(b) <> '';
    exception when unique_violation then perform app.fail('BARCODE_EXISTS'); end;
  end if;
  perform app.audit(v_org, null, case when v_old.id is null then 'product.create' else 'product.update' end, 'product', v_id, null,
    case when v_old.id is null then null else jsonb_build_object('sku', v_old.sku, 'name_ar', v_old.name_ar, 'base_price_baisa', v_old.base_price_baisa, 'is_active', v_old.is_active) end,
    jsonb_build_object('sku', v_new.sku, 'name_ar', v_new.name_ar, 'base_price_baisa', v_new.base_price_baisa, 'is_active', v_new.is_active));
  return to_jsonb(v_new);
end $$;

-- p_price_baisa = null يحذف سعر الفرع فيعود سعر المنشأة
create or replace function public.set_branch_price(p_branch_id uuid, p_product_id uuid, p_price_baisa bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_old bigint;
begin
  select organization_id into v_org from public.branches where id = p_branch_id;
  if v_org is null or not app.has_org_perm(v_org, 'catalog.manage') or not app.has_branch(p_branch_id) then perform app.fail('FORBIDDEN'); end if;
  if not exists (select 1 from public.products where id = p_product_id and organization_id = v_org) then perform app.fail('NOT_FOUND'); end if;
  select price_baisa into v_old from public.branch_prices where branch_id = p_branch_id and product_id = p_product_id;
  if p_price_baisa is null then delete from public.branch_prices where branch_id = p_branch_id and product_id = p_product_id;
  elsif p_price_baisa < 0 then perform app.fail('INVALID_AMOUNT');
  else insert into public.branch_prices (branch_id, product_id, organization_id, price_baisa) values (p_branch_id, p_product_id, v_org, p_price_baisa)
       on conflict (branch_id, product_id) do update set price_baisa = excluded.price_baisa, updated_at = now(); end if;
  perform app.audit(v_org, p_branch_id, 'branch_price.set', 'product', p_product_id, null, jsonb_build_object('price_baisa', v_old), jsonb_build_object('price_baisa', p_price_baisa));
end $$;

-- ───────────── المخزون والمشتريات ─────────────
create or replace function public.stock_report(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(p_branch_id, 'inventory.view') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('product_id', p.id, 'sku', p.sku, 'name_ar', p.name_ar, 'category', p.category, 'unit', p.unit,
        'tire_size', case when p.tire_size_key is not null then p.tire_width || '/' || p.tire_aspect || 'R' || p.tire_rim end,
        'is_active', p.is_active, 'price_baisa', app.effective_price(p_branch_id, p.id), 'qty', coalesce(s.qty, 0),
        'value_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') then coalesce(s.val, 0) end,
        'lots', case when app.has_perm(p_branch_id, 'inventory.cost.view') then coalesce(s.lots, '[]'::jsonb) end) order by p.category, p.name_ar)
    from public.products p
    left join lateral (select sum(l.qty_on_hand) qty, sum(round(l.qty_on_hand * l.unit_cost_baisa)) val,
        jsonb_agg(jsonb_build_object('lot_id', l.id, 'lot_code', l.lot_code, 'dot_code', l.dot_code, 'qty', l.qty_on_hand, 'unit_cost_baisa', l.unit_cost_baisa,
          'received_at', l.received_at) order by l.received_at) filter (where l.qty_on_hand > 0) lots
      from public.inventory_lots l where l.branch_id = p_branch_id and l.product_id = p.id) s on true
    where p.organization_id = (select organization_id from public.branches where id = p_branch_id) and p.track_stock), '[]'::jsonb) end;
$$;

create or replace function public.save_supplier(p_supplier jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := (p_supplier->>'organization_id')::uuid; v_row public.suppliers;
begin
  if v_org is null or not app.has_org_perm(v_org, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  if coalesce(btrim(p_supplier->>'name'), '') = '' then perform app.fail('INVALID_REQUEST'); end if;
  insert into public.suppliers (id, organization_id, name, phone, notes, is_active)
  values (coalesce((p_supplier->>'id')::uuid, gen_random_uuid()), v_org, btrim(p_supplier->>'name'), nullif(btrim(p_supplier->>'phone'), ''),
    nullif(btrim(p_supplier->>'notes'), ''), coalesce((p_supplier->>'is_active')::boolean, true))
  on conflict (id) do update set name = excluded.name, phone = excluded.phone, notes = excluded.notes, is_active = excluded.is_active
    where public.suppliers.organization_id = v_org
  returning * into v_row;
  if v_row.id is null then perform app.fail('NOT_FOUND'); end if;
  return to_jsonb(v_row);
end $$;

-- p_payload: { branch_id, supplier_id?, reference?, note?, lines:[{product_id, qty, unit_cost_baisa, lot_code?, dot_code?}] }
create or replace function public.receive_purchase(p_operation_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_hash text := md5(p_payload::text); v_r jsonb;
  v_branch uuid := (p_payload->>'branch_id')::uuid; v_org uuid; v_id uuid := gen_random_uuid(); v_total bigint := 0;
  l jsonb; v_prod public.products; v_qty numeric(12,3); v_cost bigint; v_lot uuid; v_n int := 0;
begin
  v_r := app.op_replay(p_operation_id, 'purchase_receipt', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = v_branch;
  if v_org is null or not app.has_perm(v_branch, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  if jsonb_typeof(p_payload->'lines') <> 'array' or jsonb_array_length(p_payload->'lines') not between 1 and 200 then perform app.fail('EMPTY_CART'); end if;
  if (p_payload->>'supplier_id') is not null and not exists (select 1 from public.suppliers where id = (p_payload->>'supplier_id')::uuid and organization_id = v_org) then
    perform app.fail('NOT_FOUND'); end if;
  insert into public.purchase_receipts (id, organization_id, branch_id, supplier_id, reference, note, total_cost_baisa, created_by, operation_id)
  values (v_id, v_org, v_branch, (p_payload->>'supplier_id')::uuid, nullif(btrim(p_payload->>'reference'), ''), nullif(btrim(p_payload->>'note'), ''), 0, v_uid, p_operation_id);
  for l in select * from jsonb_array_elements(p_payload->'lines') loop
    v_n := v_n + 1;
    select * into v_prod from public.products where id = (l->>'product_id')::uuid and organization_id = v_org and track_stock;
    if not found then perform app.fail('PRODUCT_NOT_FOUND', jsonb_build_object('line_no', v_n)); end if;
    v_qty := (l->>'qty')::numeric; v_cost := (l->>'unit_cost_baisa')::bigint;
    if v_qty is null or v_qty <= 0 or (v_prod.whole_units_only and v_qty <> trunc(v_qty)) then perform app.fail('INVALID_QUANTITY', jsonb_build_object('line_no', v_n)); end if;
    if v_cost is null or v_cost < 0 then perform app.fail('INVALID_AMOUNT', jsonb_build_object('line_no', v_n)); end if;
    insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand, purchase_receipt_id)
    values (v_org, v_branch, v_prod.id, nullif(btrim(l->>'lot_code'), ''), nullif(btrim(l->>'dot_code'), ''), v_cost, v_qty, v_qty, v_id) returning id into v_lot;
    insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
    values (v_org, v_branch, v_prod.id, v_lot, 'purchase_receipt', v_qty, v_cost, 'purchase_receipt', v_id, v_uid);
    v_total := v_total + app.round_baisa(v_qty * v_cost);
  end loop;
  update public.purchase_receipts set total_cost_baisa = v_total where id = v_id;
  perform app.post_journal(v_org, v_branch, null, 'purchase_receipt', v_id, 'استلام مشتريات ' || coalesce(p_payload->>'reference', ''),
    jsonb_build_array(jsonb_build_array('inventory', v_total, 0), jsonb_build_array('accounts_payable', 0, v_total)));
  perform app.audit(v_org, v_branch, 'purchase.receive', 'purchase_receipt', v_id, null, null, jsonb_build_object('total_cost_baisa', v_total, 'lines', v_n));
  return app.op_store(p_operation_id, v_org, v_branch, null, 'purchase_receipt', v_hash,
    jsonb_build_object('status', 'received', 'receipt_id', v_id, 'total_cost_baisa', v_total, 'lines', v_n));
end $$;

-- تسوية جرد: موجب يضيف دفعة بالتكلفة المعطاة (أو تكلفة آخر دفعة)، سالب يخصم FIFO. السبب إلزامي.
create or replace function public.adjust_stock(p_operation_id uuid, p_branch_id uuid, p_product_id uuid, p_qty_delta numeric,
  p_unit_cost_baisa bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_org uuid; v_prod public.products; v_r jsonb; v_lot record; v_cost bigint; v_value bigint := 0;
  v_need numeric(12,3); v_take numeric(12,3); v_new uuid; v_ref uuid := gen_random_uuid();
  v_hash text := md5(jsonb_build_object('b', p_branch_id, 'p', p_product_id, 'q', p_qty_delta, 'c', p_unit_cost_baisa, 'r', p_reason)::text);
begin
  v_r := app.op_replay(p_operation_id, 'stock_adjust', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = p_branch_id;
  if v_org is null or not app.has_perm(p_branch_id, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  select * into v_prod from public.products where id = p_product_id and organization_id = v_org and track_stock;
  if not found then perform app.fail('PRODUCT_NOT_FOUND'); end if;
  if p_qty_delta is null or p_qty_delta = 0 or (v_prod.whole_units_only and p_qty_delta <> trunc(p_qty_delta)) then perform app.fail('INVALID_QUANTITY'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('REASON_REQUIRED'); end if;
  if p_qty_delta > 0 then
    v_cost := coalesce(p_unit_cost_baisa, (select unit_cost_baisa from public.inventory_lots where branch_id = p_branch_id and product_id = p_product_id order by received_at desc, id desc limit 1));
    if v_cost is null or v_cost < 0 then perform app.fail('INVALID_AMOUNT'); end if;
    insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, unit_cost_baisa, qty_received, qty_on_hand)
    values (v_org, p_branch_id, p_product_id, 'ADJ', v_cost, p_qty_delta, p_qty_delta) returning id into v_new;
    insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
    values (v_org, p_branch_id, p_product_id, v_new, 'adjustment', p_qty_delta, v_cost, 'adjustment', v_ref, v_uid);
    v_value := app.round_baisa(p_qty_delta * v_cost);
    perform app.post_journal(v_org, p_branch_id, null, 'stock_adjustment', v_ref, 'تسوية مخزون (زيادة): ' || v_prod.name_ar,
      jsonb_build_array(jsonb_build_array('inventory', v_value, 0), jsonb_build_array('inventory_adjustment', 0, v_value)));
  else
    v_need := -p_qty_delta;
    for v_lot in select id, qty_on_hand, unit_cost_baisa from public.inventory_lots
                 where branch_id = p_branch_id and product_id = p_product_id and qty_on_hand > 0 order by received_at, id for update loop
      v_take := least(v_need, v_lot.qty_on_hand);
      update public.inventory_lots set qty_on_hand = qty_on_hand - v_take where id = v_lot.id;
      insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
      values (v_org, p_branch_id, p_product_id, v_lot.id, 'adjustment', -v_take, v_lot.unit_cost_baisa, 'adjustment', v_ref, v_uid);
      v_value := v_value + app.round_baisa(v_take * v_lot.unit_cost_baisa); v_need := v_need - v_take; exit when v_need = 0;
    end loop;
    if v_need > 0 then perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('name_ar', v_prod.name_ar, 'requested', -p_qty_delta, 'available', -p_qty_delta - v_need)); end if;
    perform app.post_journal(v_org, p_branch_id, null, 'stock_adjustment', v_ref, 'تسوية مخزون (نقص): ' || v_prod.name_ar,
      jsonb_build_array(jsonb_build_array('inventory_adjustment', v_value, 0), jsonb_build_array('inventory', 0, v_value)));
  end if;
  perform app.audit(v_org, p_branch_id, 'stock.adjust', 'product', p_product_id, btrim(p_reason), null, jsonb_build_object('qty_delta', p_qty_delta, 'value_baisa', v_value));
  return app.op_store(p_operation_id, v_org, p_branch_id, null, 'stock_adjust', v_hash, jsonb_build_object('status', 'adjusted', 'qty_delta', p_qty_delta, 'value_baisa', v_value));
end $$;

-- ───────────── العملاء ─────────────
-- p: { branch_id, name, phone?, preferred_lang?, plate?, make?, model? } — هاتف موجود يعيد العميل نفسه ويضيف المركبة.
create or replace function public.save_customer(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_branch uuid := (p->>'branch_id')::uuid; v_org uuid; v_cust public.customers; v_veh public.vehicles;
  v_phone text := nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9]', '', 'g'), ''); v_plate text := nullif(btrim(p->>'plate'), '');
begin
  select organization_id into v_org from public.branches where id = v_branch;
  if v_org is null or not app.has_perm(v_branch, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if coalesce(btrim(p->>'name'), '') = '' then perform app.fail('INVALID_REQUEST'); end if;
  if v_phone is not null then select * into v_cust from public.customers where organization_id = v_org and phone = v_phone; end if;
  if v_cust.id is null then
    insert into public.customers (organization_id, name, phone, preferred_lang)
    values (v_org, btrim(p->>'name'), v_phone, coalesce(nullif(p->>'preferred_lang', ''), 'ar')) returning * into v_cust;
    perform app.audit(v_org, v_branch, 'customer.create', 'customer', v_cust.id, null, null, jsonb_build_object('name', v_cust.name));
  end if;
  if v_plate is not null then
    select * into v_veh from public.vehicles where organization_id = v_org and customer_id = v_cust.id and plate = v_plate;
    if not found then
      insert into public.vehicles (organization_id, customer_id, plate, make, model)
      values (v_org, v_cust.id, v_plate, nullif(btrim(p->>'make'), ''), nullif(btrim(p->>'model'), '')) returning * into v_veh;
    end if;
  end if;
  return jsonb_build_object('customer', jsonb_build_object('id', v_cust.id, 'name', v_cust.name, 'phone', v_cust.phone),
    'vehicle', case when v_veh.id is null then null else jsonb_build_object('id', v_veh.id, 'plate', v_veh.plate) end);
end $$;

-- ───────────── المسودات ─────────────
create or replace function public.save_draft(p_id uuid, p_cash_session_id uuid, p_title text, p_total_baisa bigint, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_sess public.cash_sessions; v_row public.invoice_drafts;
begin
  select * into v_sess from public.cash_sessions where id = p_cash_session_id and status = 'open';
  if not found or not app.has_perm(v_sess.branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if jsonb_typeof(p_payload) <> 'object' or coalesce(btrim(p_title), '') = '' then perform app.fail('INVALID_REQUEST'); end if;
  if p_id is null then
    insert into public.invoice_drafts (organization_id, branch_id, device_id, created_by, title, total_baisa, payload)
    values (v_sess.organization_id, v_sess.branch_id, v_sess.device_id, (select auth.uid()), btrim(p_title), coalesce(p_total_baisa, 0), p_payload) returning * into v_row;
  else
    update public.invoice_drafts set title = btrim(p_title), total_baisa = coalesce(p_total_baisa, 0), payload = p_payload, updated_at = now()
    where id = p_id and branch_id = v_sess.branch_id returning * into v_row;
    if v_row.id is null then perform app.fail('NOT_FOUND'); end if;
  end if;
  return jsonb_build_object('id', v_row.id, 'title', v_row.title);
end $$;

create or replace function public.list_drafts(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'total_baisa', d.total_baisa, 'updated_at', d.updated_at,
      'created_by_name', pr.full_name, 'payload', d.payload) order by d.updated_at desc), '[]'::jsonb)
  from public.invoice_drafts d join public.profiles pr on pr.id = d.created_by
  where d.branch_id = p_branch_id and (app.has_perm(d.branch_id, 'pos.sell') or app.has_perm(d.branch_id, 'draft.delete'));
$$;

-- حذف مسودة: صاحبها، أو من يملك draft.delete (مع سبب). فتح المسودة للبيع يحذفها بالدالة نفسها.
create or replace function public.delete_draft(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_row public.invoice_drafts;
begin
  select * into v_row from public.invoice_drafts where id = p_id for update;
  if not found then perform app.fail('NOT_FOUND'); end if;
  if not ((v_row.created_by = (select auth.uid()) and app.has_perm(v_row.branch_id, 'pos.sell')) or app.has_perm(v_row.branch_id, 'draft.delete')
          or (p_reason = 'opened' and app.has_perm(v_row.branch_id, 'pos.sell'))) then perform app.fail('FORBIDDEN'); end if;
  delete from public.invoice_drafts where id = p_id;
  perform app.audit(v_row.organization_id, v_row.branch_id, 'draft.delete', 'invoice_draft', v_row.id, p_reason,
    jsonb_build_object('title', v_row.title, 'total_baisa', v_row.total_baisa), null);
end $$;

-- ───────────── القبض والصرف النقدي ─────────────
create or replace function public.record_cash_movement(p_operation_id uuid, p_cash_session_id uuid, p_type text, p_amount_baisa bigint, p_note text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_sess public.cash_sessions; v_r jsonb; v_id uuid; v_drawer bigint;
  v_hash text := md5(jsonb_build_object('s', p_cash_session_id, 't', p_type, 'a', p_amount_baisa, 'n', p_note)::text);
begin
  v_r := app.op_replay(p_operation_id, 'cash_movement', v_hash); if v_r is not null then return v_r; end if;
  select * into v_sess from public.cash_sessions where id = p_cash_session_id for update;
  if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
  if not app.has_perm(v_sess.branch_id, 'cash.movement') then perform app.fail('FORBIDDEN'); end if;
  if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
  if v_sess.opened_by <> (select auth.uid()) and not app.has_perm(v_sess.branch_id, 'cash.close.any') then perform app.fail('SESSION_NOT_YOURS'); end if;
  if p_type not in ('cash_in', 'cash_out') or p_amount_baisa is null or p_amount_baisa <= 0 then perform app.fail('INVALID_AMOUNT'); end if;
  if coalesce(btrim(p_note), '') = '' then perform app.fail('REASON_REQUIRED'); end if;
  select coalesce(sum(amount_baisa), 0) into v_drawer from public.cash_movements where cash_session_id = v_sess.id;
  if p_type = 'cash_out' and p_amount_baisa > v_drawer then perform app.fail('INSUFFICIENT_CASH', jsonb_build_object('drawer_baisa', v_drawer)); end if;
  insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, note, created_by)
  values (v_sess.organization_id, v_sess.branch_id, v_sess.id, p_type, case when p_type = 'cash_in' then p_amount_baisa else -p_amount_baisa end, btrim(p_note), (select auth.uid()))
  returning id into v_id;
  perform app.post_journal(v_sess.organization_id, v_sess.branch_id, v_sess.business_day_id, 'cash_movement', v_id, btrim(p_note),
    case when p_type = 'cash_in' then jsonb_build_array(jsonb_build_array('cash_on_hand', p_amount_baisa, 0), jsonb_build_array('misc_income', 0, p_amount_baisa))
         else jsonb_build_array(jsonb_build_array('misc_expense', p_amount_baisa, 0), jsonb_build_array('cash_on_hand', 0, p_amount_baisa)) end);
  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'cash.' || p_type, 'cash_session', v_sess.id, btrim(p_note), null, jsonb_build_object('amount_baisa', p_amount_baisa));
  return app.op_store(p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.id, 'cash_movement', v_hash,
    jsonb_build_object('status', 'recorded', 'type', p_type, 'amount_baisa', p_amount_baisa, 'drawer_baisa', v_drawer + case when p_type = 'cash_in' then p_amount_baisa else -p_amount_baisa end));
end $$;

-- ───────────── المرتجع والإلغاء ─────────────
-- الكميات والمبالغ المتبقية القابلة للإرجاع لكل سطر، وسجل المرتجعات السابقة.
create or replace function public.invoice_refund_state(p_invoice_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(i.branch_id, 'invoice.view') then null else jsonb_build_object(
    'invoice_id', i.id, 'status', i.status,
    'lines', (select jsonb_agg(jsonb_build_object('line_no', l.line_no, 'description_ar', l.description_ar, 'kind', l.kind, 'unit', l.unit, 'qty', l.qty,
        'total_baisa', l.total_baisa, 'refunded_qty', coalesce(r.q, 0), 'refunded_baisa', coalesce(r.a, 0),
        'remaining_qty', l.qty - coalesce(r.q, 0), 'remaining_baisa', l.total_baisa - coalesce(r.a, 0),
        'track_stock', (select track_stock from public.products where id = l.product_id)) order by l.line_no)
      from public.invoice_lines l left join lateral (select sum(qty) q, sum(amount_baisa) a from public.refund_lines where invoice_line_id = l.id) r on true
      where l.invoice_id = i.id),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'refund_no', f.refund_no, 'kind', f.kind, 'method', f.method, 'reason', f.reason,
        'amount_baisa', f.amount_baisa, 'created_at', f.created_at, 'created_by_name', (select full_name from public.profiles where id = f.created_by)) order by f.created_at)
      from public.refunds f where f.invoice_id = i.id), '[]'::jsonb),
    'open_sessions', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'device_name', d.name, 'opened_by_name', (select full_name from public.profiles where id = s.opened_by)))
      from public.cash_sessions s join public.devices d on d.id = s.device_id where s.branch_id = i.branch_id and s.status = 'open'), '[]'::jsonb)) end
  from public.invoices i where i.id = p_invoice_id;
$$;

-- p_payload: { invoice_id, kind:'refund'|'void', reason, method:'cash'|'card', cash_session_id? (مطلوب للنقدي),
--              lines:[{line_no, qty, restock}] (للمرتجع؛ الإلغاء يشمل كل البنود ويعيد البضاعة للمخزون) }
-- يُرحَّل إلى اليوم المحاسبي المفتوح حاليًا للفرع مع ربطه بالفاتورة الأصلية.
create or replace function public.refund_invoice(p_operation_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_hash text := md5(p_payload::text); v_r jsonb;
  v_inv public.invoices; v_kind text := p_payload->>'kind'; v_method text := p_payload->>'method'; v_reason text := btrim(coalesce(p_payload->>'reason', ''));
  v_sess public.cash_sessions; v_day public.business_days; v_id uuid := gen_random_uuid(); v_seq bigint; v_no text; v_prefix text;
  v_req jsonb; l record; v_qty numeric(12,3); v_restock boolean; v_amt bigint; v_tax bigint; v_net bigint; v_cost bigint; v_line_cost bigint; v_prev_cost bigint;
  v_tot_net bigint := 0; v_tot_tax bigint := 0; v_tot_amt bigint := 0; v_net_goods bigint := 0; v_net_serv bigint := 0; v_cost_back bigint := 0;
  v_lot uuid; v_src record; v_n int := 0; v_cust public.customers; v_lines jsonb := '[]'::jsonb;
begin
  v_r := app.op_replay(p_operation_id, 'refund', v_hash); if v_r is not null then return v_r; end if;
  if v_kind not in ('refund', 'void') or v_method not in ('cash', 'card') then perform app.fail('INVALID_REQUEST'); end if;
  select * into v_inv from public.invoices where id = (p_payload->>'invoice_id')::uuid for update;
  if not found or not app.has_perm(v_inv.branch_id, 'invoice.view') then perform app.fail('NOT_FOUND'); end if;
  if not app.has_perm(v_inv.branch_id, case when v_kind = 'void' then 'invoice.void' else 'invoice.refund' end) then perform app.fail('FORBIDDEN'); end if;
  if v_inv.status <> 'approved' then perform app.fail('INVOICE_NOT_REFUNDABLE'); end if;
  if v_reason = '' then perform app.fail('REASON_REQUIRED'); end if;
  if v_kind = 'void' and exists (select 1 from public.refunds where invoice_id = v_inv.id) then perform app.fail('INVOICE_HAS_REFUNDS'); end if;

  select * into v_day from public.business_days where branch_id = v_inv.branch_id and status = 'open';
  if not found then perform app.fail('BUSINESS_DAY_CLOSED'); end if;
  if v_method = 'cash' then
    select * into v_sess from public.cash_sessions where id = (p_payload->>'cash_session_id')::uuid for update;
    if not found or v_sess.branch_id <> v_inv.branch_id or v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
  end if;

  select invoice_prefix into v_prefix from public.branch_settings where branch_id = v_inv.branch_id;
  insert into public.branch_counters (branch_id, counter_key, last_value) values (v_inv.branch_id, 'refund', 1)
  on conflict (branch_id, counter_key) do update set last_value = public.branch_counters.last_value + 1 returning last_value into v_seq;
  v_no := 'R-' || v_prefix || '-' || to_char(v_day.business_date, 'YY') || '-' || lpad(v_seq::text, 6, '0');

  for l in
    select il.*, p.track_stock, p.whole_units_only, coalesce(c.cost_baisa, 0) as line_cost,
           coalesce(r.q, 0) as ref_qty, coalesce(r.a, 0) as ref_amt, coalesce(r.t, 0) as ref_tax, coalesce(r.c, 0) as ref_cost
    from public.invoice_lines il join public.products p on p.id = il.product_id
    left join public.invoice_line_costs c on c.invoice_line_id = il.id
    left join lateral (select sum(qty) q, sum(amount_baisa) a, sum(tax_baisa) t, sum(cost_baisa) filter (where restocked) c
                       from public.refund_lines where invoice_line_id = il.id) r on true
    where il.invoice_id = v_inv.id order by il.line_no
  loop
    if v_kind = 'void' then v_qty := l.qty; v_restock := l.track_stock;
    else
      select x into v_req from jsonb_array_elements(coalesce(p_payload->'lines', '[]'::jsonb)) x where (x->>'line_no')::int = l.line_no limit 1;
      continue when v_req is null;
      v_qty := (v_req->>'qty')::numeric; v_restock := l.track_stock and coalesce((v_req->>'restock')::boolean, false);
      v_req := null;
    end if;
    if v_qty is null or v_qty <= 0 or (l.whole_units_only and v_qty <> trunc(v_qty)) or v_qty > l.qty - l.ref_qty then
      perform app.fail('REFUND_EXCEEDS_REMAINING', jsonb_build_object('line_no', l.line_no, 'remaining_qty', l.qty - l.ref_qty)); end if;
    -- آخر كمية متبقية تأخذ الباقي بالضبط حتى لا يتراكم فرق تقريب
    if v_qty = l.qty - l.ref_qty then
      v_amt := l.total_baisa - l.ref_amt; v_tax := l.tax_baisa - l.ref_tax;
    else
      v_amt := app.round_baisa(l.total_baisa * v_qty / l.qty); v_tax := app.round_baisa(l.tax_baisa * v_qty / l.qty);
    end if;
    v_net := v_amt - v_tax; v_line_cost := 0;
    if v_restock then
      v_line_cost := app.round_baisa(l.line_cost * v_qty / l.qty);
      select m.lot_id, lt.dot_code, lt.lot_code into v_src from public.stock_movements m join public.inventory_lots lt on lt.id = m.lot_id
      where m.source_type = 'invoice' and m.source_id = v_inv.id and m.product_id = l.product_id and m.movement_type = 'sale' order by m.id limit 1;
      insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand)
      values (v_inv.organization_id, v_inv.branch_id, l.product_id, coalesce(v_src.lot_code, 'RET'), v_src.dot_code,
        app.round_baisa(v_line_cost / v_qty), v_qty, v_qty) returning id into v_lot;
      insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
      values (v_inv.organization_id, v_inv.branch_id, l.product_id, v_lot, case when v_kind = 'void' then 'void_reversal' else 'sale_return' end,
        v_qty, app.round_baisa(v_line_cost / v_qty), 'refund', v_id, v_uid);
      v_cost_back := v_cost_back + v_line_cost;
    end if;
    v_lines := v_lines || jsonb_build_object('id', l.id, 'qty', v_qty, 'net', v_net, 'tax', v_tax, 'amt', v_amt, 'restock', v_restock, 'cost', v_line_cost);
    v_tot_net := v_tot_net + v_net; v_tot_tax := v_tot_tax + v_tax; v_tot_amt := v_tot_amt + v_amt; v_n := v_n + 1;
    if l.kind = 'service' then v_net_serv := v_net_serv + v_net; else v_net_goods := v_net_goods + v_net; end if;
  end loop;
  if v_n = 0 then perform app.fail('EMPTY_CART'); end if;

  insert into public.refunds (id, organization_id, branch_id, invoice_id, refund_no, kind, business_day_id, cash_session_id, method, reason,
    net_baisa, tax_baisa, amount_baisa, created_by, operation_id)
  values (v_id, v_inv.organization_id, v_inv.branch_id, v_inv.id, v_no, v_kind, v_day.id, v_sess.id, v_method, v_reason,
    v_tot_net, v_tot_tax, v_tot_amt, v_uid, p_operation_id);
  insert into public.refund_lines (refund_id, organization_id, branch_id, invoice_line_id, qty, net_baisa, tax_baisa, amount_baisa, restocked, cost_baisa)
  select v_id, v_inv.organization_id, v_inv.branch_id, (x->>'id')::uuid, (x->>'qty')::numeric, (x->>'net')::bigint, (x->>'tax')::bigint,
         (x->>'amt')::bigint, (x->>'restock')::boolean, (x->>'cost')::bigint
  from jsonb_array_elements(v_lines) x;

  if v_method = 'cash' and v_tot_amt > 0 then
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, note, created_by)
    values (v_inv.organization_id, v_inv.branch_id, v_sess.id, 'refund', -v_tot_amt, 'refund', v_id, v_no, v_uid);
  end if;
  perform app.post_journal(v_inv.organization_id, v_inv.branch_id, v_day.id, 'refund', v_id,
    case when v_kind = 'void' then 'إلغاء الفاتورة ' else 'مرتجع من الفاتورة ' end || v_inv.invoice_no,
    jsonb_build_array(jsonb_build_array('sales_goods', v_net_goods, 0), jsonb_build_array('sales_services', v_net_serv, 0),
      jsonb_build_array('vat_output', v_tot_tax, 0),
      jsonb_build_array(case when v_method = 'cash' then 'cash_on_hand' else 'card_clearing' end, 0, v_tot_amt),
      jsonb_build_array('inventory', v_cost_back, 0), jsonb_build_array('cogs', 0, v_cost_back)));

  if v_kind = 'void' then
    update public.invoices set status = 'voided', version = version + 1 where id = v_inv.id;
    if v_inv.customer_id is not null then
      select * into v_cust from public.customers where id = v_inv.customer_id;
      if v_cust.phone is not null then
        insert into public.notification_events (organization_id, branch_id, event_type, customer_id, invoice_id, lang, payload)
        values (v_inv.organization_id, v_inv.branch_id, 'invoice_voided', v_cust.id, v_inv.id, v_cust.preferred_lang, jsonb_build_object('invoice_no', v_inv.invoice_no));
      end if;
    end if;
  end if;
  perform app.audit(v_inv.organization_id, v_inv.branch_id, case when v_kind = 'void' then 'invoice.void' else 'invoice.refund' end, 'invoice', v_inv.id, v_reason,
    jsonb_build_object('status', v_inv.status), jsonb_build_object('refund_no', v_no, 'amount_baisa', v_tot_amt, 'method', v_method,
      'status', case when v_kind = 'void' then 'voided' else 'approved' end));
  return app.op_store(p_operation_id, v_inv.organization_id, v_inv.branch_id, v_sess.id, 'refund', v_hash,
    jsonb_build_object('status', case when v_kind = 'void' then 'voided' else 'refunded' end, 'refund_id', v_id, 'refund_no', v_no,
      'net_baisa', v_tot_net, 'tax_baisa', v_tot_tax, 'amount_baisa', v_tot_amt, 'restocked_cost_baisa', v_cost_back));
end $$;

-- المؤشرات: الفواتير الملغاة مستبعدة، والمرتجعات تُطرح في يومها المحاسبي.
create or replace function public.dashboard_summary(p_branch_id uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with inv as (
    select i.*, app.has_perm(i.branch_id, 'inventory.cost.view') as can_cost
    from public.invoices i join public.business_days d on d.id = i.business_day_id
    where d.business_date between p_from and p_to and i.status = 'approved'
      and (p_branch_id is null or i.branch_id = p_branch_id) and app.has_perm(i.branch_id, 'reports.view')),
  ref as (
    select f.* from public.refunds f join public.business_days d on d.id = f.business_day_id
    where d.business_date between p_from and p_to and f.kind = 'refund'
      and (p_branch_id is null or f.branch_id = p_branch_id) and app.has_perm(f.branch_id, 'reports.view')),
  t as (select (select coalesce(sum(net_baisa), 0) from inv) net, (select coalesce(sum(net_baisa), 0) from ref) rnet,
               (select coalesce(sum(rl.cost_baisa), 0) from public.refund_lines rl join ref on ref.id = rl.refund_id where rl.restocked) rcost)
  select jsonb_build_object(
    'invoice_count', (select count(*) from inv),
    'net_sales_baisa', t.net - t.rnet,
    'refunds_baisa', (select coalesce(sum(amount_baisa), 0) from ref),
    'tax_baisa', (select coalesce(sum(tax_baisa), 0) from inv) - (select coalesce(sum(tax_baisa), 0) from ref),
    'total_baisa', (select coalesce(sum(total_baisa), 0) from inv),
    'discount_baisa', (select coalesce(sum(discount_baisa), 0) from inv),
    'cash_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = 'cash'),
    'card_baisa', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = 'card'),
    'gross_profit_baisa', case when (select bool_and(can_cost) from inv) then
        t.net - t.rnet - ((select coalesce(sum(c.cost_baisa), 0) from public.invoice_line_costs c
           join public.invoice_lines l on l.id = c.invoice_line_id join inv on inv.id = l.invoice_id) - t.rcost) end)
  from t;
$$;

revoke all on function public.save_product(jsonb), public.set_branch_price(uuid, uuid, bigint), public.stock_report(uuid), public.save_supplier(jsonb),
  public.receive_purchase(uuid, jsonb), public.adjust_stock(uuid, uuid, uuid, numeric, bigint, text), public.save_customer(jsonb),
  public.save_draft(uuid, uuid, text, bigint, jsonb), public.list_drafts(uuid), public.delete_draft(uuid, text),
  public.record_cash_movement(uuid, uuid, text, bigint, text), public.invoice_refund_state(uuid), public.refund_invoice(uuid, jsonb) from public, anon;
grant execute on function public.save_product(jsonb), public.set_branch_price(uuid, uuid, bigint), public.stock_report(uuid), public.save_supplier(jsonb),
  public.receive_purchase(uuid, jsonb), public.adjust_stock(uuid, uuid, uuid, numeric, bigint, text), public.save_customer(jsonb),
  public.save_draft(uuid, uuid, text, bigint, jsonb), public.list_drafts(uuid), public.delete_draft(uuid, text),
  public.record_cash_movement(uuid, uuid, text, bigint, text), public.invoice_refund_state(uuid), public.refund_invoice(uuid, jsonb) to authenticated, service_role;
-- لمسات | إعدادات الفرع من لوحة الإدارة، والأدوار المسموح لها بفتح وردية (الكاشير افتراضيًا فقط)

alter table public.branch_settings add column shift_roles text[] not null default '{cashier}';

-- فتح الوردية لحساب دوره غير مفعّل في إعدادات الفرع يُرفض، حتى لو استُدعيت الدالة مباشرة.
create or replace function app.session_role_allowed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.memberships m join public.branch_settings s on s.branch_id = new.branch_id
    where m.user_id = new.opened_by and m.is_active and m.organization_id = new.organization_id
      and (m.branch_id is null or m.branch_id = new.branch_id) and m.role_code = any (s.shift_roles)) then
    raise exception using errcode = 'P0001', message = 'SHIFT_NOT_ENABLED_FOR_ROLE', detail = '';
  end if;
  return new;
end $$;
create trigger cash_sessions_role_allowed before insert on public.cash_sessions
  for each row execute function app.session_role_allowed();

-- p_settings: { shift_roles?, tax_enabled?, tax_rate_bp?, prices_include_tax?, receipt_header_ar?, receipt_footer_ar? }
create or replace function public.update_branch_settings(p_branch_id uuid, p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_old public.branch_settings; v_new public.branch_settings; v_roles text[];
begin
  if not app.has_perm(p_branch_id, 'settings.manage') then perform app.fail('FORBIDDEN'); end if;
  select * into v_old from public.branch_settings where branch_id = p_branch_id for update;
  if not found then perform app.fail('NOT_FOUND'); end if;
  if p_settings ? 'shift_roles' then
    select array_agg(distinct r) into v_roles from jsonb_array_elements_text(p_settings->'shift_roles') r where r in (select code from public.roles);
    v_roles := coalesce(v_roles, '{}') || case when 'cashier' = any (coalesce(v_roles, '{}')) then '{}'::text[] else '{cashier}'::text[] end;
  end if;
  if (p_settings->>'tax_rate_bp')::int not between 0 and 10000 then perform app.fail('INVALID_AMOUNT'); end if;
  update public.branch_settings set
    shift_roles = coalesce(v_roles, shift_roles),
    tax_enabled = coalesce((p_settings->>'tax_enabled')::boolean, tax_enabled),
    tax_rate_bp = coalesce((p_settings->>'tax_rate_bp')::int, tax_rate_bp),
    prices_include_tax = coalesce((p_settings->>'prices_include_tax')::boolean, prices_include_tax),
    receipt_header_ar = case when p_settings ? 'receipt_header_ar' then nullif(btrim(p_settings->>'receipt_header_ar'), '') else receipt_header_ar end,
    receipt_footer_ar = case when p_settings ? 'receipt_footer_ar' then nullif(btrim(p_settings->>'receipt_footer_ar'), '') else receipt_footer_ar end,
    updated_at = now()
  where branch_id = p_branch_id returning * into v_new;
  perform app.audit(v_new.organization_id, p_branch_id, 'branch_settings.update', 'branch', p_branch_id, null,
    to_jsonb(v_old) - 'updated_at', to_jsonb(v_new) - 'updated_at');
  return to_jsonb(v_new);
end $$;
revoke all on function public.update_branch_settings(uuid, jsonb) from public, anon;
grant execute on function public.update_branch_settings(uuid, jsonb) to authenticated, service_role;
-- لمسات | وردية لكل موظف: أكثر من وردية مفتوحة على الجهاز نفسه، واحدة لكل حساب.
drop index public.cash_sessions_one_open_per_device;
create unique index cash_sessions_one_open_per_user_device on public.cash_sessions (device_id, opened_by) where status = 'open';

-- تعديل موضعي لشرط «وردية مفتوحة على الجهاز» ليصبح «وردية مفتوحة لهذا المستخدم على الجهاز» في الدالتين،
-- بدل إعادة تعريفهما كاملتين. يفشل الترحيل إن لم يوجد النص المستهدف.
do $$
declare d text; f regprocedure; target constant text := 'where device_id = v_dev.id and status = ''open'';';
begin
  foreach f in array array['public.open_cash_session(uuid,uuid,bigint)'::regprocedure, 'public.resolve_device(text)'::regprocedure] loop
    d := pg_get_functiondef(f);
    if position(target in d) = 0 then raise exception 'patch target missing in %', f; end if;
    execute replace(d, target, 'where device_id = v_dev.id and status = ''open'' and opened_by = (select auth.uid());');
  end loop;
end $$;
-- طرق الدفع حسب شاشة الدفع: نقدي، بطاقة، تحويل بنكي، آجل (على حساب العميل)، وتحصيل الآجل لاحقًا.
-- paid_baisa في الفاتورة يبقى مساويًا للإجمالي؛ الجزء الآجل يُعرف من سطر الدفع method='credit' ومن حساب «العملاء — ذمم مدينة».

alter table public.payments drop constraint payments_method_check;
alter table public.payments add constraint payments_method_check check (method in ('cash', 'card', 'transfer', 'credit'));
alter table public.refunds drop constraint refunds_method_check;
alter table public.refunds add constraint refunds_method_check check (method in ('cash', 'card', 'transfer', 'credit'));
alter table public.cash_sessions add column transfer_total_baisa bigint, add column credit_total_baisa bigint;

create or replace function app.ensure_system_accounts(p_org uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.accounts (organization_id, code, name_ar, name_en, account_type, system_key)
  select p_org, v.code, v.name_ar, v.name_en, v.t, v.k from (values
    ('1130', 'تحويلات بنكية تحت التسوية', 'Bank transfers clearing', 'asset', 'bank_transfer_clearing'),
    ('1210', 'العملاء — ذمم مدينة', 'Accounts receivable', 'asset', 'accounts_receivable'),
    ('2110', 'الموردون — ذمم دائنة', 'Accounts payable', 'liability', 'accounts_payable'),
    ('4910', 'إيرادات أخرى', 'Other income', 'revenue', 'misc_income'),
    ('5120', 'تسويات المخزون', 'Inventory adjustments', 'expense', 'inventory_adjustment'),
    ('5210', 'مصروفات نثرية', 'Petty expenses', 'expense', 'misc_expense')) as v(code, name_ar, name_en, t, k)
  where not exists (select 1 from public.accounts a where a.organization_id = p_org and (a.system_key = v.k or a.code = v.code));
$$;
select app.ensure_system_accounts(id) from public.organizations;

-- تعديل الدوال القائمة في موضعها؛ يفشل الترحيل إن لم يوجد النص المستهدف.
do $$
declare d text; r record;
begin
  for r in select * from (values
    ('public.approve_sale(uuid,jsonb)', 'v_cash bigint := 0; v_card bigint := 0;', 'v_cash bigint := 0; v_card bigint := 0; v_transfer bigint := 0; v_credit bigint := 0;'),
    ('public.approve_sale(uuid,jsonb)', 'elsif v_pay->>''method'' = ''card'' then v_card := v_card + v_amt;',
       'elsif v_pay->>''method'' = ''card'' then v_card := v_card + v_amt;
    elsif v_pay->>''method'' = ''transfer'' then v_transfer := v_transfer + v_amt;
    elsif v_pay->>''method'' = ''credit'' then v_credit := v_credit + v_amt;'),
    ('public.approve_sale(uuid,jsonb)', 'if v_cash + v_card <> v_total then', 'if v_cash + v_card + v_transfer + v_credit <> v_total then'),
    ('public.approve_sale(uuid,jsonb)', '''paid_baisa'', v_cash + v_card)); end if;', '''paid_baisa'', v_cash + v_card + v_transfer + v_credit)); end if;'),
    ('public.approve_sale(uuid,jsonb)', 'v_vehicle := (p_payload->>''vehicle_id'')::uuid;',
       'v_vehicle := (p_payload->>''vehicle_id'')::uuid;
  if v_credit > 0 and v_customer is null then perform app.fail(''CREDIT_REQUIRES_CUSTOMER''); end if;'),
    ('public.approve_sale(uuid,jsonb)', 'v_tax_total, v_total, v_cash + v_card, v_change,', 'v_tax_total, v_total, v_cash + v_card + v_transfer + v_credit, v_change,'),
    ('public.approve_sale(uuid,jsonb)', 'case when v_pay->>''method'' = ''card'' then nullif', 'case when v_pay->>''method'' in (''card'', ''transfer'') then nullif'),
    ('public.approve_sale(uuid,jsonb)', '(''card_clearing'', v_card, 0),', '(''card_clearing'', v_card, 0), (''bank_transfer_clearing'', v_transfer, 0), (''accounts_receivable'', v_credit, 0),'),
    ('public.approve_sale(uuid,jsonb)', '''card_baisa'', v_card));', '''card_baisa'', v_card, ''transfer_baisa'', v_transfer, ''credit_baisa'', v_credit));'),
    ('public.refund_invoice(uuid,jsonb)', 'v_method not in (''cash'', ''card'')', 'v_method not in (''cash'', ''card'', ''transfer'', ''credit'')'),
    ('public.refund_invoice(uuid,jsonb)', 'case when v_method = ''cash'' then ''cash_on_hand'' else ''card_clearing'' end',
       'case v_method when ''cash'' then ''cash_on_hand'' when ''card'' then ''card_clearing'' when ''transfer'' then ''bank_transfer_clearing'' else ''accounts_receivable'' end'),
    ('public.close_cash_session(uuid,uuid,bigint,text)', 'card_total_baisa = v_card,',
       'card_total_baisa = v_card,
    transfer_total_baisa = (select coalesce(sum(amount_baisa), 0) from public.payments where cash_session_id = v_sess.id and method = ''transfer''),
    credit_total_baisa = (select coalesce(sum(amount_baisa), 0) from public.payments where cash_session_id = v_sess.id and method = ''credit''),'),
    ('public.dashboard_summary(uuid,date,date)', '''gross_profit_baisa'', case',
       '''transfer_baisa'', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = ''transfer''),
    ''credit_baisa'', (select coalesce(sum(p.amount_baisa), 0) from public.payments p join inv on inv.id = p.invoice_id where p.method = ''credit''),
    ''gross_profit_baisa'', case')
  ) as t(fn, target, repl) loop
    d := pg_get_functiondef(r.fn::regprocedure);
    if position(r.target in d) = 0 then raise exception 'patch target missing in %: %', r.fn, r.target; end if;
    execute replace(d, r.target, r.repl);
  end loop;
end $$;

-- إن كان المرتجع «على حساب العميل» فلا بد أن تكون للفاتورة عميل
create or replace function app.refund_credit_needs_customer() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.method = 'credit' and (select customer_id from public.invoices where id = new.invoice_id) is null then
    perform app.fail('CREDIT_REQUIRES_CUSTOMER'); end if;
  return new;
end $$;
create trigger refunds_credit_needs_customer before insert on public.refunds for each row execute function app.refund_credit_needs_customer();

create or replace function app.session_summary_json(p_session public.cash_sessions) returns jsonb
language sql stable security definer set search_path = '' as $$
  with m as (
    select coalesce(sum(amount_baisa) filter (where movement_type = 'sale'), 0) as cash_sales,
           coalesce(sum(amount_baisa) filter (where movement_type not in ('opening', 'sale')), 0) as cash_other,
           coalesce(sum(amount_baisa), 0) as expected
    from public.cash_movements where cash_session_id = p_session.id),
  i as (
    select count(*) as n, coalesce(sum(total_baisa), 0) as total
    from public.invoices where cash_session_id = p_session.id and status = 'approved'),
  c as (
    select coalesce(sum(amount_baisa) filter (where method = 'card'), 0) as card,
           coalesce(sum(amount_baisa) filter (where method = 'transfer'), 0) as transfer,
           coalesce(sum(amount_baisa) filter (where method = 'credit'), 0) as credit
    from public.payments where cash_session_id = p_session.id)
  select jsonb_build_object(
    'session_id', p_session.id, 'status', p_session.status, 'branch_id', p_session.branch_id,
    'opened_at', p_session.opened_at, 'closed_at', p_session.closed_at,
    'opened_by_name', (select full_name from public.profiles where id = p_session.opened_by),
    'business_date', (select business_date from public.business_days where id = p_session.business_day_id),
    'opening_cash_baisa', p_session.opening_cash_baisa,
    'cash_sales_baisa', m.cash_sales, 'cash_other_baisa', m.cash_other,
    'expected_cash_baisa', coalesce(p_session.expected_cash_baisa, m.expected),
    'card_baisa', coalesce(p_session.card_total_baisa, c.card),
    'transfer_baisa', coalesce(p_session.transfer_total_baisa, c.transfer),
    'credit_baisa', coalesce(p_session.credit_total_baisa, c.credit),
    'invoice_count', i.n, 'total_sales_baisa', i.total,
    'counted_cash_baisa', p_session.counted_cash_baisa, 'difference_baisa', p_session.difference_baisa,
    'close_note', p_session.close_note)
  from m, i, c;
$$;

-- ───────────── حساب العميل الآجل وتحصيله ─────────────
create table public.customer_receipts (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  branch_id       uuid not null,
  customer_id     uuid not null,
  cash_session_id uuid not null references public.cash_sessions(id),
  method          text not null check (method in ('cash', 'card', 'transfer')),
  amount_baisa    bigint not null check (amount_baisa > 0),
  reference       text,
  created_by      uuid not null,
  created_at      timestamptz not null default now(),
  foreign key (customer_id, organization_id) references public.customers(id, organization_id)
);
create index customer_receipts_customer_idx on public.customer_receipts (customer_id);
alter table public.customer_receipts enable row level security;
create policy customer_receipts_read on public.customer_receipts for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));
create trigger customer_receipts_immutable before update or delete on public.customer_receipts for each row execute function app.forbid_change();

create or replace function app.customer_balance(p_customer uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select (select coalesce(sum(p.amount_baisa), 0) from public.payments p join public.invoices i on i.id = p.invoice_id where i.customer_id = p_customer and p.method = 'credit')
       - (select coalesce(sum(f.amount_baisa), 0) from public.refunds f join public.invoices i on i.id = f.invoice_id where i.customer_id = p_customer and f.method = 'credit')
       - (select coalesce(sum(amount_baisa), 0) from public.customer_receipts where customer_id = p_customer);
$$;
revoke all on function app.customer_balance(uuid) from public;

-- رصيد العميل الآجل على مستوى المنشأة وآخر التحصيلات
create or replace function public.customer_account(p_customer_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_c public.customers;
begin
  select * into v_c from public.customers where id = p_customer_id;
  if not found or not app.has_org(v_c.organization_id) then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  return jsonb_build_object('customer_id', v_c.id, 'name', v_c.name, 'phone', v_c.phone,
    'balance_baisa', app.customer_balance(v_c.id),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object('created_at', r.created_at, 'method', r.method, 'amount_baisa', r.amount_baisa, 'reference', r.reference) order by r.created_at desc)
      from (select * from public.customer_receipts where customer_id = v_c.id order by created_at desc limit 20) r), '[]'::jsonb));
end $$;

-- تحصيل من رصيد العميل الآجل داخل وردية مفتوحة. النقدي يدخل درج الوردية.
create or replace function public.collect_customer_payment(p_operation_id uuid, p_cash_session_id uuid, p_customer_id uuid, p_method text, p_amount_baisa bigint, p_reference text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_sess public.cash_sessions; v_c public.customers; v_r jsonb; v_id uuid; v_bal bigint;
  v_hash text := md5(jsonb_build_object('s', p_cash_session_id, 'c', p_customer_id, 'm', p_method, 'a', p_amount_baisa, 'r', p_reference)::text);
begin
  v_r := app.op_replay(p_operation_id, 'customer_receipt', v_hash); if v_r is not null then return v_r; end if;
  select * into v_sess from public.cash_sessions where id = p_cash_session_id for update;
  if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
  if not app.has_perm(v_sess.branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
  if v_sess.opened_by <> (select auth.uid()) then perform app.fail('SESSION_NOT_YOURS'); end if;
  select * into v_c from public.customers where id = p_customer_id and organization_id = v_sess.organization_id for update;
  if not found then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  if p_method not in ('cash', 'card', 'transfer') or p_amount_baisa is null or p_amount_baisa <= 0 then perform app.fail('INVALID_AMOUNT'); end if;
  v_bal := app.customer_balance(v_c.id);
  if p_amount_baisa > v_bal then perform app.fail('AMOUNT_EXCEEDS_BALANCE', jsonb_build_object('balance_baisa', v_bal)); end if;
  insert into public.customer_receipts (organization_id, branch_id, customer_id, cash_session_id, method, amount_baisa, reference, created_by)
  values (v_sess.organization_id, v_sess.branch_id, v_c.id, v_sess.id, p_method, p_amount_baisa, nullif(btrim(p_reference), ''), (select auth.uid()))
  returning id into v_id;
  if p_method = 'cash' then
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, note, created_by)
    values (v_sess.organization_id, v_sess.branch_id, v_sess.id, 'cash_in', p_amount_baisa, 'customer_receipt', v_id, 'تحصيل آجل — ' || v_c.name, (select auth.uid()));
  end if;
  perform app.post_journal(v_sess.organization_id, v_sess.branch_id, v_sess.business_day_id, 'customer_receipt', v_id, 'تحصيل من العميل ' || v_c.name,
    jsonb_build_array(
      jsonb_build_array(case p_method when 'cash' then 'cash_on_hand' when 'card' then 'card_clearing' else 'bank_transfer_clearing' end, p_amount_baisa, 0),
      jsonb_build_array('accounts_receivable', 0, p_amount_baisa)));
  perform app.audit(v_sess.organization_id, v_sess.branch_id, 'customer.receipt', 'customer', v_c.id, null, null, jsonb_build_object('amount_baisa', p_amount_baisa, 'method', p_method));
  return app.op_store(p_operation_id, v_sess.organization_id, v_sess.branch_id, v_sess.id, 'customer_receipt', v_hash,
    jsonb_build_object('status', 'recorded', 'receipt_id', v_id, 'balance_baisa', v_bal - p_amount_baisa));
end $$;

revoke all on function public.customer_account(uuid), public.collect_customer_payment(uuid, uuid, uuid, text, bigint, text) from public, anon;
grant execute on function public.customer_account(uuid), public.collect_customer_payment(uuid, uuid, uuid, text, bigint, text) to authenticated;
-- بطاقة الصنف (مورّد افتراضي، حد التنبيه، أدنى سعر للكاشير، سنة وبلد الإطار)، استلام المشتريات بطريقة دفع وضريبة مدخلات،
-- وحساب المورّد وسداده.

alter table public.products
  add column default_supplier_id uuid,
  add column reorder_level numeric(12,3) check (reorder_level >= 0),
  add column min_price_baisa bigint check (min_price_baisa >= 0),
  add column tire_year int check (tire_year between 1990 and 2100),
  add column tire_country text,
  add foreign key (default_supplier_id, organization_id) references public.suppliers(id, organization_id);
alter table public.products drop constraint products_category_check;
alter table public.products add constraint products_category_check check (category in ('tire', 'tint', 'accessory', 'service', 'raw', 'general'));

alter table public.purchase_receipts
  add column supplier_invoice_date date,
  add column payment_method text not null default 'credit' check (payment_method in ('cash', 'credit', 'transfer')),
  add column due_date date,
  add column tax_baisa bigint not null default 0 check (tax_baisa >= 0),
  add column cash_session_id uuid references public.cash_sessions(id);

create or replace function app.ensure_system_accounts(p_org uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.accounts (organization_id, code, name_ar, name_en, account_type, system_key)
  select p_org, v.code, v.name_ar, v.name_en, v.t, v.k from (values
    ('1130', 'تحويلات بنكية تحت التسوية', 'Bank transfers clearing', 'asset', 'bank_transfer_clearing'),
    ('1140', 'البنك', 'Bank', 'asset', 'bank'),
    ('1210', 'العملاء — ذمم مدينة', 'Accounts receivable', 'asset', 'accounts_receivable'),
    ('1410', 'ضريبة القيمة المضافة — مدخلات', 'VAT input', 'asset', 'vat_input'),
    ('2110', 'الموردون — ذمم دائنة', 'Accounts payable', 'liability', 'accounts_payable'),
    ('4910', 'إيرادات أخرى', 'Other income', 'revenue', 'misc_income'),
    ('5120', 'تسويات المخزون', 'Inventory adjustments', 'expense', 'inventory_adjustment'),
    ('5210', 'مصروفات نثرية', 'Petty expenses', 'expense', 'misc_expense')) as v(code, name_ar, name_en, t, k)
  where not exists (select 1 from public.accounts a where a.organization_id = p_org and (a.system_key = v.k or a.code = v.code));
$$;
select app.ensure_system_accounts(id) from public.organizations;

-- تعديل الدوال القائمة في موضعها؛ يفشل الترحيل إن لم يوجد النص المستهدف.
do $$
declare d text; r record;
begin
  for r in select * from (values
    -- حقول بطاقة الصنف الإضافية: تُحدَّث فقط إن أُرسلت، فلا تُمسح من واجهة لا تعرفها
    ('public.save_product(jsonb)', 'return to_jsonb(v_new);',
       'if p_product ?| array[''default_supplier_id'', ''reorder_level'', ''min_price_baisa'', ''tire_year'', ''tire_country''] then
    if (p_product->>''default_supplier_id'') is not null and not exists (select 1 from public.suppliers where id = (p_product->>''default_supplier_id'')::uuid and organization_id = v_org) then
      perform app.fail(''NOT_FOUND''); end if;
    update public.products set
      default_supplier_id = case when p_product ? ''default_supplier_id'' then (p_product->>''default_supplier_id'')::uuid else default_supplier_id end,
      reorder_level = case when p_product ? ''reorder_level'' then (p_product->>''reorder_level'')::numeric else reorder_level end,
      min_price_baisa = case when p_product ? ''min_price_baisa'' then (p_product->>''min_price_baisa'')::bigint else min_price_baisa end,
      tire_year = case when p_product ? ''tire_year'' then (p_product->>''tire_year'')::int else tire_year end,
      tire_country = case when p_product ? ''tire_country'' then nullif(btrim(p_product->>''tire_country''), '''') else tire_country end
    where id = v_id returning * into v_new;
  end if;
  return to_jsonb(v_new);'),
    -- أدنى سعر للكاشير: الخصم لا ينزل بسعر الوحدة تحته إلا لمن يرى التكلفة (مدير الفرع والمالك)
    ('public.approve_sale(uuid,jsonb)', 'perform app.fail(''DISCOUNT_LIMIT_EXCEEDED'', jsonb_build_object(''line_no'', v_idx, ''max_discount_bp'', v_max_disc)); end if;',
       'perform app.fail(''DISCOUNT_LIMIT_EXCEEDED'', jsonb_build_object(''line_no'', v_idx, ''max_discount_bp'', v_max_disc)); end if;
    if v_disc > 0 and v_prod.min_price_baisa is not null and v_gross - v_disc < app.round_baisa(v_qty * v_prod.min_price_baisa)
       and not app.has_perm(v_sess.branch_id, ''inventory.cost.view'') then
      perform app.fail(''BELOW_MIN_PRICE'', jsonb_build_object(''line_no'', v_idx, ''name_ar'', v_prod.name_ar, ''min_price_baisa'', v_prod.min_price_baisa)); end if;')
  ) as t(fn, target, repl) loop
    d := pg_get_functiondef(r.fn::regprocedure);
    if position(r.target in d) = 0 then raise exception 'patch target missing in %: %', r.fn, r.target; end if;
    execute replace(d, r.target, r.repl);
  end loop;
end $$;

create or replace function public.stock_report(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(p_branch_id, 'inventory.view') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('product_id', p.id, 'sku', p.sku, 'name_ar', p.name_ar, 'category', p.category, 'unit', p.unit,
        'brand', p.brand, 'tire_year', p.tire_year, 'reorder_level', p.reorder_level, 'whole_units_only', p.whole_units_only,
        'tire_size', case when p.tire_size_key is not null then p.tire_width || '/' || p.tire_aspect || 'R' || p.tire_rim end,
        'is_active', p.is_active, 'price_baisa', app.effective_price(p_branch_id, p.id), 'qty', coalesce(s.qty, 0),
        'value_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') then coalesce(s.val, 0) end,
        'avg_cost_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') and coalesce(s.qty, 0) > 0 then round(s.val / s.qty) end,
        'lots', case when app.has_perm(p_branch_id, 'inventory.cost.view') then coalesce(s.lots, '[]'::jsonb) end) order by p.category, p.name_ar)
    from public.products p
    left join lateral (select sum(l.qty_on_hand) qty, sum(round(l.qty_on_hand * l.unit_cost_baisa)) val,
        jsonb_agg(jsonb_build_object('lot_id', l.id, 'lot_code', l.lot_code, 'dot_code', l.dot_code, 'qty', l.qty_on_hand, 'unit_cost_baisa', l.unit_cost_baisa,
          'received_at', l.received_at) order by l.received_at) filter (where l.qty_on_hand > 0) lots
      from public.inventory_lots l where l.branch_id = p_branch_id and l.product_id = p.id) s on true
    where p.organization_id = (select organization_id from public.branches where id = p_branch_id) and p.track_stock), '[]'::jsonb) end;
$$;

-- بطاقة الصنف: البيانات، الباركود، الرصيد في كل فرع متاح للمستخدم، وآخر الحركات في الفرع الحالي
create or replace function public.product_card(p_branch_id uuid, p_product_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_p public.products; v_cost boolean := app.has_perm(p_branch_id, 'inventory.cost.view');
begin
  if not app.has_perm(p_branch_id, 'inventory.view') then perform app.fail('FORBIDDEN'); end if;
  select p.* into v_p from public.products p join public.branches b on b.organization_id = p.organization_id where p.id = p_product_id and b.id = p_branch_id;
  if not found then perform app.fail('PRODUCT_NOT_FOUND'); end if;
  return jsonb_build_object(
    'product', to_jsonb(v_p),
    'price_baisa', app.effective_price(p_branch_id, v_p.id),
    'barcodes', coalesce((select jsonb_agg(barcode order by barcode) from public.product_barcodes where product_id = v_p.id), '[]'::jsonb),
    'supplier_name', (select name from public.suppliers where id = v_p.default_supplier_id),
    'can_edit', app.has_org_perm(v_p.organization_id, 'catalog.manage'),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('branch_id', b.id, 'name_ar', b.name_ar,
          'qty', coalesce((select sum(qty_on_hand) from public.inventory_lots where branch_id = b.id and product_id = v_p.id), 0),
          'avg_cost_baisa', case when v_cost then (select round(sum(qty_on_hand * unit_cost_baisa) / nullif(sum(qty_on_hand), 0)) from public.inventory_lots where branch_id = b.id and product_id = v_p.id) end)
        order by b.code)
      from public.branches b where b.organization_id = v_p.organization_id and b.is_active and app.has_perm(b.id, 'inventory.view')), '[]'::jsonb),
    'movements', coalesce((select jsonb_agg(jsonb_build_object('at', m.created_at, 'type', m.movement_type, 'qty_delta', m.qty_delta,
          'unit_cost_baisa', case when v_cost then m.unit_cost_baisa end) order by m.id desc)
      from (select * from public.stock_movements where branch_id = p_branch_id and product_id = v_p.id order by id desc limit 15) m), '[]'::jsonb));
end $$;

-- ───────────── استلام المشتريات ─────────────
-- p_payload: { branch_id, supplier_id?, reference? (رقم فاتورة المورّد), supplier_invoice_date?, note?,
--   payment_method: 'credit'(افتراضي)|'cash'|'transfer', due_date? (للآجل), tax_rate_bp? (ضريبة المدخلات، التكاليف غير شاملة لها),
--   cash_session_id? (مطلوب للنقدي: يخرج المبلغ من درج وردية المستخدم), lines:[{product_id, qty, unit_cost_baisa, lot_code?, dot_code?}] }
create or replace function public.receive_purchase(p_operation_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid()); v_hash text := md5(p_payload::text); v_r jsonb;
  v_branch uuid := (p_payload->>'branch_id')::uuid; v_org uuid; v_id uuid := gen_random_uuid(); v_total bigint := 0;
  l jsonb; v_prod public.products; v_qty numeric(12,3); v_cost bigint; v_lot uuid; v_n int := 0;
  v_method text := coalesce(nullif(p_payload->>'payment_method', ''), 'credit'); v_rate int := coalesce((p_payload->>'tax_rate_bp')::int, 0);
  v_tax bigint; v_sess public.cash_sessions; v_drawer bigint; v_supplier uuid := (p_payload->>'supplier_id')::uuid;
begin
  v_r := app.op_replay(p_operation_id, 'purchase_receipt', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = v_branch;
  if v_org is null or not app.has_perm(v_branch, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  if jsonb_typeof(p_payload->'lines') <> 'array' or jsonb_array_length(p_payload->'lines') not between 1 and 200 then perform app.fail('EMPTY_CART'); end if;
  if v_supplier is not null and not exists (select 1 from public.suppliers where id = v_supplier and organization_id = v_org) then perform app.fail('NOT_FOUND'); end if;
  if v_method not in ('cash', 'credit', 'transfer') or v_rate not between 0 and 10000 then perform app.fail('INVALID_REQUEST'); end if;
  if v_method = 'credit' and v_supplier is null then perform app.fail('SUPPLIER_REQUIRED'); end if;
  if v_method = 'cash' then
    select * into v_sess from public.cash_sessions where id = (p_payload->>'cash_session_id')::uuid and branch_id = v_branch for update;
    if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
    if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
    if v_sess.opened_by <> v_uid then perform app.fail('SESSION_NOT_YOURS'); end if;
  end if;
  insert into public.purchase_receipts (id, organization_id, branch_id, supplier_id, reference, note, total_cost_baisa, created_by, operation_id,
    supplier_invoice_date, payment_method, due_date, cash_session_id)
  values (v_id, v_org, v_branch, v_supplier, nullif(btrim(p_payload->>'reference'), ''), nullif(btrim(p_payload->>'note'), ''), 0, v_uid, p_operation_id,
    (p_payload->>'supplier_invoice_date')::date, v_method, case when v_method = 'credit' then (p_payload->>'due_date')::date end, v_sess.id);
  for l in select * from jsonb_array_elements(p_payload->'lines') loop
    v_n := v_n + 1;
    select * into v_prod from public.products where id = (l->>'product_id')::uuid and organization_id = v_org and track_stock;
    if not found then perform app.fail('PRODUCT_NOT_FOUND', jsonb_build_object('line_no', v_n)); end if;
    v_qty := (l->>'qty')::numeric; v_cost := (l->>'unit_cost_baisa')::bigint;
    if v_qty is null or v_qty <= 0 or (v_prod.whole_units_only and v_qty <> trunc(v_qty)) then perform app.fail('INVALID_QUANTITY', jsonb_build_object('line_no', v_n)); end if;
    if v_cost is null or v_cost < 0 then perform app.fail('INVALID_AMOUNT', jsonb_build_object('line_no', v_n)); end if;
    insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand, purchase_receipt_id)
    values (v_org, v_branch, v_prod.id, nullif(btrim(l->>'lot_code'), ''), nullif(btrim(l->>'dot_code'), ''), v_cost, v_qty, v_qty, v_id) returning id into v_lot;
    insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
    values (v_org, v_branch, v_prod.id, v_lot, 'purchase_receipt', v_qty, v_cost, 'purchase_receipt', v_id, v_uid);
    v_total := v_total + app.round_baisa(v_qty * v_cost);
  end loop;
  v_tax := app.round_baisa(v_total * v_rate / 10000.0);
  update public.purchase_receipts set total_cost_baisa = v_total, tax_baisa = v_tax where id = v_id;
  if v_method = 'cash' then
    select coalesce(sum(amount_baisa), 0) into v_drawer from public.cash_movements where cash_session_id = v_sess.id;
    if v_total + v_tax > v_drawer then perform app.fail('INSUFFICIENT_CASH', jsonb_build_object('drawer_baisa', v_drawer)); end if;
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, note, created_by)
    values (v_org, v_branch, v_sess.id, 'cash_out', -(v_total + v_tax), 'purchase_receipt', v_id, 'مشتريات نقدية ' || coalesce(p_payload->>'reference', ''), v_uid);
  end if;
  perform app.post_journal(v_org, v_branch, v_sess.business_day_id, 'purchase_receipt', v_id, 'استلام مشتريات ' || coalesce(p_payload->>'reference', ''),
    jsonb_build_array(jsonb_build_array('inventory', v_total, 0), jsonb_build_array('vat_input', v_tax, 0),
      jsonb_build_array(case v_method when 'cash' then 'cash_on_hand' when 'transfer' then 'bank' else 'accounts_payable' end, 0, v_total + v_tax)));
  perform app.audit(v_org, v_branch, 'purchase.receive', 'purchase_receipt', v_id, null, null,
    jsonb_build_object('total_cost_baisa', v_total, 'tax_baisa', v_tax, 'payment_method', v_method, 'lines', v_n));
  return app.op_store(p_operation_id, v_org, v_branch, v_sess.id, 'purchase_receipt', v_hash,
    jsonb_build_object('status', 'received', 'receipt_id', v_id, 'total_cost_baisa', v_total, 'tax_baisa', v_tax, 'payable_baisa', v_total + v_tax, 'lines', v_n));
end $$;

create or replace function public.list_purchases(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(p_branch_id, 'inventory.cost.view') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'created_at', r.created_at, 'reference', r.reference, 'supplier_invoice_date', r.supplier_invoice_date,
        'supplier_name', (select name from public.suppliers where id = r.supplier_id), 'payment_method', r.payment_method, 'due_date', r.due_date,
        'total_cost_baisa', r.total_cost_baisa, 'tax_baisa', r.tax_baisa) order by r.created_at desc)
    from (select * from public.purchase_receipts where branch_id = p_branch_id order by created_at desc limit 200) r), '[]'::jsonb) end;
$$;

-- ───────────── حساب المورّد وسداده ─────────────
create table public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null, supplier_id uuid not null,
  method text not null check (method in ('cash', 'transfer')),
  amount_baisa bigint not null check (amount_baisa > 0),
  reference text, cash_session_id uuid references public.cash_sessions(id),
  created_by uuid not null, created_at timestamptz not null default now(),
  foreign key (supplier_id, organization_id) references public.suppliers(id, organization_id),
  foreign key (branch_id, organization_id) references public.branches(id, organization_id));
create index supplier_payments_supplier_idx on public.supplier_payments (supplier_id);
alter table public.supplier_payments enable row level security;
create policy supplier_payments_read on public.supplier_payments for select to authenticated using (app.has_perm(branch_id, 'inventory.cost.view'));
create trigger supplier_payments_immutable before update or delete on public.supplier_payments for each row execute function app.forbid_change();

-- المستحق للمورّد = المشتريات الآجلة (شاملة ضريبتها) − ما سُدِّد
create or replace function app.supplier_balance(p_supplier uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select (select coalesce(sum(total_cost_baisa + tax_baisa), 0) from public.purchase_receipts where supplier_id = p_supplier and payment_method = 'credit')
       - (select coalesce(sum(amount_baisa), 0) from public.supplier_payments where supplier_id = p_supplier);
$$;
revoke all on function app.supplier_balance(uuid) from public;

create or replace function public.suppliers_overview(p_branch_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when not app.has_perm(p_branch_id, 'inventory.view') then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'phone', s.phone, 'is_active', s.is_active,
        'balance_baisa', case when app.has_perm(p_branch_id, 'inventory.cost.view') then app.supplier_balance(s.id) end) order by s.name)
    from public.suppliers s where s.organization_id = (select organization_id from public.branches where id = p_branch_id)), '[]'::jsonb) end;
$$;

-- سداد للمورّد: نقدي من درج وردية المستخدم أو تحويل بنكي
create or replace function public.pay_supplier(p_operation_id uuid, p_branch_id uuid, p_supplier_id uuid, p_method text, p_amount_baisa bigint,
  p_reference text, p_cash_session_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_org uuid; v_sup public.suppliers; v_sess public.cash_sessions; v_r jsonb; v_id uuid; v_bal bigint; v_drawer bigint;
  v_hash text := md5(jsonb_build_object('b', p_branch_id, 's', p_supplier_id, 'm', p_method, 'a', p_amount_baisa, 'r', p_reference, 'c', p_cash_session_id)::text);
begin
  v_r := app.op_replay(p_operation_id, 'supplier_payment', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = p_branch_id;
  if v_org is null or not app.has_perm(p_branch_id, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  select * into v_sup from public.suppliers where id = p_supplier_id and organization_id = v_org for update;
  if not found then perform app.fail('NOT_FOUND'); end if;
  if p_method not in ('cash', 'transfer') or p_amount_baisa is null or p_amount_baisa <= 0 then perform app.fail('INVALID_AMOUNT'); end if;
  v_bal := app.supplier_balance(v_sup.id);
  if p_amount_baisa > v_bal then perform app.fail('AMOUNT_EXCEEDS_BALANCE', jsonb_build_object('balance_baisa', v_bal)); end if;
  if p_method = 'cash' then
    select * into v_sess from public.cash_sessions where id = p_cash_session_id and branch_id = p_branch_id for update;
    if not found then perform app.fail('SESSION_NOT_FOUND'); end if;
    if v_sess.status <> 'open' then perform app.fail('SESSION_CLOSED'); end if;
    if v_sess.opened_by <> v_uid then perform app.fail('SESSION_NOT_YOURS'); end if;
    select coalesce(sum(amount_baisa), 0) into v_drawer from public.cash_movements where cash_session_id = v_sess.id;
    if p_amount_baisa > v_drawer then perform app.fail('INSUFFICIENT_CASH', jsonb_build_object('drawer_baisa', v_drawer)); end if;
  end if;
  insert into public.supplier_payments (organization_id, branch_id, supplier_id, method, amount_baisa, reference, cash_session_id, created_by)
  values (v_org, p_branch_id, v_sup.id, p_method, p_amount_baisa, nullif(btrim(p_reference), ''), v_sess.id, v_uid) returning id into v_id;
  if p_method = 'cash' then
    insert into public.cash_movements (organization_id, branch_id, cash_session_id, movement_type, amount_baisa, source_type, source_id, note, created_by)
    values (v_org, p_branch_id, v_sess.id, 'cash_out', -p_amount_baisa, 'supplier_payment', v_id, 'سداد للمورّد — ' || v_sup.name, v_uid);
  end if;
  perform app.post_journal(v_org, p_branch_id, v_sess.business_day_id, 'supplier_payment', v_id, 'سداد للمورّد ' || v_sup.name,
    jsonb_build_array(jsonb_build_array('accounts_payable', p_amount_baisa, 0),
      jsonb_build_array(case when p_method = 'cash' then 'cash_on_hand' else 'bank' end, 0, p_amount_baisa)));
  perform app.audit(v_org, p_branch_id, 'supplier.payment', 'supplier', v_sup.id, null, null, jsonb_build_object('amount_baisa', p_amount_baisa, 'method', p_method));
  return app.op_store(p_operation_id, v_org, p_branch_id, v_sess.id, 'supplier_payment', v_hash,
    jsonb_build_object('status', 'recorded', 'payment_id', v_id, 'balance_baisa', v_bal - p_amount_baisa));
end $$;

revoke all on function public.product_card(uuid, uuid), public.list_purchases(uuid), public.suppliers_overview(uuid),
  public.pay_supplier(uuid, uuid, uuid, text, bigint, text, uuid) from public, anon;
grant execute on function public.product_card(uuid, uuid), public.list_purchases(uuid), public.suppliers_overview(uuid),
  public.pay_supplier(uuid, uuid, uuid, text, bigint, text, uuid) to authenticated;
-- العملاء والضمان، تصنيف المصروفات، لوحة المالك، تقرير الضريبة، التحويل بين الفرعين، وإدارة المستخدمين.

-- ───────────── الضمان ─────────────
alter table public.products add column warranty_months int check (warranty_months between 0 and 120);

create table public.warranties (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null, branch_id uuid not null,
  invoice_id uuid not null references public.invoices(id),
  invoice_line_id uuid not null unique references public.invoice_lines(id),
  customer_id uuid, vehicle_id uuid,
  warranty_no text not null, product_name text not null, months int not null,
  starts_on date not null, expires_on date not null,
  created_at timestamptz not null default now(),
  unique (organization_id, warranty_no));
create index warranties_customer_idx on public.warranties (customer_id);
create index warranties_invoice_idx on public.warranties (invoice_id);
alter table public.warranties enable row level security;
create policy warranties_read on public.warranties for select to authenticated using (app.has_perm(branch_id, 'invoice.view'));

-- كل بند مباع من صنف له مدة ضمان يُصدر له ضمان مرتبط بالفاتورة والعميل والمركبة
create or replace function app.issue_warranty() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_m int; v_inv public.invoices; v_day date := (now() at time zone 'Asia/Muscat')::date;
begin
  select warranty_months into v_m from public.products where id = new.product_id;
  if coalesce(v_m, 0) <= 0 then return new; end if;
  select * into v_inv from public.invoices where id = new.invoice_id;
  insert into public.warranties (organization_id, branch_id, invoice_id, invoice_line_id, customer_id, vehicle_id, warranty_no, product_name, months, starts_on, expires_on)
  values (new.organization_id, new.branch_id, new.invoice_id, new.id, v_inv.customer_id, v_inv.vehicle_id,
    'W-' || v_inv.invoice_no || '-' || new.line_no, new.description_ar, v_m, v_day, (v_day + make_interval(months => v_m))::date);
  return new;
end $$;
create trigger invoice_lines_issue_warranty after insert on public.invoice_lines for each row execute function app.issue_warranty();

-- ───────────── تصنيف المصروفات ─────────────
alter table public.cash_movements add column category text;
create or replace function app.cash_movement_category() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.category is null and new.movement_type in ('cash_in', 'cash_out') and new.source_type is null then
    new.category := nullif(current_setting('app.cash_category', true), '');
  end if;
  return new;
end $$;
create trigger cash_movements_category before insert on public.cash_movements for each row execute function app.cash_movement_category();

create or replace function public.record_cash_movement_cat(p_operation_id uuid, p_cash_session_id uuid, p_type text, p_amount_baisa bigint, p_note text, p_category text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_r jsonb;
begin
  perform set_config('app.cash_category', coalesce(btrim(p_category), ''), true);
  v_r := public.record_cash_movement(p_operation_id, p_cash_session_id, p_type, p_amount_baisa, p_note);
  perform set_config('app.cash_category', '', true);
  return v_r;
end $$;

-- حركات الدرج غير البيع في وردية (مصروفات، قبض، مرتجعات، مشتريات نقدية، تحصيل)
create or replace function public.session_movements(p_cash_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_sess public.cash_sessions;
begin
  select * into v_sess from public.cash_sessions where id = p_cash_session_id;
  if not found or not (app.can_close_session(v_sess.branch_id, v_sess.opened_by) or app.has_perm(v_sess.branch_id, 'reports.view')) then
    perform app.fail('NOT_FOUND'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', m.created_at, 'type', m.movement_type, 'source_type', m.source_type,
      'category', m.category, 'note', m.note, 'amount_baisa', m.amount_baisa) order by m.created_at)
    from public.cash_movements m where m.cash_session_id = v_sess.id and m.movement_type not in ('opening', 'sale', 'closing')), '[]'::jsonb);
end $$;

-- ───────────── تعديل الدوال القائمة في موضعها ─────────────
do $$
declare d text; r record;
begin
  for r in select * from (values
    ('public.save_product(jsonb)', 'if p_product ?| array[''default_supplier_id'', ', 'if p_product ?| array[''warranty_months'', ''default_supplier_id'', '),
    ('public.save_product(jsonb)', '      tire_year = case when p_product ? ''tire_year''',
       '      warranty_months = case when p_product ? ''warranty_months'' then (p_product->>''warranty_months'')::int else warranty_months end,
      tire_year = case when p_product ? ''tire_year'''),
    ('app.invoice_json(uuid)', '''note'', i.note, ''print_count'', i.print_count,',
       '''note'', i.note, ''print_count'', i.print_count,
    ''warranties'', coalesce((select jsonb_agg(jsonb_build_object(''warranty_no'', w.warranty_no, ''product_name'', w.product_name, ''months'', w.months,
        ''starts_on'', w.starts_on, ''expires_on'', w.expires_on) order by w.warranty_no) from public.warranties w where w.invoice_id = i.id), ''[]''::jsonb),')
  ) as t(fn, target, repl) loop
    d := pg_get_functiondef(r.fn::regprocedure);
    if position(r.target in d) = 0 then raise exception 'patch target missing in %: %', r.fn, r.target; end if;
    execute replace(d, r.target, r.repl);
  end loop;
end $$;

-- ───────────── ملف العميل ─────────────
create or replace function public.add_vehicle(p_branch_id uuid, p_customer_id uuid, p_plate text, p_make text, p_model text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_veh public.vehicles; v_plate text := nullif(btrim(p_plate), '');
begin
  select organization_id into v_org from public.branches where id = p_branch_id;
  if v_org is null or not app.has_perm(p_branch_id, 'pos.sell') then perform app.fail('FORBIDDEN'); end if;
  if v_plate is null then perform app.fail('INVALID_REQUEST'); end if;
  if not exists (select 1 from public.customers where id = p_customer_id and organization_id = v_org) then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  select * into v_veh from public.vehicles where organization_id = v_org and customer_id = p_customer_id and plate = v_plate;
  if not found then
    insert into public.vehicles (organization_id, customer_id, plate, make, model)
    values (v_org, p_customer_id, v_plate, nullif(btrim(p_make), ''), nullif(btrim(p_model), '')) returning * into v_veh;
  end if;
  return to_jsonb(v_veh);
end $$;

-- العميل ومركباته وضماناته ورصيده الآجل وكشف حسابه وآخر فواتيره (ضمن الفروع المتاحة للمستخدم)
create or replace function public.customer_profile(p_customer_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_c public.customers; v_today date := (now() at time zone 'Asia/Muscat')::date;
begin
  select * into v_c from public.customers where id = p_customer_id;
  if not found or not app.has_org(v_c.organization_id) then perform app.fail('CUSTOMER_NOT_FOUND'); end if;
  return jsonb_build_object(
    'customer', jsonb_build_object('id', v_c.id, 'name', v_c.name, 'phone', v_c.phone, 'notes', v_c.notes),
    'balance_baisa', app.customer_balance(v_c.id),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model) order by v.created_at)
      from public.vehicles v where v.customer_id = v_c.id), '[]'::jsonb),
    'warranties', coalesce((select jsonb_agg(jsonb_build_object('warranty_no', w.warranty_no, 'product_name', w.product_name, 'months', w.months,
        'starts_on', w.starts_on, 'expires_on', w.expires_on, 'active', w.expires_on >= v_today, 'invoice_id', w.invoice_id,
        'plate', (select plate from public.vehicles where id = w.vehicle_id)) order by w.expires_on desc)
      from public.warranties w where w.customer_id = v_c.id and app.has_perm(w.branch_id, 'invoice.view')), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'invoice_no', i.invoice_no, 'status', i.status, 'approved_at', i.approved_at,
        'total_baisa', i.total_baisa, 'plate', (select plate from public.vehicles where id = i.vehicle_id)) order by i.approved_at desc)
      from (select * from public.invoices where customer_id = v_c.id order by approved_at desc limit 50) i where app.has_perm(i.branch_id, 'invoice.view')), '[]'::jsonb),
    'statement', coalesce((select jsonb_agg(jsonb_build_object('at', s.at, 'kind', s.kind, 'ref', s.ref, 'debit_baisa', s.debit, 'credit_baisa', s.credit) order by s.at)
      from (
        select p.created_at as at, 'sale' as kind, i.invoice_no as ref, p.amount_baisa as debit, 0::bigint as credit
          from public.payments p join public.invoices i on i.id = p.invoice_id where i.customer_id = v_c.id and p.method = 'credit'
        union all
        select f.created_at, 'refund', f.refund_no, 0, f.amount_baisa
          from public.refunds f join public.invoices i on i.id = f.invoice_id where i.customer_id = v_c.id and f.method = 'credit'
        union all
        select r.created_at, 'receipt', coalesce(r.reference, r.method), 0, r.amount_baisa from public.customer_receipts r where r.customer_id = v_c.id
      ) s), '[]'::jsonb));
end $$;

-- ───────────── التحويل بين الفرعين ─────────────
-- يُخصم من الفرع المصدر FIFO ويُضاف للفرع المستلم بالتكلفة نفسها فورًا (بلا مرحلة «في الطريق»).
create or replace function public.transfer_stock(p_operation_id uuid, p_from_branch uuid, p_to_branch uuid, p_product_id uuid, p_qty numeric, p_note text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_org uuid; v_org2 uuid; v_prod public.products; v_r jsonb; v_lot record; v_new uuid;
  v_need numeric(12,3); v_take numeric(12,3); v_ref uuid := gen_random_uuid(); v_value bigint := 0;
  v_hash text := md5(jsonb_build_object('f', p_from_branch, 't', p_to_branch, 'p', p_product_id, 'q', p_qty, 'n', p_note)::text);
begin
  v_r := app.op_replay(p_operation_id, 'stock_transfer', v_hash); if v_r is not null then return v_r; end if;
  select organization_id into v_org from public.branches where id = p_from_branch;
  select organization_id into v_org2 from public.branches where id = p_to_branch and is_active;
  if v_org is null or not app.has_perm(p_from_branch, 'inventory.manage') then perform app.fail('FORBIDDEN'); end if;
  if v_org2 is distinct from v_org or p_from_branch = p_to_branch then perform app.fail('INVALID_REQUEST'); end if;
  select * into v_prod from public.products where id = p_product_id and organization_id = v_org and track_stock;
  if not found then perform app.fail('PRODUCT_NOT_FOUND'); end if;
  if p_qty is null or p_qty <= 0 or (v_prod.whole_units_only and p_qty <> trunc(p_qty)) then perform app.fail('INVALID_QUANTITY'); end if;
  v_need := p_qty;
  for v_lot in select id, qty_on_hand, unit_cost_baisa, lot_code, dot_code from public.inventory_lots
               where branch_id = p_from_branch and product_id = p_product_id and qty_on_hand > 0 order by received_at, id for update loop
    v_take := least(v_need, v_lot.qty_on_hand);
    update public.inventory_lots set qty_on_hand = qty_on_hand - v_take where id = v_lot.id;
    insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
    values (v_org, p_from_branch, p_product_id, v_lot.id, 'transfer_out', -v_take, v_lot.unit_cost_baisa, 'transfer', v_ref, v_uid);
    insert into public.inventory_lots (organization_id, branch_id, product_id, lot_code, dot_code, unit_cost_baisa, qty_received, qty_on_hand)
    values (v_org, p_to_branch, p_product_id, coalesce(v_lot.lot_code, 'TRF'), v_lot.dot_code, v_lot.unit_cost_baisa, v_take, v_take) returning id into v_new;
    insert into public.stock_movements (organization_id, branch_id, product_id, lot_id, movement_type, qty_delta, unit_cost_baisa, source_type, source_id, created_by)
    values (v_org, p_to_branch, p_product_id, v_new, 'transfer_in', v_take, v_lot.unit_cost_baisa, 'transfer', v_ref, v_uid);
    v_value := v_value + app.round_baisa(v_take * v_lot.unit_cost_baisa); v_need := v_need - v_take; exit when v_need = 0;
  end loop;
  if v_need > 0 then perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('name_ar', v_prod.name_ar, 'requested', p_qty, 'available', p_qty - v_need)); end if;
  perform app.audit(v_org, p_from_branch, 'stock.transfer', 'product', p_product_id, nullif(btrim(p_note), ''), null,
    jsonb_build_object('to_branch', p_to_branch, 'qty', p_qty, 'value_baisa', v_value));
  return app.op_store(p_operation_id, v_org, p_from_branch, null, 'stock_transfer', v_hash,
    jsonb_build_object('status', 'transferred', 'qty', p_qty, 'value_baisa', v_value));
end $$;

-- ───────────── لوحة المالك ─────────────
create or replace function public.owner_dashboard(p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with br as (select b.* from public.branches b where b.is_active and app.has_perm(b.id, 'reports.view')),
  inv as (select i.*, d.business_date from public.invoices i join public.business_days d on d.id = i.business_day_id
          where i.branch_id in (select id from br) and i.status = 'approved' and d.business_date between p_from and p_to),
  ref as (select f.* from public.refunds f join public.business_days d on d.id = f.business_day_id
          where f.branch_id in (select id from br) and f.kind = 'refund' and d.business_date between p_from and p_to)
  select jsonb_build_object(
    'branches', coalesce((select jsonb_agg(jsonb_build_object('branch_id', b.id, 'name_ar', b.name_ar,
        'invoice_count', (select count(*) from inv where inv.branch_id = b.id),
        'total_baisa', (select coalesce(sum(total_baisa), 0) from inv where inv.branch_id = b.id),
        'net_baisa', (select coalesce(sum(net_baisa), 0) from inv where inv.branch_id = b.id) - (select coalesce(sum(net_baisa), 0) from ref where ref.branch_id = b.id),
        'gross_profit_baisa', case when app.has_perm(b.id, 'inventory.cost.view') then
            (select coalesce(sum(net_baisa), 0) from inv where inv.branch_id = b.id) - (select coalesce(sum(net_baisa), 0) from ref where ref.branch_id = b.id)
            - (select coalesce(sum(c.cost_baisa), 0) from public.invoice_line_costs c join public.invoice_lines l on l.id = c.invoice_line_id join inv on inv.id = l.invoice_id where inv.branch_id = b.id)
            + (select coalesce(sum(rl.cost_baisa), 0) from public.refund_lines rl join ref on ref.id = rl.refund_id where ref.branch_id = b.id and rl.restocked) end,
        'low_stock', (select count(*) from public.products p where p.organization_id = b.organization_id and p.track_stock and p.is_active
            and coalesce((select sum(qty_on_hand) from public.inventory_lots where branch_id = b.id and product_id = p.id), 0) <= coalesce(p.reorder_level, 3))
      ) order by b.code) from br b), '[]'::jsonb),
    'top_products', coalesce((select jsonb_agg(t) from (
        select l.description_ar as name_ar, sum(l.qty) as qty, sum(l.net_baisa) as net_baisa
        from public.invoice_lines l join inv on inv.id = l.invoice_id group by l.description_ar order by sum(l.net_baisa) desc limit 8) t), '[]'::jsonb),
    'series', coalesce((select jsonb_agg(jsonb_build_object('date', g.d::date, 'total_baisa',
          (select coalesce(sum(i.total_baisa), 0) from public.invoices i join public.business_days bd on bd.id = i.business_day_id
           where i.branch_id in (select id from br) and i.status = 'approved' and bd.business_date = g.d::date)) order by g.d)
      from generate_series(p_to - 6, p_to, interval '1 day') g(d)), '[]'::jsonb),
    'receivables_baisa', (select coalesce(sum(app.customer_balance(c.id)), 0) from public.customers c
        where c.organization_id in (select organization_id from br) and exists (select 1 from public.payments p join public.invoices i on i.id = p.invoice_id where i.customer_id = c.id and p.method = 'credit')),
    'payables_baisa', (select coalesce(sum(app.supplier_balance(s.id)), 0) from public.suppliers s where s.organization_id in (select organization_id from br)
        and exists (select 1 from br where app.has_perm(br.id, 'inventory.cost.view'))));
$$;

-- ───────────── تقرير ضريبة القيمة المضافة ─────────────
-- المخرجات من الفواتير المعتمدة ناقص المرتجعات حسب اليوم المحاسبي؛ المدخلات من المشتريات حسب تاريخ فاتورة المورّد.
create or replace function public.vat_report(p_branch_id uuid, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with br as (select b.id from public.branches b where (p_branch_id is null or b.id = p_branch_id) and app.has_perm(b.id, 'reports.view')),
  o as (select to_char(d.business_date, 'YYYY-MM') m, i.net_baisa net, i.tax_baisa tax from public.invoices i join public.business_days d on d.id = i.business_day_id
        where i.branch_id in (select id from br) and i.status = 'approved' and d.business_date between p_from and p_to
        union all
        select to_char(d.business_date, 'YYYY-MM'), -f.net_baisa, -f.tax_baisa from public.refunds f join public.business_days d on d.id = f.business_day_id
        where f.branch_id in (select id from br) and f.kind = 'refund' and d.business_date between p_from and p_to),
  i as (select to_char(coalesce(r.supplier_invoice_date, (r.created_at at time zone 'Asia/Muscat')::date), 'YYYY-MM') m, r.total_cost_baisa net, r.tax_baisa tax
        from public.purchase_receipts r where r.branch_id in (select id from br)
          and coalesce(r.supplier_invoice_date, (r.created_at at time zone 'Asia/Muscat')::date) between p_from and p_to),
  months as (select m from o union select m from i)
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', mm.m,
        'sales_net_baisa', (select coalesce(sum(net), 0) from o where o.m = mm.m), 'output_tax_baisa', (select coalesce(sum(tax), 0) from o where o.m = mm.m),
        'purchases_net_baisa', (select coalesce(sum(net), 0) from i where i.m = mm.m), 'input_tax_baisa', (select coalesce(sum(tax), 0) from i where i.m = mm.m)) order by mm.m)
      from months mm), '[]'::jsonb),
    'sales_net_baisa', (select coalesce(sum(net), 0) from o), 'output_tax_baisa', (select coalesce(sum(tax), 0) from o),
    'purchases_net_baisa', (select coalesce(sum(net), 0) from i), 'input_tax_baisa', (select coalesce(sum(tax), 0) from i),
    'net_tax_baisa', (select coalesce(sum(tax), 0) from o) - (select coalesce(sum(tax), 0) from i));
$$;

-- ───────────── المستخدمون والصلاحيات ─────────────
create or replace function public.list_users(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_org_perm(p_organization_id, 'users.manage') then perform app.fail('FORBIDDEN'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', p.id, 'full_name', p.full_name, 'is_active', p.is_active,
      'username', (select split_part(u.email, '@', 1) from auth.users u where u.id = p.id),
      'memberships', (select jsonb_agg(jsonb_build_object('id', m.id, 'role_code', m.role_code, 'branch_id', m.branch_id,
          'branch_name', (select name_ar from public.branches where id = m.branch_id), 'max_discount_bp', m.max_discount_bp, 'is_active', m.is_active) order by m.created_at)
        from public.memberships m where m.user_id = p.id and m.organization_id = p_organization_id)) order by p.created_at)
    from public.profiles p where exists (select 1 from public.memberships m where m.user_id = p.id and m.organization_id = p_organization_id)), '[]'::jsonb);
end $$;

-- p: { organization_id, user_id, full_name?, is_active?, role_code, branch_id (null = كل الفروع), max_discount_bp }
-- للمستخدم دور واحد في المنشأة: يُستبدل ما قبله. لا يستطيع المدير تعطيل نفسه أو نزع دوره.
create or replace function public.save_user_role(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := (p->>'organization_id')::uuid; v_user uuid := (p->>'user_id')::uuid; v_role text := p->>'role_code';
  v_branch uuid := (p->>'branch_id')::uuid; v_disc int := coalesce((p->>'max_discount_bp')::int, 0);
begin
  if v_org is null or not app.has_org_perm(v_org, 'users.manage') then perform app.fail('FORBIDDEN'); end if;
  if not exists (select 1 from public.profiles where id = v_user) or not exists (select 1 from public.roles where code = v_role) then perform app.fail('NOT_FOUND'); end if;
  if v_branch is not null and not exists (select 1 from public.branches where id = v_branch and organization_id = v_org) then perform app.fail('NOT_FOUND'); end if;
  if v_disc not between 0 and 10000 then perform app.fail('INVALID_AMOUNT'); end if;
  if v_user = (select auth.uid()) and (v_role <> 'owner' or coalesce((p->>'is_active')::boolean, true) = false) then perform app.fail('CANNOT_CHANGE_SELF'); end if;
  if v_role in ('cashier', 'branch_manager') and v_branch is null then perform app.fail('BRANCH_REQUIRED'); end if;
  update public.profiles set full_name = coalesce(nullif(btrim(p->>'full_name'), ''), full_name),
    is_active = coalesce((p->>'is_active')::boolean, is_active) where id = v_user;
  delete from public.memberships where user_id = v_user and organization_id = v_org;
  insert into public.memberships (organization_id, user_id, branch_id, role_code, max_discount_bp) values (v_org, v_user, v_branch, v_role, v_disc);
  perform app.audit(v_org, v_branch, 'user.role.save', 'user', v_user, null, null, p - 'organization_id');
  return jsonb_build_object('status', 'saved');
end $$;

revoke all on function public.record_cash_movement_cat(uuid, uuid, text, bigint, text, text), public.session_movements(uuid), public.add_vehicle(uuid, uuid, text, text, text),
  public.customer_profile(uuid), public.transfer_stock(uuid, uuid, uuid, uuid, numeric, text), public.owner_dashboard(date, date), public.vat_report(uuid, date, date),
  public.list_users(uuid), public.save_user_role(jsonb) from public, anon;
grant execute on function public.record_cash_movement_cat(uuid, uuid, text, bigint, text, text), public.session_movements(uuid), public.add_vehicle(uuid, uuid, text, text, text),
  public.customer_profile(uuid), public.transfer_stock(uuid, uuid, uuid, uuid, numeric, text), public.owner_dashboard(date, date), public.vat_report(uuid, date, date),
  public.list_users(uuid), public.save_user_role(jsonb) to authenticated;
grant execute on function public.save_user_role(jsonb), public.list_users(uuid) to service_role;
-- إشعارات العملاء (المرحلة 4): إعدادات لكل منشأة وسجل محاولات. الإرسال تنفذه دالة الخادم notify-worker.
-- الإرسال الحقيقي معطّل افتراضيًا: يتطلب تفعيله من الإعدادات ووجود أسرار المزوّد في الخادم؛ وإلا تُسجَّل الرسالة «تجريبية» ولا تُرسل.

create table public.notification_settings (
  organization_id uuid primary key references public.organizations(id),
  enabled boolean not null default false,
  whatsapp_template text not null default 'invoice_issued',
  whatsapp_lang text not null default 'ar',
  sms_fallback boolean not null default true,
  updated_at timestamptz not null default now());
alter table public.notification_settings enable row level security;
create policy notification_settings_read on public.notification_settings for select to authenticated using (app.has_org_perm(organization_id, 'notifications.manage'));
insert into public.notification_settings (organization_id) select id from public.organizations on conflict do nothing;

alter table public.notification_events
  add column attempts int not null default 0,
  add column channel text,
  add column last_error text,
  add column message text,
  add column sent_at timestamptz;

create or replace function public.notification_overview(p_organization_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not app.has_org_perm(p_organization_id, 'notifications.manage') then perform app.fail('FORBIDDEN'); end if;
  return jsonb_build_object(
    'settings', (select to_jsonb(s) from public.notification_settings s where s.organization_id = p_organization_id),
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
  insert into public.notification_settings (organization_id) values (p_organization_id) on conflict do nothing;
  update public.notification_settings set
    enabled = coalesce((p->>'enabled')::boolean, enabled),
    sms_fallback = coalesce((p->>'sms_fallback')::boolean, sms_fallback),
    whatsapp_template = coalesce(nullif(btrim(p->>'whatsapp_template'), ''), whatsapp_template),
    whatsapp_lang = coalesce(nullif(btrim(p->>'whatsapp_lang'), ''), whatsapp_lang),
    updated_at = now()
  where organization_id = p_organization_id returning * into v;
  perform app.audit(p_organization_id, null, 'notifications.settings', 'organization', p_organization_id, null, null, to_jsonb(v));
  return to_jsonb(v);
end $$;

revoke all on function public.notification_overview(uuid), public.update_notification_settings(uuid, jsonb) from public, anon;
grant execute on function public.notification_overview(uuid), public.update_notification_settings(uuid, jsonb) to authenticated, service_role;
-- قرار المالك: إعدادات الضريبة ونص الفاتورة يضبطها المالك أو مدير الفرع لفرعه.
-- تحديد من يفتح الورديات يبقى للمالك وحده (حتى لا يمنح المدير الصلاحية لنفسه).
insert into public.role_permissions (role_code, permission_code) values ('branch_manager', 'settings.manage') on conflict do nothing;

do $$
declare d text; target constant text := 'if p_settings ? ''shift_roles'' then';
begin
  d := pg_get_functiondef('public.update_branch_settings(uuid,jsonb)'::regprocedure);
  if position(target in d) = 0 then raise exception 'patch target missing'; end if;
  execute replace(d, target, 'if p_settings ? ''shift_roles'' and not app.has_org_perm(v_old.organization_id, ''users.manage'') then perform app.fail(''FORBIDDEN''); end if;
  ' || target);
end $$;
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
-- رابط فاتورة PDF للعميل في رسالة واتساب.
-- المخزن خاص (غير عام): لا يفتح الملف إلا رابط موقّع محدود المدة ينشئه موظف مسجّل الدخول ويرسله للعميل نفسه.
do $$
begin
  if to_regclass('storage.buckets') is null then return; end if; -- بيئة الاختبار المحلية بلا Storage
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('invoices', 'invoices', false, 3145728, array['application/pdf'])
  on conflict (id) do update set public = false, file_size_limit = 3145728, allowed_mime_types = array['application/pdf'];
  execute 'drop policy if exists invoices_pdf_insert on storage.objects';
  execute 'drop policy if exists invoices_pdf_update on storage.objects';
  execute 'drop policy if exists invoices_pdf_select on storage.objects';
  execute 'create policy invoices_pdf_insert on storage.objects for insert to authenticated with check (bucket_id = ''invoices'')';
  execute 'create policy invoices_pdf_update on storage.objects for update to authenticated using (bucket_id = ''invoices'') with check (bucket_id = ''invoices'')';
  execute 'create policy invoices_pdf_select on storage.objects for select to authenticated using (bucket_id = ''invoices'')';
end $$;
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
