-- Подписка «Фигурного катания»: новые удобства поверх бесплатного приложения. Всё, что в приложении есть
-- сейчас, остаётся бесплатным; подписка только добавляет.
-- Выполнить в Supabase (SQL Editor → New query) после tools/sync/schema.sql. Файл можно выполнять повторно.
--
-- Сейчас ВЫКЛЮЧЕНО: billing_config.enabled = false — сервер не отдаёт планы и не принимает оплату, а
-- приложение без --dart-define=BILLING=true экран подписки не показывает и к серверу о ней не ходит.
-- Как включить — ПОДПИСКА.md в корне.
--
-- Что здесь:
--   billing_config    — одна строка: выключатель, оферта (адрес и версия), продавец, за сколько дней напоминать;
--   billing_plans     — планы: срок, цена, валюта и платёжный сервис, который их принимает;
--   subscriptions     — по строке на аккаунт: оплачено до, продлевать ли, сохранённый способ оплаты;
--   billing_payments  — каждый платёж (первый и продления), суммы, возвраты;
--   billing_events    — журнал: согласие на продление, отказ от него, напоминания, списания, возвраты.
--                       Закон требует уметь подтвердить согласие и отказ — здесь они с временем и текстом.
-- Таблицы закрыты всем, кроме владельца функций и service_role. Человек видит своё только через функции
-- my_subscription() и my_payments(), условия — через billing_offer(). Деньгами занимаются функции сервера
-- (tools/billing/supabase/functions) с ключом service_role.
--
-- Ошибки функций — стабильные идентификаторы в message: приложение и функции сервера переводят их в текст.

-- ---------------------------------------------------------------- таблицы

create table if not exists public.billing_config (
  id boolean primary key default true check (id),
  -- главный выключатель: пока false, оплата не предлагается и не принимается, продления не идут
  enabled boolean not null default false,
  -- опубликованная оферта (условия) и её версия: что именно принял человек, пишется в журнал
  offer_url text,
  offer_version text,
  -- кто продаёт — показывается рядом с ценой: «Фамилия Имя Отчество, самозанятый, ИНН …»
  seller text,
  -- за сколько дней до продления напоминать письмом
  notice_days int not null default 3 check (notice_days between 1 and 30),
  updated_at timestamptz not null default now()
);
insert into public.billing_config (id) values (true) on conflict (id) do nothing;

create table if not exists public.billing_plans (
  id text primary key check (id ~ '^[a-z0-9_-]{1,32}$'),
  title text not null,
  period_days int not null check (period_days between 1 and 400),
  -- цена в копейках (рублях × 100) или в копейках белорусского рубля
  price_minor int not null check (price_minor > 0),
  currency text not null check (currency in ('RUB', 'BYN')),
  -- платёжный сервис: yookassa, robokassa, cloudpayments, bepaid (tools/billing/supabase/functions/_shared/providers)
  provider text not null check (provider in ('yookassa', 'robokassa', 'cloudpayments', 'bepaid')),
  sort int not null default 0,
  active boolean not null default false
);

