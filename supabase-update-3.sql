-- 모여봐요 뱌티의 숲 · 업데이트 3 (운영진 초기화)
-- Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여넣고 Run 하세요.
-- 여러 번 실행해도 안전해요. 실행만으로는 아무 데이터도 지워지지 않아요.

-- 운영진 초기화: 운영진 코드가 맞을 때만 동작해요.
--   p_all = false : 광장에 들어온 사람만 모두 내보내요 (방명록, 질문, Thanks to 는 그대로)
--   p_all = true  : 사람, 방명록, 질문·답변, 메시지를 모두 지워요 (Thanks to 명단만 남아요)
create or replace function public.admin_reset(p_code text, p_all boolean default false) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_code is null or p_code = '여기에-운영진-코드'
     or not exists (select 1 from private.admin_code where code = p_code) then
    raise exception 'wrong code';
  end if;
  if coalesce(p_all, false) then
    delete from public.answers where id is not null;
    delete from public.question_votes where question_id is not null;
    delete from public.questions where id is not null;
    delete from public.post_likes where post_id is not null;
    delete from public.posts where id is not null;
    delete from public.messages where id is not null;
  end if;
  delete from public.players where id is not null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.admin_reset(text, boolean) from public;
grant execute on function public.admin_reset(text, boolean) to anon, authenticated;

-- 저장소가 공개라서, 예시로 적어 둔 기본 코드는 쓸 수 없게 지워요.
delete from private.admin_code where code = '여기에-운영진-코드';
