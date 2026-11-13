-- =========================================================
-- 번개 산수 : Supabase 설정 SQL
-- Supabase 대시보드 → SQL Editor 에 전체를 붙여넣고 [Run] 한 번만 실행하세요.
-- 다시 실행해도 안전합니다.
-- =========================================================

create extension if not exists pgcrypto;

-- 1) 라운드 기록 테이블 -----------------------------------
create table if not exists public.rounds (
  id           uuid primary key default gen_random_uuid(),
  player_key   text not null check (char_length(player_key) between 8 and 80),
  nick         text not null,
  level        text not null check (level in ('easy','normal','hard')),
  week_id      text not null,                 -- 예: 2026-W46 (한국 시간 기준, 월요일 시작)
  problems     jsonb not null,                -- [{a, op, b}, ...]  (정답은 클라이언트에 안 보냄)
  answers      int[] not null,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  duration_ms  int,                           -- 서버가 잰 기록 (작을수록 좋음)
  wrong_count  int,
  status       text not null default 'playing' check (status in ('playing','done','invalid'))
);
create index if not exists rounds_rank_idx   on public.rounds (week_id, level, status, duration_ms);
create index if not exists rounds_player_idx on public.rounds (player_key, started_at);

-- 플레이어(이름) 테이블: 이름은 대소문자 구분 없이 중복 불가
create table if not exists public.players (
  player_key  text primary key,               -- 8자리 플레이어 코드
  nick        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists players_nick_uniq on public.players (lower(nick));

-- 금칙어: Table Editor에서 직접 단어를 추가/삭제할 수 있어요 (이름에 포함되면 거절)
create table if not exists public.banned_words (word text primary key);
insert into public.banned_words(word) values
  ('시발'),('씨발'),('시바'),('씨바'),('병신'),('븅신'),('개새'),('새끼'),('좆'),('존나'),('졸라'),
  ('미친'),('지랄'),('닥쳐'),('꺼져'),('엿먹'),('섹스'),('야동'),('애미'),('애비'),('느금'),('니미'),
  ('fuck'),('shit'),('bitch'),('sex'),('porn'),('admin'),('관리자'),('운영자')
on conflict do nothing;

-- 테이블은 외부에서 직접 읽기/쓰기 금지. 아래 함수(RPC)로만 접근합니다.
alter table public.rounds       enable row level security;
alter table public.players      enable row level security;
alter table public.banned_words enable row level security;
revoke all on public.rounds, public.players, public.banned_words from anon, authenticated;

-- 2) 도우미 함수 -------------------------------------------
create or replace function public.bm_week() returns text
language sql stable as $$
  select to_char(now() at time zone 'Asia/Seoul', 'IYYY-"W"IW');
$$;

create or replace function public.bm_r(lo int, hi int) returns int
language sql volatile as $$
  select lo + floor(random() * (hi - lo + 1))::int;
$$;

-- 문제 하나 만들기: ok=false 면 조건 불만족(다시 뽑기)
create or replace function public.bm_make(p_level text, p_op text,
  out a int, out b int, out carry boolean, out ok boolean)
language plpgsql volatile as $$
declare q int;
begin
  ok := true; carry := false;
  if p_level = 'easy' then
    if p_op = '+' then
      a := bm_r(1,9); b := bm_r(1,9); carry := a + b >= 10;
    else
      a := bm_r(2,18); b := bm_r(1,9);
      if a - b < 0 then ok := false; return; end if;
      carry := a >= 10 and a % 10 < b;
    end if;
  elsif p_level = 'normal' then
    if p_op = '+' then
      a := bm_r(11,89); b := bm_r(2,9); carry := a % 10 + b >= 10;
    elsif p_op = '-' then
      a := bm_r(11,99); b := bm_r(2,9);
      if a - b < 10 then ok := false; return; end if;
      carry := a % 10 < b;
    elsif p_op = '*' then
      a := bm_r(2,9); b := bm_r(2,9);
    else
      b := bm_r(2,9); q := bm_r(2,9); a := b * q;
    end if;
  else -- hard
    if p_op = '+' then
      a := bm_r(11,79); b := bm_r(11,79);
      if a + b > 99 then ok := false; return; end if;
      carry := a % 10 + b % 10 >= 10;
    elsif p_op = '-' then
      a := bm_r(30,99); b := bm_r(11,89);
      if a - b < 10 then ok := false; return; end if;
      carry := a % 10 < b % 10;
    elsif p_op = '*' then
      a := bm_r(12,39); b := bm_r(2,9);
      if a * b < 40 or a * b > 199 then ok := false; return; end if;
    else
      b := bm_r(3,9); q := bm_r(12,25); a := b * q;
      if a > 199 then ok := false; return; end if;
    end if;
  end if;
