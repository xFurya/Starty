-- Проверка tools/billing/schema.sql на чистом Postgres (без Supabase): заглушки ролей и auth, затем обе
-- схемы и сценарии — первый платёж, продление с напоминанием, отказ, возврат, права.
-- Запуск: bash tools/billing/test/run.sh

\set ON_ERROR_STOP 1
set client_min_messages = warning;
-- проверки молчат; ошибка — в stderr и остановка
\o /dev/null

-- ---------------------------------------------------------------- заглушки Supabase
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text, email_confirmed_at timestamptz);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

\ir ../../sync/schema.sql
\ir ../schema.sql
-- второй раз: файл можно выполнять повторно
\ir ../schema.sql

insert into auth.users values
  ('11111111-1111-1111-1111-111111111111', 'a@example.com', now()),
  ('22222222-2222-2222-2222-222222222222', 'b@example.com', null);

create or replace function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'ПРОВАЛ: %', what; end if;
end $$;

create or replace function pg_temp.fails(sql text, code text) returns void language plpgsql as $$
begin
  execute sql;
  raise exception 'ПРОВАЛ: ждали ошибку % от %', code, sql;
exception when others then
  if sqlerrm not like 'ПРОВАЛ%' and (code is null or sqlerrm = code) then return; end if;
  raise;
end $$;

-- ---------------------------------------------------------------- выключено
select pg_temp.check(public.billing_offer() is null, 'выключено — условий нет');
select pg_temp.fails($$select public.billing_start('11111111-1111-1111-1111-111111111111', 'month', false, 'v1', '', '', '')$$, 'billing_off');

insert into public.billing_plans (id, title, period_days, price_minor, currency, provider, sort, active) values
  ('month', 'Месяц', 30, 14900, 'RUB', 'yookassa', 1, true),
  ('year', 'Год', 365, 129000, 'RUB', 'yookassa', 2, true),
  ('old', 'Старый', 30, 9900, 'RUB', 'yookassa', 3, false);
update public.billing_config set enabled = true;
-- включено, но без условий — всё равно выключено
select pg_temp.check(public.billing_offer() is null, 'без оферты условий нет');
update public.billing_config set offer_url = 'https://example.com/offer', offer_version = 'v1', seller = 'Продавец';

select pg_temp.check(jsonb_array_length(public.billing_offer()->'plans') = 2, 'только активные планы');
select pg_temp.check(public.billing_offer()->'plans'->0->>'id' = 'month', 'порядок по sort');

-- ---------------------------------------------------------------- права
set role anon;
select pg_temp.check(public.billing_offer() is not null, 'аноним видит условия');
select pg_temp.fails($$select * from public.subscriptions$$, null);
select pg_temp.fails($$select public.my_subscription()$$, null);
select pg_temp.fails($$select public.billing_start('11111111-1111-1111-1111-111111111111', 'month', false, 'v1', '', '', '')$$, null);
reset role;

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.fails($$select * from public.billing_payments$$, null);
select pg_temp.fails($$select * from public.billing_events$$, null);
select pg_temp.fails($$select public.billing_paid(gen_random_uuid(), 'x', 1, 'RUB', null, null)$$, null);
select pg_temp.fails($$select public.billing_start('11111111-1111-1111-1111-111111111111', 'month', false, 'v1', '', '', '')$$, null);
select pg_temp.check(public.my_subscription() ? 'now' and not public.my_subscription() ? 'paid_until', 'без подписки — только время');
select pg_temp.check(public.my_payments() = '[]'::jsonb, 'платежей нет');
reset role;
reset request.jwt.claim.sub;

-- ---------------------------------------------------------------- ошибки начала оплаты
select pg_temp.fails($$select public.billing_start('11111111-1111-1111-1111-111111111111', 'month', false, 'v0', '', '', '')$$, 'offer_changed');
select pg_temp.fails($$select public.billing_start('11111111-1111-1111-1111-111111111111', 'old', false, 'v1', '', '', '')$$, 'no_plan');
select pg_temp.fails($$select public.billing_start('22222222-2222-2222-2222-222222222222', 'month', false, 'v1', '', '', '')$$, 'no_email');

