-- ============================================================================
-- راصد | 130مم — النسخة المحصّنة v2.7.0 (RLS + RPC + Realtime + Voice Storage)
-- نفّذ هذا السكربت كاملاً مرة واحدة في Supabase -> SQL Editor
-- ============================================================================
create extension if not exists pgcrypto;

-- 1) جدول اللقطة السحابية الرئيسية (المزامنة التلقائية + منع تضارب الإصدارات)
create table if not exists public.app_snapshots (
  id text primary key default 'primary_130mm',
  payload jsonb not null default '{}'::jsonb,
  revision bigint not null default 1,
  updated_by text,
  updated_at timestamptz not null default now()
);

alter table public.app_snapshots add column if not exists revision bigint not null default 1;
alter table public.app_snapshots add column if not exists updated_by text;

-- 2) جدول الرموز السرية وإعدادات الأمان (محجوب تماماً عن القراءة من المتصفح)
create table if not exists public.app_security_config (
  id text primary key default 'primary_130mm',
  owner_pin_hash text not null,
  supervisor_pin_hash text not null,
  viewer_pin_hash text not null,
  global_block boolean not null default false,
  require_approval boolean not null default false,
  block_message text not null default 'تم حظرك من الوصول للتطبيق بأمر من المالك',
  updated_at timestamptz not null default now()
);

-- الرموز الأولية:
-- • المالك: نفس رمزك الحالي (Hash محفوظ دون تغيير)
-- • المشرف: 2026 (غيّره من الإعدادات فوراً)
-- • المشاهد: 1111 (غيّره من الإعدادات فوراً)
insert into public.app_security_config (id, owner_pin_hash, supervisor_pin_hash, viewer_pin_hash)
values (
  'primary_130mm',
  'a037a7dfaf26abe1265bd5d51447be3bb1fdaef7c4c7a14bcf0d819818fb80b0',
  '158a323a7ba44870f23d96f1516dd70aa48e9a72db4ebb026b0a89e212a208ab',
  '0ffe1abd1a08215353c233d6e009613e95eec4253832a761af28ff37ac5a150c'
) on conflict (id) do nothing;

-- 3) جدول الأجهزة والصلاحيات وموافقات إعدادات المشرف ووضع التخفي للمالك
create table if not exists public.app_devices (
  device_id text primary key,
  display_name text not null default 'مستخدم',
  role text not null check (role in ('VIEWER', 'ADMIN', 'OWNER')),
  status text not null default 'approved' check (status in ('pending', 'approved', 'blocked')),
  settings_access text not null default 'none' check (settings_access in ('none', 'requested', 'approved')),
  is_stealth boolean not null default false,
  block_reason text not null default '',
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now()
);

-- 4) جدول غرفة التواصل الفوري (رسائل نصية + رسائل صوتية)
create table if not exists public.app_chat_messages (
  id bigint generated always as identity primary key,
  sender_device_id text not null,
  sender_name text not null,
  sender_role text not null,
  message_type text not null check (message_type in ('text', 'voice')),
  text_content text,
  audio_url text,
  duration_sec integer not null default 0,
  target_mode text not null default 'ALL',
  targets jsonb not null default '[]'::jsonb,
  priority text not null default 'NORMAL',
  notify boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists idx_chat_created_at on public.app_chat_messages (created_at desc);

-- 5) سجل التدقيق الأمني غير القابل للتعديل (يستثني المالك أثناء وضع التخفي)
create table if not exists public.app_audit_log (
  id bigserial primary key,
  device_id text not null,
  actor_role text not null,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- 6) تفعيل RLS وإزالة أي سياسات مفتوحة خطيرة
alter table public.app_snapshots enable row level security;
alter table public.app_security_config enable row level security;
alter table public.app_devices enable row level security;
alter table public.app_chat_messages enable row level security;
alter table public.app_audit_log enable row level security;

drop policy if exists "allow_snapshot_rw" on public.app_snapshots;
drop policy if exists "allow_read_snapshots" on public.app_snapshots;
create policy "allow_read_snapshots" on public.app_snapshots for select using (true);

drop policy if exists "allow_read_chat" on public.app_chat_messages;
create policy "allow_read_chat" on public.app_chat_messages for select using (true);

