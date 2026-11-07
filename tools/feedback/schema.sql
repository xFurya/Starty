-- Обратная связь «Фигурного катания»: ошибки, идеи и прочее — прямо из приложения (Настройки → Обратная
-- связь, ссылка «Сообщить об ошибке» в карточке старта и в профиле спортсмена).
-- Выполнить в Supabase: SQL Editor → New query → вставить файл → Run. Файл можно выполнять повторно.
--
-- Читать: Table Editor → feedback (новые сверху — сортировка по created_at). Разобранное отметить done = true.
--
-- Что здесь:
--   feedback       — сообщения. Таблица закрыта всем (RLS без политик): ни прочитать, ни записать напрямую
--                    из приложения нельзя, ни анонимно, ни из аккаунта. Видно только в панели Supabase;
--   send_feedback  — единственный вход: проверяет и записывает одно сообщение, возвращает его номер.
--                    SECURITY DEFINER, доступна анонимно.
-- Защита от потока: одинаковое сообщение за 10 минут не записывается второй раз (повторное нажатие после
-- «Сервер не отвечает» возвращает тот же номер); больше 60 сообщений за 10 минут от всех вместе сервер
-- не принимает — feedback_busy.
--
-- Ошибки — стабильные идентификаторы в message, приложение переводит их в текст (app/lib/feedback.dart):
--   bad_kind, empty_message, long_message, feedback_busy.

create table if not exists public.feedback (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  -- bug — ошибка, idea — идея, other — другое
  kind text not null check (kind in ('bug', 'idea', 'other')),
  message text not null check (char_length(message) between 1 and 4000),
  -- почта или Telegram, если человек хочет ответа; необязательно
  contact text check (char_length(contact) <= 200),
  -- к чему относится: start:<id старта> или profile:<имя>; пусто — из настроек
  about text check (char_length(about) <= 300),
  -- версия и номер сборки: 1.0.63+64
  app_version text check (char_length(app_version) <= 40),
  -- android, ios, windows, macos, web
  platform text check (char_length(platform) <= 20),
  -- разобрано: отмечать вручную в Table Editor
  done boolean not null default false
);

create index if not exists feedback_created_at on public.feedback (created_at desc);

alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;

create or replace function public.send_feedback(
  kind text,
  message text,
  contact text default null,
  about text default null,
  app_version text default null,
  platform text default null
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  k text := lower(btrim(coalesce(send_feedback.kind, '')));
  m text := btrim(coalesce(send_feedback.message, ''));
  c text := nullif(btrim(coalesce(send_feedback.contact, '')), '');
  a text := nullif(btrim(coalesce(send_feedback.about, '')), '');
  v text := nullif(btrim(coalesce(send_feedback.app_version, '')), '');
  p text := nullif(lower(btrim(coalesce(send_feedback.platform, ''))), '');
  n bigint;
begin
  if k not in ('bug', 'idea', 'other') then
    raise exception 'bad_kind' using errcode = '22023';
  end if;
  if m = '' then
    raise exception 'empty_message' using errcode = '22023';
  end if;
  if char_length(m) > 4000 then
    raise exception 'long_message' using errcode = '22023';
  end if;

  -- то же сообщение только что уже пришло (повтор после обрыва связи) — тот же номер
  select f.id into n from public.feedback f
   where f.message = m and f.kind = k and f.contact is not distinct from left(c, 200)
     and f.created_at > now() - interval '10 minutes'
   order by f.id desc limit 1;
  if n is not null then
    return n;
  end if;

  if (select count(*) from public.feedback f where f.created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'feedback_busy' using errcode = '22023';
  end if;

  insert into public.feedback (kind, message, contact, about, app_version, platform)
  values (k, m, left(c, 200), left(a, 300), left(v, 40), left(p, 20))
  returning id into n;
  return n;
end;
$$;

revoke all on function public.send_feedback(text, text, text, text, text, text) from public;
grant execute on function public.send_feedback(text, text, text, text, text, text) to anon, authenticated;

-- PostgREST должен увидеть новую функцию сразу, а не после перезапуска
notify pgrst, 'reload schema';
