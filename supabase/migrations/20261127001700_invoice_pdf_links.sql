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