drop policy if exists "allow_read_visible_devices" on public.app_devices;
create policy "allow_read_visible_devices" on public.app_devices
  for select using (is_stealth = false);

-- جدولا app_security_config و app_audit_log بدون أي سياسة SELECT للعميل = محميان بالكامل

-- ============================================================================
-- 7) دوال RPC المحصّنة (SECURITY DEFINER)
-- ============================================================================

-- أ) تسجيل الدخول بالرمز وتحديد الدور (مشاهد / مشرف / مالك)
create or replace function public.rpc_login_with_pin(
  p_device_id text,
  p_pin_hash text,
  p_display_name text default '',
  p_requested_role text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg record;
  v_dev record;
  v_role text;
  v_name text;
begin
  select * into v_cfg from public.app_security_config where id = 'primary_130mm';
  select * into v_dev from public.app_devices where device_id = p_device_id;

  if p_pin_hash = v_cfg.owner_pin_hash then
    v_role := 'OWNER';
  elsif p_pin_hash = v_cfg.supervisor_pin_hash then
    v_role := 'ADMIN';
  elsif p_pin_hash = v_cfg.viewer_pin_hash then
    v_role := 'VIEWER';
  else
    return jsonb_build_object('ok', false, 'error', 'INVALID_PIN');
  end if;

  if nullif(trim(p_requested_role), '') is not null and v_role <> upper(trim(p_requested_role)) then
    return jsonb_build_object('ok', false, 'error', 'WRONG_ROLE_TAB');
  end if;

  if v_role <> 'OWNER' then
    if v_cfg.global_block then
      return jsonb_build_object('ok', false, 'error', 'GLOBAL_BLOCK', 'message', v_cfg.block_message);
    end if;
    if v_dev.status = 'blocked' then
      return jsonb_build_object('ok', false, 'error', 'DEVICE_BLOCKED', 'message', coalesce(nullif(v_dev.block_reason, ''), v_cfg.block_message));
    end if;
  end if;

  v_name := nullif(trim(p_display_name), '');
  if v_name is null then
    v_name := coalesce(nullif(v_dev.display_name, ''), case when v_role = 'OWNER' then 'أبو سعيد' when v_role = 'ADMIN' then 'مشرف' else 'مشاهد' end);
  end if;

  insert into public.app_devices (device_id, display_name, role, status, settings_access, is_stealth, last_seen)
  values (
    p_device_id,
    v_name,
    v_role,
    case when v_role = 'OWNER' or not v_cfg.require_approval then 'approved' else coalesce(v_dev.status, 'pending') end,
    case when v_role = 'OWNER' then 'approved' else coalesce(v_dev.settings_access, 'none') end,
    coalesce(v_dev.is_stealth, false),
    now()
  )
  on conflict (device_id) do update
  set display_name = case when nullif(trim(p_display_name), '') is not null then excluded.display_name else app_devices.display_name end,
      role = excluded.role,
      status = case when excluded.role = 'OWNER' then 'approved' when app_devices.status = 'blocked' then 'blocked' when not v_cfg.require_approval then 'approved' else app_devices.status end,
      settings_access = case when excluded.role = 'OWNER' then 'approved' else app_devices.settings_access end,
      last_seen = now()
  returning * into v_dev;

  return jsonb_build_object(
    'ok', true,
    'role', v_dev.role,
    'status', v_dev.status,
    'settings_access', v_dev.settings_access,
    'is_stealth', v_dev.is_stealth,
    'display_name', v_dev.display_name,
    'require_approval', v_cfg.require_approval
  );
end;
$$;

-- ب) فحص حالة الجهاز الحالي دون كشف أي أسرار أو المالك المتخفي
create or replace function public.rpc_check_device_status(p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg record;
  v_dev record;
begin
  select global_block, require_approval, block_message into v_cfg
  from public.app_security_config where id = 'primary_130mm';

  select device_id, display_name, role, status, settings_access, is_stealth, block_reason into v_dev
  from public.app_devices where device_id = p_device_id;

  return jsonb_build_object(
    'ok', true,
    'global_block', coalesce(v_cfg.global_block, false),
    'require_approval', coalesce(v_cfg.require_approval, false),
    'block_message', coalesce(v_cfg.block_message, 'تم حظرك من الوصول للتطبيق بأمر من المالك'),
    'exists', found,
    'role', coalesce(v_dev.role, 'VIEWER'),
    'status', coalesce(v_dev.status, 'pending'),
    'settings_access', coalesce(v_dev.settings_access, 'none'),
    'is_stealth', coalesce(v_dev.is_stealth, false),
    'block_reason', coalesce(v_dev.block_reason, ''),
    'display_name', coalesce(v_dev.display_name, '')
  );
end;
$$;

-- ج) إرسال طلب موافقة جهاز جديد (عند تفعيل اشتراط الموافقة)
create or replace function public.rpc_request_device_approval(
  p_device_id text,
  p_display_name text,
  p_requested_role text default 'VIEWER'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  v_role := case when upper(coalesce(p_requested_role, '')) = 'ADMIN' then 'ADMIN' else 'VIEWER' end;
  insert into public.app_devices (device_id, display_name, role, status, settings_access, last_seen)
  values (p_device_id, coalesce(nullif(trim(p_display_name), ''), 'مستخدم جديد'), v_role, 'pending', 'none', now())
  on conflict (device_id) do update
  set display_name = excluded.display_name,
      role = case when app_devices.role = 'OWNER' then 'OWNER' else excluded.role end,
      status = case when app_devices.status = 'blocked' then 'blocked' when app_devices.status = 'approved' then 'approved' else 'pending' end,
      last_seen = now();
  return jsonb_build_object('ok', true);
end;
$$;

-- د) المزامنة التلقائية للقطة الرئيسية (للمالك والمشرف المعتمد فقط)
create or replace function public.rpc_auto_sync_snapshot(
  p_device_id text,
  p_pin_hash text,
  p_payload jsonb,
  p_expected_revision bigint default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg record;
  v_dev record;
  v_curr_rev bigint;
  v_new_rev bigint;
  v_actor_role text;
begin
  select * into v_cfg from public.app_security_config where id = 'primary_130mm';
  if p_pin_hash = v_cfg.owner_pin_hash then
    v_actor_role := 'OWNER';
  elsif p_pin_hash = v_cfg.supervisor_pin_hash then
    v_actor_role := 'ADMIN';
  else
    return jsonb_build_object('ok', false, 'error', 'UNAUTHORIZED_SYNC');
  end if;

  select * into v_dev from public.app_devices where device_id = p_device_id;
  if v_actor_role <> 'OWNER' and (not found or v_dev.status <> 'approved' or v_cfg.global_block) then
    return jsonb_build_object('ok', false, 'error', 'DEVICE_NOT_APPROVED');
  end if;

  select revision into v_curr_rev from public.app_snapshots where id = 'primary_130mm' for update;

  if v_curr_rev is null then
    insert into public.app_snapshots (id, payload, revision, updated_by, updated_at)
    values ('primary_130mm', p_payload, 1, case when coalesce(v_dev.is_stealth, false) then 'system' else p_device_id end, now())
    returning revision into v_new_rev;
  else
    v_new_rev := v_curr_rev + 1;
    update public.app_snapshots
    set payload = p_payload,
        revision = v_new_rev,
        updated_by = case when coalesce(v_dev.is_stealth, false) then 'system' else p_device_id end,
        updated_at = now()
    where id = 'primary_130mm';
  end if;

  if not coalesce(v_dev.is_stealth, false) then
    insert into public.app_audit_log (device_id, actor_role, action, details)
    values (p_device_id, v_actor_role, 'AUTO_SYNC', jsonb_build_object('revision', v_new_rev));
  end if;

  return jsonb_build_object('ok', true, 'revision', v_new_rev);
end;
$$;

-- هـ) إرسال رسالة شات نصية أو صوتية (للمالك والمشرف)
create or replace function public.rpc_send_chat(
  p_device_id text,
  p_pin_hash text,
  p_sender_name text,
  p_type text,
  p_text text default null,
  p_audio_url text default null,
  p_duration_sec integer default 0,
  p_target_mode text default 'ALL',
  p_targets jsonb default '[]'::jsonb,
  p_priority text default 'NORMAL',
  p_notify boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg record;
  v_dev record;
  v_role text;
  v_row public.app_chat_messages;
begin
  select * into v_cfg from public.app_security_config where id = 'primary_130mm';
  if p_pin_hash = v_cfg.owner_pin_hash then
    v_role := 'OWNER';
  elsif p_pin_hash = v_cfg.supervisor_pin_hash then
    v_role := 'ADMIN';
  else
    return jsonb_build_object('ok', false, 'error', 'UNAUTHORIZED_CHAT');
  end if;

  select * into v_dev from public.app_devices where device_id = p_device_id;
  if v_role <> 'OWNER' and (not found or v_dev.status <> 'approved' or v_cfg.global_block) then
    return jsonb_build_object('ok', false, 'error', 'DEVICE_NOT_APPROVED');
  end if;

  insert into public.app_chat_messages (
    sender_device_id, sender_name, sender_role, message_type,
    text_content, audio_url, duration_sec, target_mode, targets, priority, notify
  ) values (
    p_device_id,
    coalesce(nullif(trim(p_sender_name), ''), coalesce(v_dev.display_name, case when v_role = 'OWNER' then 'أبو سعيد' else 'مشرف' end)),
    v_role,
    case when p_type = 'voice' then 'voice' else 'text' end,
    p_text,
    p_audio_url,
    greatest(0, coalesce(p_duration_sec, 0)),
    coalesce(p_target_mode, 'ALL'),
    coalesce(p_targets, '[]'::jsonb),
    coalesce(p_priority, 'NORMAL'),
    coalesce(p_notify, true)
  ) returning * into v_row;

  return jsonb_build_object('ok', true, 'message', to_jsonb(v_row));
end;
$$;

-- و) مسح الشات لدى الجميع (حصري للمالك)
create or replace function public.rpc_clear_chat(p_owner_pin_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.app_security_config where id = 'primary_130mm' and owner_pin_hash = p_owner_pin_hash) then
    return jsonb_build_object('ok', false, 'error', 'OWNER_ONLY');
  end if;
  delete from public.app_chat_messages where id > 0;
  return jsonb_build_object('ok', true);
