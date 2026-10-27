-- 모여봐요 뱌티의 숲 · Supabase 설정
-- Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여넣고 Run 하세요.
-- 실행 전에 맨 아래 "운영진 코드" 한 줄을 원하는 코드로 바꿔 주세요.

-- 1) 캐릭터 -----------------------------------------------------------------
create table if not exists public.players (
  id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  gen text not null check (gen ~ '^(G|[0-9]{1,2})$'),
  name text not null check (char_length(name) between 1 and 10),
  av jsonb not null check (pg_column_size(av) < 4000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.players enable row level security;
drop policy if exists "players: everyone reads" on public.players;
drop policy if exists "players: insert own" on public.players;
drop policy if exists "players: update own" on public.players;
drop policy if exists "players: delete own" on public.players;
create policy "players: everyone reads" on public.players for select to anon, authenticated using (true);
create policy "players: insert own" on public.players for insert to authenticated with check (id = auth.uid());
create policy "players: update own" on public.players for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "players: delete own" on public.players for delete to authenticated using (id = auth.uid());

-- 2) 1:1 메시지 (보낸 사람과 받은 사람만 볼 수 있음) --------------------------
create table if not exists public.messages (
  id bigint generated always as identity primary key,
  from_id uuid not null default auth.uid() references public.players(id) on delete cascade,
  to_id uuid not null references public.players(id) on delete cascade,
  from_gen text, from_name text, from_av jsonb,
  text text not null check (char_length(text) between 1 and 200),
  created_at timestamptz not null default now()
);
alter table public.messages enable row level security;
drop policy if exists "messages: sender or receiver reads" on public.messages;
drop policy if exists "messages: send as yourself" on public.messages;
create policy "messages: sender or receiver reads" on public.messages for select to authenticated using (to_id = auth.uid() or from_id = auth.uid());
create policy "messages: send as yourself" on public.messages for insert to authenticated with check (from_id = auth.uid());

-- 3) 방명록과 좋아요 ----------------------------------------------------------
create table if not exists public.posts (
  id bigint generated always as identity primary key,
  author uuid default auth.uid() references public.players(id) on delete set null,
  author_gen text, author_name text, author_av jsonb,
  text text not null check (char_length(text) between 1 and 200),
  color text not null default 'yellow' check (color in ('yellow','pink','mint','sky')),
  created_at timestamptz not null default now()
);
alter table public.posts enable row level security;
drop policy if exists "posts: everyone reads" on public.posts;
drop policy if exists "posts: write as yourself" on public.posts;
drop policy if exists "posts: delete own" on public.posts;
create policy "posts: everyone reads" on public.posts for select to anon, authenticated using (true);
create policy "posts: write as yourself" on public.posts for insert to authenticated with check (author = auth.uid());
create policy "posts: delete own" on public.posts for delete to authenticated using (author = auth.uid());

create table if not exists public.post_likes (
  post_id bigint not null references public.posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.players(id) on delete cascade,
  primary key (post_id, user_id)
);
alter table public.post_likes enable row level security;
drop policy if exists "likes: everyone reads" on public.post_likes;
drop policy if exists "likes: add own" on public.post_likes;
drop policy if exists "likes: remove own" on public.post_likes;
create policy "likes: everyone reads" on public.post_likes for select to anon, authenticated using (true);
create policy "likes: add own" on public.post_likes for insert to authenticated with check (user_id = auth.uid());
create policy "likes: remove own" on public.post_likes for delete to authenticated using (user_id = auth.uid());

-- 이름·기수·아바타는 서버가 캐릭터 정보에서 직접 채워 넣어요 (다른 사람인 척 못 하게)
create or replace function public.stamp_from_player() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select gen, name, av into p from public.players where id = auth.uid();
  if p is null then raise exception '캐릭터가 없어요'; end if;
  if tg_table_name = 'posts' then
    new.author := auth.uid(); new.author_gen := p.gen; new.author_name := p.name; new.author_av := p.av;
  else
    new.from_id := auth.uid(); new.from_gen := p.gen; new.from_name := p.name; new.from_av := p.av;
  end if;
  return new;
end $$;
drop trigger if exists posts_stamp on public.posts;
create trigger posts_stamp before insert on public.posts for each row execute function public.stamp_from_player();
drop trigger if exists messages_stamp on public.messages;
create trigger messages_stamp before insert on public.messages for each row execute function public.stamp_from_player();

-- 4) Thanks to 명단 (운영진 코드가 있어야 추가·삭제 가능) ----------------------
create table if not exists public.thanks (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('fund','gift')),
  gen text not null default '' check (char_length(gen) <= 6),
  name text not null check (char_length(name) between 1 and 20),
  what text not null default '' check (char_length(what) <= 40),
  created_at timestamptz not null default now()
);
alter table public.thanks enable row level security;
drop policy if exists "thanks: everyone reads" on public.thanks;
create policy "thanks: everyone reads" on public.thanks for select to anon, authenticated using (true);

create schema if not exists private;
create table if not exists private.admin_code (code text primary key);

create or replace function public.add_thanks(p_code text, p_kind text, p_gen text, p_name text, p_what text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from private.admin_code where code = p_code) then raise exception 'wrong code'; end if;
  insert into public.thanks(kind, gen, name, what) values (p_kind, coalesce(p_gen, ''), p_name, coalesce(p_what, ''));
end $$;
create or replace function public.delete_thanks(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from private.admin_code where code = p_code) then raise exception 'wrong code'; end if;
  delete from public.thanks where id = p_id;
end $$;
revoke all on function public.add_thanks(text, text, text, text, text) from public;
revoke all on function public.delete_thanks(text, bigint) from public;
grant execute on function public.add_thanks(text, text, text, text, text) to anon, authenticated;
grant execute on function public.delete_thanks(text, bigint) to anon, authenticated;

-- 5) 권한과 실시간 -------------------------------------------------------------
grant select on public.players, public.posts, public.post_likes, public.thanks to anon, authenticated;
grant insert, update, delete on public.players to authenticated;
grant select, insert on public.messages to authenticated;
grant insert, delete on public.posts, public.post_likes to authenticated;

do $$
declare t text;
begin
  foreach t in array array['players','messages','posts','post_likes','thanks'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- 6) 운영진 코드: 따옴표 안을 원하는 코드로 바꾼 뒤 실행하세요 -----------------
insert into private.admin_code(code) values ('여기에-운영진-코드') on conflict do nothing;
