--
-- PostgreSQL database dump
--

-- \restrict eU2ycP2YXXGkqJyAPZ61mQe0fPi9CcWWfKNgFqKBEtH974oPBSeb0FRNcPieP08

-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: SCHEMA "public"; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA "public" IS 'standard public schema';


--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";


--
-- Name: EXTENSION "pg_stat_statements"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "pg_stat_statements" IS 'track planning and execution statistics of all SQL statements executed';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";


--
-- Name: EXTENSION "pgcrypto"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "pgcrypto" IS 'cryptographic functions';


--
-- Name: supabase_vault; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";


--
-- Name: EXTENSION "supabase_vault"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "supabase_vault" IS 'Supabase Vault Extension';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: assign_free_plan_on_signup(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."assign_free_plan_on_signup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  free_plan_id uuid;
begin
  select id into free_plan_id from plans where slug = 'free';

  insert into subscriptions (
    user_id, plan_id, status,
    billing_cycle, started_at, expires_at
  ) values (
    new.id, free_plan_id, 'active',
    'monthly', now(), null
  );

  update users set current_plan_id = free_plan_id
  where id = new.id;

  return new;
end;
$$;


ALTER FUNCTION "public"."assign_free_plan_on_signup"() OWNER TO "postgres";

--
-- Name: check_and_award_badges("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."check_and_award_badges"("p_user_id" "uuid", "p_group_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  m members%rowtype;
  b badge_definitions%rowtype;
begin
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


ALTER FUNCTION "public"."check_and_award_badges"("p_user_id" "uuid", "p_group_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";

--
-- Name: game_claims; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."game_claims" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "prize_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "ticket_id" "uuid",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "verification_details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "claimed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "verified_at" timestamp with time zone,
    "verified_by" "uuid",
    CONSTRAINT "game_claims_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'rejected'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."game_claims" OWNER TO "postgres";

--
-- Name: claim_tambola_prize("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."claim_tambola_prize"("p_ticket_id" "uuid", "p_prize_id" "uuid") RETURNS "public"."game_claims"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare t public.tambola_tickets; p public.game_prizes; s public.game_sessions; c public.game_claims;
begin
 select * into t from public.tambola_tickets where id=p_ticket_id;
 if t.id is null or t.user_id<>auth.uid() then raise exception 'Ticket not found'; end if;
 select * into p from public.game_prizes where id=p_prize_id and session_id=t.session_id;
 if p.id is null or p.is_closed or p.awarded_slots>=p.total_slots then raise exception 'Prize unavailable'; end if;
 select * into s from public.game_sessions where id=t.session_id;
 if s.status<>'active' then raise exception 'Game is not active'; end if;
 if exists(select 1 from public.game_claims where prize_id=p.id and ticket_id=t.id and status='pending') then raise exception 'Claim already pending'; end if;
 insert into public.game_claims(session_id,prize_id,user_id,ticket_id,status,verification_details)
 values(t.session_id,p.id,auth.uid(),t.id,'pending',jsonb_build_object('raised_by_player',true)) returning * into c;
 insert into public.game_events(session_id,event_type,actor_id,payload) values(t.session_id,'claim_raised',auth.uid(),jsonb_build_object('claim_id',c.id,'prize_id',p.id,'user_id',auth.uid()));
 return c;
end $$;


ALTER FUNCTION "public"."claim_tambola_prize"("p_ticket_id" "uuid", "p_prize_id" "uuid") OWNER TO "postgres";

--
-- Name: ensure_host_membership(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."ensure_host_membership"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
 insert into public.members(group_id,user_id,role,joined_at) values(new.id,new.host_id,'host',now()) on conflict(group_id,user_id) do update set role='host';
 return new;
end $$;


ALTER FUNCTION "public"."ensure_host_membership"() OWNER TO "postgres";

--
-- Name: generate_tambola_grid(); Type: FUNCTION; Schema: public; Owner: postgres
--

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


ALTER FUNCTION "public"."generate_tambola_grid"() OWNER TO "postgres";

--
-- Name: get_user_plan_limits("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."get_user_plan_limits"("p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  plan_limits jsonb;
begin
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


ALTER FUNCTION "public"."get_user_plan_limits"("p_user_id" "uuid") OWNER TO "postgres";

--
-- Name: host_call_tambola_number("uuid", integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."host_call_tambola_number"("p_session_id" "uuid", "p_number" integer DEFAULT NULL::integer) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare s public.game_sessions; available integer[]; chosen integer;
begin
 select * into s from public.game_sessions where id=p_session_id for update;
 if s.id is null or s.game_type<>'tambola' or not public.is_group_host(s.group_id,auth.uid()) then raise exception 'Host access required'; end if;
 if s.status<>'active' then raise exception 'Session is not active'; end if;
 if cardinality(s.called_numbers)>=90 then raise exception 'All numbers have been called'; end if;
 if p_number is not null then
   if s.play_mode<>'manual' then raise exception 'Manual number selection disabled in automatic mode'; end if;
   if p_number<1 or p_number>90 or p_number=any(s.called_numbers) then raise exception 'Invalid or already called number'; end if;
   chosen:=p_number;
 else
   select array_agg(x) into available from generate_series(1,90) x where not (x=any(s.called_numbers));
   chosen:=available[1+floor(random()*cardinality(available))::integer];
 end if;
 update public.game_sessions set current_number=chosen,called_numbers=array_append(called_numbers,chosen),next_auto_draw_at=case when play_mode='automatic' then now()+make_interval(secs=>draw_interval_seconds) else null end,updated_at=now() where id=p_session_id;
 insert into public.game_events(session_id,event_type,actor_id,payload) values(p_session_id,'number_called',auth.uid(),jsonb_build_object('number',chosen));
 return chosen;
end $$;


ALTER FUNCTION "public"."host_call_tambola_number"("p_session_id" "uuid", "p_number" integer) OWNER TO "postgres";

--
-- Name: host_check_tambola_claim("uuid", boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."host_check_tambola_claim"("p_claim_id" "uuid", "p_force_reject" boolean DEFAULT false) RETURNS "public"."game_claims"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare c public.game_claims; t public.tambola_tickets; p public.game_prizes; s public.game_sessions; valid boolean; slot integer;
begin
 select * into c from public.game_claims where id=p_claim_id for update;
 if c.id is null or c.status<>'pending' then raise exception 'Pending claim not found'; end if;
 select * into s from public.game_sessions where id=c.session_id;
 if not public.is_group_host(s.group_id,auth.uid()) then raise exception 'Host access required'; end if;
 select * into t from public.tambola_tickets where id=c.ticket_id;
 select * into p from public.game_prizes where id=c.prize_id for update;
 valid:=not p_force_reject and not p.is_closed and p.awarded_slots<p.total_slots and public.tambola_pattern_matches(t.grid,t.marked_numbers,p.prize_type);
 if valid then
   slot:=p.awarded_slots+1;
   update public.game_claims set status='verified',verification_details=verification_details||jsonb_build_object('slot',slot,'server_verified',true),verified_at=now(),verified_by=auth.uid() where id=c.id returning * into c;
   update public.game_prizes set awarded_slots=awarded_slots+1,is_closed=(awarded_slots+1>=total_slots) where id=p.id;
   insert into public.game_events(session_id,event_type,actor_id,payload) values(c.session_id,'claim_verified',auth.uid(),jsonb_build_object('claim_id',c.id,'prize_id',p.id,'winner_id',c.user_id,'slot',slot));
 else
   update public.game_claims set status='rejected',verification_details=verification_details||jsonb_build_object('server_verified',true,'reason',case when p_force_reject then 'host_rejected' else 'pattern_incomplete_or_prize_closed' end),verified_at=now(),verified_by=auth.uid() where id=c.id returning * into c;
   insert into public.game_events(session_id,event_type,actor_id,payload) values(c.session_id,'claim_rejected',auth.uid(),jsonb_build_object('claim_id',c.id,'prize_id',p.id,'user_id',c.user_id));
 end if;
 return c;
end $$;


ALTER FUNCTION "public"."host_check_tambola_claim"("p_claim_id" "uuid", "p_force_reject" boolean) OWNER TO "postgres";

--
-- Name: host_create_tambola_session("uuid", "text", "text", "jsonb"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."host_create_tambola_session"("p_event_id" "uuid", "p_variant" "text" DEFAULT 'classic'::"text", "p_play_mode" "text" DEFAULT 'manual'::"text", "p_prizes" "jsonb" DEFAULT NULL::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare e public.events; sid uuid; pack jsonb; defs jsonb; item jsonb; prize text; slots integer; interval_s integer;
begin
 if p_variant not in ('classic','quick_10','bollywood','kitty_special') then raise exception 'Unsupported Tambola variant'; end if;
 if p_play_mode not in ('manual','automatic') then raise exception 'Unsupported play mode'; end if;
 select * into e from public.events where id=p_event_id; if e.id is null or not public.is_group_host(e.group_id,auth.uid()) then raise exception 'Host access required'; end if;
 select content into pack from public.game_theme_packs where game_key='tambola' and theme_key=p_variant and locale='en-IN' and is_active limit 1;
 interval_s:=coalesce((pack->>'default_interval_seconds')::integer,8);
 insert into public.game_sessions(event_id,group_id,game_type,variant,play_mode,status,host_id,config,draw_interval_seconds) values(e.id,e.group_id,'tambola',p_variant,p_play_mode,'lobby',auth.uid(),jsonb_build_object('theme_key',p_variant),interval_s) returning id into sid;
 defs:=p_prizes;
 if defs is null then
   select jsonb_agg(jsonb_build_object('type',x,'slots',1)) into defs from jsonb_array_elements_text(pack->'default_prizes') x;
 end if;
 for item in select * from jsonb_array_elements(defs) loop
   prize:=item->>'type'; slots:=greatest(1,least(100,coalesce((item->>'slots')::integer,1)));
   if prize not in ('early_five','top_line','middle_line','bottom_line','corners','full_house') then raise exception 'Unsupported prize %',prize; end if;
   insert into public.game_prizes(session_id,prize_type,display_name,total_slots,sort_order) values(sid,prize,initcap(replace(prize,'_',' ')),slots,(select count(*) from public.game_prizes where session_id=sid)+1);
 end loop;
 insert into public.game_events(session_id,event_type,actor_id,payload) values(sid,'session_created',auth.uid(),jsonb_build_object('variant',p_variant,'play_mode',p_play_mode)); return sid;
end $$;


ALTER FUNCTION "public"."host_create_tambola_session"("p_event_id" "uuid", "p_variant" "text", "p_play_mode" "text", "p_prizes" "jsonb") OWNER TO "postgres";

--
-- Name: host_distribute_tambola_tickets("uuid", "uuid"[], integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."host_distribute_tambola_tickets"("p_session_id" "uuid", "p_user_ids" "uuid"[] DEFAULT NULL::"uuid"[], "p_tickets_each" integer DEFAULT 1) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare s public.game_sessions; uid uuid; ticket_no integer; made integer:=0; i integer; targets uuid[];
begin
 select * into s from public.game_sessions where id=p_session_id for update;
 if s.id is null or s.game_type<>'tambola' or not public.is_group_host(s.group_id,auth.uid()) then raise exception 'Host access required'; end if;
 if s.status<>'lobby' then raise exception 'Tickets can only be distributed in lobby'; end if;
 if p_tickets_each<1 or p_tickets_each>6 then raise exception 'Tickets per player must be 1-6'; end if;
 if p_user_ids is null then select array_agg(user_id) into targets from public.members where group_id=s.group_id;
 else targets:=p_user_ids; end if;
 select coalesce(max(t.ticket_no),0) into ticket_no from public.tambola_tickets t where t.session_id=p_session_id;
 foreach uid in array coalesce(targets,array[]::uuid[]) loop
   if not public.is_group_member(s.group_id,uid) then raise exception 'Selected user is not a group member'; end if;
   insert into public.game_players(session_id,user_id,status) values(p_session_id,uid,'joined') on conflict(session_id,user_id) do update set status='joined';
   for i in 1..p_tickets_each loop
     ticket_no:=ticket_no+1;
     insert into public.tambola_tickets(session_id,user_id,ticket_no,grid) values(p_session_id,uid,ticket_no,public.generate_tambola_grid());
     made:=made+1;
   end loop;
 end loop;
 insert into public.game_events(session_id,event_type,actor_id,payload) values(p_session_id,'tickets_distributed',auth.uid(),jsonb_build_object('count',made));
 return made;
end $$;


ALTER FUNCTION "public"."host_distribute_tambola_tickets"("p_session_id" "uuid", "p_user_ids" "uuid"[], "p_tickets_each" integer) OWNER TO "postgres";

--
-- Name: game_sessions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."game_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "game_id" "uuid",
    "event_id" "uuid" NOT NULL,
    "group_id" "uuid" NOT NULL,
    "game_type" "text" NOT NULL,
    "variant" "text" DEFAULT 'classic'::"text" NOT NULL,
    "play_mode" "text" DEFAULT 'manual'::"text" NOT NULL,
    "status" "text" DEFAULT 'lobby'::"text" NOT NULL,
    "host_id" "uuid" NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "current_round" integer DEFAULT 1 NOT NULL,
    "current_number" integer,
    "called_numbers" integer[] DEFAULT '{}'::integer[] NOT NULL,
    "started_at" timestamp with time zone,
    "ended_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "draw_interval_seconds" integer DEFAULT 8 NOT NULL,
    "next_auto_draw_at" timestamp with time zone,
    CONSTRAINT "game_sessions_draw_interval_seconds_check" CHECK ((("draw_interval_seconds" >= 3) AND ("draw_interval_seconds" <= 60))),
    CONSTRAINT "game_sessions_play_mode_check" CHECK (("play_mode" = ANY (ARRAY['manual'::"text", 'automatic'::"text"]))),
    CONSTRAINT "game_sessions_status_check" CHECK (("status" = ANY (ARRAY['lobby'::"text", 'active'::"text", 'paused'::"text", 'completed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."game_sessions" OWNER TO "postgres";

--
-- Name: TABLE "game_sessions"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."game_sessions" IS 'Authoritative live session state shared by all KiT-PaT games.';


--
-- Name: COLUMN "game_sessions"."variant"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."game_sessions"."variant" IS 'Tambola: classic, quick_10, bollywood, kitty_special; extensible for other games.';


--
-- Name: COLUMN "game_sessions"."play_mode"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."game_sessions"."play_mode" IS 'manual lets host choose/call numbers; automatic lets server choose numbers.';


--
-- Name: host_pause_tambola("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."host_pause_tambola"("p_session_id" "uuid") RETURNS "public"."game_sessions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare s public.game_sessions;
begin
 select * into s from public.game_sessions where id=p_session_id for update;
 if s.id is null or not public.is_group_host(s.group_id,auth.uid()) then raise exception 'Host access required'; end if;
 if s.status <> 'active' then raise exception 'Only active session can be paused'; end if;
 update public.game_sessions set status='paused',next_auto_draw_at=null,updated_at=now() where id=p_session_id returning * into s;
 insert into public.game_events(session_id,event_type,actor_id) values(p_session_id,'session_paused',auth.uid()); return s;
end $$;


ALTER FUNCTION "public"."host_pause_tambola"("p_session_id" "uuid") OWNER TO "postgres";

--
-- Name: host_start_tambola("uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."host_start_tambola"("p_session_id" "uuid") RETURNS "public"."game_sessions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare s public.game_sessions;
begin
 select * into s from public.game_sessions where id=p_session_id for update;
 if s.id is null or s.game_type <> 'tambola' then raise exception 'Tambola session not found'; end if;
 if not public.is_group_host(s.group_id,auth.uid()) then raise exception 'Host access required'; end if;
 if s.status not in ('lobby','paused') then raise exception 'Session cannot be started from %',s.status; end if;
 update public.game_sessions set status='active',started_at=coalesce(started_at,now()),next_auto_draw_at=case when play_mode='automatic' then now() else null end,updated_at=now() where id=p_session_id returning * into s;
 insert into public.game_events(session_id,event_type,actor_id,payload) values(p_session_id,'session_started',auth.uid(),jsonb_build_object('mode',s.play_mode));
 return s;
end $$;


ALTER FUNCTION "public"."host_start_tambola"("p_session_id" "uuid") OWNER TO "postgres";

--
-- Name: is_group_host("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."is_group_host"("p_group_id" "uuid", "p_user_id" "uuid" DEFAULT "auth"."uid"()) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$ select exists(select 1 from public.groups g where g.id=p_group_id and g.host_id=p_user_id); $$;


ALTER FUNCTION "public"."is_group_host"("p_group_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";

--
-- Name: is_group_member("uuid", "uuid"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."is_group_member"("p_group_id" "uuid", "p_user_id" "uuid" DEFAULT "auth"."uid"()) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$ select exists(select 1 from public.members m where m.group_id=p_group_id and m.user_id=p_user_id); $$;


ALTER FUNCTION "public"."is_group_member"("p_group_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";

--
-- Name: tambola_tickets; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."tambola_tickets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "ticket_no" integer NOT NULL,
    "grid" "jsonb" NOT NULL,
    "marked_numbers" integer[] DEFAULT '{}'::integer[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."tambola_tickets" OWNER TO "postgres";

--
-- Name: mark_tambola_number("uuid", integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."mark_tambola_number"("p_ticket_id" "uuid", "p_number" integer) RETURNS "public"."tambola_tickets"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare t public.tambola_tickets; s public.game_sessions; exists_on_ticket boolean;
begin
 select * into t from public.tambola_tickets where id=p_ticket_id for update;
 if t.id is null or t.user_id<>auth.uid() then raise exception 'Ticket not found'; end if;
 select * into s from public.game_sessions where id=t.session_id;
 if s.status<>'active' or not (p_number=any(s.called_numbers)) then raise exception 'Number has not been called'; end if;
 select exists(select 1 from jsonb_array_elements(t.grid) rr, jsonb_array_elements(rr) cc where cc<>'null'::jsonb and (cc#>>'{}')::integer=p_number) into exists_on_ticket;
 if not exists_on_ticket then raise exception 'Number is not on ticket'; end if;
 if not (p_number=any(t.marked_numbers)) then update public.tambola_tickets set marked_numbers=array_append(marked_numbers,p_number) where id=p_ticket_id returning * into t; end if;
 return t;
end $$;


ALTER FUNCTION "public"."mark_tambola_number"("p_ticket_id" "uuid", "p_number" integer) OWNER TO "postgres";

--
-- Name: tambola_pattern_matches("jsonb", integer[], "text"); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."tambola_pattern_matches"("p_grid" "jsonb", "p_marked" integer[], "p_pattern" "text") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare vals integer[]; topv integer[]; midv integer[]; botv integer[]; corners integer[]; allv integer[]; cnt integer;
begin
 select array_agg((v#>>'{}')::integer) into topv from jsonb_array_elements(p_grid->0) v where v<>'null'::jsonb;
 select array_agg((v#>>'{}')::integer) into midv from jsonb_array_elements(p_grid->1) v where v<>'null'::jsonb;
 select array_agg((v#>>'{}')::integer) into botv from jsonb_array_elements(p_grid->2) v where v<>'null'::jsonb;
 allv:=coalesce(topv,array[]::integer[])||coalesce(midv,array[]::integer[])||coalesce(botv,array[]::integer[]);
 select count(*) into cnt from unnest(allv) x where x=any(p_marked);
 if p_pattern in ('early_five','early5') then return cnt>=5;
 elsif p_pattern='top_line' then return not exists(select 1 from unnest(topv) x where not (x=any(p_marked)));
 elsif p_pattern='middle_line' then return not exists(select 1 from unnest(midv) x where not (x=any(p_marked)));
 elsif p_pattern='bottom_line' then return not exists(select 1 from unnest(botv) x where not (x=any(p_marked)));
 elsif p_pattern='full_house' then return cnt=15;
 elsif p_pattern='corners' then
   corners:=array[topv[1],topv[cardinality(topv)],botv[1],botv[cardinality(botv)]];
   return not exists(select 1 from unnest(corners) x where not (x=any(p_marked)));
 else return false; end if;
end $$;


ALTER FUNCTION "public"."tambola_pattern_matches"("p_grid" "jsonb", "p_marked" integer[], "p_pattern" "text") OWNER TO "postgres";

--
-- Name: update_updated_at(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE OR REPLACE FUNCTION "public"."update_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."update_updated_at"() OWNER TO "postgres";

--
-- Name: admin_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."admin_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin_id" "uuid",
    "action" "text" NOT NULL,
    "target_table" "text",
    "target_id" "uuid",
    "old_value" "jsonb",
    "new_value" "jsonb",
    "ip_address" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."admin_logs" OWNER TO "postgres";

--
-- Name: admins; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."admins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "role" "text" DEFAULT 'admin'::"text",
    "permissions" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid",
    CONSTRAINT "admins_role_check" CHECK (("role" = ANY (ARRAY['superadmin'::"text", 'admin'::"text", 'support'::"text"])))
);


ALTER TABLE "public"."admins" OWNER TO "postgres";

--
-- Name: ai_cache; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."ai_cache" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cache_key" "text" NOT NULL,
    "output_text" "text" NOT NULL,
    "model" "text" DEFAULT 'gpt-4o-mini'::"text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ai_cache" OWNER TO "postgres";

--
-- Name: analytics_event_catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."analytics_event_catalog" (
    "event_name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "description" "text" NOT NULL,
    "required_properties" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "contains_pii" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."analytics_event_catalog" OWNER TO "postgres";

--
-- Name: app_config; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."app_config" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."app_config" OWNER TO "postgres";

--
-- Name: attendance; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."attendance" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "checked_in_at" timestamp with time zone DEFAULT "now"(),
    "was_late" boolean DEFAULT false
);


ALTER TABLE "public"."attendance" OWNER TO "postgres";

--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."audit_events" (
    "id" bigint NOT NULL,
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid",
    "group_id" "uuid",
    "event_id" "uuid",
    "session_id" "uuid",
    "event_name" "text" NOT NULL,
    "source" "text" DEFAULT 'app'::"text" NOT NULL,
    "request_id" "text",
    "properties" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."audit_events" OWNER TO "postgres";

--
-- Name: TABLE "audit_events"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."audit_events" IS 'Server-side operational/audit trail. Never store secrets, OTP values or raw payment credentials.';


--
-- Name: audit_events_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE "public"."audit_events" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."audit_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: badge_definitions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."badge_definitions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "emoji" "text",
    "category" "text",
    "auto_rule" "text",
    "is_host_assigned" boolean DEFAULT false,
    CONSTRAINT "badge_definitions_category_check" CHECK (("category" = ANY (ARRAY['attendance'::"text", 'games'::"text", 'social'::"text", 'host'::"text", 'funny'::"text"])))
);


ALTER TABLE "public"."badge_definitions" OWNER TO "postgres";

--
-- Name: comments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" bigint NOT NULL,
    "platform" "text",
    "post_title" "text",
    "post_url" "text",
    "comment_text" "text",
    "commenter_name" "text",
    "reply_short" "text",
    "reply_insightful" "text",
    "reply_bold" "text",
    "priority" "text",
    "intent" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."comments" OWNER TO "postgres";

--
-- Name: comments_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE "public"."comments" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."comments_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_id" "uuid" NOT NULL,
    "theme" "text",
    "party_date" timestamp with time zone,
    "venue" "text",
    "venue_address" "text",
    "contribution_amount" integer,
    "status" "text" DEFAULT 'draft'::"text",
    "summary_card_template" integer DEFAULT 1,
    "invite_text" "text",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "content_locale" "text",
    CONSTRAINT "events_status_check" CHECK ((("status" IS NULL) OR ("status" = ANY (ARRAY['draft'::"text", 'scheduled'::"text", 'live'::"text", 'completed'::"text", 'cancelled'::"text"]))))
);


ALTER TABLE "public"."events" OWNER TO "postgres";

--
-- Name: expenses; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."expenses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid",
    "group_id" "uuid",
    "added_by" "uuid",
    "amount" integer NOT NULL,
    "description" "text",
    "category" "text" DEFAULT 'other'::"text",
    "bill_photo_url" "text",
    "bill_data" "jsonb",
    "vendor_name" "text",
    "bill_date" "date",
    "source" "text" DEFAULT 'manual'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "expenses_category_check" CHECK (("category" = ANY (ARRAY['food'::"text", 'venue'::"text", 'decoration'::"text", 'games'::"text", 'gifts'::"text", 'other'::"text"]))),
    CONSTRAINT "expenses_source_check" CHECK (("source" = ANY (ARRAY['manual'::"text", 'ocr'::"text", 'restaurant_qr'::"text"])))
);


ALTER TABLE "public"."expenses" OWNER TO "postgres";

--
-- Name: fcm_tokens; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."fcm_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "token" "text" NOT NULL,
    "device_type" "text" DEFAULT 'web'::"text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."fcm_tokens" OWNER TO "postgres";

--
-- Name: feature_flags; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."feature_flags" (
    "key" "text" NOT NULL,
    "label" "text" NOT NULL,
    "description" "text",
    "is_enabled" boolean DEFAULT false,
    "category" "text",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "updated_by" "uuid"
);


ALTER TABLE "public"."feature_flags" OWNER TO "postgres";

--
-- Name: game_actions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."game_actions" (
    "id" bigint NOT NULL,
    "session_id" "uuid" NOT NULL,
    "round_id" "uuid",
    "user_id" "uuid" NOT NULL,
    "action_type" "text" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "server_score" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."game_actions" OWNER TO "postgres";

--
-- Name: game_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_actions" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."game_actions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: game_catalog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."game_catalog" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "game_key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "engine_type" "text" NOT NULL,
    "min_players" integer DEFAULT 2 NOT NULL,
    "max_players" integer,
    "supports_teams" boolean DEFAULT false NOT NULL,
    "supports_themes" boolean DEFAULT true NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."game_catalog" OWNER TO "postgres";

--
-- Name: game_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."game_events" (
    "id" bigint NOT NULL,
    "session_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "actor_id" "uuid",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."game_events" OWNER TO "postgres";

--
-- Name: game_events_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_events" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."game_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: game_players; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."game_players" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'joined'::"text" NOT NULL,
    "score" integer DEFAULT 0 NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "game_players_status_check" CHECK (("status" = ANY (ARRAY['invited'::"text", 'joined'::"text", 'left'::"text", 'disqualified'::"text"])))
);


ALTER TABLE "public"."game_players" OWNER TO "postgres";

--
-- Name: game_prizes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."game_prizes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "prize_type" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "total_slots" integer DEFAULT 1 NOT NULL,
    "awarded_slots" integer DEFAULT 0 NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_closed" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "game_prizes_awarded_slots_check" CHECK (("awarded_slots" >= 0)),
    CONSTRAINT "game_prizes_total_slots_check" CHECK ((("total_slots" >= 1) AND ("total_slots" <= 100)))
);


ALTER TABLE "public"."game_prizes" OWNER TO "postgres";

--
-- Name: COLUMN "game_prizes"."total_slots"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."game_prizes"."total_slots" IS 'Host-configurable number of winners for a pattern, e.g. 4 Early Five or 8 Top Line.';


--
-- Name: game_rounds; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."game_rounds" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "session_id" "uuid" NOT NULL,
    "round_no" integer NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "prompt" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "answer" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "started_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    CONSTRAINT "game_rounds_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'completed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."game_rounds" OWNER TO "postgres";

--
-- Name: game_theme_packs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."game_theme_packs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "game_key" "text" NOT NULL,
    "theme_key" "text" NOT NULL,
    "locale" "text" DEFAULT 'en-IN'::"text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "rules_text" "text" NOT NULL,
    "content" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "presentation" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."game_theme_packs" OWNER TO "postgres";

--
-- Name: games; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."games" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid",
    "game_type" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "winner_ids" "uuid"[] DEFAULT '{}'::"uuid"[],
    "scores" "jsonb" DEFAULT '{}'::"jsonb",
    "config" "jsonb" DEFAULT '{}'::"jsonb",
    "started_at" timestamp with time zone,
    "ended_at" timestamp with time zone,
    CONSTRAINT "games_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'done'::"text"])))
);


ALTER TABLE "public"."games" OWNER TO "postgres";

--
-- Name: groups; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."groups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "host_id" "uuid" NOT NULL,
    "ai_personality" "text" DEFAULT 'bollywood'::"text",
    "group_title" "text",
    "badge_emoji" "text" DEFAULT '👑'::"text",
    "description" "text",
    "invite_code" "text" DEFAULT "substr"("md5"(("random"())::"text"), 1, 8),
    "telegram_group_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "default_locale" "text" DEFAULT 'en-IN'::"text",
    CONSTRAINT "groups_ai_personality_check" CHECK (("ai_personality" = ANY (ARRAY['bollywood'::"text", 'luxury'::"text", 'savage'::"text", 'sweet'::"text"])))
);


ALTER TABLE "public"."groups" OWNER TO "postgres";

--
-- Name: invite_templates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."invite_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tone" "text" NOT NULL,
    "festival_tag" "text" DEFAULT 'general'::"text",
    "template_text" "text" NOT NULL,
    "variables" "text"[],
    CONSTRAINT "invite_templates_tone_check" CHECK (("tone" = ANY (ARRAY['bollywood'::"text", 'luxury'::"text", 'savage'::"text", 'sweet'::"text"])))
);


ALTER TABLE "public"."invite_templates" OWNER TO "postgres";

--
-- Name: languages; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."languages" (
    "code" "text" NOT NULL,
    "name_english" "text" NOT NULL,
    "name_native" "text" NOT NULL,
    "script_direction" "text" DEFAULT 'ltr'::"text",
    "is_active" boolean DEFAULT false,
    "is_coming_soon" boolean DEFAULT true,
    "sort_order" integer,
    CONSTRAINT "languages_script_direction_check" CHECK (("script_direction" = ANY (ARRAY['ltr'::"text", 'rtl'::"text"])))
);


ALTER TABLE "public"."languages" OWNER TO "postgres";

--
-- Name: media; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."media" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid",
    "group_id" "uuid",
    "uploader_id" "uuid",
    "cloudinary_url" "text",
    "cloudinary_public_id" "text",
    "media_type" "text" DEFAULT 'photo'::"text",
    "caption" "text",
    "uploaded_at" timestamp with time zone DEFAULT "now"(),
    "asset_type" "text" DEFAULT 'image'::"text" NOT NULL,
    "resource_type" "text",
    "format" "text",
    "bytes" bigint,
    "width" integer,
    "height" integer,
    "duration_seconds" numeric,
    "thumbnail_url" "text",
    "blurhash" "text",
    "moderation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "processing_status" "text" DEFAULT 'ready'::"text" NOT NULL,
    "captured_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "media_asset_type_check" CHECK (("asset_type" = ANY (ARRAY['image'::"text", 'video'::"text"]))),
    CONSTRAINT "media_media_type_check" CHECK (("media_type" = ANY (ARRAY['photo'::"text", 'summary_card'::"text", 'game_screenshot'::"text"]))),
    CONSTRAINT "media_moderation_status_check" CHECK (("moderation_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'flagged'::"text"]))),
    CONSTRAINT "media_processing_status_check" CHECK (("processing_status" = ANY (ARRAY['uploading'::"text", 'processing'::"text", 'ready'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."media" OWNER TO "postgres";

--
-- Name: member_badges; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."member_badges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "group_id" "uuid",
    "badge_id" "uuid",
    "event_id" "uuid",
    "awarded_by" "uuid",
    "awarded_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."member_badges" OWNER TO "postgres";

--
-- Name: members; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'member'::"text",
    "streak_count" integer DEFAULT 0,
    "attendance_count" integer DEFAULT 0,
    "late_count" integer DEFAULT 0,
    "tambola_wins" integer DEFAULT 0,
    "rapidfire_wins" integer DEFAULT 0,
    "quiz_wins" integer DEFAULT 0,
    "dares_completed" integer DEFAULT 0,
    "media_uploads" integer DEFAULT 0,
    "hosted_events" integer DEFAULT 0,
    "referrals" integer DEFAULT 0,
    "near_wins" integer DEFAULT 0,
    "consecutive_wins" integer DEFAULT 0,
    "member_rank" integer,
    "joined_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "members_role_check" CHECK (("role" = ANY (ARRAY['host'::"text", 'co-host'::"text", 'member'::"text"])))
);


ALTER TABLE "public"."members" OWNER TO "postgres";

--
-- Name: memory_artifacts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."memory_artifacts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_id" "uuid" NOT NULL,
    "event_id" "uuid",
    "artifact_type" "text" NOT NULL,
    "title" "text",
    "cloudinary_public_id" "text",
    "asset_url" "text",
    "thumbnail_url" "text",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "generated_by" "text" DEFAULT 'system'::"text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "memory_artifacts_artifact_type_check" CHECK (("artifact_type" = ANY (ARRAY['winner_card'::"text", 'party_recap'::"text", 'collage'::"text", 'leaderboard'::"text", 'badge_card'::"text", 'next_party_teaser'::"text"]))),
    CONSTRAINT "memory_artifacts_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'generating'::"text", 'ready'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."memory_artifacts" OWNER TO "postgres";

--
-- Name: TABLE "memory_artifacts"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."memory_artifacts" IS 'Shareable outputs generated from party/game memory; Cloudinary holds rendered binary assets.';


--
-- Name: otp_verification; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."otp_verification" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "phone" "text" NOT NULL,
    "otp_code" "text" NOT NULL,
    "channel" "text" NOT NULL,
    "is_used" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:05:00'::interval),
    "otp_hash" "text",
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "max_attempts" integer DEFAULT 5 NOT NULL,
    "request_ip_hash" "text",
    "last_attempt_at" timestamp with time zone,
    CONSTRAINT "otp_verification_channel_check" CHECK (("channel" = ANY (ARRAY['telegram'::"text", 'sms'::"text", 'whatsapp'::"text"])))
);


ALTER TABLE "public"."otp_verification" OWNER TO "postgres";

--
-- Name: COLUMN "otp_verification"."otp_code"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN "public"."otp_verification"."otp_code" IS 'DEPRECATED: do not store plaintext OTP. Remove after Edge Function migration.';


--
-- Name: payments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "amount" integer,
    "paid" boolean DEFAULT false,
    "paid_at" timestamp with time zone,
    "payment_method" "text",
    "noted_by" "uuid",
    CONSTRAINT "payments_amount_nonnegative" CHECK ((("amount" IS NULL) OR ("amount" >= 0)))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";

--
-- Name: plans; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "price_monthly" integer NOT NULL,
    "price_yearly" integer NOT NULL,
    "price_yearly_per_month" integer GENERATED ALWAYS AS (("price_yearly" / 12)) STORED,
    "currency" "text" DEFAULT 'INR'::"text",
    "is_active" boolean DEFAULT true,
    "is_popular" boolean DEFAULT false,
    "razorpay_plan_id_monthly" "text",
    "razorpay_plan_id_yearly" "text",
    "features" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "limits" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."plans" OWNER TO "postgres";

--
-- Name: questions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."questions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "game_type" "text" NOT NULL,
    "category" "text",
    "question_text" "text" NOT NULL,
    "answer" "text",
    "mood_tag" "text",
    "difficulty" "text" DEFAULT 'medium'::"text",
    CONSTRAINT "questions_difficulty_check" CHECK (("difficulty" = ANY (ARRAY['easy'::"text", 'medium'::"text", 'hard'::"text"])))
);


ALTER TABLE "public"."questions" OWNER TO "postgres";

--
-- Name: razorpay_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."razorpay_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_type" "text" NOT NULL,
    "razorpay_event_id" "text",
    "payload" "jsonb",
    "processed" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."razorpay_events" OWNER TO "postgres";

--
-- Name: reminder_templates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."reminder_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "timing" "text" NOT NULL,
    "tone" "text" NOT NULL,
    "template_text" "text" NOT NULL,
    CONSTRAINT "reminder_templates_timing_check" CHECK (("timing" = ANY (ARRAY['24h'::"text", 'morning'::"text", '1h'::"text"])))
);


ALTER TABLE "public"."reminder_templates" OWNER TO "postgres";

--
-- Name: rsvp; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."rsvp" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text",
    "responded_at" timestamp with time zone,
    CONSTRAINT "rsvp_status_check" CHECK ((("status" IS NULL) OR ("status" = ANY (ARRAY['going'::"text", 'maybe'::"text", 'not_going'::"text"]))))
);


ALTER TABLE "public"."rsvp" OWNER TO "postgres";

--
-- Name: sent_reminders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."sent_reminders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid",
    "user_id" "uuid",
    "timing" "text",
    "sent_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."sent_reminders" OWNER TO "postgres";

--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "plan_id" "uuid",
    "status" "text" DEFAULT 'active'::"text",
    "billing_cycle" "text",
    "started_at" timestamp with time zone DEFAULT "now"(),
    "expires_at" timestamp with time zone,
    "cancelled_at" timestamp with time zone,
    "razorpay_subscription_id" "text",
    "razorpay_customer_id" "text",
    "auto_renew" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "subscriptions_billing_cycle_check" CHECK (("billing_cycle" = ANY (ARRAY['monthly'::"text", 'yearly'::"text"]))),
    CONSTRAINT "subscriptions_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'cancelled'::"text", 'expired'::"text", 'paused'::"text", 'trial'::"text"])))
);


ALTER TABLE "public"."subscriptions" OWNER TO "postgres";

--
-- Name: supported_locales; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."supported_locales" (
    "locale" "text" NOT NULL,
    "language_name_en" "text" NOT NULL,
    "language_name_native" "text" NOT NULL,
    "script_name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."supported_locales" OWNER TO "postgres";

--
-- Name: TABLE "supported_locales"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE "public"."supported_locales" IS 'English plus the 22 languages in the Eighth Schedule of the Constitution of India. User-entered content remains Unicode and may be written in any language.';


--
-- Name: tambola_state; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."tambola_state" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid",
    "called_numbers" integer[] DEFAULT '{}'::integer[],
    "current_number" integer,
    "winners" "jsonb" DEFAULT '{}'::"jsonb",
    "tickets" "jsonb" DEFAULT '{}'::"jsonb",
    "status" "text" DEFAULT 'waiting'::"text",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "tambola_state_status_check" CHECK (("status" = ANY (ARRAY['waiting'::"text", 'active'::"text", 'paused'::"text", 'done'::"text"])))
);


ALTER TABLE "public"."tambola_state" OWNER TO "postgres";

--
-- Name: transactions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "subscription_id" "uuid",
    "plan_id" "uuid",
    "amount" integer NOT NULL,
    "currency" "text" DEFAULT 'INR'::"text",
    "status" "text" DEFAULT 'pending'::"text",
    "razorpay_order_id" "text",
    "razorpay_payment_id" "text",
    "razorpay_signature" "text",
    "payment_method" "text",
    "failure_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "transactions_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'success'::"text", 'failed'::"text", 'refunded'::"text"])))
);


ALTER TABLE "public"."transactions" OWNER TO "postgres";

--
-- Name: translations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."translations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "language_code" "text",
    "translation_key" "text" NOT NULL,
    "translation_value" "text" NOT NULL,
    "screen" "text"
);


ALTER TABLE "public"."translations" OWNER TO "postgres";

--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "phone" "text",
    "name" "text",
    "avatar_url" "text",
    "telegram_id" "text",
    "telegram_username" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "current_plan_id" "uuid",
    "subscription_id" "uuid",
    "theme_preference" "text" DEFAULT 'party_queen'::"text",
    "notifications_enabled" boolean DEFAULT true,
    "preferred_locale" "text" DEFAULT 'en-IN'::"text"
);


ALTER TABLE "public"."users" OWNER TO "postgres";

--
-- Name: admin_logs admin_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."admin_logs"
    ADD CONSTRAINT "admin_logs_pkey" PRIMARY KEY ("id");


--
-- Name: admins admins_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("id");


--
-- Name: admins admins_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_user_id_key" UNIQUE ("user_id");


--
-- Name: ai_cache ai_cache_cache_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."ai_cache"
    ADD CONSTRAINT "ai_cache_cache_key_key" UNIQUE ("cache_key");


--
-- Name: ai_cache ai_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."ai_cache"
    ADD CONSTRAINT "ai_cache_pkey" PRIMARY KEY ("id");


--
-- Name: analytics_event_catalog analytics_event_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."analytics_event_catalog"
    ADD CONSTRAINT "analytics_event_catalog_pkey" PRIMARY KEY ("event_name");


--
-- Name: app_config app_config_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."app_config"
    ADD CONSTRAINT "app_config_pkey" PRIMARY KEY ("key");


--
-- Name: attendance attendance_event_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_event_id_user_id_key" UNIQUE ("event_id", "user_id");


--
-- Name: attendance attendance_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_pkey" PRIMARY KEY ("id");


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."audit_events"
    ADD CONSTRAINT "audit_events_pkey" PRIMARY KEY ("id");


--
-- Name: badge_definitions badge_definitions_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."badge_definitions"
    ADD CONSTRAINT "badge_definitions_name_key" UNIQUE ("name");


--
-- Name: badge_definitions badge_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."badge_definitions"
    ADD CONSTRAINT "badge_definitions_pkey" PRIMARY KEY ("id");


--
-- Name: comments comments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");


--
-- Name: expenses expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "expenses_pkey" PRIMARY KEY ("id");


--
-- Name: fcm_tokens fcm_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."fcm_tokens"
    ADD CONSTRAINT "fcm_tokens_pkey" PRIMARY KEY ("id");


--
-- Name: fcm_tokens fcm_tokens_token_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."fcm_tokens"
    ADD CONSTRAINT "fcm_tokens_token_key" UNIQUE ("token");


--
-- Name: feature_flags feature_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."feature_flags"
    ADD CONSTRAINT "feature_flags_pkey" PRIMARY KEY ("key");


--
-- Name: game_actions game_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_actions"
    ADD CONSTRAINT "game_actions_pkey" PRIMARY KEY ("id");


--
-- Name: game_catalog game_catalog_game_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_catalog"
    ADD CONSTRAINT "game_catalog_game_key_key" UNIQUE ("game_key");


--
-- Name: game_catalog game_catalog_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_catalog"
    ADD CONSTRAINT "game_catalog_pkey" PRIMARY KEY ("id");


--
-- Name: game_claims game_claims_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_claims"
    ADD CONSTRAINT "game_claims_pkey" PRIMARY KEY ("id");


--
-- Name: game_events game_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_events"
    ADD CONSTRAINT "game_events_pkey" PRIMARY KEY ("id");


--
-- Name: game_players game_players_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_players"
    ADD CONSTRAINT "game_players_pkey" PRIMARY KEY ("id");


--
-- Name: game_players game_players_session_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_players"
    ADD CONSTRAINT "game_players_session_id_user_id_key" UNIQUE ("session_id", "user_id");


--
-- Name: game_prizes game_prizes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_prizes"
    ADD CONSTRAINT "game_prizes_pkey" PRIMARY KEY ("id");


--
-- Name: game_prizes game_prizes_session_id_prize_type_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_prizes"
    ADD CONSTRAINT "game_prizes_session_id_prize_type_key" UNIQUE ("session_id", "prize_type");


--
-- Name: game_rounds game_rounds_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_rounds"
    ADD CONSTRAINT "game_rounds_pkey" PRIMARY KEY ("id");


--
-- Name: game_rounds game_rounds_session_id_round_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_rounds"
    ADD CONSTRAINT "game_rounds_session_id_round_no_key" UNIQUE ("session_id", "round_no");


--
-- Name: game_sessions game_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_sessions"
    ADD CONSTRAINT "game_sessions_pkey" PRIMARY KEY ("id");


--
-- Name: game_theme_packs game_theme_packs_game_key_theme_key_locale_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_theme_packs"
    ADD CONSTRAINT "game_theme_packs_game_key_theme_key_locale_key" UNIQUE ("game_key", "theme_key", "locale");


--
-- Name: game_theme_packs game_theme_packs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_theme_packs"
    ADD CONSTRAINT "game_theme_packs_pkey" PRIMARY KEY ("id");


--
-- Name: games games_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."games"
    ADD CONSTRAINT "games_pkey" PRIMARY KEY ("id");


--
-- Name: groups groups_invite_code_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_invite_code_key" UNIQUE ("invite_code");


--
-- Name: groups groups_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_pkey" PRIMARY KEY ("id");


--
-- Name: invite_templates invite_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."invite_templates"
    ADD CONSTRAINT "invite_templates_pkey" PRIMARY KEY ("id");


--
-- Name: languages languages_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."languages"
    ADD CONSTRAINT "languages_pkey" PRIMARY KEY ("code");


--
-- Name: media media_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_pkey" PRIMARY KEY ("id");


--
-- Name: member_badges member_badges_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."member_badges"
    ADD CONSTRAINT "member_badges_pkey" PRIMARY KEY ("id");


--
-- Name: member_badges member_badges_user_id_group_id_badge_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."member_badges"
    ADD CONSTRAINT "member_badges_user_id_group_id_badge_id_key" UNIQUE ("user_id", "group_id", "badge_id");


--
-- Name: members members_group_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."members"
    ADD CONSTRAINT "members_group_id_user_id_key" UNIQUE ("group_id", "user_id");


--
-- Name: members members_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."members"
    ADD CONSTRAINT "members_pkey" PRIMARY KEY ("id");


--
-- Name: memory_artifacts memory_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."memory_artifacts"
    ADD CONSTRAINT "memory_artifacts_pkey" PRIMARY KEY ("id");


--
-- Name: otp_verification otp_verification_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."otp_verification"
    ADD CONSTRAINT "otp_verification_pkey" PRIMARY KEY ("id");


--
-- Name: payments payments_event_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_event_id_user_id_key" UNIQUE ("event_id", "user_id");


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");


--
-- Name: plans plans_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plans"
    ADD CONSTRAINT "plans_name_key" UNIQUE ("name");


--
-- Name: plans plans_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plans"
    ADD CONSTRAINT "plans_pkey" PRIMARY KEY ("id");


--
-- Name: plans plans_slug_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plans"
    ADD CONSTRAINT "plans_slug_key" UNIQUE ("slug");


--
-- Name: questions questions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."questions"
    ADD CONSTRAINT "questions_pkey" PRIMARY KEY ("id");


--
-- Name: razorpay_events razorpay_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."razorpay_events"
    ADD CONSTRAINT "razorpay_events_pkey" PRIMARY KEY ("id");


--
-- Name: razorpay_events razorpay_events_razorpay_event_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."razorpay_events"
    ADD CONSTRAINT "razorpay_events_razorpay_event_id_key" UNIQUE ("razorpay_event_id");


--
-- Name: reminder_templates reminder_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."reminder_templates"
    ADD CONSTRAINT "reminder_templates_pkey" PRIMARY KEY ("id");


--
-- Name: rsvp rsvp_event_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."rsvp"
    ADD CONSTRAINT "rsvp_event_id_user_id_key" UNIQUE ("event_id", "user_id");


--
-- Name: rsvp rsvp_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."rsvp"
    ADD CONSTRAINT "rsvp_pkey" PRIMARY KEY ("id");


--
-- Name: sent_reminders sent_reminders_event_id_user_id_timing_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."sent_reminders"
    ADD CONSTRAINT "sent_reminders_event_id_user_id_timing_key" UNIQUE ("event_id", "user_id", "timing");


--
-- Name: sent_reminders sent_reminders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."sent_reminders"
    ADD CONSTRAINT "sent_reminders_pkey" PRIMARY KEY ("id");


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_pkey" PRIMARY KEY ("id");


--
-- Name: subscriptions subscriptions_razorpay_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_razorpay_subscription_id_key" UNIQUE ("razorpay_subscription_id");


--
-- Name: supported_locales supported_locales_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."supported_locales"
    ADD CONSTRAINT "supported_locales_pkey" PRIMARY KEY ("locale");


--
-- Name: tambola_state tambola_state_event_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tambola_state"
    ADD CONSTRAINT "tambola_state_event_id_key" UNIQUE ("event_id");


--
-- Name: tambola_state tambola_state_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tambola_state"
    ADD CONSTRAINT "tambola_state_pkey" PRIMARY KEY ("id");


--
-- Name: tambola_tickets tambola_tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tambola_tickets"
    ADD CONSTRAINT "tambola_tickets_pkey" PRIMARY KEY ("id");


--
-- Name: tambola_tickets tambola_tickets_session_id_ticket_no_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tambola_tickets"
    ADD CONSTRAINT "tambola_tickets_session_id_ticket_no_key" UNIQUE ("session_id", "ticket_no");


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_pkey" PRIMARY KEY ("id");


--
-- Name: transactions transactions_razorpay_order_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_razorpay_order_id_key" UNIQUE ("razorpay_order_id");


--
-- Name: transactions transactions_razorpay_payment_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_razorpay_payment_id_key" UNIQUE ("razorpay_payment_id");


--
-- Name: translations translations_language_code_translation_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."translations"
    ADD CONSTRAINT "translations_language_code_translation_key_key" UNIQUE ("language_code", "translation_key");


--
-- Name: translations translations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."translations"
    ADD CONSTRAINT "translations_pkey" PRIMARY KEY ("id");


--
-- Name: users users_phone_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_phone_key" UNIQUE ("phone");


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");


--
-- Name: users users_telegram_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_telegram_id_key" UNIQUE ("telegram_id");


--
-- Name: idx_attendance_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_attendance_user" ON "public"."attendance" USING "btree" ("user_id");


--
-- Name: idx_audit_events_event; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_audit_events_event" ON "public"."audit_events" USING "btree" ("event_id");


--
-- Name: idx_audit_events_group; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_audit_events_group" ON "public"."audit_events" USING "btree" ("group_id", "occurred_at" DESC);


--
-- Name: idx_audit_events_occurred; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_audit_events_occurred" ON "public"."audit_events" USING "btree" ("occurred_at" DESC);


--
-- Name: idx_audit_events_session; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_audit_events_session" ON "public"."audit_events" USING "btree" ("session_id", "occurred_at" DESC);


--
-- Name: idx_audit_events_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_audit_events_user" ON "public"."audit_events" USING "btree" ("user_id", "occurred_at" DESC);


--
-- Name: idx_events_created_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_events_created_by" ON "public"."events" USING "btree" ("created_by");


--
-- Name: idx_events_group_date; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_events_group_date" ON "public"."events" USING "btree" ("group_id", "party_date" DESC);


--
-- Name: idx_game_actions_round; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_actions_round" ON "public"."game_actions" USING "btree" ("round_id");


--
-- Name: idx_game_actions_session_round; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_actions_session_round" ON "public"."game_actions" USING "btree" ("session_id", "round_id", "created_at");


--
-- Name: idx_game_actions_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_actions_user" ON "public"."game_actions" USING "btree" ("user_id");


--
-- Name: idx_game_claims_prize; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_claims_prize" ON "public"."game_claims" USING "btree" ("prize_id");


--
-- Name: idx_game_claims_session_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_claims_session_status" ON "public"."game_claims" USING "btree" ("session_id", "status");


--
-- Name: idx_game_claims_ticket; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_claims_ticket" ON "public"."game_claims" USING "btree" ("ticket_id");


--
-- Name: idx_game_claims_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_claims_user" ON "public"."game_claims" USING "btree" ("user_id");


--
-- Name: idx_game_claims_verified_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_claims_verified_by" ON "public"."game_claims" USING "btree" ("verified_by");


--
-- Name: idx_game_events_actor; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_events_actor" ON "public"."game_events" USING "btree" ("actor_id");


--
-- Name: idx_game_events_session_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_events_session_created" ON "public"."game_events" USING "btree" ("session_id", "created_at");


--
-- Name: idx_game_players_session; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_players_session" ON "public"."game_players" USING "btree" ("session_id");


--
-- Name: idx_game_players_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_players_user" ON "public"."game_players" USING "btree" ("user_id");


--
-- Name: idx_game_prizes_session; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_prizes_session" ON "public"."game_prizes" USING "btree" ("session_id");


--
-- Name: idx_game_rounds_session; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_rounds_session" ON "public"."game_rounds" USING "btree" ("session_id", "round_no");


--
-- Name: idx_game_sessions_event; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_sessions_event" ON "public"."game_sessions" USING "btree" ("event_id");


--
-- Name: idx_game_sessions_game; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_sessions_game" ON "public"."game_sessions" USING "btree" ("game_id");


--
-- Name: idx_game_sessions_group; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_sessions_group" ON "public"."game_sessions" USING "btree" ("group_id");


--
-- Name: idx_game_sessions_host; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_sessions_host" ON "public"."game_sessions" USING "btree" ("host_id");


--
-- Name: idx_game_theme_packs_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_game_theme_packs_lookup" ON "public"."game_theme_packs" USING "btree" ("game_key", "theme_key", "locale") WHERE "is_active";


--
-- Name: idx_groups_host; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_groups_host" ON "public"."groups" USING "btree" ("host_id");


--
-- Name: idx_media_event; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_media_event" ON "public"."media" USING "btree" ("event_id");


--
-- Name: idx_media_group_event_uploaded; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_media_group_event_uploaded" ON "public"."media" USING "btree" ("group_id", "event_id", "uploaded_at" DESC);


--
-- Name: idx_media_processing; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_media_processing" ON "public"."media" USING "btree" ("processing_status", "moderation_status");


--
-- Name: idx_media_uploader; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_media_uploader" ON "public"."media" USING "btree" ("uploader_id");


--
-- Name: idx_members_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_members_user" ON "public"."members" USING "btree" ("user_id");


--
-- Name: idx_memory_artifacts_event; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_memory_artifacts_event" ON "public"."memory_artifacts" USING "btree" ("event_id");


--
-- Name: idx_memory_artifacts_group_event; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_memory_artifacts_group_event" ON "public"."memory_artifacts" USING "btree" ("group_id", "event_id", "created_at" DESC);


--
-- Name: idx_otp_expiry_unused; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_otp_expiry_unused" ON "public"."otp_verification" USING "btree" ("expires_at") WHERE ("is_used" = false);


--
-- Name: idx_otp_phone_channel_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_otp_phone_channel_created" ON "public"."otp_verification" USING "btree" ("phone", "channel", "created_at" DESC);


--
-- Name: idx_payments_noted_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_payments_noted_by" ON "public"."payments" USING "btree" ("noted_by");


--
-- Name: idx_payments_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_payments_user" ON "public"."payments" USING "btree" ("user_id");


--
-- Name: idx_rsvp_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_rsvp_user" ON "public"."rsvp" USING "btree" ("user_id");


--
-- Name: idx_tambola_tickets_session_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_tambola_tickets_session_user" ON "public"."tambola_tickets" USING "btree" ("session_id", "user_id");


--
-- Name: idx_tambola_tickets_user; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_tambola_tickets_user" ON "public"."tambola_tickets" USING "btree" ("user_id");


--
-- Name: idx_users_preferred_locale; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "idx_users_preferred_locale" ON "public"."users" USING "btree" ("preferred_locale");


--
-- Name: uq_game_claim_verified_slot; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "uq_game_claim_verified_slot" ON "public"."game_claims" USING "btree" ("prize_id", ((("verification_details" ->> 'slot'::"text"))::integer)) WHERE (("status" = 'verified'::"text") AND ("verification_details" ? 'slot'::"text"));


--
-- Name: uq_groups_invite_code; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "uq_groups_invite_code" ON "public"."groups" USING "btree" ("invite_code") WHERE ("invite_code" IS NOT NULL);


--
-- Name: uq_media_cloudinary_public_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "uq_media_cloudinary_public_id" ON "public"."media" USING "btree" ("cloudinary_public_id") WHERE ("cloudinary_public_id" IS NOT NULL);


--
-- Name: events events_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE OR REPLACE TRIGGER "events_updated_at" BEFORE UPDATE ON "public"."events" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();


--
-- Name: groups groups_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE OR REPLACE TRIGGER "groups_updated_at" BEFORE UPDATE ON "public"."groups" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();


--
-- Name: users on_user_created_assign_plan; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE OR REPLACE TRIGGER "on_user_created_assign_plan" AFTER INSERT ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."assign_free_plan_on_signup"();


--
-- Name: groups trg_ensure_host_membership; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE OR REPLACE TRIGGER "trg_ensure_host_membership" AFTER INSERT ON "public"."groups" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_host_membership"();


--
-- Name: users users_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE OR REPLACE TRIGGER "users_updated_at" BEFORE UPDATE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();


--
-- Name: admin_logs admin_logs_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."admin_logs"
    ADD CONSTRAINT "admin_logs_admin_id_fkey" FOREIGN KEY ("admin_id") REFERENCES "public"."admins"("id");


--
-- Name: admins admins_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id");


--
-- Name: admins admins_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: attendance attendance_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: attendance attendance_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: audit_events audit_events_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."audit_events"
    ADD CONSTRAINT "audit_events_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE SET NULL;


--
-- Name: audit_events audit_events_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."audit_events"
    ADD CONSTRAINT "audit_events_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE SET NULL;


--
-- Name: audit_events audit_events_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."audit_events"
    ADD CONSTRAINT "audit_events_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."game_sessions"("id") ON DELETE SET NULL;


--
-- Name: audit_events audit_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."audit_events"
    ADD CONSTRAINT "audit_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;


--
-- Name: events events_content_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_content_locale_fkey" FOREIGN KEY ("content_locale") REFERENCES "public"."supported_locales"("locale");


--
-- Name: events events_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id");


--
-- Name: events events_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE CASCADE;


--
-- Name: expenses expenses_added_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "expenses_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."users"("id");


--
-- Name: expenses expenses_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "expenses_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: expenses expenses_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."expenses"
    ADD CONSTRAINT "expenses_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE CASCADE;


--
-- Name: fcm_tokens fcm_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."fcm_tokens"
    ADD CONSTRAINT "fcm_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: feature_flags feature_flags_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."feature_flags"
    ADD CONSTRAINT "feature_flags_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."users"("id");


--
-- Name: game_actions game_actions_round_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_actions"
    ADD CONSTRAINT "game_actions_round_id_fkey" FOREIGN KEY ("round_id") REFERENCES "public"."game_rounds"("id") ON DELETE CASCADE;


--
-- Name: game_actions game_actions_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_actions"
    ADD CONSTRAINT "game_actions_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."game_sessions"("id") ON DELETE CASCADE;


--
-- Name: game_actions game_actions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_actions"
    ADD CONSTRAINT "game_actions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: game_claims game_claims_prize_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_claims"
    ADD CONSTRAINT "game_claims_prize_id_fkey" FOREIGN KEY ("prize_id") REFERENCES "public"."game_prizes"("id") ON DELETE CASCADE;


--
-- Name: game_claims game_claims_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_claims"
    ADD CONSTRAINT "game_claims_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."game_sessions"("id") ON DELETE CASCADE;


--
-- Name: game_claims game_claims_ticket_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_claims"
    ADD CONSTRAINT "game_claims_ticket_id_fkey" FOREIGN KEY ("ticket_id") REFERENCES "public"."tambola_tickets"("id") ON DELETE SET NULL;


--
-- Name: game_claims game_claims_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_claims"
    ADD CONSTRAINT "game_claims_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: game_claims game_claims_verified_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_claims"
    ADD CONSTRAINT "game_claims_verified_by_fkey" FOREIGN KEY ("verified_by") REFERENCES "public"."users"("id");


--
-- Name: game_events game_events_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_events"
    ADD CONSTRAINT "game_events_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "public"."users"("id");


--
-- Name: game_events game_events_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_events"
    ADD CONSTRAINT "game_events_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."game_sessions"("id") ON DELETE CASCADE;


--
-- Name: game_players game_players_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_players"
    ADD CONSTRAINT "game_players_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."game_sessions"("id") ON DELETE CASCADE;


--
-- Name: game_players game_players_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_players"
    ADD CONSTRAINT "game_players_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: game_prizes game_prizes_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_prizes"
    ADD CONSTRAINT "game_prizes_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."game_sessions"("id") ON DELETE CASCADE;


--
-- Name: game_rounds game_rounds_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_rounds"
    ADD CONSTRAINT "game_rounds_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."game_sessions"("id") ON DELETE CASCADE;


--
-- Name: game_sessions game_sessions_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_sessions"
    ADD CONSTRAINT "game_sessions_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: game_sessions game_sessions_game_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_sessions"
    ADD CONSTRAINT "game_sessions_game_id_fkey" FOREIGN KEY ("game_id") REFERENCES "public"."games"("id") ON DELETE SET NULL;


--
-- Name: game_sessions game_sessions_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_sessions"
    ADD CONSTRAINT "game_sessions_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE CASCADE;


--
-- Name: game_sessions game_sessions_host_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_sessions"
    ADD CONSTRAINT "game_sessions_host_id_fkey" FOREIGN KEY ("host_id") REFERENCES "public"."users"("id");


--
-- Name: game_theme_packs game_theme_packs_game_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."game_theme_packs"
    ADD CONSTRAINT "game_theme_packs_game_key_fkey" FOREIGN KEY ("game_key") REFERENCES "public"."game_catalog"("game_key") ON DELETE CASCADE;


--
-- Name: games games_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."games"
    ADD CONSTRAINT "games_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: groups groups_default_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_default_locale_fkey" FOREIGN KEY ("default_locale") REFERENCES "public"."supported_locales"("locale");


--
-- Name: groups groups_host_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."groups"
    ADD CONSTRAINT "groups_host_id_fkey" FOREIGN KEY ("host_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;


--
-- Name: media media_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: media media_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE CASCADE;


--
-- Name: media media_uploader_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_uploader_id_fkey" FOREIGN KEY ("uploader_id") REFERENCES "public"."users"("id");


--
-- Name: member_badges member_badges_awarded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."member_badges"
    ADD CONSTRAINT "member_badges_awarded_by_fkey" FOREIGN KEY ("awarded_by") REFERENCES "public"."users"("id");


--
-- Name: member_badges member_badges_badge_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."member_badges"
    ADD CONSTRAINT "member_badges_badge_id_fkey" FOREIGN KEY ("badge_id") REFERENCES "public"."badge_definitions"("id");


--
-- Name: member_badges member_badges_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."member_badges"
    ADD CONSTRAINT "member_badges_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id");


--
-- Name: member_badges member_badges_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."member_badges"
    ADD CONSTRAINT "member_badges_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE CASCADE;


--
-- Name: member_badges member_badges_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."member_badges"
    ADD CONSTRAINT "member_badges_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: members members_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."members"
    ADD CONSTRAINT "members_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE CASCADE;


--
-- Name: members members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."members"
    ADD CONSTRAINT "members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: memory_artifacts memory_artifacts_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."memory_artifacts"
    ADD CONSTRAINT "memory_artifacts_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: memory_artifacts memory_artifacts_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."memory_artifacts"
    ADD CONSTRAINT "memory_artifacts_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."groups"("id") ON DELETE CASCADE;


--
-- Name: payments payments_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: payments payments_noted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_noted_by_fkey" FOREIGN KEY ("noted_by") REFERENCES "public"."users"("id");


--
-- Name: payments payments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: rsvp rsvp_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."rsvp"
    ADD CONSTRAINT "rsvp_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: rsvp rsvp_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."rsvp"
    ADD CONSTRAINT "rsvp_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: sent_reminders sent_reminders_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."sent_reminders"
    ADD CONSTRAINT "sent_reminders_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: sent_reminders sent_reminders_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."sent_reminders"
    ADD CONSTRAINT "sent_reminders_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: subscriptions subscriptions_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."plans"("id");


--
-- Name: subscriptions subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: tambola_state tambola_state_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tambola_state"
    ADD CONSTRAINT "tambola_state_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;


--
-- Name: tambola_tickets tambola_tickets_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tambola_tickets"
    ADD CONSTRAINT "tambola_tickets_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."game_sessions"("id") ON DELETE CASCADE;


--
-- Name: tambola_tickets tambola_tickets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tambola_tickets"
    ADD CONSTRAINT "tambola_tickets_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;


--
-- Name: transactions transactions_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."plans"("id");


--
-- Name: transactions transactions_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_subscription_id_fkey" FOREIGN KEY ("subscription_id") REFERENCES "public"."subscriptions"("id");


--
-- Name: transactions transactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");


--
-- Name: translations translations_language_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."translations"
    ADD CONSTRAINT "translations_language_code_fkey" FOREIGN KEY ("language_code") REFERENCES "public"."languages"("code");


--
-- Name: users users_current_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_current_plan_id_fkey" FOREIGN KEY ("current_plan_id") REFERENCES "public"."plans"("id");


--
-- Name: users users_preferred_locale_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_preferred_locale_fkey" FOREIGN KEY ("preferred_locale") REFERENCES "public"."supported_locales"("locale");


--
-- Name: users users_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_subscription_id_fkey" FOREIGN KEY ("subscription_id") REFERENCES "public"."subscriptions"("id");


--
-- Name: admin_logs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."admin_logs" ENABLE ROW LEVEL SECURITY;

--
-- Name: admin_logs admin_logs_admins_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "admin_logs_admins_only" ON "public"."admin_logs" USING ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."user_id" = "auth"."uid"()))));


--
-- Name: admins; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."admins" ENABLE ROW LEVEL SECURITY;

--
-- Name: admins admins_superadmin_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "admins_superadmin_only" ON "public"."admins" USING ((EXISTS ( SELECT 1
   FROM "public"."admins" "a"
  WHERE (("a"."user_id" = "auth"."uid"()) AND ("a"."role" = 'superadmin'::"text")))));


--
-- Name: ai_cache; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."ai_cache" ENABLE ROW LEVEL SECURITY;

--
-- Name: ai_cache ai_cache_service_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "ai_cache_service_only" ON "public"."ai_cache" USING (false);


--
-- Name: analytics_event_catalog; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."analytics_event_catalog" ENABLE ROW LEVEL SECURITY;

--
-- Name: supported_locales anyone reads active locales; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "anyone reads active locales" ON "public"."supported_locales" FOR SELECT TO "authenticated", "anon" USING ("is_active");


--
-- Name: app_config; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."app_config" ENABLE ROW LEVEL SECURITY;

--
-- Name: app_config app_config_public_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "app_config_public_read" ON "public"."app_config" FOR SELECT USING (true);


--
-- Name: attendance; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."attendance" ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."audit_events" ENABLE ROW LEVEL SECURITY;

--
-- Name: analytics_event_catalog authenticated read analytics taxonomy; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated read analytics taxonomy" ON "public"."analytics_event_catalog" FOR SELECT TO "authenticated" USING (true);


--
-- Name: game_catalog authenticated view active games; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated view active games" ON "public"."game_catalog" FOR SELECT TO "authenticated" USING ("is_active");


--
-- Name: game_theme_packs authenticated view active themes; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated view active themes" ON "public"."game_theme_packs" FOR SELECT TO "authenticated" USING ("is_active");


--
-- Name: badge_definitions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."badge_definitions" ENABLE ROW LEVEL SECURITY;

--
-- Name: badge_definitions badges_public_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "badges_public_read" ON "public"."badge_definitions" FOR SELECT USING (true);


--
-- Name: comments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_events deny client audit events; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "deny client audit events" ON "public"."audit_events" TO "authenticated", "anon" USING (false) WITH CHECK (false);


--
-- Name: comments deny client comments; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "deny client comments" ON "public"."comments" TO "authenticated", "anon" USING (false) WITH CHECK (false);


--
-- Name: attendance event members view attendance; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "event members view attendance" ON "public"."attendance" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "attendance"."event_id") AND ("public"."is_group_member"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;

--
-- Name: events events_delete_host; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "events_delete_host" ON "public"."events" FOR DELETE TO "authenticated" USING ("public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid")));


--
-- Name: events events_insert_host; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "events_insert_host" ON "public"."events" FOR INSERT TO "authenticated" WITH CHECK ((("created_by" = ( SELECT "auth"."uid"() AS "uid")) AND "public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: events events_read_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "events_read_members" ON "public"."events" FOR SELECT TO "authenticated" USING (("public"."is_group_member"("group_id", ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: events events_update_host; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "events_update_host" ON "public"."events" FOR UPDATE TO "authenticated" USING ("public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK ("public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid")));


--
-- Name: expenses; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."expenses" ENABLE ROW LEVEL SECURITY;

--
-- Name: expenses expenses_read_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "expenses_read_members" ON "public"."expenses" FOR SELECT USING (("group_id" IN ( SELECT "members"."group_id"
   FROM "public"."members"
  WHERE ("members"."user_id" = "auth"."uid"()))));


--
-- Name: expenses expenses_write_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "expenses_write_members" ON "public"."expenses" FOR INSERT WITH CHECK ((("group_id" IN ( SELECT "members"."group_id"
   FROM "public"."members"
  WHERE ("members"."user_id" = "auth"."uid"()))) AND ("added_by" = "auth"."uid"())));


--
-- Name: fcm_tokens fcm_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "fcm_own" ON "public"."fcm_tokens" USING (("user_id" = "auth"."uid"()));


--
-- Name: fcm_tokens; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."fcm_tokens" ENABLE ROW LEVEL SECURITY;

--
-- Name: feature_flags; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."feature_flags" ENABLE ROW LEVEL SECURITY;

--
-- Name: feature_flags flags_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "flags_admin_write" ON "public"."feature_flags" USING ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."user_id" = "auth"."uid"()))));


--
-- Name: feature_flags flags_public_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "flags_public_read" ON "public"."feature_flags" FOR SELECT USING (true);


--
-- Name: game_actions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_actions" ENABLE ROW LEVEL SECURITY;

--
-- Name: game_catalog; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_catalog" ENABLE ROW LEVEL SECURITY;

--
-- Name: game_claims; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_claims" ENABLE ROW LEVEL SECURITY;

--
-- Name: game_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_events" ENABLE ROW LEVEL SECURITY;

--
-- Name: game_players; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_players" ENABLE ROW LEVEL SECURITY;

--
-- Name: game_prizes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_prizes" ENABLE ROW LEVEL SECURITY;

--
-- Name: game_rounds; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_rounds" ENABLE ROW LEVEL SECURITY;

--
-- Name: game_sessions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_sessions" ENABLE ROW LEVEL SECURITY;

--
-- Name: game_theme_packs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."game_theme_packs" ENABLE ROW LEVEL SECURITY;

--
-- Name: games; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."games" ENABLE ROW LEVEL SECURITY;

--
-- Name: games games_read_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "games_read_members" ON "public"."games" FOR SELECT USING (("event_id" IN ( SELECT "e"."id"
   FROM ("public"."events" "e"
     JOIN "public"."members" "m" ON (("m"."group_id" = "e"."group_id")))
  WHERE ("m"."user_id" = "auth"."uid"()))));


--
-- Name: game_claims group members view claims; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "group members view claims" ON "public"."game_claims" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_claims"."session_id") AND "public"."is_group_member"("s"."group_id", "auth"."uid"())))));


--
-- Name: game_events group members view game events; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "group members view game events" ON "public"."game_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_events"."session_id") AND "public"."is_group_member"("s"."group_id", "auth"."uid"())))));


--
-- Name: memory_artifacts group members view memory artifacts; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "group members view memory artifacts" ON "public"."memory_artifacts" FOR SELECT TO "authenticated" USING (("public"."is_group_member"("group_id", ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: game_prizes group members view prizes; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "group members view prizes" ON "public"."game_prizes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_prizes"."session_id") AND "public"."is_group_member"("s"."group_id", "auth"."uid"())))));


--
-- Name: game_sessions group members view sessions; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "group members view sessions" ON "public"."game_sessions" FOR SELECT TO "authenticated" USING ("public"."is_group_member"("group_id", "auth"."uid"()));


--
-- Name: groups; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."groups" ENABLE ROW LEVEL SECURITY;

--
-- Name: groups groups_insert_auth; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "groups_insert_auth" ON "public"."groups" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "host_id"));