create table if not exists public.subscriptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  plan_id text references public.billing_plans(id),
  paid_until timestamptz,
  auto_renew boolean not null default false,
  provider text,
  -- сохранённый способ оплаты: токен платёжного сервиса (не номер карты); без согласия на продление — null
  method_token text,
  method_title text,
  -- когда и под какой версией условий человек отметил «продлевать автоматически»
  consent_at timestamptz,
  consent_version text,
  -- о продлении какого срока (paid_until) уже напомнили, когда и на какую сумму
  notice_for timestamptz,
  notice_at timestamptz,
  notice_minor int,
  renew_attempts int not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.billing_payments (
  id uuid primary key default gen_random_uuid(),
  -- номер для сервисов, которым нужен целый номер счёта (Робокасса)
  seq bigint generated always as identity unique,
  -- аккаунт удалили — платёж остаётся для учёта, но уже ни с кем не связан
  user_id uuid references auth.users(id) on delete set null,
  plan_id text not null references public.billing_plans(id),
  provider text not null,
  provider_id text,
  kind text not null check (kind in ('first', 'renew')),
  amount_minor int not null check (amount_minor > 0),
  currency text not null,
  status text not null default 'pending' check (status in ('pending', 'succeeded', 'canceled', 'refunded')),
  -- человек согласился на продление: сервис должен сохранить способ оплаты
  save_method boolean not null default false,
  period_from timestamptz,
  period_to timestamptz,
  refunded_minor int not null default 0,
  -- возврат, который владелец делает вручную в кабинете сервиса (у сервиса нет возврата через API):
  -- заявлен, но деньги ещё не ушли. Сделал — billing_refunded(платёж, сумма, false) переносит в refunded_minor
  refund_pending_minor int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists billing_payments_user on public.billing_payments (user_id, created_at desc);

create table if not exists public.billing_events (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  at timestamptz not null default clock_timestamp(),
  -- checkout, consent_given, consent_withdrawn, paid, payment_failed, notice_sent, refund, refund_requested
  kind text not null,
  detail jsonb not null default '{}'::jsonb
);
create index if not exists billing_events_user on public.billing_events (user_id, at desc);

alter table public.billing_config enable row level security;
alter table public.billing_plans enable row level security;
alter table public.subscriptions enable row level security;
alter table public.billing_payments enable row level security;
alter table public.billing_events enable row level security;

revoke all on public.billing_config from anon, authenticated;
revoke all on public.billing_plans from anon, authenticated;
revoke all on public.subscriptions from anon, authenticated;
revoke all on public.billing_payments from anon, authenticated;
revoke all on public.billing_events from anon, authenticated;

-- ---------------------------------------------------------------- для приложения

-- Условия и планы. null — подписка выключена или условия не опубликованы: приложение её не предлагает.
create or replace function public.billing_offer()
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select case when c.enabled and c.offer_url is not null and c.offer_version is not null then
    jsonb_build_object(
      'offer_url', c.offer_url,
      'offer_version', c.offer_version,
      'seller', c.seller,
      'notice_days', c.notice_days,
      'plans', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', p.id, 'title', p.title, 'period_days', p.period_days,
          'price_minor', p.price_minor, 'currency', p.currency
        ) order by p.sort, p.id)
        from public.billing_plans p where p.active
      ), '[]'::jsonb)
    )
  end
  from public.billing_config c;
$$;

-- Сколько вернуть сейчас: по каждому оплаченному сроку — доля его неиспользованных дней (ст. 32 ЗоЗПП:
-- отказ в любой момент с оплатой только использованного). Срок, который ещё не начался, — целиком.
create or replace function public.billing_refund_quote(_uid uuid, _at timestamptz)
returns table (payment_id uuid, provider text, provider_id text, amount int, currency text)
language sql
security definer
set search_path = public
stable
as $$
  select q.id, q.provider, q.provider_id, q.amount, q.currency
  from (
    select p.id, p.provider, p.provider_id, p.currency,
      greatest(0, floor(
        (p.amount_minor - p.refunded_minor)::numeric
        * least(1::numeric, extract(epoch from (p.period_to - greatest(_at, p.period_from)))::numeric
                / nullif(extract(epoch from (p.period_to - p.period_from)), 0)::numeric)
      ))::int as amount
    from public.billing_payments p
    where p.user_id = _uid and p.status = 'succeeded' and p.period_to > _at
  ) q
  where q.amount > 0;
$$;

-- Подписка вошедшего. Без строки — только время сервера (по нему приложение сверяет свои часы).
create or replace function public.my_subscription()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  uid uuid := auth.uid();
  s public.subscriptions;
  p public.billing_plans;
  t timestamptz := clock_timestamp();
  refund int;
