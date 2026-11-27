// إعدادات الفرع: الورديات للكاشير فقط افتراضيًا، وبقية الأدوار تُفعَّل من إعدادات النظام.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startDb, ID, uuid, expectCode } from '../harness.mjs';

let db;
before(async () => { db = await startDb(); });
after(async () => { await db.stop(); });

test('افتراضيًا يفتح الكاشير الوردية فقط؛ المدير والمالك يُرفضان حتى يفعّلهما المالك من الإعدادات', async () => {
  await expectCode(db.rpc(ID.manager, 'open_cash_session', [uuid(), ID.devTyr2, 0]), 'SHIFT_NOT_ENABLED_FOR_ROLE');
  await expectCode(db.rpc(ID.owner, 'open_cash_session', [uuid(), ID.devTyr2, 0]), 'SHIFT_NOT_ENABLED_FOR_ROLE');
  assert.equal((await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr1, 0])).status, 'opened');
  assert.equal(Number((await db.sql('select count(*) n from cash_sessions'))[0].n), 1);

  await expectCode(db.rpc(ID.manager, 'update_branch_settings', [ID.tyr, { shift_roles: ['branch_manager'] }]), 'FORBIDDEN');
  const s = await db.rpc(ID.owner, 'update_branch_settings', [ID.tyr, { shift_roles: ['branch_manager', 'nonsense'] }]);
  assert.deepEqual([...s.shift_roles].sort(), ['branch_manager', 'cashier'], 'الكاشير يبقى دائمًا والأدوار المجهولة تُهمل');
  assert.equal((await db.rpc(ID.manager, 'open_cash_session', [uuid(), ID.devTyr2, 0])).status, 'opened');
  await expectCode(db.rpc(ID.owner, 'open_cash_session', [uuid(), ID.devTnt, 0]), 'SHIFT_NOT_ENABLED_FOR_ROLE');
  // الإعداد لكل فرع على حدة
  assert.deepEqual((await db.sql('select shift_roles from branch_settings where branch_id=$1', [ID.tnt]))[0].shift_roles, ['cashier']);
  assert.equal(Number((await db.sql(`select count(*) n from audit_log where action='branch_settings.update' and user_id=$1`, [ID.owner]))[0].n), 1);
});

test('إعدادات الضريبة ونص الإيصال تُحدَّث وتُطبَّق على البيع التالي', async () => {
  await db.rpc(ID.owner, 'update_branch_settings', [ID.tnt, { tax_enabled: false, receipt_footer_ar: 'نسعد بخدمتكم' }]);
  const s = (await db.rpc(ID.cashierTnt, 'open_cash_session', [uuid(), ID.devTnt, 0])).session.id;
  const r = await db.rpc(ID.cashierTnt, 'approve_sale', [uuid(), { cash_session_id: s,
    lines: [{ product_id: ID.holder, qty: 1, unit_price_baisa: 3000, discount_baisa: 0 }], payments: [{ method: 'cash', amount_baisa: 3000 }], expected_total_baisa: 3000 }]);
  assert.deepEqual([r.invoice.tax_baisa, r.invoice.branch.receipt_footer_ar], [0, 'نسعد بخدمتكم']);
  await expectCode(db.rpc(ID.owner, 'update_branch_settings', [ID.tnt, { tax_rate_bp: 20000 }]), 'INVALID_AMOUNT');
});

test('كل موظف يفتح ورديته على الجهاز نفسه، ويبيع ويقفل في ورديته فقط', async () => {
  // كاشير الإطارات لديه وردية مفتوحة على الجهاز 1؛ المدير (مفعّل) يفتح ورديته على الجهاز نفسه
  const mine = (await db.rpc(ID.cashierTyr, 'resolve_device', ['POS-TYR-01'])).open_session;
  assert.equal(mine.mine, true);
  assert.equal((await db.rpc(ID.manager, 'resolve_device', ['POS-TYR-01'])).open_session, null, 'لا يرى وردية غيره كورديته');
  const m = (await db.rpc(ID.manager, 'open_cash_session', [uuid(), ID.devTyr1, 5000])).session.id;
  assert.notEqual(m, mine.id);
  await expectCode(db.rpc(ID.manager, 'open_cash_session', [uuid(), ID.devTyr1, 0]), 'SESSION_ALREADY_OPEN');
  const sale = (s) => ({ cash_session_id: s, lines: [{ product_id: ID.install, qty: 1, unit_price_baisa: 1000, discount_baisa: 0 }],
    payments: [{ method: 'cash', amount_baisa: 1000 }], expected_total_baisa: 1000 });
  await db.rpc(ID.manager, 'approve_sale', [uuid(), sale(m)]);
  await db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(mine.id)]);
  await expectCode(db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(m)]), 'SESSION_NOT_YOURS');
  const a = await db.rpc(ID.manager, 'cash_session_summary', [m]);
  const b = await db.rpc(ID.cashierTyr, 'cash_session_summary', [mine.id]);
  assert.deepEqual([a.expected_cash_baisa, b.expected_cash_baisa], [6000, 1000], 'نقد كل وردية محسوب على حدة');
  await db.rpc(ID.cashierTyr, 'close_cash_session', [uuid(), mine.id, 1000, null]);
  assert.equal((await db.rpc(ID.manager, 'resolve_device', ['POS-TYR-01'])).open_session.id, m, 'إقفال وردية لا يمس وردية الآخر');
});

