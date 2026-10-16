-- Синхронизация настроек «Фигурного катания». Выполнить в Supabase: SQL Editor → New query.
-- Файл можно выполнять повторно: функции сохранения пересоздаются (см. ниже).
-- Что здесь есть:
--   1) таблица user_settings — по одной строке на аккаунт; читать и писать свою строку может только
--      её владелец (политика RLS), анонимам таблица закрыта полностью;
--   2) save_settings / load_settings — функции для входа по почте (вызываются с токеном пользователя);
--   3) code_links + link_code — привязка кода к аккаунту: у одного аккаунта настройки одни, а входов в него
--      два (почта и код). Привязанный код работает с документом аккаунта, а не со своей строкой;
--   4) save_settings_by_code / load_settings_by_code — для кода синхронизации: строка ищется по хэшу
--      кода, сам код на сервере не хранится. Доступ — анонимный, поэтому функции помечены
--      SECURITY DEFINER и доступны только через них.
-- Привязка: кто вошёл по почте, привязывает к себе код (link_code). Один код — один аккаунт, у аккаунта
-- не больше одного кода (новая привязка заменяет прежнюю). Документы при привязке сливаются по правилу
-- «побеждает более позднее updated_at», дальше живёт только user_settings.
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

-- привязка кода к аккаунту: code_hash → user_id; код привязан к одному аккаунту, у аккаунта один код
create table if not exists public.code_links (
  code_hash text primary key check (char_length(code_hash) = 64),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  linked_at timestamptz not null default now()
);

alter table public.user_settings enable row level security;
alter table public.code_settings enable row level security;
alter table public.code_links enable row level security;

-- сначала закрываем всё; аккаунту ниже возвращаются права на свою строку (RLS), коду — только функции
revoke all on public.user_settings from anon, authenticated;
revoke all on public.code_settings from anon, authenticated;
revoke all on public.code_links from anon, authenticated;

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
-- без FORCE: функции кода (security definer, владелец таблицы) пишут документ привязанного аккаунта;
-- для anon и authenticated RLS действует как раньше
alter table public.user_settings no force row level security;
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

-- Привязать код к аккаунту вошедшего (auth.uid()). Возвращает updated_at документа аккаунта после
-- слияния (null — документов не было). Ошибки (message — стабильный идентификатор для приложения):
--   not_signed_in — нет входа; bad_code — хэш не того вида; code_taken — код уже привязан к другому аккаунту.
-- Слияние: нет документа аккаунта, а у кода есть — переносится документ кода; есть оба — остаётся тот,
-- у кого updated_at позже (при равенстве — документ аккаунта). Время победившего документа не меняется,
-- поэтому устройства, уже видевшие его, ничего заново не скачивают. Строка code_settings удаляется.
create or replace function public.link_code(code_hash text)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  owner uuid;
  cdoc jsonb;
  cat timestamptz;
  adoc timestamptz;
  result timestamptz;
begin
  if uid is null then
    raise exception 'not_signed_in';
  end if;
  if link_code.code_hash is null or char_length(link_code.code_hash) <> 64 then
    raise exception 'bad_code';
  end if;
  -- записи и привязка одного кода идут по очереди
  perform pg_advisory_xact_lock(hashtext('starty-code:' || link_code.code_hash));

  select l.user_id into owner from public.code_links l where l.code_hash = link_code.code_hash;
  if owner is not null and owner <> uid then
    raise exception 'code_taken';
  end if;

  -- прежняя привязка этого аккаунта к другому коду заменяется
  delete from public.code_links l where l.user_id = uid and l.code_hash <> link_code.code_hash;

  if owner is null then
    select s.doc, s.updated_at into cdoc, cat from public.code_settings s where s.code_hash = link_code.code_hash;
    select s.updated_at into adoc from public.user_settings s where s.user_id = uid;
    if cdoc is not null and (adoc is null or cat > adoc) then
      insert into public.user_settings (user_id, doc, updated_at) values (uid, cdoc, cat)
      on conflict (user_id) do update set doc = excluded.doc, updated_at = excluded.updated_at;
    end if;
    delete from public.code_settings s where s.code_hash = link_code.code_hash;
    insert into public.code_links (code_hash, user_id) values (link_code.code_hash, uid);
  end if;

  select s.updated_at into result from public.user_settings s where s.user_id = uid;
  return result;
end;
$$;

revoke execute on function public.link_code(text) from public, anon;
grant execute on function public.link_code(text) to authenticated;

-- Есть ли у аккаунта привязанный код (сам код на сервере не хранится, только хэш).
create or replace function public.has_code_link()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (select 1 from public.code_links l where l.user_id = auth.uid());
$$;

revoke execute on function public.has_code_link() from public, anon;
grant execute on function public.has_code_link() to authenticated;

-- по коду: привязанный код работает с документом аккаунта, остальные — со своей строкой
drop function if exists public.save_settings_by_code(text, jsonb);
create or replace function public.save_settings_by_code(code_hash text, doc jsonb)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  saved timestamptz;
  uid uuid;
begin
  if char_length(code_hash) <> 64 or jsonb_typeof(doc) <> 'object' or octet_length(doc::text) > 65536 then
    raise exception 'документ не подходит';
  end if;
  perform pg_advisory_xact_lock(hashtext('starty-code:' || save_settings_by_code.code_hash));
  select l.user_id into uid from public.code_links l where l.code_hash = save_settings_by_code.code_hash;
  if uid is not null then
    insert into public.user_settings (user_id, doc, updated_at)
    values (uid, save_settings_by_code.doc, clock_timestamp())
    on conflict (user_id) do update set doc = excluded.doc, updated_at = clock_timestamp()
    returning updated_at into saved;
    return saved;
  end if;
  insert into public.code_settings (code_hash, doc, updated_at)
  values (save_settings_by_code.code_hash, save_settings_by_code.doc, clock_timestamp())
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
  return query
    select s.doc, s.updated_at
    from public.code_links l
    join public.user_settings s on s.user_id = l.user_id
    where l.code_hash = load_settings_by_code.code_hash;
  if found then
    return;
  end if;
  return query select s.doc, s.updated_at from public.code_settings s where s.code_hash = load_settings_by_code.code_hash;
end;
$$;

grant execute on function public.save_settings_by_code(text, jsonb) to anon, authenticated;
grant execute on function public.load_settings_by_code(text) to anon, authenticated;
