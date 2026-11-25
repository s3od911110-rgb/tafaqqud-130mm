-- نفّذ هذا السكربت مرة واحدة داخل Supabase -> SQL Editor
-- 1) جدول المزامنة السحابية لبيانات الكتائب والقوة والتفقد
create table if not exists public.app_snapshots (
  id text primary key,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.app_snapshots enable row level security;

drop policy if exists "allow_snapshot_rw" on public.app_snapshots;
create policy "allow_snapshot_rw"
  on public.app_snapshots
  for all
  using (true)
  with check (true);

-- 2) جدول التحكم بالوصول وحظر التطبيق عن بعد (أفراد / أجهزة / حظر شامل)
create table if not exists public.app_access_control (
  id text primary key,
  global_block boolean not null default false,
  block_message text not null default 'تم حظر الوصول إلى هذا التطبيق من قبل قيادة الكتيبة.',
  blocked_devices jsonb not null default '[]'::jsonb,
  registered_devices jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.app_access_control enable row level security;

drop policy if exists "allow_access_control_rw" on public.app_access_control;
create policy "allow_access_control_rw"
  on public.app_access_control
  for all
  using (true)
  with check (true);

insert into public.app_access_control (id)
values ('primary_130mm')
on conflict (id) do nothing;