test('تحويل بنكي وآجل: الآجل يتطلب عميلًا، يُرحَّل للذمم، ويُحصَّل لاحقًا في درج الوردية', async () => {
  const s = (await db.rpc(ID.manager, 'resolve_device', ['POS-TYR-01'])).open_session.id;
  const sale = (payments, extra = {}) => ({ cash_session_id: s, lines: [{ product_id: ID.install, qty: 10, unit_price_baisa: 1000, discount_baisa: 0 }],
    payments, expected_total_baisa: 10000, ...extra });
  await expectCode(db.rpc(ID.manager, 'approve_sale', [uuid(), sale([{ method: 'credit', amount_baisa: 10000 }])]), 'CREDIT_REQUIRES_CUSTOMER');
  const cust = (await db.rpc(ID.manager, 'save_customer', [{ branch_id: ID.tyr, name: 'عميل آجل', phone: '96890000077' }])).customer.id;
  const before = (await db.rpc(ID.manager, 'cash_session_summary', [s])).expected_cash_baisa;
  const r = await db.rpc(ID.manager, 'approve_sale', [uuid(), sale([{ method: 'cash', amount_baisa: 2000 }, { method: 'transfer', amount_baisa: 3000, card_reference: 'TRX-1' },
    { method: 'credit', amount_baisa: 5000 }], { customer_id: cust })]);
  assert.equal(r.status, 'approved');
  const sum = await db.rpc(ID.manager, 'cash_session_summary', [s]);
  assert.deepEqual([sum.expected_cash_baisa - before, sum.transfer_baisa, sum.credit_baisa], [2000, 3000, 5000]);
  assert.equal((await db.rpc(ID.manager, 'customer_account', [cust])).balance_baisa, 5000);
  const j = await db.sql(`select a.system_key k, l.debit_baisa d from journal_lines l join accounts a on a.id=l.account_id join journal_entries e on e.id=l.entry_id
    where e.source_id=$1 and l.debit_baisa>0 and a.system_key in ('bank_transfer_clearing','accounts_receivable') order by 1`, [r.invoice.id]);
  assert.deepEqual(j.map((x) => [x.k, Number(x.d)]), [['accounts_receivable', 5000], ['bank_transfer_clearing', 3000]]);

  await expectCode(db.rpc(ID.manager, 'collect_customer_payment', [uuid(), s, cust, 'cash', 6000, null]), 'AMOUNT_EXCEEDS_BALANCE');
  const op = uuid();
  const c1 = await db.rpc(ID.manager, 'collect_customer_payment', [op, s, cust, 'cash', 4000, null]);
  const c2 = await db.rpc(ID.manager, 'collect_customer_payment', [op, s, cust, 'cash', 4000, null]);
  assert.deepEqual([c1.balance_baisa, c2.replayed], [1000, true], 'إعادة الطلب لا تحصّل مرتين');
  assert.equal((await db.rpc(ID.manager, 'cash_session_summary', [s])).expected_cash_baisa - before, 6000);
  assert.equal((await db.rpc(ID.manager, 'customer_account', [cust])).balance_baisa, 1000);
  // إلغاء الفاتورة «رصيدًا للعميل»: لا نقد يخرج من الدرج، ويصير للعميل رصيد دائن
  await db.rpc(ID.manager, 'refund_invoice', [uuid(), { invoice_id: r.invoice.id, kind: 'void', method: 'credit', reason: 'إلغاء تجريبي' }]);
  assert.equal((await db.rpc(ID.manager, 'customer_account', [cust])).balance_baisa, -9000);
  assert.equal((await db.rpc(ID.manager, 'cash_session_summary', [s])).expected_cash_baisa - before, 6000);
});