end;
$$;

-- ز) طلب المشرف فتح الإعدادات + موافقة/رفض المالك
create or replace function public.rpc_request_settings_access(p_device_id text, p_pin_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_cfg record;
begin
  select * into v_cfg from public.app_security_config where id = 'primary_130mm';
  if p_pin_hash <> v_cfg.supervisor_pin_hash then
    return jsonb_build_object('ok', false, 'error', 'SUPERVISOR_ONLY');
  end if;
  update public.app_devices
  set settings_access = 'requested', last_seen = now()
  where device_id = p_device_id;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.rpc_owner_decide_settings(
  p_owner_pin_hash text,
  p_target_device_id text,
  p_approve boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.app_security_config where id = 'primary_130mm' and owner_pin_hash = p_owner_pin_hash) then
    return jsonb_build_object('ok', false, 'error', 'OWNER_ONLY');
  end if;
  update public.app_devices
  set settings_access = case when p_approve then 'approved' else 'none' end
  where device_id = p_target_device_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- ح) وضع التخفي للمالك فقط (لا يراه أحد)
create or replace function public.rpc_owner_set_stealth(
  p_device_id text,
  p_owner_pin_hash text,
  p_stealth boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.app_security_config where id = 'primary_130mm' and owner_pin_hash = p_owner_pin_hash) then
    return jsonb_build_object('ok', false, 'error', 'OWNER_ONLY');
  end if;
  update public.app_devices set is_stealth = p_stealth, last_seen = now() where device_id = p_device_id;
  return jsonb_build_object('ok', true, 'is_stealth', p_stealth);