--
-- Name: groups groups_read_member; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "groups_read_member" ON "public"."groups" FOR SELECT TO "authenticated" USING (("public"."is_group_member"("id", ( SELECT "auth"."uid"() AS "uid")) OR ("host_id" = ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: groups groups_update_host; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "groups_update_host" ON "public"."groups" FOR UPDATE TO "authenticated" USING (("host_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("host_id" = ( SELECT "auth"."uid"() AS "uid")));


--
-- Name: attendance host deletes attendance; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "host deletes attendance" ON "public"."attendance" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "attendance"."event_id") AND "public"."is_group_host"("e"."group_id", ( SELECT "auth"."uid"() AS "uid"))))));


--
-- Name: game_claims host manages claims; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "host manages claims" ON "public"."game_claims" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_claims"."session_id") AND "public"."is_group_host"("s"."group_id", "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_claims"."session_id") AND "public"."is_group_host"("s"."group_id", "auth"."uid"())))));


--
-- Name: game_players host manages players; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "host manages players" ON "public"."game_players" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_players"."session_id") AND "public"."is_group_host"("s"."group_id", "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_players"."session_id") AND "public"."is_group_host"("s"."group_id", "auth"."uid"())))));


--
-- Name: game_prizes host manages prizes; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "host manages prizes" ON "public"."game_prizes" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_prizes"."session_id") AND "public"."is_group_host"("s"."group_id", "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_prizes"."session_id") AND "public"."is_group_host"("s"."group_id", "auth"."uid"())))));