-- ---------------------------------------------------------------- первый платёж с согласием на продление
create temp table v (k text primary key, j jsonb);
insert into v select 'start', public.billing_start('11111111-1111-1111-1111-111111111111', 'month', true, 'v1',
  'Продлевать автоматически', '1.2.3.4', 'test');
select pg_temp.check((select j->>'email' from v where k = 'start') = 'a@example.com', 'почта для чека');
select pg_temp.check((select (j->>'amount_minor')::int from v where k = 'start') = 14900, 'сумма из плана');
select pg_temp.check((select count(*) from public.billing_events where kind = 'consent_given' and detail->>'text' = 'Продлевать автоматически') = 1, 'согласие в журнале с текстом');
select public.billing_attach((select (j->>'payment_id')::uuid from v where k = 'start'), 'yk-1');
select pg_temp.check(public.billing_payment_by_provider('yookassa', 'yk-1') = (select (j->>'payment_id')::uuid from v where k = 'start'), 'поиск по номеру сервиса');
select pg_temp.check(public.billing_payment_by_seq((select (j->>'seq')::bigint from v where k = 'start')) = (select (j->>'payment_id')::uuid from v where k = 'start'), 'поиск по номеру счёта');

-- не та сумма — отказ
select pg_temp.fails(format($$select public.billing_paid(%L, 'yk-1', 100, 'RUB', 'tok', 'Карта •• 4242')$$, (select j->>'payment_id' from v where k = 'start')), 'amount_mismatch');
select pg_temp.fails(format($$select public.billing_paid(%L, 'yk-1', 14900, 'BYN', 'tok', 'Карта •• 4242')$$, (select j->>'payment_id' from v where k = 'start')), 'amount_mismatch');

insert into v select 'paid', public.billing_paid((select (j->>'payment_id')::uuid from v where k = 'start'), 'yk-1', 14900, 'RUB', 'tok-1', 'Карта •• 4242');
select pg_temp.check((select paid_until from public.subscriptions) between now() + interval '29 days 23 hours' and now() + interval '30 days 1 hour', 'оплачено на 30 дней');
select pg_temp.check((select auto_renew and method_token = 'tok-1' and consent_version = 'v1' from public.subscriptions), 'продление включено с токеном');
-- повтор уведомления — ничего не меняет
insert into v select 'again', public.billing_paid((select (j->>'payment_id')::uuid from v where k = 'start'), 'yk-1', 14900, 'RUB', 'tok-1', 'Карта •• 4242');
select pg_temp.check((select (j->>'already')::boolean from v where k = 'again'), 'повтор — already');
select pg_temp.check((select count(*) from public.billing_events where kind = 'paid') = 1, 'оплата в журнале один раз');

-- пока срок идёт, второй раз не купить
select pg_temp.fails($$select public.billing_start('11111111-1111-1111-1111-111111111111', 'year', false, 'v1', '', '', '')$$, 'already_active');

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.check((public.my_subscription()->>'auto_renew')::boolean, 'видно: продление включено');
select pg_temp.check(public.my_subscription()->>'method_title' = 'Карта •• 4242', 'видно: карта');
select pg_temp.check((public.my_subscription()->>'renew_minor')::int = 14900, 'видно: сумма продления');
select pg_temp.check((public.my_subscription()->>'refund_minor')::int between 14890 and 14900, 'вернуть можно почти всё');
select pg_temp.check(not (public.my_subscription() ? 'method_token'), 'токен наружу не отдаётся');
select pg_temp.check(jsonb_array_length(public.my_payments()) = 1, 'платёж в истории');
reset role;
reset request.jwt.claim.sub;