test('بطاقة الصنف، استلام مشتريات نقدي وآجل بضريبة مدخلات، حساب المورّد وسداده، وأدنى سعر للكاشير', async () => {
  const s = (await db.rpc(ID.manager, 'resolve_device', ['POS-TYR-01'])).open_session.id;
  const sup = (await db.rpc(ID.manager, 'save_supplier', [{ organization_id: ID.org, name: 'مورّد البطاقة' }])).id;
  // المدير لا يدير الأصناف؛ المالك يحفظ بطاقة بحقولها الجديدة
  const base = { organization_id: ID.org, sku: 'TR-CARD-1', name_ar: 'إطار بطاقة', kind: 'item', category: 'tire', base_price_baisa: 30000,
    tire_width: 195, tire_aspect: 65, tire_rim: 15 };
  await expectCode(db.rpc(ID.manager, 'save_product', [base]), 'FORBIDDEN');
  const p = await db.rpc(ID.owner, 'save_product', [{ ...base, default_supplier_id: sup, reorder_level: 4, min_price_baisa: 28000, tire_year: 2024, tire_country: 'اليابان' }]);
  assert.deepEqual([p.default_supplier_id, Number(p.reorder_level), p.min_price_baisa, p.tire_year], [sup, 4, 28000, 2024]);
  // حفظ بلا الحقول الإضافية (لوحة الإدارة القديمة) لا يمسحها
  const p2 = await db.rpc(ID.owner, 'save_product', [{ ...base, id: p.id, base_price_baisa: 31000 }]);
  assert.deepEqual([p2.base_price_baisa, p2.min_price_baisa, p2.tire_country], [31000, 28000, 'اليابان']);

  const lines = [{ product_id: p.id, qty: 10, unit_cost_baisa: 20000 }];
  await expectCode(db.rpc(ID.manager, 'receive_purchase', [uuid(), { branch_id: ID.tyr, lines, payment_method: 'credit' }]), 'SUPPLIER_REQUIRED');
  const before = (await db.rpc(ID.manager, 'cash_session_summary', [s])).expected_cash_baisa;
  await expectCode(db.rpc(ID.manager, 'receive_purchase', [uuid(), { branch_id: ID.tyr, lines, payment_method: 'cash', cash_session_id: s, tax_rate_bp: 500 }]), 'INSUFFICIENT_CASH');
  const cr = await db.rpc(ID.manager, 'receive_purchase', [uuid(), { branch_id: ID.tyr, supplier_id: sup, reference: 'INV-9', lines, payment_method: 'credit',
    due_date: '2026-12-31', tax_rate_bp: 500 }]);
  assert.deepEqual([cr.total_cost_baisa, cr.tax_baisa, cr.payable_baisa], [200000, 10000, 210000]);
  const small = [{ product_id: p.id, qty: 1, unit_cost_baisa: 2000 }];
  await db.rpc(ID.manager, 'receive_purchase', [uuid(), { branch_id: ID.tyr, lines: small, payment_method: 'cash', cash_session_id: s, tax_rate_bp: 500 }]);
  assert.equal((await db.rpc(ID.manager, 'cash_session_summary', [s])).expected_cash_baisa - before, -2100);

  const ov = (await db.rpc(ID.manager, 'suppliers_overview', [ID.tyr])).find((x) => x.id === sup);
  assert.equal(ov.balance_baisa, 210000);
  await expectCode(db.rpc(ID.manager, 'pay_supplier', [uuid(), ID.tyr, sup, 'transfer', 300000, null, null]), 'AMOUNT_EXCEEDS_BALANCE');
  const pay = await db.rpc(ID.manager, 'pay_supplier', [uuid(), ID.tyr, sup, 'transfer', 110000, 'TRX-7', null]);
  assert.equal(pay.balance_baisa, 100000);
  const bad = await db.sql(`select e.id from journal_entries e join journal_lines l on l.entry_id=e.id group by e.id having sum(l.debit_baisa)<>sum(l.credit_baisa)`);
  assert.equal(bad.length, 0, 'كل القيود متوازنة');

  const card = await db.rpc(ID.manager, 'product_card', [ID.tyr, p.id]);
  assert.deepEqual([card.supplier_name, card.can_edit, card.movements.length, Number(card.branches.find((b) => b.branch_id === ID.tyr).qty)], ['مورّد البطاقة', false, 2, 11]);
  const row = (await db.rpc(ID.manager, 'stock_report', [ID.tyr])).find((x) => x.product_id === p.id);
  assert.deepEqual([Number(row.qty), row.tire_year, Number(row.reorder_level)], [11, 2024, 4]);
  assert.equal((await db.rpc(ID.manager, 'list_purchases', [ID.tyr]))[0].payment_method, 'cash');

  // أدنى سعر: الكاشير لا ينزل تحته بالخصم، والمدير يستطيع
  await db.sql(`update memberships set max_discount_bp = 5000 where user_id = any($1)`, [[ID.cashierTyr, ID.manager]]);
  await db.sql(`insert into role_permissions (role_code, permission_code) values ('cashier', 'pos.discount') on conflict do nothing`);
  const cs = (await db.rpc(ID.cashierTyr, 'open_cash_session', [uuid(), ID.devTyr2, 0])).session.id;
  const sale = (sid) => ({ cash_session_id: sid, lines: [{ product_id: p.id, qty: 1, unit_price_baisa: 31000, discount_baisa: 5000 }],
    payments: [{ method: 'cash', amount_baisa: 26000 }], expected_total_baisa: 26000 });
  await expectCode(db.rpc(ID.cashierTyr, 'approve_sale', [uuid(), sale(cs)]), 'BELOW_MIN_PRICE');
  assert.equal((await db.rpc(ID.manager, 'approve_sale', [uuid(), sale(s)])).status, 'approved');
});