--
-- Name: game_rounds host manages rounds; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "host manages rounds" ON "public"."game_rounds" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_rounds"."session_id") AND "public"."is_group_host"("s"."group_id", ( SELECT "auth"."uid"() AS "uid")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_rounds"."session_id") AND "public"."is_group_host"("s"."group_id", ( SELECT "auth"."uid"() AS "uid"))))));


--
-- Name: game_sessions host manages sessions; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "host manages sessions" ON "public"."game_sessions" TO "authenticated" USING ("public"."is_group_host"("group_id", "auth"."uid"())) WITH CHECK (("public"."is_group_host"("group_id", "auth"."uid"()) AND ("host_id" = "auth"."uid"())));


--
-- Name: tambola_tickets host manages tickets; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "host manages tickets" ON "public"."tambola_tickets" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "tambola_tickets"."session_id") AND "public"."is_group_host"("s"."group_id", "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "tambola_tickets"."session_id") AND "public"."is_group_host"("s"."group_id", "auth"."uid"())))));


--
-- Name: attendance host updates attendance; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "host updates attendance" ON "public"."attendance" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "attendance"."event_id") AND "public"."is_group_host"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "attendance"."event_id") AND "public"."is_group_host"("e"."group_id", ( SELECT "auth"."uid"() AS "uid"))))));