end $$;

-- 한 라운드(20문제) 만들기: 유형 순서 고정 + 받아올림/내림 개수 고정
create or replace function public.bm_round(p_level text,
  out problems jsonb, out answers int[])
language plpgsql volatile as $$
declare
  blk record; m record;
  used text[] := '{}';
  need int; left_ int; flag boolean; tries int; key text; ans int;
begin
  problems := '[]'::jsonb; answers := '{}';
  for blk in
    select * from (values
      ('easy','+',10,4,1), ('easy','-',10,4,2),
      ('normal','+',5,3,1), ('normal','-',5,3,2), ('normal','*',5,null,3), ('normal','/',5,null,4),
      ('hard','+',5,3,1),   ('hard','-',5,3,2),   ('hard','*',5,null,3),   ('hard','/',5,null,4)
    ) as t(lv, op, n, k, ord)
    where lv = p_level order by ord
  loop
    need := blk.k; left_ := blk.n;
    for i in 1..blk.n loop
      if blk.k is null then flag := null;
      else flag := random() < need::float / left_; end if;
      tries := 0;
      loop
        tries := tries + 1;
        if tries > 5000 then raise exception 'problem generation failed'; end if;
        select * into m from bm_make(p_level, blk.op);
        continue when not m.ok;
        continue when flag is not null and m.carry <> flag;
        key := m.a || blk.op || m.b;
        continue when key = any(used);
        exit;
      end loop;
      used := used || key;
      ans := case blk.op when '+' then m.a + m.b when '-' then m.a - m.b
                         when '*' then m.a * m.b else m.a / m.b end;
      problems := problems || jsonb_build_object('a', m.a, 'op', blk.op, 'b', m.b);
      answers := answers || ans;
      if flag then need := need - 1; end if;
      left_ := left_ - 1;
    end loop;
  end loop;
end $$;

drop function if exists public.bm_nick(int, int, int);

-- 이름 규칙 검사: 문제가 없으면 null, 있으면 이유 코드
create or replace function public.bm_name_problem(p text) returns text
language plpgsql stable as $$
begin
  if p is null or char_length(p) < 2 or char_length(p) > 10 then return 'length'; end if;
  if p !~ '^[가-힣A-Za-z0-9]+$' then return 'chars'; end if;
  if exists (select 1 from banned_words w where position(lower(w.word) in lower(p)) > 0) then return 'banned'; end if;
  return null;
end $$;

create or replace function public.bm_valid_player(p text) returns boolean
language sql immutable as $$ select p ~ '^[A-HJ-NP-Z2-9]{8}$' $$;

-- 3) 게임에서 부르는 함수 (RPC) ----------------------------

-- (구버전 함수 정리)
drop function if exists public.start_round(text, text, int, int, int);

