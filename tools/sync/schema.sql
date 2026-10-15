-- Синхронизация настроек «Фигурного катания». Выполнить в Supabase: SQL Editor → New query.
-- Файл можно выполнять повторно: функции сохранения пересоздаются (см. ниже).
-- Что здесь есть:
--   1) таблица user_settings — по одной строке на аккаунт; читать и писать свою строку может только
--      её владелец (политика RLS), анонимам таблица закрыта полностью;
--   2) save_settings / load_settings — функции для входа по почте (вызываются с токеном пользователя);
--   3) save_settings_by_code / load_settings_by_code — для кода синхронизации: строка ищется по хэшу
--      кода, сам код на сервере не хранится. Доступ — анонимный, поэтому функции помечены
--      SECURITY DEFINER и доступны только через них.
-- Время сохранения ставит сервер: updated_at = clock_timestamp() при каждой записи. Save-функции
-- возвращают это время, приложение по нему судит о порядке сохранений (часы устройств не участвуют).

create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  doc jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.code_settings (
  code_hash text primary key check (char_length(code_hash) = 64),
  doc jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.user_settings enable row level security;
alter table public.code_settings enable row level security;

-- сначала закрываем всё; аккаунту ниже возвращаются права на свою строку (RLS), коду — только функции
revoke all on public.user_settings from anon, authenticated;
revoke all on public.code_settings from anon, authenticated;

-- ---------------------------------------------------------------- аккаунт

-- тип результата сменился (был void): create or replace его не меняет, поэтому сначала drop
drop function if exists public.save_settings(jsonb);
create or replace function public.save_settings(doc jsonb)
returns timestamptz
language plpgsql
security invoker
set search_path = public
as $$
declare
  saved timestamptz;
begin
  if auth.uid() is null then
    raise exception 'не выполнен вход';
  end if;
  if jsonb_typeof(doc) <> 'object' or octet_length(doc::text) > 65536 then
    raise exception 'документ не подходит';
  end if;
  insert into public.user_settings (user_id, doc, updated_at)
  values (auth.uid(), doc, clock_timestamp())
  on conflict (user_id) do update set doc = excluded.doc, updated_at = clock_timestamp()
  returning updated_at into saved;
  return saved;
end;
$$;

create or replace function public.load_settings()
returns table (doc jsonb, updated_at timestamptz)
language sql
security invoker
set search_path = public
stable
as $$
  select s.doc, s.updated_at from public.user_settings s where s.user_id = auth.uid();
$$;

-- политика на всякий случай: владелец видит и меняет только свою строку
alter table public.user_settings force row level security;
drop policy if exists own_settings on public.user_settings;
create policy own_settings on public.user_settings
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- save_settings/load_settings — SECURITY INVOKER: работают с правами вошедшего, поэтому ему нужны
-- права на таблицу; что он видит и меняет только свою строку, обеспечивает политика выше.
-- anon прав не получает.
grant select, insert, update on public.user_settings to authenticated;

grant execute on function public.save_settings(jsonb) to authenticated;
grant execute on function public.load_settings() to authenticated;

-- ---------------------------------------------------------------- код синхронизации

drop function if exists public.save_settings_by_code(text, jsonb);
create or replace function public.save_settings_by_code(code_hash text, doc jsonb)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  saved timestamptz;
begin
  if char_length(code_hash) <> 64 or jsonb_typeof(doc) <> 'object' or octet_length(doc::text) > 65536 then
    raise exception 'документ не подходит';
  end if;
  insert into public.code_settings (code_hash, doc, updated_at)
  values (code_hash, doc, clock_timestamp())
  -- параметр назван как колонка (это ключ JSON в rpc), поэтому конфликт — по имени ограничения,
  -- иначе PL/pgSQL отвечает «column reference "code_hash" is ambiguous»
  on conflict on constraint code_settings_pkey do update set doc = excluded.doc, updated_at = clock_timestamp()
  returning updated_at into saved;
  return saved;
end;
$$;

create or replace function public.load_settings_by_code(code_hash text)
returns table (doc jsonb, updated_at timestamptz)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if char_length(code_hash) <> 64 then
    return;
  end if;
  return query select s.doc, s.updated_at from public.code_settings s where s.code_hash = load_settings_by_code.code_hash;
end;
$$;

grant execute on function public.save_settings_by_code(text, jsonb) to anon, authenticated;
grant execute on function public.load_settings_by_code(text) to anon, authenticated;