-- ---------------------------------------------------------------- напоминание и продление
-- рано: до конца срока больше notice_days
select pg_temp.check((select count(*) from public.billing_notices_due(now())) = 0, 'рано напоминать');
select pg_temp.check((select count(*) from public.billing_notices_due(now() + interval '27 days 1 hour')) = 1, 'за 3 дня — пора');
-- без напоминания не списываем
select pg_temp.check((select count(*) from public.billing_renewals_start(now() + interval '30 days')) = 0, 'без напоминания не списываем');
select public.billing_noticed('11111111-1111-1111-1111-111111111111', (select paid_until from public.subscriptions), 14900);
select pg_temp.check((select count(*) from public.billing_notices_due(now() + interval '27 days 1 hour')) = 0, 'второй раз не напоминаем');
-- напомнили только что — сутки не списываем (часы сервера: notice_at = сейчас)
select pg_temp.check((select count(*) from public.billing_renewals_start(now() + interval '12 hours')) = 0, 'меньше суток после напоминания — ждём');
-- сдвигаем напоминание на трое суток назад, как было бы в жизни
update public.subscriptions set notice_at = now() - interval '3 days', paid_until = now() + interval '30 minutes', notice_for = now() + interval '30 minutes';
insert into v select 'renew', r from public.billing_renewals_start(now()) r;
select pg_temp.check((select j->>'token' from v where k = 'renew') = 'tok-1', 'продление по токену');
select pg_temp.check((select (j->>'amount_minor')::int from v where k = 'renew') = 14900, 'сумма из напоминания');
-- уже есть «ждёт» — второй раз не создаём
select pg_temp.check((select count(*) from public.billing_renewals_start(now())) = 0, 'не дублируем списание');
insert into v select 'renewed', public.billing_paid((select (j->>'payment_id')::uuid from v where k = 'renew'), 'yk-2', 14900, 'RUB', null, null);
select pg_temp.check((select paid_until from public.subscriptions) > now() + interval '30 days', 'продлено от конца срока');
select pg_temp.check((select auto_renew and method_token = 'tok-1' and notice_for is null from public.subscriptions), 'продление осталось, напоминание сброшено');

-- ---------------------------------------------------------------- три неудачи подряд — продление выключается
update public.subscriptions set paid_until = now() + interval '10 minutes', notice_for = now() + interval '10 minutes', notice_at = now() - interval '3 days', notice_minor = 14900;
do $$
declare r jsonb; i int;
begin
  for i in 1..3 loop
    select x into r from public.billing_renewals_start(now()) x;
    perform pg_temp.check(r is not null, 'попытка ' || i);
    perform public.billing_failed((r->>'payment_id')::uuid, 'declined');
  end loop;
end $$;
select pg_temp.check((select not auto_renew and method_token is null from public.subscriptions), 'три неудачи — продление выключено');
select pg_temp.check((select count(*) from public.billing_events where kind = 'consent_withdrawn' and detail->>'reason' = 'charge_failed') = 1, 'отказ записан');

-- ---------------------------------------------------------------- отказ от продления пользователем
update public.subscriptions set auto_renew = true, method_token = 'tok-1', paid_until = now() + interval '20 days';
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select public.cancel_auto_renew();
select pg_temp.check(not (public.my_subscription()->>'auto_renew')::boolean, 'отказ — сразу');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select method_token is null and paid_until > now() from public.subscriptions), 'карта забыта, срок остался');
select pg_temp.check((select count(*) from public.billing_events where kind = 'consent_withdrawn' and detail->>'reason' = 'user') = 1, 'отказ пользователя в журнале');

-- ---------------------------------------------------------------- возврат за неиспользованные дни
-- срок второго платежа: от paid_until прежнего, т. е. ещё не начался — возвращается целиком
create temp table q as select * from public.billing_refund_begin('11111111-1111-1111-1111-111111111111');
select pg_temp.check((select count(*) from q) >= 1, 'есть что вернуть');
select pg_temp.check((select paid_until <= clock_timestamp() and not auto_renew from public.subscriptions), 'начатый возврат сразу закрывает подписку');
select pg_temp.check((select count(*) from public.billing_refund_begin('11111111-1111-1111-1111-111111111111')) = 0, 'второе нажатие — пусто');
do $$
declare r record;
begin
  for r in select * from q loop
    perform public.billing_refunded(r.payment_id, r.amount, false);
  end loop;