begin
  if uid is null then
    raise exception 'not_signed_in';
  end if;
  select * into s from public.subscriptions where user_id = uid;
  if not found then
    return jsonb_build_object('now', t);
  end if;
  select * into p from public.billing_plans where id = s.plan_id;
  select coalesce(sum(q.amount), 0)::int into refund from public.billing_refund_quote(uid, t) q;
  return jsonb_build_object(
    'now', t,
    'plan_id', s.plan_id,
    'plan_title', p.title,
    'paid_until', s.paid_until,
    'auto_renew', s.auto_renew,
    'method_title', s.method_title,
    -- сумма продления: та, что названа в напоминании, а до него — цена плана
    'renew_minor', case when s.auto_renew then coalesce(s.notice_minor, p.price_minor) end,
    'currency', p.currency,
    'refund_minor', refund
  );
end;
$$;

-- Платежи вошедшего, новые сверху. Незавершённые старше суток не показываются: оплату бросили.
create or replace function public.my_payments()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not_signed_in';
  end if;
  return coalesce((
    select jsonb_agg(x.j order by x.created_at desc)
    from (
      select p.created_at, jsonb_build_object(
        'id', p.id, 'at', p.created_at, 'kind', p.kind, 'status', p.status,
        'amount_minor', p.amount_minor, 'refunded_minor', p.refunded_minor,
        'refund_pending_minor', p.refund_pending_minor, 'currency', p.currency,
        'period_to', p.period_to
      ) as j
      from public.billing_payments p
      where p.user_id = uid
        and (p.status <> 'pending' or p.created_at > clock_timestamp() - interval '1 day')
      order by p.created_at desc
      limit 24
    ) x
  ), '[]'::jsonb);
end;
$$;

-- Отказ от автопродления — одной кнопкой, сразу: сохранённый способ оплаты забывается, оплаченный срок
-- остаётся. Запись в журнале — подтверждение отказа.
create or replace function public.cancel_auto_renew()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not_signed_in';
  end if;
  perform public.billing_stop_renew(uid, 'user');
end;
$$;

-- ---------------------------------------------------------------- для функций сервера (service_role)

