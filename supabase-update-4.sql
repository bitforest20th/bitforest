-- 모여봐요 뱌티의 숲 · 업데이트 4 (MEMORY LANE 사진 올리기)
-- Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여넣고 Run 하세요.
-- 여러 번 실행해도 안전해요. 기존 데이터는 지워지지 않아요.

-- 1) 사진 파일 보관함 (누구나 볼 수 있고, 한 장에 5MB까지, 사진 형식만) ------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 각자 자기 폴더(내 계정 번호)에만 올리고 지울 수 있어요
drop policy if exists "photos: upload own folder" on storage.objects;
drop policy if exists "photos: delete own files" on storage.objects;
create policy "photos: upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos: delete own files" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- 2) 사진 목록 -------------------------------------------------------------------
create table if not exists public.photos (
  id bigint generated always as identity primary key,
  author uuid default auth.uid() references public.players(id) on delete set null,
  author_gen text, author_name text, author_av jsonb,
  path text not null, thumb text not null,
  caption text not null default '' check (char_length(caption) <= 60),
  created_at timestamptz not null default now()
);
alter table public.photos enable row level security;
drop policy if exists "photos: everyone reads" on public.photos;
drop policy if exists "photos: add as yourself" on public.photos;
drop policy if exists "photos: delete own" on public.photos;
create policy "photos: everyone reads" on public.photos for select to anon, authenticated using (true);
create policy "photos: add as yourself" on public.photos for insert to authenticated with check (author = auth.uid());
create policy "photos: delete own" on public.photos for delete to authenticated using (author = auth.uid());

-- 이름·기수·아바타는 서버가 캐릭터 정보에서 채워 넣어요 (방명록, 답변, 사진, 메시지 공통)
create or replace function public.stamp_from_player() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select gen, name, av into p from public.players where id = auth.uid();
  if p is null then raise exception '캐릭터가 없어요'; end if;
  if tg_table_name in ('posts', 'answers', 'photos') then
    new.author := auth.uid(); new.author_gen := p.gen; new.author_name := p.name; new.author_av := p.av;
  else
    new.from_id := auth.uid(); new.from_gen := p.gen; new.from_name := p.name; new.from_av := p.av;
  end if;
  return new;
end $$;
drop trigger if exists photos_stamp on public.photos;
create trigger photos_stamp before insert on public.photos for each row execute function public.stamp_from_player();

-- 한 사람당 40장까지, 파일은 자기 폴더에 있는 것만
create or replace function public.photos_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.photos where author = auth.uid()) >= 40 then
    raise exception '사진은 한 사람당 40장까지 올릴 수 있어요';
  end if;
  if new.path not like auth.uid()::text || '/%' or new.thumb not like auth.uid()::text || '/%' then
    raise exception 'bad path';
  end if;
  return new;
end $$;
drop trigger if exists photos_guard on public.photos;
create trigger photos_guard before insert on public.photos for each row execute function public.photos_guard();

-- 3) 운영진: 코드 확인, 사진 내리기, 초기화에 사진 포함 ----------------------------
create or replace function public.admin_check(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_code is not null and p_code <> '여기에-운영진-코드' and exists (select 1 from private.admin_code where code = p_code)
$$;
create or replace function public.admin_delete_photo(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.admin_check(p_code) then raise exception 'wrong code'; end if;
  delete from public.photos where id = p_id;
end $$;
create or replace function public.admin_reset(p_code text, p_all boolean default false) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.admin_check(p_code) then raise exception 'wrong code'; end if;
  if coalesce(p_all, false) then
    delete from public.answers where id is not null;
    delete from public.question_votes where question_id is not null;
    delete from public.questions where id is not null;
    delete from public.post_likes where post_id is not null;
    delete from public.posts where id is not null;
    delete from public.messages where id is not null;
    delete from public.photos where id is not null;
  end if;
  delete from public.players where id is not null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.admin_check(text) from public;
revoke all on function public.admin_delete_photo(text, bigint) from public;
revoke all on function public.admin_reset(text, boolean) from public;
grant execute on function public.admin_check(text) to anon, authenticated;
grant execute on function public.admin_delete_photo(text, bigint) to anon, authenticated;
grant execute on function public.admin_reset(text, boolean) to anon, authenticated;

-- 4) 권한과 실시간 -----------------------------------------------------------------
grant select on public.photos to anon, authenticated;
grant insert, delete on public.photos to authenticated;
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'photos') then
    alter publication supabase_realtime add table public.photos;
  end if;
end $$;