--
-- Name: invite_templates; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."invite_templates" ENABLE ROW LEVEL SECURITY;

--
-- Name: invite_templates invite_templates_public_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "invite_templates_public_read" ON "public"."invite_templates" FOR SELECT USING (true);


--
-- Name: languages; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."languages" ENABLE ROW LEVEL SECURITY;

--
-- Name: languages languages_public_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "languages_public_read" ON "public"."languages" FOR SELECT USING (true);


--
-- Name: media; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."media" ENABLE ROW LEVEL SECURITY;

--
-- Name: media media_delete_owner_or_host; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "media_delete_owner_or_host" ON "public"."media" FOR DELETE TO "authenticated" USING ((("uploader_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: media media_insert_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "media_insert_members" ON "public"."media" FOR INSERT TO "authenticated" WITH CHECK ((("uploader_id" = ( SELECT "auth"."uid"() AS "uid")) AND "public"."is_group_member"("group_id", ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: media media_read_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "media_read_members" ON "public"."media" FOR SELECT TO "authenticated" USING (("public"."is_group_member"("group_id", ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: member_badges; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."member_badges" ENABLE ROW LEVEL SECURITY;

--
-- Name: member_badges member_badges_read_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "member_badges_read_members" ON "public"."member_badges" FOR SELECT USING (("group_id" IN ( SELECT "members"."group_id"
   FROM "public"."members"
  WHERE ("members"."user_id" = "auth"."uid"()))));


--
-- Name: members; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."members" ENABLE ROW LEVEL SECURITY;

--
-- Name: members members_delete_host_or_self; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "members_delete_host_or_self" ON "public"."members" FOR DELETE TO "authenticated" USING (("public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid")) OR ("user_id" = ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: members members_insert_host_or_self; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "members_insert_host_or_self" ON "public"."members" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid")) OR ("user_id" = ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: members members_read_group; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "members_read_group" ON "public"."members" FOR SELECT TO "authenticated" USING ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("group_id", ( SELECT "auth"."uid"() AS "uid"))));


--
-- Name: memory_artifacts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."memory_artifacts" ENABLE ROW LEVEL SECURITY;

--
-- Name: otp_verification otp_service_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "otp_service_only" ON "public"."otp_verification" USING (false);


--
-- Name: otp_verification; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."otp_verification" ENABLE ROW LEVEL SECURITY;

--
-- Name: payments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;

--
-- Name: payments payments_insert_self_or_host; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "payments_insert_self_or_host" ON "public"."payments" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) OR (EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "payments"."event_id") AND "public"."is_group_host"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: payments payments_read_event_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "payments_read_event_members" ON "public"."payments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "payments"."event_id") AND ("public"."is_group_member"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: payments payments_update_host; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "payments_update_host" ON "public"."payments" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "payments"."event_id") AND "public"."is_group_host"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "payments"."event_id") AND "public"."is_group_host"("e"."group_id", ( SELECT "auth"."uid"() AS "uid"))))));


--
-- Name: plans; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."plans" ENABLE ROW LEVEL SECURITY;

--
-- Name: plans plans_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "plans_admin_write" ON "public"."plans" USING ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."user_id" = "auth"."uid"()))));