end;
$$;

-- ط) تحديث رموز الدخول الثلاثة (المالك / المشرف / المشاهد) حصرياً للمالك
create or replace function public.rpc_owner_update_pins(
  p_owner_pin_hash text,
  p_new_owner_hash text default null,
  p_new_supervisor_hash text default null,
  p_new_viewer_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.app_security_config where id = 'primary_130mm' and owner_pin_hash = p_owner_pin_hash) then
    return jsonb_build_object('ok', false, 'error', 'OWNER_ONLY');
  end if;
  update public.app_security_config
  set owner_pin_hash = coalesce(nullif(p_new_owner_hash, ''), owner_pin_hash),
      supervisor_pin_hash = coalesce(nullif(p_new_supervisor_hash, ''), supervisor_pin_hash),
      viewer_pin_hash = coalesce(nullif(p_new_viewer_hash, ''), viewer_pin_hash),
      updated_at = now()
  where id = 'primary_130mm';
  return jsonb_build_object('ok', true);
end;
$$;

-- ي) لوحة إدارة الأجهزة والحظر والتدقيق (حصرياً للمالك)
create or replace function public.rpc_owner_get_control_state(p_owner_pin_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg record;
  v_devs jsonb;
  v_audit jsonb;
begin
  select * into v_cfg from public.app_security_config where id = 'primary_130mm';
  if p_owner_pin_hash <> v_cfg.owner_pin_hash then
    return jsonb_build_object('ok', false, 'error', 'OWNER_ONLY');
  end if;

  select coalesce(jsonb_agg(to_jsonb(d) order by d.last_seen desc), '[]'::jsonb) into v_devs
  from public.app_devices d;

  select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc), '[]'::jsonb) into v_audit
  from (select id, device_id, actor_role, action, details, created_at from public.app_audit_log order by created_at desc limit 40) a;

  return jsonb_build_object(
    'ok', true,
    'global_block', v_cfg.global_block,
    'require_approval', v_cfg.require_approval,
    'block_message', v_cfg.block_message,
    'devices', v_devs,
    'audit_log', v_audit
  );
