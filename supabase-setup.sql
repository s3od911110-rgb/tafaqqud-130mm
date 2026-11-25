-- نفّذ هذا السكربت مرة واحدة داخل Supabase -> SQL Editor
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