--
-- Name: plans plans_public_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "plans_public_read" ON "public"."plans" FOR SELECT USING (true);


--
-- Name: game_actions players create own actions; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "players create own actions" ON "public"."game_actions" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_actions"."session_id") AND ("s"."status" = 'active'::"text") AND "public"."is_group_member"("s"."group_id", ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: game_claims players submit own claims; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "players submit own claims" ON "public"."game_claims" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_claims"."session_id") AND ("s"."status" = 'active'::"text") AND "public"."is_group_member"("s"."group_id", "auth"."uid"()))))));


--
-- Name: game_players players view session players; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "players view session players" ON "public"."game_players" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_players"."session_id") AND "public"."is_group_member"("s"."group_id", "auth"."uid"())))));


--
-- Name: questions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."questions" ENABLE ROW LEVEL SECURITY;

--
-- Name: questions questions_public_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "questions_public_read" ON "public"."questions" FOR SELECT USING (true);


--
-- Name: razorpay_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."razorpay_events" ENABLE ROW LEVEL SECURITY;

--
-- Name: razorpay_events razorpay_events_admin_only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "razorpay_events_admin_only" ON "public"."razorpay_events" USING ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."user_id" = "auth"."uid"()))));


--
-- Name: reminder_templates; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."reminder_templates" ENABLE ROW LEVEL SECURITY;