end $$;
select pg_temp.check((select paid_until <= now() from public.subscriptions), 'после возврата подписка кончилась');
select pg_temp.check((select count(*) from public.billing_refund_quote('11111111-1111-1111-1111-111111111111', now())) = 0, 'второй раз не вернуть');
select pg_temp.check((select count(*) from public.billing_payments where status = 'refunded') >= 1, 'платёж возвращён');
select pg_temp.check((select count(*) from public.billing_events where kind = 'refund') >= 1, 'возврат в журнале');

-- после конца можно купить снова, без продления
insert into v select 'start2', public.billing_start('11111111-1111-1111-1111-111111111111', 'year', false, 'v1', '', '', '');
select public.billing_paid((select (j->>'payment_id')::uuid from v where k = 'start2'), 'yk-3', 129000, 'RUB', 'tok-2', 'Карта');
select pg_temp.check((select not auto_renew and method_token is null and plan_id = 'year' from public.subscriptions), 'без согласия токен не сохраняется');

-- согласие было, а сервис токен не вернул — продление выключено и это записано
update public.subscriptions set paid_until = now() - interval '1 minute';
insert into v select 'start3', public.billing_start('11111111-1111-1111-1111-111111111111', 'month', true, 'v1', 'Продлевать автоматически', '', '');
select public.billing_paid((select (j->>'payment_id')::uuid from v where k = 'start3'), 'yk-4', 14900, 'RUB', null, null);
select pg_temp.check((select not auto_renew from public.subscriptions), 'нет токена — нет продления');

-- ручной возврат: заявлен — видно «ждёт», владелец вернул и отметил — видно «возвращено»
create temp table q2 as select * from public.billing_refund_begin('11111111-1111-1111-1111-111111111111');
select pg_temp.check((select count(*) from q2) >= 1, 'ручной: есть что вернуть');
select public.billing_refunded(payment_id, amount, true) from q2;
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select set_config('t.pays', public.my_payments()::text, false);
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select bool_and((x->>'refund_pending_minor')::int = q2.amount and (x->>'refunded_minor')::int = 0)
                      from q2 join jsonb_array_elements(current_setting('t.pays')::jsonb) x on x->>'id' = q2.payment_id::text
                      having count(*) = (select count(*) from q2)), 'видно: возврат ждёт');
select public.billing_refunded(payment_id, amount, false) from q2;
select pg_temp.check((select bool_and(p.refund_pending_minor = 0 and p.refunded_minor = q2.amount)
                      from q2 join public.billing_payments p on p.id = q2.payment_id), 'отмечено: возвращено');
select pg_temp.check((select count(*) from public.billing_events where kind = 'consent_withdrawn' and detail->>'reason' = 'no_token') = 1, 'записано, почему');

-- просроченный больше трёх суток — не списываем, продление выключаем
update public.subscriptions set auto_renew = true, method_token = 'tok-3', paid_until = now() - interval '5 days',
  notice_for = now() - interval '5 days', notice_at = now() - interval '8 days', notice_minor = 14900;
select pg_temp.check((select count(*) from public.billing_renewals_start(now())) = 0, 'давно кончилось — не списываем');
select pg_temp.check((select not auto_renew from public.subscriptions), 'и продление выключено');

-- удаление аккаунта: платежи остаются без привязки
delete from auth.users where id = '11111111-1111-1111-1111-111111111111';
select pg_temp.check((select count(*) from public.billing_payments where user_id is null) >= 4, 'платежи остались для учёта');
select pg_temp.check((select count(*) from public.subscriptions) = 0, 'подписка удалена вместе с аккаунтом');

-- ---------------------------------------------------------------- подарочные коды и токен разработчика
insert into auth.users values
  ('33333333-3333-3333-3333-333333333333', 'c@example.com', now()),
  ('44444444-4444-4444-4444-444444444444', 'd@example.com', now());