-- Отключить продление: способ оплаты забыть, в журнал — отказ и причина (user, charge_failed, refund).
create or replace function public.billing_stop_renew(_uid uuid, _reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  was boolean;
begin
  select s.auto_renew or s.method_token is not null into was from public.subscriptions s where s.user_id = _uid for update;
  update public.subscriptions
     set auto_renew = false, method_token = null, method_title = null,
         notice_for = null, notice_at = null, notice_minor = null, updated_at = clock_timestamp()
   where user_id = _uid;
  if coalesce(was, false) then
    insert into public.billing_events (user_id, kind, detail)
    values (_uid, 'consent_withdrawn', jsonb_build_object('reason', _reason));
  end if;
end;
$$;

-- Начать оплату: проверить условия и план, создать платёж «ждёт». Согласие на продление — в журнал с
-- текстом, который видел человек, версией условий, адресом и приложением.
-- Ошибки: billing_off, offer_changed, no_plan, no_email, already_active.
create or replace function public.billing_start(
  _uid uuid, _plan text, _renew boolean, _offer_version text, _consent text, _ip text, _ua text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.billing_config;
  p public.billing_plans;
  s public.subscriptions;
  mail text;
  pid uuid;
  pseq bigint;
  detail jsonb;
begin
  select * into c from public.billing_config where id;
  if not found or not c.enabled or c.offer_url is null or c.offer_version is null then
    raise exception 'billing_off';
  end if;
  if _offer_version is distinct from c.offer_version then
    raise exception 'offer_changed';
  end if;
  select * into p from public.billing_plans where id = _plan and active;
  if not found then
    raise exception 'no_plan';
  end if;
  select u.email into mail from auth.users u where u.id = _uid and u.email_confirmed_at is not null;
  if mail is null or mail = '' then
    raise exception 'no_email';
  end if;
  perform pg_advisory_xact_lock(hashtext('starty-billing:' || _uid::text));
  select * into s from public.subscriptions where user_id = _uid;
  if found and s.paid_until > clock_timestamp() then
    raise exception 'already_active';
  end if;
  insert into public.billing_payments (user_id, plan_id, provider, kind, amount_minor, currency, save_method)
  values (_uid, p.id, p.provider, 'first', p.price_minor, p.currency, coalesce(_renew, false))
  returning id, seq into pid, pseq;
  detail := jsonb_build_object(
    'payment', pid, 'plan', p.id, 'amount_minor', p.price_minor, 'currency', p.currency,
    'auto_renew', coalesce(_renew, false), 'offer_version', c.offer_version, 'ip', _ip, 'ua', _ua
  );
  insert into public.billing_events (user_id, kind, detail) values (_uid, 'checkout', detail);
  if coalesce(_renew, false) then
    insert into public.billing_events (user_id, kind, detail)
    values (_uid, 'consent_given', detail || jsonb_build_object('text', _consent));
  end if;
  return jsonb_build_object(
    'payment_id', pid, 'seq', pseq, 'user_id', _uid, 'email', mail,
    'plan_id', p.id, 'title', p.title, 'period_days', p.period_days,
    'amount_minor', p.price_minor, 'currency', p.currency, 'provider', p.provider,
    'save_method', coalesce(_renew, false)
  );
end;
$$;

-- Номер платежа у сервиса, когда он его выдал.
create or replace function public.billing_attach(_payment uuid, _provider_id text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.billing_payments set provider_id = _provider_id, updated_at = clock_timestamp()
  where id = _payment and provider_id is null;
$$;

-- Платёж по номеру у сервиса — для уведомлений, где нашего номера нет (возврат, отмена).
create or replace function public.billing_payment_by_provider(_provider text, _provider_id text)
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select id from public.billing_payments where provider = _provider and provider_id = _provider_id;
$$;

-- Платёж по номеру счёта (Робокасса).
create or replace function public.billing_payment_by_seq(_seq bigint)
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select id from public.billing_payments where seq = _seq;
$$;

-- Платёж прошёл (подтвердил сервис). Повторное уведомление ничего не меняет. Сумма и валюта сверяются
-- с платежом. Срок продлевается от конца оплаченного (или от сейчас, если он кончился).
-- Первый платёж с согласием на продление: сервис вернул токен — продление включается; не вернул —
-- продлевать нечем, так и остаётся выключенным (и пишется в журнал).
-- Ошибки: no_payment, amount_mismatch.
create or replace function public.billing_paid(
  _payment uuid, _provider_id text, _amount int, _currency text, _token text, _method text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  pay public.billing_payments;
  p public.billing_plans;
  s public.subscriptions;
  t timestamptz := clock_timestamp();
  from_ timestamptz;
  to_ timestamptz;
  consent public.billing_events;
begin
  select * into pay from public.billing_payments where id = _payment;
  if not found then
    raise exception 'no_payment';
  end if;
  if pay.user_id is not null then
    perform pg_advisory_xact_lock(hashtext('starty-billing:' || pay.user_id::text));
  end if;
  select * into pay from public.billing_payments where id = _payment for update;
  if pay.status in ('succeeded', 'refunded') then
    return jsonb_build_object('already', true, 'paid_until', pay.period_to, 'user_id', pay.user_id);
  end if;
  if _amount is distinct from pay.amount_minor or _currency is distinct from pay.currency then
    raise exception 'amount_mismatch';
  end if;
  select * into p from public.billing_plans where id = pay.plan_id;
  select * into s from public.subscriptions where user_id = pay.user_id for update;
  from_ := greatest(t, coalesce(s.paid_until, t));
  to_ := from_ + make_interval(days => p.period_days);
  update public.billing_payments
     set status = 'succeeded', provider_id = coalesce(_provider_id, provider_id),
         period_from = from_, period_to = to_, updated_at = t
   where id = _payment;
  if pay.user_id is null then
    return jsonb_build_object('paid_until', to_, 'user_id', null);
  end if;
  insert into public.subscriptions (user_id, plan_id, paid_until, provider, updated_at)
  values (pay.user_id, pay.plan_id, to_, pay.provider, t)
  on conflict (user_id) do update
    set plan_id = excluded.plan_id, paid_until = excluded.paid_until, provider = excluded.provider,
        renew_attempts = 0, notice_for = null, notice_at = null, notice_minor = null, updated_at = t;
  if pay.kind = 'first' then
    if pay.save_method and coalesce(_token, '') <> '' then
      select * into consent from public.billing_events e
       where e.user_id = pay.user_id and e.kind = 'consent_given' and e.detail->>'payment' = _payment::text
       order by e.at desc limit 1;
      update public.subscriptions
         set auto_renew = true, method_token = _token, method_title = _method,
             consent_at = coalesce(consent.at, t), consent_version = consent.detail->>'offer_version'
       where user_id = pay.user_id;
    else
      update public.subscriptions
         set auto_renew = false, method_token = null, method_title = null
       where user_id = pay.user_id;
      if pay.save_method then
        insert into public.billing_events (user_id, kind, detail)
        values (pay.user_id, 'consent_withdrawn', jsonb_build_object('reason', 'no_token', 'payment', _payment));
      end if;
    end if;
  end if;
  insert into public.billing_events (user_id, kind, detail)
  values (pay.user_id, 'paid', jsonb_build_object(
    'payment', _payment, 'kind', pay.kind, 'amount_minor', _amount, 'currency', _currency,
    'provider_id', _provider_id, 'paid_until', to_
  ));
  return jsonb_build_object('paid_until', to_, 'user_id', pay.user_id);
end;
$$;

-- Платёж не прошёл. Продление, не прошедшее три раза подряд, выключается.
create or replace function public.billing_failed(_payment uuid, _reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  pay public.billing_payments;
  tries int;
begin
  update public.billing_payments set status = 'canceled', updated_at = clock_timestamp()
   where id = _payment and status = 'pending'
  returning * into pay;
  if not found then
    return;
  end if;
  insert into public.billing_events (user_id, kind, detail)
  values (pay.user_id, 'payment_failed', jsonb_build_object('payment', _payment, 'kind', pay.kind, 'reason', _reason));
  if pay.kind = 'renew' and pay.user_id is not null then
    update public.subscriptions set renew_attempts = renew_attempts + 1, updated_at = clock_timestamp()
     where user_id = pay.user_id
    returning renew_attempts into tries;
    if tries >= 3 then
      perform public.billing_stop_renew(pay.user_id, 'charge_failed');
    end if;
  end if;
end;
$$;

-- Возврат по одному платежу прошёл (или принят к ручному возврату — _manual: сумма ждёт в
-- refund_pending_minor). Срок платежа обрезается по сейчас, чтобы его не вернули второй раз.
-- Владелец вернул вручную — тот же вызов с _manual = false переносит сумму из ожидания в возвращённое.
create or replace function public.billing_refunded(_payment uuid, _amount int, _manual boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  pay public.billing_payments;
  t timestamptz := clock_timestamp();
begin
  update public.billing_payments
     set refunded_minor = case when _manual then refunded_minor else refunded_minor + _amount end,
         refund_pending_minor = case when _manual then refund_pending_minor + _amount
                                     else greatest(0, refund_pending_minor - _amount) end,
         status = case when not _manual and refunded_minor + _amount >= amount_minor then 'refunded' else status end,
         period_to = least(period_to, t), period_from = least(period_from, t), updated_at = t
   where id = _payment
  returning * into pay;
  if not found then
    return;
  end if;
  insert into public.billing_events (user_id, kind, detail)
  values (pay.user_id, case when _manual then 'refund_requested' else 'refund' end,
          jsonb_build_object('payment', _payment, 'amount_minor', _amount, 'currency', pay.currency));
end;
$$;

-- Начать возврат: под замком посчитать, что вернуть, и сразу обрезать сроки этих платежей и подписку по
-- сейчас — второй такой же запрос (двойное нажатие) получит пустой список, а не второй возврат.
-- Деньги возвращает функция сервера; итог по каждому платежу — billing_refunded. Вернуть нечего — ничего
-- не меняется.
create or replace function public.billing_refund_begin(_uid uuid)
returns table (payment_id uuid, provider text, provider_id text, amount int, currency text)
language plpgsql
security definer
set search_path = public
as $$
declare
  t timestamptz := clock_timestamp();
begin
  perform pg_advisory_xact_lock(hashtext('starty-billing:' || _uid::text));
  create temp table if not exists billing_refund_rows (
    payment_id uuid, provider text, provider_id text, amount int, currency text
  ) on commit drop;
  delete from billing_refund_rows;
  insert into billing_refund_rows select * from public.billing_refund_quote(_uid, t);
  if not exists (select 1 from billing_refund_rows) then
    return;
  end if;
  update public.billing_payments p
     set period_to = least(p.period_to, t), period_from = least(p.period_from, t), updated_at = t
   where p.user_id = _uid and p.status = 'succeeded' and p.period_to > t;
  insert into public.billing_events (user_id, kind, detail)
  values (_uid, 'refund_started', jsonb_build_object(
    'amount_minor', (select sum(r.amount) from billing_refund_rows r),
    'payments', (select jsonb_agg(r.payment_id) from billing_refund_rows r)
  ));
  perform public.billing_end(_uid, 'refund');
  return query select * from billing_refund_rows;
end;
$$;

-- Подписка кончается сейчас (после возврата): доступ закрыт, продление выключено.
create or replace function public.billing_end(_uid uuid, _reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.billing_stop_renew(_uid, _reason);
  update public.subscriptions set paid_until = least(paid_until, clock_timestamp()), updated_at = clock_timestamp()
   where user_id = _uid;
end;
$$;

-- Кому пора напомнить о продлении: продление включено, до конца срока не больше notice_days, о этом
-- сроке ещё не напоминали. Сумма — цена плана сейчас; она же и спишется.
-- набор столбцов менялся: create or replace другой набор не примет
drop function if exists public.billing_notices_due(timestamptz);
create or replace function public.billing_notices_due(_at timestamptz)
returns table (user_id uuid, email text, paid_until timestamptz, amount int, currency text, plan_title text, method_title text, seller text)
language sql
security definer
set search_path = public
stable
as $$
  select s.user_id, u.email, s.paid_until, p.price_minor, p.currency, p.title, s.method_title, c.seller
  from public.subscriptions s
  join public.billing_plans p on p.id = s.plan_id and p.active
  join auth.users u on u.id = s.user_id
  cross join public.billing_config c
  where c.enabled and s.auto_renew and s.method_token is not null
    and s.paid_until > _at and s.paid_until <= _at + make_interval(days => c.notice_days)
    and s.notice_for is distinct from s.paid_until;
$$;

-- Напоминание ушло: запомнить, о каком сроке и на какую сумму.
create or replace function public.billing_noticed(_uid uuid, _for timestamptz, _amount int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.subscriptions
     set notice_for = _for, notice_at = clock_timestamp(), notice_minor = _amount, updated_at = clock_timestamp()
   where user_id = _uid and paid_until = _for and auto_renew;
  if found then
    insert into public.billing_events (user_id, kind, detail)
    values (_uid, 'notice_sent', jsonb_build_object('for', _for, 'amount_minor', _amount));
  end if;
end;
$$;

-- Продления, которые пора списать, — сразу с созданными платежами «ждёт». Списывается только то, о чём
-- напомнили не меньше суток назад, и ровно названная в напоминании сумма. Срок, кончившийся больше трёх
-- суток назад, не продлевается (продление выключается): списание через неделю после конца — сюрприз.
create or replace function public.billing_renewals_start(_at timestamptz)
returns setof jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  pid uuid;
  pseq bigint;
  parent bigint;
begin
  for r in
    select s.user_id, s.plan_id, s.provider, s.method_token, s.notice_minor, s.paid_until, p.currency, p.title, p.period_days, u.email
    from public.subscriptions s
    join public.billing_plans p on p.id = s.plan_id
    join auth.users u on u.id = s.user_id
    cross join public.billing_config c
    where c.enabled and s.auto_renew and s.method_token is not null
      and s.paid_until <= _at + interval '1 hour'
      and s.notice_for = s.paid_until and s.notice_at <= _at - interval '1 day'
      and not exists (
        select 1 from public.billing_payments x
        where x.user_id = s.user_id and x.kind = 'renew' and x.status = 'pending'
          and x.created_at > _at - interval '1 day'
      )
    for update of s skip locked
  loop
    if r.paid_until < _at - interval '3 days' then
      perform public.billing_stop_renew(r.user_id, 'expired');
      continue;
    end if;
    insert into public.billing_payments (user_id, plan_id, provider, kind, amount_minor, currency, save_method)
    values (r.user_id, r.plan_id, r.provider, 'renew', r.notice_minor, r.currency, true)
    returning id, seq into pid, pseq;
    -- Робокасса продлевает по номеру первого счёта: он и есть «токен»
    parent := case when r.method_token ~ '^[0-9]+$' then r.method_token::bigint end;
    return next jsonb_build_object(
      'payment_id', pid, 'seq', pseq, 'user_id', r.user_id, 'email', r.email,
      'plan_id', r.plan_id, 'title', r.title, 'period_days', r.period_days,
      'amount_minor', r.notice_minor, 'currency', r.currency, 'provider', r.provider,
      'token', r.method_token, 'parent_seq', parent
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------- права

revoke execute on function public.billing_offer() from public;
revoke execute on function public.billing_refund_quote(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function public.my_subscription() from public, anon;
revoke execute on function public.my_payments() from public, anon;
revoke execute on function public.cancel_auto_renew() from public, anon;
revoke execute on function public.billing_stop_renew(uuid, text) from public, anon, authenticated;
revoke execute on function public.billing_start(uuid, text, boolean, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.billing_attach(uuid, text) from public, anon, authenticated;
revoke execute on function public.billing_payment_by_provider(text, text) from public, anon, authenticated;
revoke execute on function public.billing_payment_by_seq(bigint) from public, anon, authenticated;
revoke execute on function public.billing_paid(uuid, text, int, text, text, text) from public, anon, authenticated;
revoke execute on function public.billing_failed(uuid, text) from public, anon, authenticated;
revoke execute on function public.billing_refunded(uuid, int, boolean) from public, anon, authenticated;
revoke execute on function public.billing_end(uuid, text) from public, anon, authenticated;
revoke execute on function public.billing_refund_begin(uuid) from public, anon, authenticated;
revoke execute on function public.billing_notices_due(timestamptz) from public, anon, authenticated;
revoke execute on function public.billing_noticed(uuid, timestamptz, int) from public, anon, authenticated;
revoke execute on function public.billing_renewals_start(timestamptz) from public, anon, authenticated;

grant execute on function public.billing_offer() to anon, authenticated;
grant execute on function public.my_subscription() to authenticated;
grant execute on function public.my_payments() to authenticated;
grant execute on function public.cancel_auto_renew() to authenticated;

grant execute on function public.billing_refund_quote(uuid, timestamptz) to service_role;
grant execute on function public.billing_stop_renew(uuid, text) to service_role;
grant execute on function public.billing_start(uuid, text, boolean, text, text, text, text) to service_role;
grant execute on function public.billing_attach(uuid, text) to service_role;
grant execute on function public.billing_payment_by_provider(text, text) to service_role;
grant execute on function public.billing_payment_by_seq(bigint) to service_role;
grant execute on function public.billing_paid(uuid, text, int, text, text, text) to service_role;
grant execute on function public.billing_failed(uuid, text) to service_role;
grant execute on function public.billing_refunded(uuid, int, boolean) to service_role;
grant execute on function public.billing_end(uuid, text) to service_role;
grant execute on function public.billing_refund_begin(uuid) to service_role;
grant execute on function public.billing_notices_due(timestamptz) to service_role;
grant execute on function public.billing_noticed(uuid, timestamptz, int) to service_role;
grant execute on function public.billing_renewals_start(timestamptz) to service_role;