test('الضمان، ملف العميل، تصنيف المصروفات، التحويل بين الفرعين، لوحة المالك، تقرير الضريبة، وأدوار المستخدمين', async () => {
  const s = (await db.rpc(ID.manager, 'resolve_device', ['POS-TYR-01'])).open_session.id;
  // صنف بضمان 12 شهرًا يُصدر بطاقة ضمان على الفاتورة
  const p = await db.rpc(ID.owner, 'save_product', [{ organization_id: ID.org, sku: 'TNT-W-1', name_ar: 'عازل بضمان', kind: 'service', category: 'tint',
    base_price_baisa: 40000, warranty_months: 12 }]);
  assert.equal(p.warranty_months, 12);
  const cust = (await db.rpc(ID.manager, 'save_customer', [{ branch_id: ID.tyr, name: 'عميل الضمان', phone: '96890000088', plate: '1234 A' }]));
  const tot = (await db.sql(`select tax_enabled, prices_include_tax from branch_settings where branch_id=$1`, [ID.tyr]))[0];
  const total = tot.tax_enabled && !tot.prices_include_tax ? 42000 : 40000;
  const r = await db.rpc(ID.manager, 'approve_sale', [uuid(), { cash_session_id: s, customer_id: cust.customer.id, vehicle_id: cust.vehicle.id,
    lines: [{ product_id: p.id, qty: 1, unit_price_baisa: 40000, discount_baisa: 0 }], payments: [{ method: 'cash', amount_baisa: total }], expected_total_baisa: total }]);
  assert.equal(r.invoice.warranties.length, 1);
  assert.match(r.invoice.warranties[0].warranty_no, /^W-/);
  await db.rpc(ID.manager, 'add_vehicle', [ID.tyr, cust.customer.id, '9999 B', 'تويوتا', 'كامري']);
  const prof = await db.rpc(ID.manager, 'customer_profile', [cust.customer.id]);
  assert.deepEqual([prof.vehicles.length, prof.warranties.length, prof.warranties[0].active, prof.invoices.length, prof.warranties[0].plate], [2, 1, true, 1, '1234 A']);

  // مصروف مصنّف يظهر في حركات الوردية
  await db.rpc(ID.manager, 'record_cash_movement_cat', [uuid(), s, 'cash_out', 1500, 'ماء وشاي', 'ضيافة']);
  const mv = await db.rpc(ID.manager, 'session_movements', [s]);
  assert.deepEqual(mv.filter((m) => m.category === 'ضيافة').map((m) => m.amount_baisa), [-1500]);

  // تحويل مخزون: يحتاج صلاحية على الفرع المصدر، ويحافظ على التكلفة
  const q = async (b) => Number((await db.sql(`select coalesce(sum(qty_on_hand),0) q from inventory_lots where branch_id=$1 and product_id=$2`, [b, ID.tireBS]))[0].q);
  const [a0, b0] = [await q(ID.tyr), await q(ID.tnt)];
  await expectCode(db.rpc(ID.manager, 'transfer_stock', [uuid(), ID.tnt, ID.tyr, ID.tireBS, 1, null]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.manager, 'transfer_stock', [uuid(), ID.tyr, ID.tnt, ID.tireBS, a0 + 1, null]), 'INSUFFICIENT_STOCK');
  await db.rpc(ID.manager, 'transfer_stock', [uuid(), ID.tyr, ID.tnt, ID.tireBS, 2, 'نقل']);
  assert.deepEqual([await q(ID.tyr), await q(ID.tnt)], [a0 - 2, b0 + 2]);

  // لوحة المالك وتقرير الضريبة
  const today = (await db.sql(`select (now() at time zone 'Asia/Muscat')::date::text d`))[0].d;
  const dash = await db.rpc(ID.owner, 'owner_dashboard', [today, today]);
  assert.equal(dash.branches.length, 2);
  assert.equal(dash.series.length, 7);
  assert.ok(dash.top_products.length > 0 && dash.payables_baisa >= 0 && dash.receivables_baisa !== undefined);
  assert.equal((await db.rpc(ID.cashierTyr, 'owner_dashboard', [today, today])).branches.length, 0, 'الكاشير لا يرى اللوحة');
  const vat = await db.rpc(ID.owner, 'vat_report', [null, today.slice(0, 8) + '01', today]);
  assert.equal(vat.net_tax_baisa, vat.output_tax_baisa - vat.input_tax_baisa);
  assert.ok(vat.input_tax_baisa >= 10100, 'ضريبة مدخلات المشتريات السابقة');

  // المستخدمون: المالك فقط، ودور واحد لكل مستخدم
  await expectCode(db.rpc(ID.manager, 'list_users', [ID.org]), 'FORBIDDEN');
  const users = await db.rpc(ID.owner, 'list_users', [ID.org]);
  assert.equal(users.length, 5);
  await expectCode(db.rpc(ID.owner, 'save_user_role', [{ organization_id: ID.org, user_id: ID.owner, role_code: 'cashier', branch_id: ID.tyr }]), 'CANNOT_CHANGE_SELF');
  await expectCode(db.rpc(ID.owner, 'save_user_role', [{ organization_id: ID.org, user_id: ID.cashierTnt, role_code: 'cashier' }]), 'BRANCH_REQUIRED');
  await db.rpc(ID.owner, 'save_user_role', [{ organization_id: ID.org, user_id: ID.cashierTnt, role_code: 'branch_manager', branch_id: ID.tnt, max_discount_bp: 1500 }]);
  const m = await db.sql(`select role_code, max_discount_bp from memberships where user_id=$1`, [ID.cashierTnt]);
  assert.deepEqual(m.map((x) => [x.role_code, x.max_discount_bp]), [['branch_manager', 1500]]);
});