create temp table codes (k text, code text);
grant select on codes to authenticated, anon;
insert into codes select 'gift', c from public.billing_codes_make('gift', 30, 2, 1, 'друзья', 30, null) c;
insert into codes select 'dev', c from public.billing_codes_make('dev', null, 1, 1, 'разработчик', 7, null) c;
select pg_temp.check((select count(*) from codes where k = 'gift') = 2, 'сделано два подарка');
select pg_temp.check((select bool_and(code ~ '^[0-9A-F]{5}(-[0-9A-F]{5}){3}$') from codes), 'вид кода: 4 по 5 знаков');
select pg_temp.check((select count(distinct code) from codes) = 3, 'коды разные');
select pg_temp.check((select count(*) from public.billing_codes) = 3 and (select bool_and(hash ~ '^[0-9a-f]{64}$') from public.billing_codes),
                     'в таблице только хэши');
select pg_temp.check(not exists (select 1 from public.billing_codes b join codes c on b.hash = c.code), 'самих кодов в таблице нет');
select pg_temp.check(public.billing_code_hash('abcde-12345') = public.billing_code_hash(' ABCDE 12345 '), 'регистр и разделители не важны');
select pg_temp.fails($$select public.billing_codes_make('gift', 0, 1)$$, 'bad_days');
select pg_temp.fails($$select public.billing_codes_make('vip', 1, 1)$$, 'bad_kind');
select pg_temp.fails($$select public.billing_codes_make('gift', 30, 500)$$, 'bad_count');

-- приложению недоступно: сделать коды, увидеть таблицы, ввести без входа
set role anon;
select pg_temp.fails($$select public.redeem_code('x')$$, null);
select pg_temp.fails($$select * from public.billing_codes$$, null);
reset role;
set role authenticated;
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select pg_temp.fails($$select public.billing_codes_make('gift', 30, 1)$$, null);
select pg_temp.fails($$select * from public.billing_codes$$, null);
select pg_temp.fails($$select * from public.billing_redemptions$$, null);
select pg_temp.fails($$select public.dev_make_gifts(30, 1)$$, 'not_dev');

-- неверный код: ответ значением, промах записан
select pg_temp.check(public.redeem_code('00000-00000-00000-00000') = '{"error": "bad_code"}'::jsonb, 'неверный код');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select count(*) from public.billing_events where kind = 'code_failed' and user_id = '33333333-3333-3333-3333-333333333333') = 1,
                     'промах записан в журнал');

-- подарок: срок с сегодняшнего дня, потом второй код поверх
set role authenticated;
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select set_config('t.g1', public.redeem_code((select code from codes where k = 'gift' order by code limit 1))::text, false);
select pg_temp.check(current_setting('t.g1')::jsonb->>'kind' = 'gift' and (current_setting('t.g1')::jsonb->>'days')::int = 30, 'подарок введён');
select pg_temp.check((public.my_subscription()->>'paid_until')::timestamptz between now() + interval '29 days 23 hours' and now() + interval '30 days 1 hour',
                     'срок — 30 дней от сегодня');
select pg_temp.check((public.my_subscription()->>'dev')::boolean = false, 'подарок — не разработчик');
select pg_temp.check((public.my_subscription()->>'refund_minor')::int = 0, 'за подарок возвращать нечего');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select uses_left from public.billing_codes b where b.hash = public.billing_code_hash((select code from codes where k = 'gift' order by code limit 1))) = 0,
                     'код израсходован');

-- тот же код: второй раз тем же человеком и другим человеком — нельзя
set role authenticated;
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select pg_temp.check(public.redeem_code((select code from codes where k = 'gift' order by code limit 1)) = '{"error": "bad_code"}'::jsonb,
                     'использованный код не вводится снова');
reset role;
reset request.jwt.claim.sub;
set role authenticated;
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select pg_temp.check(public.redeem_code((select code from codes where k = 'gift' order by code limit 1)) = '{"error": "bad_code"}'::jsonb,
                     'и другим человеком');