--
-- Name: reminder_templates reminder_templates_public_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "reminder_templates_public_read" ON "public"."reminder_templates" FOR SELECT USING (true);


--
-- Name: rsvp; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."rsvp" ENABLE ROW LEVEL SECURITY;

--
-- Name: rsvp rsvp_delete_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "rsvp_delete_own" ON "public"."rsvp" FOR DELETE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));


--
-- Name: rsvp rsvp_insert_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "rsvp_insert_own" ON "public"."rsvp" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "rsvp"."event_id") AND "public"."is_group_member"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: rsvp rsvp_read_group_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "rsvp_read_group_members" ON "public"."rsvp" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "rsvp"."event_id") AND ("public"."is_group_member"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: rsvp rsvp_update_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "rsvp_update_own" ON "public"."rsvp" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));


--
-- Name: attendance self check in; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "self check in" ON "public"."attendance" FOR INSERT TO "authenticated" WITH CHECK ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM "public"."events" "e"
  WHERE (("e"."id" = "attendance"."event_id") AND "public"."is_group_member"("e"."group_id", ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: sent_reminders; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."sent_reminders" ENABLE ROW LEVEL SECURITY;

--
-- Name: sent_reminders sent_reminders_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "sent_reminders_own" ON "public"."sent_reminders" FOR SELECT USING (("user_id" = "auth"."uid"()));


--
-- Name: game_actions session members view actions; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "session members view actions" ON "public"."game_actions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_actions"."session_id") AND ("public"."is_group_member"("s"."group_id", ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("s"."group_id", ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: game_rounds session members view rounds; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "session members view rounds" ON "public"."game_rounds" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "game_rounds"."session_id") AND ("public"."is_group_member"("s"."group_id", ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_group_host"("s"."group_id", ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: subscriptions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."subscriptions" ENABLE ROW LEVEL SECURITY;

--
-- Name: subscriptions subscriptions_admin_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "subscriptions_admin_all" ON "public"."subscriptions" USING ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."user_id" = "auth"."uid"()))));


--
-- Name: subscriptions subscriptions_read_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "subscriptions_read_own" ON "public"."subscriptions" FOR SELECT USING (("user_id" = "auth"."uid"()));


--
-- Name: supported_locales; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."supported_locales" ENABLE ROW LEVEL SECURITY;

--
-- Name: tambola_state tambola_read_members; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "tambola_read_members" ON "public"."tambola_state" FOR SELECT USING (("event_id" IN ( SELECT "e"."id"
   FROM ("public"."events" "e"
     JOIN "public"."members" "m" ON (("m"."group_id" = "e"."group_id")))
  WHERE ("m"."user_id" = "auth"."uid"()))));


--
-- Name: tambola_state; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."tambola_state" ENABLE ROW LEVEL SECURITY;

--
-- Name: tambola_tickets; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."tambola_tickets" ENABLE ROW LEVEL SECURITY;

--
-- Name: tambola_tickets ticket owner or host views ticket; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "ticket owner or host views ticket" ON "public"."tambola_tickets" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."game_sessions" "s"
  WHERE (("s"."id" = "tambola_tickets"."session_id") AND "public"."is_group_host"("s"."group_id", "auth"."uid"()))))));


--
-- Name: transactions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."transactions" ENABLE ROW LEVEL SECURITY;

--
-- Name: transactions transactions_admin_all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "transactions_admin_all" ON "public"."transactions" USING ((EXISTS ( SELECT 1
   FROM "public"."admins"
  WHERE ("admins"."user_id" = "auth"."uid"()))));


--
-- Name: transactions transactions_read_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "transactions_read_own" ON "public"."transactions" FOR SELECT USING (("user_id" = "auth"."uid"()));


--
-- Name: translations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."translations" ENABLE ROW LEVEL SECURITY;

--
-- Name: translations translations_public_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "translations_public_read" ON "public"."translations" FOR SELECT USING (true);


--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;

--
-- Name: users users_insert_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "users_insert_own" ON "public"."users" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id"));


--
-- Name: users users_read_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "users_read_own" ON "public"."users" FOR SELECT TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id"));


--
-- Name: users users_update_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "users_update_own" ON "public"."users" FOR UPDATE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "id"));


--
-- Name: supabase_realtime; Type: PUBLICATION; Schema: -; Owner: postgres
--

-- CREATE PUBLICATION "supabase_realtime" WITH (publish = 'insert, update, delete, truncate');


ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";

--
-- Name: supabase_realtime game_actions; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."game_actions";


--
-- Name: supabase_realtime game_claims; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."game_claims";


--
-- Name: supabase_realtime game_events; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."game_events";


--
-- Name: supabase_realtime game_prizes; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."game_prizes";


--
-- Name: supabase_realtime game_rounds; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."game_rounds";


--
-- Name: supabase_realtime game_sessions; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."game_sessions";


--
-- Name: supabase_realtime games; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."games";


--
-- Name: supabase_realtime rsvp; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."rsvp";


--
-- Name: supabase_realtime tambola_state; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."tambola_state";


--
-- Name: SCHEMA "public"; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";