end;
$$;

create or replace function public.rpc_owner_manage_device(
  p_owner_pin_hash text,
  p_action text,
  p_target_device_id text default null,
  p_reason text default '',
  p_global_block boolean default null,
  p_block_message text default null,
  p_require_approval boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.app_security_config where id = 'primary_130mm' and owner_pin_hash = p_owner_pin_hash) then
    return jsonb_build_object('ok', false, 'error', 'OWNER_ONLY');
  end if;

  if p_action = 'set_config' then
    update public.app_security_config
    set global_block = coalesce(p_global_block, global_block),
        block_message = coalesce(nullif(p_block_message, ''), block_message),
        require_approval = coalesce(p_require_approval, require_approval),
        updated_at = now()
    where id = 'primary_130mm';
  elsif p_action = 'approve' and p_target_device_id is not null then
    update public.app_devices set status = 'approved', block_reason = '' where device_id = p_target_device_id;
  elsif p_action = 'block' and p_target_device_id is not null then
    insert into public.app_devices (device_id, display_name, role, status, block_reason, last_seen)
    values (p_target_device_id, p_target_device_id, 'VIEWER', 'blocked', coalesce(p_reason, ''), now())
    on conflict (device_id) do update
    set status = 'blocked', block_reason = coalesce(p_reason, ''), settings_access = 'none';
  elsif p_action = 'unblock' and p_target_device_id is not null then
    update public.app_devices set status = 'approved', block_reason = '' where device_id = p_target_device_id;
  elsif p_action = 'delete' and p_target_device_id is not null then
    delete from public.app_devices where device_id = p_target_device_id and role <> 'OWNER';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- 8) تفعيل Realtime للجداول الثلاثة
do $$
begin
  begin alter publication supabase_realtime add table public.app_snapshots; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.app_devices; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.app_chat_messages; exception when duplicate_object then null; end;
end $$;

-- 9) حاوية Storage للرسائل الصوتية (voice-notes)
insert into storage.buckets (id, name, public)
values ('voice-notes', 'voice-notes', true)
on conflict (id) do nothing;

drop policy if exists "voice_notes_read" on storage.objects;
create policy "voice_notes_read" on storage.objects
  for select using (bucket_id = 'voice-notes');

drop policy if exists "voice_notes_insert" on storage.objects;
create policy "voice_notes_insert" on storage.objects
  for insert with check (bucket_id = 'voice-notes');
