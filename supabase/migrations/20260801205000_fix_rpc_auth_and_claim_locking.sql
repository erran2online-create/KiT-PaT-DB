-- Fix 4 RPC auth / locking gaps from function-logic audit.
-- Report-only review: apply to live DB only after explicit approval.
-- Does not alter table structure.

-- ---------------------------------------------------------------------------
-- 1. get_user_plan_limits — caller must be subject user or an admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."get_user_plan_limits"("p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  plan_limits jsonb;
begin
  if auth.uid() is distinct from p_user_id
     and not exists (
       select 1 from public.admins a where a.user_id = auth.uid()
     ) then
    raise exception 'Not authorized to read plan limits for this user';
  end if;

  select p.limits into plan_limits
  from plans p
  join subscriptions s on s.plan_id = p.id
  where s.user_id = p_user_id
    and s.status in ('active', 'trial')
  order by s.created_at desc
  limit 1;

  -- Default to free plan limits if no subscription
  if plan_limits is null then
    select limits into plan_limits
    from plans where slug = 'free';
  end if;

  return plan_limits;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. check_and_award_badges — caller must be subject user or group host
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."check_and_award_badges"("p_user_id" "uuid", "p_group_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  m members%rowtype;
  b badge_definitions%rowtype;
begin
  if auth.uid() is distinct from p_user_id
     and not public.is_group_host(p_group_id, auth.uid()) then
    raise exception 'Not authorized to award badges for this user/group';
  end if;

  select * into m from members
  where user_id = p_user_id and group_id = p_group_id;

  for b in select * from badge_definitions where is_host_assigned = false loop
    -- Skip if already awarded
    continue when exists (
      select 1 from member_badges
      where user_id = p_user_id
        and group_id = p_group_id
        and badge_id = b.id
    );

    -- Check each rule
    if b.auto_rule = 'streak_count >= 12' and m.streak_count >= 12 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'streak_count >= 6' and m.streak_count >= 6 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'tambola_wins >= 3' and m.tambola_wins >= 3 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'rapidfire_wins >= 2' and m.rapidfire_wins >= 2 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'quiz_wins >= 3' and m.quiz_wins >= 3 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'dares_completed >= 10' and m.dares_completed >= 10 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'media_uploads >= 20' and m.media_uploads >= 20 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'hosted_events >= 10' and m.hosted_events >= 10 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'late_count >= 5' and m.late_count >= 5 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'late_count >= 8' and m.late_count >= 8 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'referrals >= 1' and m.referrals >= 1 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'near_wins >= 5' and m.near_wins >= 5 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    elsif b.auto_rule = 'consecutive_wins >= 5' and m.consecutive_wins >= 5 then
      insert into member_badges (user_id, group_id, badge_id)
      values (p_user_id, p_group_id, b.id);

    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. claim_tambola_prize — require group membership + lock prize on raise
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."claim_tambola_prize"("p_ticket_id" "uuid", "p_prize_id" "uuid") RETURNS "public"."game_claims"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  t public.tambola_tickets;
  p public.game_prizes;
  s public.game_sessions;
  c public.game_claims;
  pending_count integer;
begin
  select * into t from public.tambola_tickets where id = p_ticket_id;
  if t.id is null or t.user_id <> auth.uid() then
    raise exception 'Ticket not found';
  end if;

  select * into s from public.game_sessions where id = t.session_id;
  if s.id is null then
    raise exception 'Session not found';
  end if;
  if not public.is_group_member(s.group_id, auth.uid()) then
    raise exception 'Group membership required to claim a prize';
  end if;
  if s.status <> 'active' then
    raise exception 'Game is not active';
  end if;

  -- Serialize concurrent claim raises against the same prize
  select * into p
  from public.game_prizes
  where id = p_prize_id and session_id = t.session_id
  for update;

  if p.id is null or p.is_closed or p.awarded_slots >= p.total_slots then
    raise exception 'Prize unavailable';
  end if;

  select count(*)::integer into pending_count
  from public.game_claims
  where prize_id = p.id and status = 'pending';

  if p.awarded_slots + pending_count >= p.total_slots then
    raise exception 'Prize already has a pending claim for remaining slot(s)';
  end if;

  if exists (
    select 1 from public.game_claims
    where prize_id = p.id and ticket_id = t.id and status = 'pending'
  ) then
    raise exception 'Claim already pending';
  end if;

  insert into public.game_claims(session_id, prize_id, user_id, ticket_id, status, verification_details)
  values (
    t.session_id, p.id, auth.uid(), t.id, 'pending',
    jsonb_build_object('raised_by_player', true)
  )
  returning * into c;

  insert into public.game_events(session_id, event_type, actor_id, payload)
  values (
    t.session_id, 'claim_raised', auth.uid(),
    jsonb_build_object('claim_id', c.id, 'prize_id', p.id, 'user_id', auth.uid())
  );

  return c;
end $$;

-- ---------------------------------------------------------------------------
-- 4. generate_tambola_grid — require authenticated caller
--    (no group_id/session_id parameter available to scope further)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."generate_tambola_grid"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
 col_counts integer[]:=array[1,1,1,1,1,1,1,1,1]; remaining integer:=6;
 row_counts integer[]:=array[0,0,0]; occupied boolean[][]:=array[array[false,false,false,false,false,false,false,false,false],array[false,false,false,false,false,false,false,false,false],array[false,false,false,false,false,false,false,false,false]];
 values_grid integer[][]:=array[array[null,null,null,null,null,null,null,null,null],array[null,null,null,null,null,null,null,null,null],array[null,null,null,null,null,null,null,null,null]];
 c integer; r integer; k integer; val integer; candidates integer[]; pick integer; nums integer[]; row_json jsonb; out_grid jsonb:='[]'::jsonb;
begin
 if auth.uid() is null then
   raise exception 'Authentication required';
 end if;
 while remaining>0 loop c:=1+floor(random()*9)::integer; if col_counts[c]<3 then col_counts[c]:=col_counts[c]+1; remaining:=remaining-1; end if; end loop;
 for c in 1..9 loop
   for k in 1..col_counts[c] loop
     candidates:=array[]::integer[];
     for r in 1..3 loop if row_counts[r]<5 and not occupied[r][c] then candidates:=array_append(candidates,r); end if; end loop;
     if cardinality(candidates)=0 then return public.generate_tambola_grid(); end if;
     pick:=candidates[1+floor(random()*cardinality(candidates))::integer]; occupied[pick][c]:=true; row_counts[pick]:=row_counts[pick]+1;
   end loop;
 end loop;
 if row_counts<>array[5,5,5] then return public.generate_tambola_grid(); end if;
 for c in 1..9 loop
   nums:=array[]::integer[];
   while cardinality(nums)<col_counts[c] loop
     if c=1 then val:=1+floor(random()*9)::integer; elsif c=9 then val:=80+floor(random()*11)::integer; else val:=(c-1)*10+floor(random()*10)::integer; end if;
     if not (val=any(nums)) then nums:=array_append(nums,val); end if;
   end loop;
   select array_agg(x order by x) into nums from unnest(nums) x; k:=1;
   for r in 1..3 loop if occupied[r][c] then values_grid[r][c]:=nums[k]; k:=k+1; end if; end loop;
 end loop;
 for r in 1..3 loop
   row_json:='[]'::jsonb;
   for c in 1..9 loop row_json:=row_json||jsonb_build_array(values_grid[r][c]); end loop;
   out_grid:=out_grid||jsonb_build_array(row_json);
 end loop;
 return out_grid;
end $$;