-- второй подарок — другому; а продлевается срок уже оплаченный: ещё 30 дней сверху
select pg_temp.check(public.redeem_code((select code from codes where k = 'gift' order by code desc limit 1))->>'kind' = 'gift', 'второй подарок');
reset role;
reset request.jwt.claim.sub;
set role authenticated;
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
-- подарок со многими вводами и срок действия
reset role;
reset request.jwt.claim.sub;
insert into codes select 'many', c from public.billing_codes_make('gift', 10, 1, 2, 'двое', 30, null) c;
set role authenticated;
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select public.redeem_code((select code from codes where k = 'many'));
select pg_temp.check((public.my_subscription()->>'paid_until')::timestamptz between now() + interval '39 days 23 hours' and now() + interval '40 days 1 hour',
                     'срок прибавляется к оплаченному: 30 + 10 дней');
select pg_temp.check(public.redeem_code((select code from codes where k = 'many')) = '{"error": "already_redeemed"}'::jsonb, 'тот же человек — тот же код один раз');
reset role;
reset request.jwt.claim.sub;
update public.billing_codes set expires_at = now() - interval '1 minute' where kind = 'gift' and uses_left > 0;
set role authenticated;
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select pg_temp.check(public.redeem_code((select code from codes where k = 'many')) = '{"error": "bad_code"}'::jsonb, 'просроченный код не вводится');
reset role;
reset request.jwt.claim.sub;

-- токен разработчика
select pg_temp.check(not exists (select 1 from public.subscriptions where user_id = '44444444-4444-4444-4444-444444444444' and dev), 'пока не разработчик');
update public.billing_config set enabled = false;
set role authenticated;
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select pg_temp.check(public.billing_offer() is null, 'продажа выключена — обычному аккаунту условий нет');
select pg_temp.fails($$select public.dev_make_gifts(7, 1)$$, 'not_dev');
select pg_temp.check(public.redeem_code((select code from codes where k = 'dev'))->>'kind' = 'dev', 'токен введён');
select pg_temp.check((public.my_subscription()->>'dev')::boolean, 'аккаунт — разработчик');
select pg_temp.check(public.billing_offer() is not null and jsonb_array_length(public.billing_offer()->'plans') = 2,
                     'разработчик видит условия и планы, даже пока продажа выключена');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select public.billing_start('44444444-4444-4444-4444-444444444444', 'month', false, 'v1', '', '', '') is not null),
                     'разработчик начинает тестовую оплату при выключенной продаже');
select pg_temp.fails($$select public.billing_start('33333333-3333-3333-3333-333333333333', 'month', false, 'v1', '', '', '')$$, 'billing_off');
-- создание подарков разработчиком: лимиты
set role authenticated;
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select pg_temp.check(jsonb_array_length(public.dev_make_gifts(14, 3, 'из приложения')) = 3, 'разработчик сделал три подарка');
select pg_temp.fails($$select public.dev_make_gifts(14, 21)$$, 'bad_args');
select pg_temp.fails($$select public.dev_make_gifts(400, 1)$$, 'bad_args');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select count(*) from public.billing_codes where made_by = '44444444-4444-4444-4444-444444444444' and days = 14) = 3, 'кто сделал — записано');
-- токен разработчика — один на человека: чужой аккаунт им не станет
insert into auth.users values ('55555555-5555-5555-5555-555555555555', 'e@example.com', now());
set role authenticated;
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select pg_temp.check(public.redeem_code((select code from codes where k = 'dev')) = '{"error": "bad_code"}'::jsonb, 'токен одноразовый');
-- подбор: больше десяти промахов за час — стоп
select public.redeem_code('1111' || g) from generate_series(1, 9) g;
select pg_temp.fails($$select public.redeem_code('2222')$$, 'too_many');
reset role;
reset request.jwt.claim.sub;
select pg_temp.check((select count(*) from public.billing_events where kind in ('gift', 'dev')) >= 4, 'подарки и токен в журнале');

\o
\pset tuples_only on
select 'schema_test: всё прошло';
