-- 모여봐요 뱌티의 숲 · 업데이트 2 (BITor 카드, 질문 게시판)
-- Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여넣고 Run 하세요.
-- 여러 번 실행해도 안전해요. 기존 데이터는 지워지지 않아요.

-- 1) BITor 카드 뒷면: "BIT에서 가장 기억에 남는 순간" -------------------------
alter table public.players add column if not exists memory text not null default '';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'players_memory_len') then
    alter table public.players add constraint players_memory_len check (char_length(memory) <= 60);
  end if;
end $$;

-- 2) 질문 ------------------------------------------------------------------
-- 질문한 사람은 private 영역에만 기록해서, "기수만 표시"로 올린 질문의 작성자는 아무도 볼 수 없어요.
create table if not exists public.questions (
  id bigint generated always as identity primary key,
  anon boolean not null default false,
  author_gen text, author_name text, author_av jsonb,
  tag text not null default 'etc' check (tag in ('job','grad','startup','club','etc')),
  text text not null check (char_length(text) between 1 and 200),
  created_at timestamptz not null default now()
);
alter table public.questions enable row level security;
drop policy if exists "questions: everyone reads" on public.questions;
create policy "questions: everyone reads" on public.questions for select to anon, authenticated using (true);

create schema if not exists private;
create table if not exists private.question_owner (
  question_id bigint primary key references public.questions(id) on delete cascade,
  owner uuid not null references public.players(id) on delete cascade
);
alter table private.question_owner enable row level security;

create or replace function public.ask_question(p_text text, p_tag text, p_anon boolean) returns bigint
language plpgsql security definer set search_path = public as $$
declare p record; qid bigint;
begin
  select gen, name, av into p from public.players where id = auth.uid();
  if p is null then raise exception '캐릭터가 없어요'; end if;
  insert into public.questions(anon, author_gen, author_name, author_av, tag, text)
  values (coalesce(p_anon, false), p.gen,
          case when coalesce(p_anon, false) then null else p.name end,
          case when coalesce(p_anon, false) then null else p.av end,
          p_tag, p_text)
  returning id into qid;
  insert into private.question_owner(question_id, owner) values (qid, auth.uid());
  return qid;
end $$;

create or replace function public.delete_question(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from private.question_owner where question_id = p_id and owner = auth.uid()) then
    raise exception '내 질문만 지울 수 있어요';
  end if;
  delete from public.questions where id = p_id;
end $$;

create or replace function public.my_questions() returns setof bigint
language sql stable security definer set search_path = public as $$
  select question_id from private.question_owner where owner = auth.uid()
$$;

revoke all on function public.ask_question(text, text, boolean) from public;
revoke all on function public.delete_question(bigint) from public;
revoke all on function public.my_questions() from public;
grant execute on function public.ask_question(text, text, boolean) to authenticated;
grant execute on function public.delete_question(bigint) to authenticated;
grant execute on function public.my_questions() to authenticated;

-- 3) 나도 궁금해요 ------------------------------------------------------------
create table if not exists public.question_votes (
  question_id bigint not null references public.questions(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.players(id) on delete cascade,
  primary key (question_id, user_id)
);
alter table public.question_votes enable row level security;
drop policy if exists "votes: everyone reads" on public.question_votes;
drop policy if exists "votes: add own" on public.question_votes;
drop policy if exists "votes: remove own" on public.question_votes;
create policy "votes: everyone reads" on public.question_votes for select to anon, authenticated using (true);
create policy "votes: add own" on public.question_votes for insert to authenticated with check (user_id = auth.uid());
create policy "votes: remove own" on public.question_votes for delete to authenticated using (user_id = auth.uid());

-- 4) 답변 -------------------------------------------------------------------
create table if not exists public.answers (
  id bigint generated always as identity primary key,
  question_id bigint not null references public.questions(id) on delete cascade,
  author uuid default auth.uid() references public.players(id) on delete set null,
  author_gen text, author_name text, author_av jsonb,
  text text not null check (char_length(text) between 1 and 300),
  created_at timestamptz not null default now()
);
alter table public.answers enable row level security;
drop policy if exists "answers: everyone reads" on public.answers;
drop policy if exists "answers: write as yourself" on public.answers;
drop policy if exists "answers: delete own" on public.answers;
create policy "answers: everyone reads" on public.answers for select to anon, authenticated using (true);
create policy "answers: write as yourself" on public.answers for insert to authenticated with check (author = auth.uid());
create policy "answers: delete own" on public.answers for delete to authenticated using (author = auth.uid());

-- 이름·기수·아바타는 서버가 캐릭터 정보에서 채워 넣어요 (방명록, 메시지, 답변 공통)
create or replace function public.stamp_from_player() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select gen, name, av into p from public.players where id = auth.uid();
  if p is null then raise exception '캐릭터가 없어요'; end if;
  if tg_table_name in ('posts', 'answers') then
    new.author := auth.uid(); new.author_gen := p.gen; new.author_name := p.name; new.author_av := p.av;
  else
    new.from_id := auth.uid(); new.from_gen := p.gen; new.from_name := p.name; new.from_av := p.av;
  end if;
  return new;
end $$;
drop trigger if exists answers_stamp on public.answers;
create trigger answers_stamp before insert on public.answers for each row execute function public.stamp_from_player();

-- 답변이 달리면 질문한 사람 편지함으로 알림
create or replace function public.notify_answer() returns trigger
language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  select owner into o from private.question_owner where question_id = new.question_id;
  if o is not null and o is distinct from new.author then
    insert into public.messages(to_id, text) values (o, left('❓ 내 질문에 답변이 달렸어요: ' || new.text, 200));
  end if;
  return new;
end $$;
drop trigger if exists answers_notify on public.answers;
create trigger answers_notify after insert on public.answers for each row execute function public.notify_answer();

-- 5) 권한과 실시간 -------------------------------------------------------------
grant select on public.questions, public.answers, public.question_votes to anon, authenticated;
grant insert, delete on public.answers, public.question_votes to authenticated;

do $$
declare t text;
begin
  foreach t in array array['questions','answers','question_votes'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