--
-- Name: FUNCTION "armor"("bytea"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."armor"("bytea") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."armor"("bytea") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."armor"("bytea") TO "dashboard_user";


--
-- Name: FUNCTION "armor"("bytea", "text"[], "text"[]); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."armor"("bytea", "text"[], "text"[]) FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."armor"("bytea", "text"[], "text"[]) TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."armor"("bytea", "text"[], "text"[]) TO "dashboard_user";


--
-- Name: FUNCTION "crypt"("text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."crypt"("text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."crypt"("text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."crypt"("text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "dearmor"("text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."dearmor"("text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."dearmor"("text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."dearmor"("text") TO "dashboard_user";


--
-- Name: FUNCTION "decrypt"("bytea", "bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."decrypt"("bytea", "bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."decrypt"("bytea", "bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."decrypt"("bytea", "bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "decrypt_iv"("bytea", "bytea", "bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."decrypt_iv"("bytea", "bytea", "bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."decrypt_iv"("bytea", "bytea", "bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."decrypt_iv"("bytea", "bytea", "bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "digest"("bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."digest"("bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."digest"("bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."digest"("bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "digest"("text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."digest"("text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."digest"("text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."digest"("text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "encrypt"("bytea", "bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."encrypt"("bytea", "bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."encrypt"("bytea", "bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."encrypt"("bytea", "bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "encrypt_iv"("bytea", "bytea", "bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."encrypt_iv"("bytea", "bytea", "bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."encrypt_iv"("bytea", "bytea", "bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."encrypt_iv"("bytea", "bytea", "bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "gen_random_bytes"(integer); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."gen_random_bytes"(integer) FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."gen_random_bytes"(integer) TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."gen_random_bytes"(integer) TO "dashboard_user";


--
-- Name: FUNCTION "gen_random_uuid"(); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."gen_random_uuid"() FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."gen_random_uuid"() TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."gen_random_uuid"() TO "dashboard_user";


--
-- Name: FUNCTION "gen_salt"("text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."gen_salt"("text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."gen_salt"("text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."gen_salt"("text") TO "dashboard_user";


--
-- Name: FUNCTION "gen_salt"("text", integer); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."gen_salt"("text", integer) FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."gen_salt"("text", integer) TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."gen_salt"("text", integer) TO "dashboard_user";


--
-- Name: FUNCTION "hmac"("bytea", "bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."hmac"("bytea", "bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."hmac"("bytea", "bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."hmac"("bytea", "bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "hmac"("text", "text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."hmac"("text", "text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."hmac"("text", "text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."hmac"("text", "text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pg_stat_statements"("showtext" boolean, OUT "userid" "oid", OUT "dbid" "oid", OUT "toplevel" boolean, OUT "queryid" bigint, OUT "query" "text", OUT "plans" bigint, OUT "total_plan_time" double precision, OUT "min_plan_time" double precision, OUT "max_plan_time" double precision, OUT "mean_plan_time" double precision, OUT "stddev_plan_time" double precision, OUT "calls" bigint, OUT "total_exec_time" double precision, OUT "min_exec_time" double precision, OUT "max_exec_time" double precision, OUT "mean_exec_time" double precision, OUT "stddev_exec_time" double precision, OUT "rows" bigint, OUT "shared_blks_hit" bigint, OUT "shared_blks_read" bigint, OUT "shared_blks_dirtied" bigint, OUT "shared_blks_written" bigint, OUT "local_blks_hit" bigint, OUT "local_blks_read" bigint, OUT "local_blks_dirtied" bigint, OUT "local_blks_written" bigint, OUT "temp_blks_read" bigint, OUT "temp_blks_written" bigint, OUT "shared_blk_read_time" double precision, OUT "shared_blk_write_time" double precision, OUT "local_blk_read_time" double precision, OUT "local_blk_write_time" double precision, OUT "temp_blk_read_time" double precision, OUT "temp_blk_write_time" double precision, OUT "wal_records" bigint, OUT "wal_fpi" bigint, OUT "wal_bytes" numeric, OUT "jit_functions" bigint, OUT "jit_generation_time" double precision, OUT "jit_inlining_count" bigint, OUT "jit_inlining_time" double precision, OUT "jit_optimization_count" bigint, OUT "jit_optimization_time" double precision, OUT "jit_emission_count" bigint, OUT "jit_emission_time" double precision, OUT "jit_deform_count" bigint, OUT "jit_deform_time" double precision, OUT "stats_since" timestamp with time zone, OUT "minmax_stats_since" timestamp with time zone); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pg_stat_statements"("showtext" boolean, OUT "userid" "oid", OUT "dbid" "oid", OUT "toplevel" boolean, OUT "queryid" bigint, OUT "query" "text", OUT "plans" bigint, OUT "total_plan_time" double precision, OUT "min_plan_time" double precision, OUT "max_plan_time" double precision, OUT "mean_plan_time" double precision, OUT "stddev_plan_time" double precision, OUT "calls" bigint, OUT "total_exec_time" double precision, OUT "min_exec_time" double precision, OUT "max_exec_time" double precision, OUT "mean_exec_time" double precision, OUT "stddev_exec_time" double precision, OUT "rows" bigint, OUT "shared_blks_hit" bigint, OUT "shared_blks_read" bigint, OUT "shared_blks_dirtied" bigint, OUT "shared_blks_written" bigint, OUT "local_blks_hit" bigint, OUT "local_blks_read" bigint, OUT "local_blks_dirtied" bigint, OUT "local_blks_written" bigint, OUT "temp_blks_read" bigint, OUT "temp_blks_written" bigint, OUT "shared_blk_read_time" double precision, OUT "shared_blk_write_time" double precision, OUT "local_blk_read_time" double precision, OUT "local_blk_write_time" double precision, OUT "temp_blk_read_time" double precision, OUT "temp_blk_write_time" double precision, OUT "wal_records" bigint, OUT "wal_fpi" bigint, OUT "wal_bytes" numeric, OUT "jit_functions" bigint, OUT "jit_generation_time" double precision, OUT "jit_inlining_count" bigint, OUT "jit_inlining_time" double precision, OUT "jit_optimization_count" bigint, OUT "jit_optimization_time" double precision, OUT "jit_emission_count" bigint, OUT "jit_emission_time" double precision, OUT "jit_deform_count" bigint, OUT "jit_deform_time" double precision, OUT "stats_since" timestamp with time zone, OUT "minmax_stats_since" timestamp with time zone) FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pg_stat_statements"("showtext" boolean, OUT "userid" "oid", OUT "dbid" "oid", OUT "toplevel" boolean, OUT "queryid" bigint, OUT "query" "text", OUT "plans" bigint, OUT "total_plan_time" double precision, OUT "min_plan_time" double precision, OUT "max_plan_time" double precision, OUT "mean_plan_time" double precision, OUT "stddev_plan_time" double precision, OUT "calls" bigint, OUT "total_exec_time" double precision, OUT "min_exec_time" double precision, OUT "max_exec_time" double precision, OUT "mean_exec_time" double precision, OUT "stddev_exec_time" double precision, OUT "rows" bigint, OUT "shared_blks_hit" bigint, OUT "shared_blks_read" bigint, OUT "shared_blks_dirtied" bigint, OUT "shared_blks_written" bigint, OUT "local_blks_hit" bigint, OUT "local_blks_read" bigint, OUT "local_blks_dirtied" bigint, OUT "local_blks_written" bigint, OUT "temp_blks_read" bigint, OUT "temp_blks_written" bigint, OUT "shared_blk_read_time" double precision, OUT "shared_blk_write_time" double precision, OUT "local_blk_read_time" double precision, OUT "local_blk_write_time" double precision, OUT "temp_blk_read_time" double precision, OUT "temp_blk_write_time" double precision, OUT "wal_records" bigint, OUT "wal_fpi" bigint, OUT "wal_bytes" numeric, OUT "jit_functions" bigint, OUT "jit_generation_time" double precision, OUT "jit_inlining_count" bigint, OUT "jit_inlining_time" double precision, OUT "jit_optimization_count" bigint, OUT "jit_optimization_time" double precision, OUT "jit_emission_count" bigint, OUT "jit_emission_time" double precision, OUT "jit_deform_count" bigint, OUT "jit_deform_time" double precision, OUT "stats_since" timestamp with time zone, OUT "minmax_stats_since" timestamp with time zone) TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pg_stat_statements"("showtext" boolean, OUT "userid" "oid", OUT "dbid" "oid", OUT "toplevel" boolean, OUT "queryid" bigint, OUT "query" "text", OUT "plans" bigint, OUT "total_plan_time" double precision, OUT "min_plan_time" double precision, OUT "max_plan_time" double precision, OUT "mean_plan_time" double precision, OUT "stddev_plan_time" double precision, OUT "calls" bigint, OUT "total_exec_time" double precision, OUT "min_exec_time" double precision, OUT "max_exec_time" double precision, OUT "mean_exec_time" double precision, OUT "stddev_exec_time" double precision, OUT "rows" bigint, OUT "shared_blks_hit" bigint, OUT "shared_blks_read" bigint, OUT "shared_blks_dirtied" bigint, OUT "shared_blks_written" bigint, OUT "local_blks_hit" bigint, OUT "local_blks_read" bigint, OUT "local_blks_dirtied" bigint, OUT "local_blks_written" bigint, OUT "temp_blks_read" bigint, OUT "temp_blks_written" bigint, OUT "shared_blk_read_time" double precision, OUT "shared_blk_write_time" double precision, OUT "local_blk_read_time" double precision, OUT "local_blk_write_time" double precision, OUT "temp_blk_read_time" double precision, OUT "temp_blk_write_time" double precision, OUT "wal_records" bigint, OUT "wal_fpi" bigint, OUT "wal_bytes" numeric, OUT "jit_functions" bigint, OUT "jit_generation_time" double precision, OUT "jit_inlining_count" bigint, OUT "jit_inlining_time" double precision, OUT "jit_optimization_count" bigint, OUT "jit_optimization_time" double precision, OUT "jit_emission_count" bigint, OUT "jit_emission_time" double precision, OUT "jit_deform_count" bigint, OUT "jit_deform_time" double precision, OUT "stats_since" timestamp with time zone, OUT "minmax_stats_since" timestamp with time zone) TO "dashboard_user";


--
-- Name: FUNCTION "pg_stat_statements_info"(OUT "dealloc" bigint, OUT "stats_reset" timestamp with time zone); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pg_stat_statements_info"(OUT "dealloc" bigint, OUT "stats_reset" timestamp with time zone) FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pg_stat_statements_info"(OUT "dealloc" bigint, OUT "stats_reset" timestamp with time zone) TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pg_stat_statements_info"(OUT "dealloc" bigint, OUT "stats_reset" timestamp with time zone) TO "dashboard_user";


--
-- Name: FUNCTION "pg_stat_statements_reset"("userid" "oid", "dbid" "oid", "queryid" bigint, "minmax_only" boolean); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pg_stat_statements_reset"("userid" "oid", "dbid" "oid", "queryid" bigint, "minmax_only" boolean) FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pg_stat_statements_reset"("userid" "oid", "dbid" "oid", "queryid" bigint, "minmax_only" boolean) TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pg_stat_statements_reset"("userid" "oid", "dbid" "oid", "queryid" bigint, "minmax_only" boolean) TO "dashboard_user";


--
-- Name: FUNCTION "pgp_armor_headers"("text", OUT "key" "text", OUT "value" "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_armor_headers"("text", OUT "key" "text", OUT "value" "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_armor_headers"("text", OUT "key" "text", OUT "value" "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_armor_headers"("text", OUT "key" "text", OUT "value" "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_key_id"("bytea"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_key_id"("bytea") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_key_id"("bytea") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_key_id"("bytea") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_decrypt"("bytea", "bytea"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_decrypt"("bytea", "bytea") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt"("bytea", "bytea") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt"("bytea", "bytea") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_decrypt"("bytea", "bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_decrypt"("bytea", "bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt"("bytea", "bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt"("bytea", "bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_decrypt"("bytea", "bytea", "text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_decrypt"("bytea", "bytea", "text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt"("bytea", "bytea", "text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt"("bytea", "bytea", "text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_decrypt_bytea"("bytea", "bytea"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_decrypt_bytea"("bytea", "bytea") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt_bytea"("bytea", "bytea") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt_bytea"("bytea", "bytea") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_decrypt_bytea"("bytea", "bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_decrypt_bytea"("bytea", "bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt_bytea"("bytea", "bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt_bytea"("bytea", "bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_decrypt_bytea"("bytea", "bytea", "text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_decrypt_bytea"("bytea", "bytea", "text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt_bytea"("bytea", "bytea", "text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_decrypt_bytea"("bytea", "bytea", "text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_encrypt"("text", "bytea"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_encrypt"("text", "bytea") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_encrypt"("text", "bytea") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_encrypt"("text", "bytea") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_encrypt"("text", "bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_encrypt"("text", "bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_encrypt"("text", "bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_encrypt"("text", "bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_encrypt_bytea"("bytea", "bytea"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_encrypt_bytea"("bytea", "bytea") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_encrypt_bytea"("bytea", "bytea") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_encrypt_bytea"("bytea", "bytea") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_pub_encrypt_bytea"("bytea", "bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_pub_encrypt_bytea"("bytea", "bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_pub_encrypt_bytea"("bytea", "bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_pub_encrypt_bytea"("bytea", "bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_sym_decrypt"("bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_sym_decrypt"("bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_sym_decrypt"("bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_sym_decrypt"("bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_sym_decrypt"("bytea", "text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_sym_decrypt"("bytea", "text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_sym_decrypt"("bytea", "text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_sym_decrypt"("bytea", "text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_sym_decrypt_bytea"("bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_sym_decrypt_bytea"("bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_sym_decrypt_bytea"("bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_sym_decrypt_bytea"("bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_sym_decrypt_bytea"("bytea", "text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_sym_decrypt_bytea"("bytea", "text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_sym_decrypt_bytea"("bytea", "text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_sym_decrypt_bytea"("bytea", "text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_sym_encrypt"("text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_sym_encrypt"("text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_sym_encrypt"("text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_sym_encrypt"("text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_sym_encrypt"("text", "text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_sym_encrypt"("text", "text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_sym_encrypt"("text", "text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_sym_encrypt"("text", "text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_sym_encrypt_bytea"("bytea", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_sym_encrypt_bytea"("bytea", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_sym_encrypt_bytea"("bytea", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_sym_encrypt_bytea"("bytea", "text") TO "dashboard_user";


--
-- Name: FUNCTION "pgp_sym_encrypt_bytea"("bytea", "text", "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."pgp_sym_encrypt_bytea"("bytea", "text", "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."pgp_sym_encrypt_bytea"("bytea", "text", "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."pgp_sym_encrypt_bytea"("bytea", "text", "text") TO "dashboard_user";


--
-- Name: FUNCTION "uuid_generate_v1"(); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_generate_v1"() FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v1"() TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v1"() TO "dashboard_user";


--
-- Name: FUNCTION "uuid_generate_v1mc"(); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_generate_v1mc"() FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v1mc"() TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v1mc"() TO "dashboard_user";


--
-- Name: FUNCTION "uuid_generate_v3"("namespace" "uuid", "name" "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_generate_v3"("namespace" "uuid", "name" "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v3"("namespace" "uuid", "name" "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v3"("namespace" "uuid", "name" "text") TO "dashboard_user";


--
-- Name: FUNCTION "uuid_generate_v4"(); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_generate_v4"() FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v4"() TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v4"() TO "dashboard_user";


--
-- Name: FUNCTION "uuid_generate_v5"("namespace" "uuid", "name" "text"); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_generate_v5"("namespace" "uuid", "name" "text") FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v5"("namespace" "uuid", "name" "text") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_generate_v5"("namespace" "uuid", "name" "text") TO "dashboard_user";


--
-- Name: FUNCTION "uuid_nil"(); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_nil"() FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_nil"() TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_nil"() TO "dashboard_user";


--
-- Name: FUNCTION "uuid_ns_dns"(); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_ns_dns"() FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_ns_dns"() TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_ns_dns"() TO "dashboard_user";


--
-- Name: FUNCTION "uuid_ns_oid"(); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_ns_oid"() FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_ns_oid"() TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_ns_oid"() TO "dashboard_user";


--
-- Name: FUNCTION "uuid_ns_url"(); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_ns_url"() FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_ns_url"() TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_ns_url"() TO "dashboard_user";


--
-- Name: FUNCTION "uuid_ns_x500"(); Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON FUNCTION "extensions"."uuid_ns_x500"() FROM "postgres";
GRANT ALL ON FUNCTION "extensions"."uuid_ns_x500"() TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "extensions"."uuid_ns_x500"() TO "dashboard_user";


--
-- Name: FUNCTION "assign_free_plan_on_signup"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."assign_free_plan_on_signup"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assign_free_plan_on_signup"() TO "service_role";


--
-- Name: FUNCTION "check_and_award_badges"("p_user_id" "uuid", "p_group_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."check_and_award_badges"("p_user_id" "uuid", "p_group_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_and_award_badges"("p_user_id" "uuid", "p_group_id" "uuid") TO "service_role";


--
-- Name: TABLE "game_claims"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."game_claims" TO "anon";
GRANT ALL ON TABLE "public"."game_claims" TO "authenticated";
GRANT ALL ON TABLE "public"."game_claims" TO "service_role";


--
-- Name: FUNCTION "claim_tambola_prize"("p_ticket_id" "uuid", "p_prize_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."claim_tambola_prize"("p_ticket_id" "uuid", "p_prize_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_tambola_prize"("p_ticket_id" "uuid", "p_prize_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."claim_tambola_prize"("p_ticket_id" "uuid", "p_prize_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "ensure_host_membership"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."ensure_host_membership"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_host_membership"() TO "service_role";


--
-- Name: FUNCTION "generate_tambola_grid"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."generate_tambola_grid"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_tambola_grid"() TO "service_role";


--
-- Name: FUNCTION "get_user_plan_limits"("p_user_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."get_user_plan_limits"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_user_plan_limits"("p_user_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "host_call_tambola_number"("p_session_id" "uuid", "p_number" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."host_call_tambola_number"("p_session_id" "uuid", "p_number" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."host_call_tambola_number"("p_session_id" "uuid", "p_number" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."host_call_tambola_number"("p_session_id" "uuid", "p_number" integer) TO "service_role";


--
-- Name: FUNCTION "host_check_tambola_claim"("p_claim_id" "uuid", "p_force_reject" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."host_check_tambola_claim"("p_claim_id" "uuid", "p_force_reject" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."host_check_tambola_claim"("p_claim_id" "uuid", "p_force_reject" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."host_check_tambola_claim"("p_claim_id" "uuid", "p_force_reject" boolean) TO "service_role";


--
-- Name: FUNCTION "host_create_tambola_session"("p_event_id" "uuid", "p_variant" "text", "p_play_mode" "text", "p_prizes" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."host_create_tambola_session"("p_event_id" "uuid", "p_variant" "text", "p_play_mode" "text", "p_prizes" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."host_create_tambola_session"("p_event_id" "uuid", "p_variant" "text", "p_play_mode" "text", "p_prizes" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."host_create_tambola_session"("p_event_id" "uuid", "p_variant" "text", "p_play_mode" "text", "p_prizes" "jsonb") TO "service_role";


--
-- Name: FUNCTION "host_distribute_tambola_tickets"("p_session_id" "uuid", "p_user_ids" "uuid"[], "p_tickets_each" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."host_distribute_tambola_tickets"("p_session_id" "uuid", "p_user_ids" "uuid"[], "p_tickets_each" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."host_distribute_tambola_tickets"("p_session_id" "uuid", "p_user_ids" "uuid"[], "p_tickets_each" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."host_distribute_tambola_tickets"("p_session_id" "uuid", "p_user_ids" "uuid"[], "p_tickets_each" integer) TO "service_role";


--
-- Name: TABLE "game_sessions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."game_sessions" TO "anon";
GRANT ALL ON TABLE "public"."game_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."game_sessions" TO "service_role";


--
-- Name: FUNCTION "host_pause_tambola"("p_session_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."host_pause_tambola"("p_session_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."host_pause_tambola"("p_session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."host_pause_tambola"("p_session_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "host_start_tambola"("p_session_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."host_start_tambola"("p_session_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."host_start_tambola"("p_session_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."host_start_tambola"("p_session_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "is_group_host"("p_group_id" "uuid", "p_user_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."is_group_host"("p_group_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_group_host"("p_group_id" "uuid", "p_user_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "is_group_member"("p_group_id" "uuid", "p_user_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."is_group_member"("p_group_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_group_member"("p_group_id" "uuid", "p_user_id" "uuid") TO "service_role";


--
-- Name: TABLE "tambola_tickets"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."tambola_tickets" TO "anon";
GRANT ALL ON TABLE "public"."tambola_tickets" TO "authenticated";
GRANT ALL ON TABLE "public"."tambola_tickets" TO "service_role";


--
-- Name: FUNCTION "mark_tambola_number"("p_ticket_id" "uuid", "p_number" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."mark_tambola_number"("p_ticket_id" "uuid", "p_number" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_tambola_number"("p_ticket_id" "uuid", "p_number" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_tambola_number"("p_ticket_id" "uuid", "p_number" integer) TO "service_role";


--
-- Name: FUNCTION "tambola_pattern_matches"("p_grid" "jsonb", "p_marked" integer[], "p_pattern" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."tambola_pattern_matches"("p_grid" "jsonb", "p_marked" integer[], "p_pattern" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tambola_pattern_matches"("p_grid" "jsonb", "p_marked" integer[], "p_pattern" "text") TO "service_role";


--
-- Name: FUNCTION "update_updated_at"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."update_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";


--
-- Name: FUNCTION "_crypto_aead_det_decrypt"("message" "bytea", "additional" "bytea", "key_id" bigint, "context" "bytea", "nonce" "bytea"); Type: ACL; Schema: vault; Owner: supabase_admin
--

GRANT ALL ON FUNCTION "vault"."_crypto_aead_det_decrypt"("message" "bytea", "additional" "bytea", "key_id" bigint, "context" "bytea", "nonce" "bytea") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "vault"."_crypto_aead_det_decrypt"("message" "bytea", "additional" "bytea", "key_id" bigint, "context" "bytea", "nonce" "bytea") TO "service_role";


--
-- Name: FUNCTION "create_secret"("new_secret" "text", "new_name" "text", "new_description" "text", "new_key_id" "uuid"); Type: ACL; Schema: vault; Owner: supabase_admin
--

GRANT ALL ON FUNCTION "vault"."create_secret"("new_secret" "text", "new_name" "text", "new_description" "text", "new_key_id" "uuid") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "vault"."create_secret"("new_secret" "text", "new_name" "text", "new_description" "text", "new_key_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "update_secret"("secret_id" "uuid", "new_secret" "text", "new_name" "text", "new_description" "text", "new_key_id" "uuid"); Type: ACL; Schema: vault; Owner: supabase_admin
--

GRANT ALL ON FUNCTION "vault"."update_secret"("secret_id" "uuid", "new_secret" "text", "new_name" "text", "new_description" "text", "new_key_id" "uuid") TO "postgres" WITH GRANT OPTION;
GRANT ALL ON FUNCTION "vault"."update_secret"("secret_id" "uuid", "new_secret" "text", "new_name" "text", "new_description" "text", "new_key_id" "uuid") TO "service_role";


--
-- Name: TABLE "pg_stat_statements"; Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON TABLE "extensions"."pg_stat_statements" FROM "postgres";
GRANT ALL ON TABLE "extensions"."pg_stat_statements" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "extensions"."pg_stat_statements" TO "dashboard_user";


--
-- Name: TABLE "pg_stat_statements_info"; Type: ACL; Schema: extensions; Owner: postgres
--

REVOKE ALL ON TABLE "extensions"."pg_stat_statements_info" FROM "postgres";
GRANT ALL ON TABLE "extensions"."pg_stat_statements_info" TO "postgres" WITH GRANT OPTION;
GRANT ALL ON TABLE "extensions"."pg_stat_statements_info" TO "dashboard_user";


--
-- Name: TABLE "admin_logs"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."admin_logs" TO "anon";
GRANT ALL ON TABLE "public"."admin_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_logs" TO "service_role";


--
-- Name: TABLE "admins"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."admins" TO "anon";
GRANT ALL ON TABLE "public"."admins" TO "authenticated";
GRANT ALL ON TABLE "public"."admins" TO "service_role";


--
-- Name: TABLE "ai_cache"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."ai_cache" TO "anon";
GRANT ALL ON TABLE "public"."ai_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_cache" TO "service_role";


--
-- Name: TABLE "analytics_event_catalog"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."analytics_event_catalog" TO "anon";
GRANT ALL ON TABLE "public"."analytics_event_catalog" TO "authenticated";
GRANT ALL ON TABLE "public"."analytics_event_catalog" TO "service_role";


--
-- Name: TABLE "app_config"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."app_config" TO "anon";
GRANT ALL ON TABLE "public"."app_config" TO "authenticated";
GRANT ALL ON TABLE "public"."app_config" TO "service_role";


--
-- Name: TABLE "attendance"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."attendance" TO "anon";
GRANT ALL ON TABLE "public"."attendance" TO "authenticated";
GRANT ALL ON TABLE "public"."attendance" TO "service_role";


--
-- Name: TABLE "audit_events"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."audit_events" TO "anon";
GRANT ALL ON TABLE "public"."audit_events" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_events" TO "service_role";


--
-- Name: SEQUENCE "audit_events_id_seq"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE "public"."audit_events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."audit_events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."audit_events_id_seq" TO "service_role";


--
-- Name: TABLE "badge_definitions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."badge_definitions" TO "anon";
GRANT ALL ON TABLE "public"."badge_definitions" TO "authenticated";
GRANT ALL ON TABLE "public"."badge_definitions" TO "service_role";


--
-- Name: TABLE "comments"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";


--
-- Name: SEQUENCE "comments_id_seq"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE "public"."comments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."comments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."comments_id_seq" TO "service_role";


--
-- Name: TABLE "events"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";


--
-- Name: TABLE "expenses"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."expenses" TO "anon";
GRANT ALL ON TABLE "public"."expenses" TO "authenticated";
GRANT ALL ON TABLE "public"."expenses" TO "service_role";


--
-- Name: TABLE "fcm_tokens"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."fcm_tokens" TO "anon";
GRANT ALL ON TABLE "public"."fcm_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."fcm_tokens" TO "service_role";


--
-- Name: TABLE "feature_flags"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."feature_flags" TO "anon";
GRANT ALL ON TABLE "public"."feature_flags" TO "authenticated";
GRANT ALL ON TABLE "public"."feature_flags" TO "service_role";


--
-- Name: TABLE "game_actions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."game_actions" TO "anon";
GRANT ALL ON TABLE "public"."game_actions" TO "authenticated";
GRANT ALL ON TABLE "public"."game_actions" TO "service_role";


--
-- Name: SEQUENCE "game_actions_id_seq"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE "public"."game_actions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."game_actions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."game_actions_id_seq" TO "service_role";


--
-- Name: TABLE "game_catalog"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."game_catalog" TO "anon";
GRANT ALL ON TABLE "public"."game_catalog" TO "authenticated";
GRANT ALL ON TABLE "public"."game_catalog" TO "service_role";


--
-- Name: TABLE "game_events"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."game_events" TO "anon";
GRANT ALL ON TABLE "public"."game_events" TO "authenticated";
GRANT ALL ON TABLE "public"."game_events" TO "service_role";


--
-- Name: SEQUENCE "game_events_id_seq"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE "public"."game_events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."game_events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."game_events_id_seq" TO "service_role";


--
-- Name: TABLE "game_players"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."game_players" TO "anon";
GRANT ALL ON TABLE "public"."game_players" TO "authenticated";
GRANT ALL ON TABLE "public"."game_players" TO "service_role";


--
-- Name: TABLE "game_prizes"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."game_prizes" TO "anon";
GRANT ALL ON TABLE "public"."game_prizes" TO "authenticated";
GRANT ALL ON TABLE "public"."game_prizes" TO "service_role";


--
-- Name: TABLE "game_rounds"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."game_rounds" TO "anon";
GRANT ALL ON TABLE "public"."game_rounds" TO "authenticated";
GRANT ALL ON TABLE "public"."game_rounds" TO "service_role";


--
-- Name: TABLE "game_theme_packs"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."game_theme_packs" TO "anon";
GRANT ALL ON TABLE "public"."game_theme_packs" TO "authenticated";
GRANT ALL ON TABLE "public"."game_theme_packs" TO "service_role";


--
-- Name: TABLE "games"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."games" TO "anon";
GRANT ALL ON TABLE "public"."games" TO "authenticated";
GRANT ALL ON TABLE "public"."games" TO "service_role";


--
-- Name: TABLE "groups"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."groups" TO "anon";
GRANT ALL ON TABLE "public"."groups" TO "authenticated";
GRANT ALL ON TABLE "public"."groups" TO "service_role";


--
-- Name: TABLE "invite_templates"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."invite_templates" TO "anon";
GRANT ALL ON TABLE "public"."invite_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."invite_templates" TO "service_role";


--
-- Name: TABLE "languages"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."languages" TO "anon";
GRANT ALL ON TABLE "public"."languages" TO "authenticated";
GRANT ALL ON TABLE "public"."languages" TO "service_role";


--
-- Name: TABLE "media"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."media" TO "anon";
GRANT ALL ON TABLE "public"."media" TO "authenticated";
GRANT ALL ON TABLE "public"."media" TO "service_role";


--
-- Name: TABLE "member_badges"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."member_badges" TO "anon";
GRANT ALL ON TABLE "public"."member_badges" TO "authenticated";
GRANT ALL ON TABLE "public"."member_badges" TO "service_role";


--
-- Name: TABLE "members"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."members" TO "anon";
GRANT ALL ON TABLE "public"."members" TO "authenticated";
GRANT ALL ON TABLE "public"."members" TO "service_role";


--
-- Name: TABLE "memory_artifacts"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."memory_artifacts" TO "anon";
GRANT ALL ON TABLE "public"."memory_artifacts" TO "authenticated";
GRANT ALL ON TABLE "public"."memory_artifacts" TO "service_role";


--
-- Name: TABLE "otp_verification"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."otp_verification" TO "service_role";


--
-- Name: TABLE "payments"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";


--
-- Name: TABLE "plans"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."plans" TO "anon";
GRANT ALL ON TABLE "public"."plans" TO "authenticated";
GRANT ALL ON TABLE "public"."plans" TO "service_role";


--
-- Name: TABLE "questions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."questions" TO "anon";
GRANT ALL ON TABLE "public"."questions" TO "authenticated";
GRANT ALL ON TABLE "public"."questions" TO "service_role";


--
-- Name: TABLE "razorpay_events"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."razorpay_events" TO "anon";
GRANT ALL ON TABLE "public"."razorpay_events" TO "authenticated";
GRANT ALL ON TABLE "public"."razorpay_events" TO "service_role";


--
-- Name: TABLE "reminder_templates"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."reminder_templates" TO "anon";
GRANT ALL ON TABLE "public"."reminder_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."reminder_templates" TO "service_role";


--
-- Name: TABLE "rsvp"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."rsvp" TO "anon";
GRANT ALL ON TABLE "public"."rsvp" TO "authenticated";
GRANT ALL ON TABLE "public"."rsvp" TO "service_role";


--
-- Name: TABLE "sent_reminders"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."sent_reminders" TO "anon";
GRANT ALL ON TABLE "public"."sent_reminders" TO "authenticated";
GRANT ALL ON TABLE "public"."sent_reminders" TO "service_role";


--
-- Name: TABLE "subscriptions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."subscriptions" TO "service_role";


--
-- Name: TABLE "supported_locales"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."supported_locales" TO "anon";
GRANT ALL ON TABLE "public"."supported_locales" TO "authenticated";
GRANT ALL ON TABLE "public"."supported_locales" TO "service_role";


--
-- Name: TABLE "tambola_state"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."tambola_state" TO "anon";
GRANT ALL ON TABLE "public"."tambola_state" TO "authenticated";
GRANT ALL ON TABLE "public"."tambola_state" TO "service_role";


--
-- Name: TABLE "transactions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."transactions" TO "anon";
GRANT ALL ON TABLE "public"."transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."transactions" TO "service_role";


--
-- Name: TABLE "translations"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."translations" TO "anon";
GRANT ALL ON TABLE "public"."translations" TO "authenticated";
GRANT ALL ON TABLE "public"."translations" TO "service_role";


--
-- Name: TABLE "users"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";


--
-- Name: TABLE "secrets"; Type: ACL; Schema: vault; Owner: supabase_admin
--

GRANT SELECT,REFERENCES,DELETE,TRUNCATE ON TABLE "vault"."secrets" TO "postgres" WITH GRANT OPTION;
GRANT SELECT,DELETE ON TABLE "vault"."secrets" TO "service_role";


--
-- Name: TABLE "decrypted_secrets"; Type: ACL; Schema: vault; Owner: supabase_admin
--

GRANT SELECT,REFERENCES,DELETE,TRUNCATE ON TABLE "vault"."decrypted_secrets" TO "postgres" WITH GRANT OPTION;
GRANT SELECT,DELETE ON TABLE "vault"."decrypted_secrets" TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";


--
-- Name: issue_graphql_placeholder; Type: EVENT TRIGGER; Schema: -; Owner: supabase_admin
--

-- CREATE EVENT TRIGGER "issue_graphql_placeholder" ON "sql_drop"
--          WHEN TAG IN ('DROP EXTENSION')
--    EXECUTE FUNCTION "extensions"."set_graphql_placeholder"();


-- ALTER EVENT TRIGGER "issue_graphql_placeholder" OWNER TO "supabase_admin";

--
-- Name: issue_pg_cron_access; Type: EVENT TRIGGER; Schema: -; Owner: supabase_admin
--

-- CREATE EVENT TRIGGER "issue_pg_cron_access" ON "ddl_command_end"
--          WHEN TAG IN ('CREATE EXTENSION')
--    EXECUTE FUNCTION "extensions"."grant_pg_cron_access"();


-- ALTER EVENT TRIGGER "issue_pg_cron_access" OWNER TO "supabase_admin";

--
-- Name: issue_pg_graphql_access; Type: EVENT TRIGGER; Schema: -; Owner: supabase_admin
--

-- CREATE EVENT TRIGGER "issue_pg_graphql_access" ON "ddl_command_end"
--          WHEN TAG IN ('CREATE EXTENSION')
--    EXECUTE FUNCTION "extensions"."grant_pg_graphql_access"();


-- ALTER EVENT TRIGGER "issue_pg_graphql_access" OWNER TO "supabase_admin";

--
-- Name: issue_pg_net_access; Type: EVENT TRIGGER; Schema: -; Owner: supabase_admin
--

-- CREATE EVENT TRIGGER "issue_pg_net_access" ON "ddl_command_end"
--          WHEN TAG IN ('CREATE EXTENSION')
--    EXECUTE FUNCTION "extensions"."grant_pg_net_access"();


-- ALTER EVENT TRIGGER "issue_pg_net_access" OWNER TO "supabase_admin";

--
-- Name: pgrst_ddl_watch; Type: EVENT TRIGGER; Schema: -; Owner: supabase_admin
--

-- CREATE EVENT TRIGGER "pgrst_ddl_watch" ON "ddl_command_end"
--    EXECUTE FUNCTION "extensions"."pgrst_ddl_watch"();


-- ALTER EVENT TRIGGER "pgrst_ddl_watch" OWNER TO "supabase_admin";

--
-- Name: pgrst_drop_watch; Type: EVENT TRIGGER; Schema: -; Owner: supabase_admin
--

-- CREATE EVENT TRIGGER "pgrst_drop_watch" ON "sql_drop"
--    EXECUTE FUNCTION "extensions"."pgrst_drop_watch"();


-- ALTER EVENT TRIGGER "pgrst_drop_watch" OWNER TO "supabase_admin";

--
-- PostgreSQL database dump complete
--

-- \unrestrict eU2ycP2YXXGkqJyAPZ61mQe0fPi9CcWWfKNgFqKBEtH974oPBSeb0FRNcPieP08