test('مدير الفرع يضبط ضريبة فرعه فقط، والكاشير لا يضبطها', async () => {
  const r = await db.rpc(ID.manager, 'update_branch_settings', [ID.tyr, { tax_enabled: true, tax_rate_bp: 500, prices_include_tax: true }]);
  assert.deepEqual([r.tax_enabled, r.tax_rate_bp], [true, 500]);
  await expectCode(db.rpc(ID.manager, 'update_branch_settings', [ID.tnt, { tax_enabled: true }]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.cashierTyr, 'update_branch_settings', [ID.tyr, { tax_enabled: false }]), 'FORBIDDEN');
});

test('الإعداد الأول يُقفل بعد وجود منشأة، وتسجيل الأجهزة بصلاحية الإدارة', async () => {
  assert.equal((await db.rpc(ID.cashierTyr, 'setup_status', [])).initialized, true);
  await assert.rejects(db.sql(`select public.bootstrap_organization('{"owner_id":"a0000000-0000-4000-8000-000000000001","owner_name":"x","org_name_ar":"y","branches":[{"code":"AA","name_ar":"z"}]}'::jsonb)`), /ALREADY_INITIALIZED/);
  await expectCode(db.rpc(ID.cashierTyr, 'register_device', ['POS-NEW-01', 'جديد', ID.tyr]), 'FORBIDDEN');
  await expectCode(db.rpc(ID.manager, 'register_device', ['POS-NEW-01', 'جديد', ID.tnt]), 'FORBIDDEN');
  const d = await db.rpc(ID.manager, 'register_device', ['POS-NEW-01', 'صندوق جديد', ID.tyr]);
  assert.equal(d.branch_id, ID.tyr);
  assert.equal((await db.rpc(ID.manager, 'resolve_device', ['POS-NEW-01'])).device.code, 'POS-NEW-01');
  const moved = await db.rpc(ID.owner, 'register_device', ['POS-NEW-01', '', ID.tnt]);
  assert.deepEqual([moved.branch_id, moved.name], [ID.tnt, 'صندوق جديد']);
});