-- 이름 사용 가능 여부 확인 (입력하는 동안 미리 확인용)
create or replace function public.check_nickname(p_nick text, p_player text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v text := btrim(coalesce(p_nick,'')); prob text;
begin
  prob := bm_name_problem(v);
  if prob is not null then return jsonb_build_object('ok', false, 'reason', prob); end if;
  if exists (select 1 from players where lower(nick) = lower(v) and player_key is distinct from p_player) then
    return jsonb_build_object('ok', false, 'reason', 'taken');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 이름 등록/변경
create or replace function public.set_nickname(p_player text, p_nick text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text := btrim(coalesce(p_nick,'')); prob text;
begin
  if not bm_valid_player(coalesce(p_player,'')) then raise exception 'invalid player'; end if;
  prob := bm_name_problem(v);
  if prob is not null then return jsonb_build_object('ok', false, 'reason', prob); end if;
  if exists (select 1 from players where lower(nick) = lower(v) and player_key <> p_player) then
    return jsonb_build_object('ok', false, 'reason', 'taken');
  end if;
  -- 이름을 너무 자주 바꾸지 못하게 (1분에 1번)
  if exists (select 1 from players where player_key = p_player and nick <> v
               and updated_at > now() - interval '1 minute') then
    return jsonb_build_object('ok', false, 'reason', 'too_often');
  end if;
  insert into players(player_key, nick) values (p_player, v)
  on conflict (player_key) do update set nick = excluded.nick, updated_at = now()
    where players.nick is distinct from excluded.nick;
  return jsonb_build_object('ok', true, 'nick', v);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'reason', 'taken');
end $$;

-- 코드로 내 이름 찾기 (다른 기기에서 이어하기)
create or replace function public.get_player(p_player text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('nick', nick) from players where player_key = p_player;
$$;

-- 라운드 시작: 문제만 돌려주고, 정답과 시작 시각은 서버에 보관
create or replace function public.start_round(p_level text, p_player text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_nick text; g record; v_id uuid;
begin
  if p_level not in ('easy','normal','hard') then raise exception 'invalid level'; end if;
  select nick into v_nick from players where player_key = p_player;
  if v_nick is null then raise exception 'no nickname'; end if;

  -- 너무 자주 시작하면 거절 (1분에 12판까지)
  if (select count(*) from rounds where player_key = p_player
        and started_at > now() - interval '1 minute') >= 12 then
    raise exception 'too many rounds, slow down';
  end if;

  select * into g from bm_round(p_level);
  insert into rounds(player_key, nick, level, week_id, problems, answers)
  values (p_player, v_nick, p_level, bm_week(), g.problems, g.answers)
  returning id into v_id;

  return jsonb_build_object('round_id', v_id, 'problems', g.problems, 'week_id', bm_week());
end $$;

-- 라운드 끝: 답 확인 + 서버 시각으로 기록 계산
create or replace function public.finish_round(p_round uuid, p_answers int[], p_wrong int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r rounds%rowtype; v_ms int; v_prev int; v_rank int; v_total int;
begin
  select * into r from rounds where id = p_round for update;
  if not found or r.status <> 'playing' then
    return jsonb_build_object('status','invalid','reason','unknown_round');
  end if;

  v_ms := round(extract(epoch from (now() - r.started_at)) * 1000);

  if p_answers is distinct from r.answers then
    update rounds set status='invalid', finished_at=now(), duration_ms=v_ms where id = r.id;
    return jsonb_build_object('status','invalid','reason','wrong_answers');
  end if;
  if v_ms < array_length(r.answers,1) * 350 or v_ms > 30*60*1000 then
    update rounds set status='invalid', finished_at=now(), duration_ms=v_ms where id = r.id;
    return jsonb_build_object('status','invalid','reason','time', 'duration_ms', v_ms);
  end if;

  select min(duration_ms) into v_prev from rounds
   where player_key = r.player_key and level = r.level and week_id = r.week_id and status = 'done';

  update rounds set status='done', finished_at=now(), duration_ms=v_ms,
         wrong_count = greatest(0, least(coalesce(p_wrong,0), 999))
   where id = r.id;

  with best as (
    select player_key, min(duration_ms) ms from rounds
     where week_id = r.week_id and level = r.level and status = 'done'
     group by player_key)
  select count(*) filter (where ms < least(v_ms, coalesce(v_prev, v_ms))) + 1, count(*)
    into v_rank, v_total from best;

  return jsonb_build_object('status','done','duration_ms', v_ms,
    'prev_best', v_prev, 'improved', v_prev is null or v_ms < v_prev,
    'rank', v_rank, 'total', v_total, 'week_id', r.week_id);
end $$;

-- 이번 주 랭킹: 상위 20명 + 내 순위
create or replace function public.get_leaderboard(p_level text, p_player text default null)
returns table(rank bigint, nick text, best_ms int, wrong int, is_me boolean, total bigint)
language sql stable security definer set search_path = public as $$
  with best as (
    select distinct on (player_key) player_key, nick, duration_ms, wrong_count, finished_at
      from rounds
     where week_id = bm_week() and level = p_level and status = 'done'
     order by player_key, duration_ms, finished_at
  ), ranked as (
    select row_number() over (order by duration_ms, finished_at) rk,
           count(*) over () cnt, *
      from best
  )
  select rk, coalesce((select p.nick from players p where p.player_key = ranked.player_key), ranked.nick),
         duration_ms, wrong_count, (player_key = p_player), cnt
    from ranked
   where rk <= 20 or player_key = p_player
   order by rk;
$$;

-- 4) 권한: 게임에서 부르는 함수만 공개 ----------------------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.start_round(text, text)               to anon, authenticated;
grant execute on function public.check_nickname(text, text)            to anon, authenticated;
grant execute on function public.set_nickname(text, text)              to anon, authenticated;
grant execute on function public.get_player(text)                      to anon, authenticated;
grant execute on function public.finish_round(uuid, int[], int)        to anon, authenticated;
grant execute on function public.get_leaderboard(text, text)           to anon, authenticated;

-- (선택) 오늘 테스트하면서 쌓인 기록을 지우고 깨끗하게 시작하려면 아래 줄 맨 앞의 -- 를 지우고 실행하세요.
-- delete from public.rounds;
