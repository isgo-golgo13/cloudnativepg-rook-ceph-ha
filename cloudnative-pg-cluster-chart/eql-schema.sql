--
-- PostgreSQL database dump
--

-- Dumped from database version 15.8
-- Dumped by pg_dump version 15.1

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: eql; Type: SCHEMA; Schema: -; Owner: eql
--

CREATE SCHEMA eql;


ALTER SCHEMA eql OWNER TO eql;

--
-- Name: hdb_catalog; Type: SCHEMA; Schema: -; Owner: eql
--

CREATE SCHEMA hdb_catalog;


ALTER SCHEMA hdb_catalog OWNER TO eql;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner:
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: payout; Type: TYPE; Schema: eql; Owner: eql
--

CREATE TYPE eql.payout AS (
	correct integer,
	payout numeric
);


ALTER TYPE eql.payout OWNER TO eql;

--
-- Name: prize_table_entry; Type: TYPE; Schema: eql; Owner: eql
--

CREATE TYPE eql.prize_table_entry AS (
	pool_id uuid,
	correct integer,
	ticket_count integer,
	odds double precision
);


ALTER TYPE eql.prize_table_entry OWNER TO eql;

--
-- Name: eql_cancel_event(uuid); Type: FUNCTION; Schema: eql; Owner: eql
--

CREATE FUNCTION eql.eql_cancel_event(uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
event_in_pool bool;
event_in_draw bool;
ret jsonb;
BEGIN

select count(*)>0 into event_in_draw from eql.draw d where (d.status='OPEN' or d.status='CLOSED') and d.id in (select draw_id from eql.draw_event where event_id=$1);

select count(*)>0 into event_in_pool from eql.pool p where p.status='CLOSED' and p.draw_id in (select draw_id from eql.draw_event where event_id=$1);

if event_in_draw then
	select '{"error": "Event is in an active or past draw.  Cannot be cancelled."}'::jsonb into ret;
elsif event_in_pool then
	select '{"error": "Event is in a past pool.  Cannot be cancelled."}'::jsonb into ret;
else
	update eql.event set status='cancelled' where id=$1;

	update eql.draw d
	set
		valid = greatest(0, valid-1),
		cancelled = least(cancelled+1,(select g.target_event_count from eql.game g where g.id=d.game_id))
	where id in (select draw_id from eql.draw_event where event_id=$1);

	delete from eql.draw_event where event_id=$1;

	select '{"success": true}'::jsonb into ret;
end if;

return ret;
END;
$_$;


ALTER FUNCTION eql.eql_cancel_event(uuid) OWNER TO eql;

--
-- Name: eql_generate_draw(uuid, uuid, timestamp without time zone, boolean); Type: FUNCTION; Schema: eql; Owner: eql
--

CREATE FUNCTION eql.eql_generate_draw(gameid uuid, operatorid uuid, pool_start_time timestamp without time zone DEFAULT NULL::timestamp without time zone, test boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
	create_pool boolean := true;
	pool_end_time timestamp;
    draw_events_start_time timestamp;
	draw_events_end_time timestamp;
	draw_results_time timestamp;
	drawid uuid;
	poolid uuid;
	priorpoolid uuid;
	ret jsonb;
BEGIN

if pool_start_time is null then
	pool_start_time := current_timestamp;
end if;

-- bump pool start time to end of the latest pool currently configured for this operator and game
select
	greatest(pool_start_time,max(p.end)) into pool_start_time
from eql.pool p
join eql.draw d on p.draw_id=d.id
where p.operator_id=operatorid and d.game_id=gameid and p.status!='CANCELLED';

-- populate prior pool id for carryovers
select
	p.id into priorpoolid
from eql.pool p
join eql.draw d on p.draw_id=d.id
where p.end<=pool_start_time and p.operator_id=operatorid and d.game_id=gameid and p.status!='CANCELLED';

-- get midnight of the minium date of a draw rule for a day of the week greater than the pool start
select
	(to_char(min(day),'YYYY-MM-DD ')||'00:00')::timestamp into draw_events_start_time
from eql.game g
cross join jsonb_each(draw_config->'event_days') d
cross join jsonb_array_elements(d.value) dd
join generate_series(pool_start_time, pool_start_time + interval  '7 days', interval  '1 day') as t(day) on substring(to_char(day,'DY'),1,2)=(dd#>>'{}')
where
day>pool_start_time
and ((substring(to_char(pool_start_time,'DY'),1,2) not in (select dd2#>>'{}' from jsonb_array_elements(d.value) dd2)) or (day=(pool_start_time + interval  '7 days')))
and g.id=gameid;

-- get midnight of the maximum date of a draw rule for a day of the week greater than the draw start
select
	(to_char(max(day)+ interval  '1 day','YYYY-MM-DD ')||'00:00')::timestamp into draw_events_end_time
from eql.game g
cross join jsonb_each(draw_config->'event_days') d
cross join jsonb_array_elements(d.value) dd
join generate_series(pool_start_time, pool_start_time + interval  '6 days', interval  '1 day') as t(day) on substring(to_char(day,'DY'),1,2)=(dd#>>'{}')
where
day>draw_events_start_time and (substring(to_char(draw_events_start_time,'DY'),1,2) in (select dd2#>>'{}' from jsonb_array_elements(d.value) dd2))
and g.id=gameid;

if draw_events_end_time is null then
	select
		(to_char(max(day)+ interval  '1 day','YYYY-MM-DD ')||'00:00')::timestamp into draw_events_end_time
	from eql.game g
	cross join jsonb_each(draw_config->'event_days') d
	cross join jsonb_array_elements(d.value) dd
	join generate_series(pool_start_time, pool_start_time + interval  '7 days', interval  '1 day') as t(day) on substring(to_char(day,'DY'),1,2)=(dd#>>'{}')
	where to_char(day,'YYYYMMDD')=to_char(draw_events_start_time,'YYYYMMDD')
	and g.id=gameid;
end if;

-- set results time to one hour beyond end of draw games
select draw_events_end_time + interval  '1 hour' into draw_results_time;

-- pool ends when draw events start
pool_end_time := draw_events_start_time;

-- setup draw and pools
insert into eql.draw (game_id, events_start, events_end, results_time, status)
values (gameid,
		to_char(draw_events_start_time,'YYYY-MM-DD 04:00:00')::timestamp,
		to_char(draw_events_end_time,'YYYY-MM-DD 04:00:00')::timestamp,
		to_char(draw_results_time,'YYYY-MM-DD 04:00:00')::timestamp,
		CASE
			WHEN test THEN 'SCHEDULED'
			WHEN draw_events_start_time<=current_timestamp
			THEN 'OPEN'
			WHEN draw_events_end_time<current_timestamp
			THEN 'CLOSED'
			ELSE 'SCHEDULED' END)
returning id into drawid;

insert into eql.pool ("start", "end", draw_id, operator_id, prior_pool_id, status, test)
values (pool_start_time,
		to_char(pool_end_time,'YYYY-MM-DD 04:00:00')::timestamp,
		drawid,
		operatorid,
		priorpoolid,
		CASE
			WHEN test THEN 'OPEN'
			WHEN pool_start_time<=current_timestamp THEN 'OPEN'
			WHEN pool_end_time<current_timestamp THEN 'CLOSED'
			ELSE 'SCHEDULED' END,
		test)
returning id into poolid;

-- configure draw with elgible events for the draw window
call eql.eql_populate_draw_events(drawid);

-- return the pool info, draw info, and all eligible events
select row_to_json(r.*)::jsonb into ret
from
(select
 	poolid as pool_id,
 	drawid as draw_id,
	(select row_to_json(p.*)::jsonb from eql.pool p where id=poolid) as pool,
	(select row_to_json(d.*)::jsonb from eql.draw d where id=drawid) as draw,
	jsonb_agg(row_to_json(x.*)::jsonb) as events
from
(select
	c.id,
 	c.identifiers,
 	c.scheduled,
 	c.status,
 	row_to_json(ta.*) away,
 	row_to_json(th.*) home
from eql.draw_event dc
join eql.event c on c.id=dc.event_id
join eql.event_participant cta on c.id=cta.event_id and cta.home=false
join eql.event_participant cth on c.id=cth.event_id and cth.home=true
join eql.organization_member ta on ta.id=cta.member_id
join eql.organization_member th on th.id=cth.member_id
where dc.draw_id=drawid) x) r;

return ret;
END;
$$;


ALTER FUNCTION eql.eql_generate_draw(gameid uuid, operatorid uuid, pool_start_time timestamp without time zone, test boolean) OWNER TO eql;

--
-- Name: eql_get_payout_schedule(uuid, integer); Type: FUNCTION; Schema: eql; Owner: eql
--

CREATE FUNCTION eql.eql_get_payout_schedule(operatorid uuid, validgamecount integer) RETURNS SETOF eql.payout
    LANGUAGE plpgsql
    AS $$
BEGIN
	return query
	select x correct, coalesce(payouts.payout,'0.0') payout
	from generate_series(0,validgamecount-1) x
	left join (select idx, data::decimal payout
		from eql.operator o
		cross join jsonb_array_elements(o.config->'payouts'->(validgamecount::text)) with ordinality as t(data, idx)
		where o.id=operatorid) payouts on x=(validgamecount-idx)
	order by x desc;
END;
$$;


ALTER FUNCTION eql.eql_get_payout_schedule(operatorid uuid, validgamecount integer) OWNER TO eql;

--
-- Name: eql_populate_draw_events(uuid); Type: PROCEDURE; Schema: eql; Owner: eql
--

CREATE PROCEDURE eql.eql_populate_draw_events(IN uuid)
    LANGUAGE plpgsql
    AS $_$
BEGIN

insert into eql.organization_member (id, organization_id, name, abbreviation, identifiers)
select id,
    organization_id,
    away_name,
    away_alias,
    identifiers::jsonb from
(select distinct away_id::uuid as id, organization_id,
    away_name,
    away_alias, '{"sr":"' || sr_away_id || '"}' identifiers
 	from eql.sportradar src
 	where not exists (select * from eql.organization_member where id::text=src.away_id) and src.away_id is not null) teams;

insert into eql.organization_member (id, organization_id, name, abbreviation, identifiers)
select id,
    organization_id,
    home_name,
    home_alias,
    identifiers::jsonb from
(select distinct home_id::uuid as id, organization_id,
    home_name,
    home_alias, '{"sr":"' || sr_home_id || '"}' identifiers
 	from eql.sportradar src
 	where not exists (select * from eql.organization_member where id::text=src.home_id) and src.home_id is not null) teams;

insert into eql.event (id, organization_id, scheduled, venue_timezone, venue, status, identifiers, config)
select distinct id::uuid, organization_id, scheduled, venue_timezone, venue, status, ('{"sr":"' || sr_id || '"}')::jsonb , '{"n":2,"pick":1,"min_n":2}'::jsonb
from eql.sportradar src
where status='closed' and not exists (select * from eql.event where id::text=src.id) and src.home_id is not null and src.away_id is not null and src.id is not null;

insert into eql.event (id, organization_id, scheduled, venue_timezone, venue, status, identifiers, config)
select distinct id::uuid, organization_id, scheduled, venue_timezone, venue, status, ('{"sr":"' || sr_id || '"}')::jsonb , '{"n":2,"pick":1,"min_n":2}'::jsonb
from eql.sportradar src
where status='schedule' and not exists (select * from eql.event where id::text=src.id) and src.home_id is not null and src.away_id is not null and src.id is not null;

insert into eql.event_participant (event_id, member_id, rank, score, home)
select
	distinct
	event_id,
	eql_home_id,
	case when home_points is null or away_points is null then null when home_points>away_points then 1 else 2 end,
	home_points,
	true
from eql.sportradar src
where not exists (select *
						from eql.event_participant sct
						join eql.event sc on sc.id=sct.event_id
						join eql.organization_member st on st.id=sct.member_id
						where sc.id::text=src.id
						and st.id::text=src.home_id)
	 and src.status='closed' and src.home_id is not null and src.away_id is not null and src.event_id is not null;

insert into eql.event_participant (event_id, member_id, rank, score, home)
select
		distinct
		event_id,
		eql_away_id,
		case when home_points is null or away_points is null then null when home_points>away_points then 2 else 1 end,
		away_points,
		false
from eql.sportradar src
where not exists (select *
						from eql.event_participant sct
						join eql.event sc on sc.id=sct.event_id
						join eql.organization_member st on st.id=sct.member_id
						where sc.id::text=src.id
						and st.id::text=src.away_id)
      and src.status='closed' and src.home_id is not null and src.away_id is not null and src.event_id is not null;

insert into eql.event_participant (event_id, member_id, rank, score, home)
select
	distinct
	event_id,
	eql_home_id,
	case when home_points is null or away_points is null then null when home_points>away_points then 1 else 2 end,
	home_points,
	true
from eql.sportradar src
where not exists (select *
						from eql.event_participant sct
						join eql.event sc on sc.id=sct.event_id
						join eql.organization_member st on st.id=sct.member_id
						where sc.id::text=src.id
						and st.id::text=src.home_id)
	 and src.status='scheduled' and src.home_id is not null and src.away_id is not null and src.event_id is not null;

insert into eql.event_participant (event_id, member_id, rank, score, home)
select
		distinct
		event_id,
		eql_away_id,
		case when home_points is null or away_points is null then null when home_points>away_points then 2 else 1 end,
		away_points,
		false
from eql.sportradar src
where not exists (select *
						from eql.event_participant sct
						join eql.event sc on sc.id=sct.event_id
						join eql.organization_member st on st.id=sct.member_id
						where sc.id::text=src.id
						and st.id::text=src.away_id)
      and src.status='scheduled' and src.home_id is not null and src.away_id is not null and src.event_id is not null;

insert into eql.draw_event (draw_id, event_id)
select d.id, c.id
from eql.event c
join eql.game g on (g.event_specs->0->'source'->>'id')::uuid=c.organization_id
join eql.draw d on d.game_id=g.id and c.scheduled>d.events_start and c.scheduled<d.events_end
where d.id=$1 and not exists (select * from eql.draw_event where draw_id=$1) and c.status not in ('cancelled','canceled','suspended','unnecessary');

update eql.draw d set valid=(select (g.event_specs->0->'target_events')::int from eql.game g where g.id=d.game_id) where id=$1;
update eql.draw d set total=(select count(*) from eql.draw_event where draw_id=d.id) where id=$1;

END;
$_$;


ALTER PROCEDURE eql.eql_populate_draw_events(IN uuid) OWNER TO eql;

--
-- Name: eql_process_ticket_results(uuid); Type: FUNCTION; Schema: eql; Owner: eql
--

CREATE FUNCTION eql.eql_process_ticket_results(uuid) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
drawid uuid;
pool_ticket_count bigint;
ret jsonb;
invalid_pool bool;
carryover numeric;
prize_pool_amount numeric;
fixed_prize_amount numeric;
top_prize_count int;
BEGIN

select draw_id into drawid from eql.pool where id=$1;

-- remove any events which are not complete from the draw
delete from eql.draw_event where draw_id=drawid and event_id in (select id from eql.event where status='postponed' or status='cancelled' or status='canceled');

update eql.draw d
set valid = (select count(*) from eql.draw_event where draw_id=d.id)
where id = (select draw_id from eql.pool where id=$1);

update eql.draw d
set cancelled = least(d.total,(select g.target_event_count from eql.game g where g.id=d.game_id))-d.valid
where id = (select draw_id from eql.pool where id=$1);

-- Set invalid_pool to true if there are less than the minimum number of valid events in this draw, otherwise false
select (g.min_event_count > v.valid_events) into invalid_pool
from eql.game g
join
(select d.game_id, count(e.id) valid_events
from eql.pool p
join eql.draw d on d.id=p.draw_id
left join eql.draw_event de on de.draw_id=p.draw_id
left join eql.event e on e.id=de.event_id and e.status = 'closed'
where p.id=$1
group by d.game_id) v on v.game_id=g.id;

-- The pool was not valid, not enough events happened
if invalid_pool then

	-- set all tickets CASHABLE i.e. redeemable for a free ticekt
	update eql.ticket set status='CASHABLE', prize_amount=price, prize_type='TICKET' where pool_id=$1;

	-- set the pool to CANCELED
	update eql.pool set status='CANCELED' where id=$1;

	-- return an error message stating why the pool was cancelled
	select '{"error": "Too many cancelations.  All tickets can be exchanged for the next pool."}'::jsonb into ret;

-- else the pool is valid continue calculating results
else
	-- this temp table is to cache all event participants for this pool to speed calculation of event results for tickets
	create temp table pool_event
	(
		event_id text NOT NULL,
		participants JSONB NOT NULL,
		CONSTRAINT eql_pool_event_pkey PRIMARY KEY (event_id)
	);

	insert into pool_event
	select
		de.event_id::text,
		(select jsonb_agg(row_to_json(r.*))
		from
		(select
				ep.member_id as id,
				om.abbreviation as alias,
				ep.rank,
				ep.score
		 from eql.event_participant ep
		 join eql.organization_member om on om.id=ep.member_id
		 where ep.event_id=de.event_id
		 order by ep.rank) r) participants
	from eql.pool p
	join eql.draw_event de on p.draw_id=de.draw_id
	join eql.event e on de.event_id=e.id
	where p.id=$1 and e.status='closed';

	-- update all tickets in this pool with the results of the events, the resulting "score" (number correct) for this ticket, and the results time
	update eql.ticket
	set data=results.data, score=results.score, results_time=current_timestamp
	from
	(select
	ticket_id,
	json_agg
	(case
		when score is not null then jsonb_set(jsonb_set(data,'{score}',score::text::jsonb),'{participants}', participants)
		else data
	end) as data,
	sum(score) score
	from
	(select
		t.id ticket_id,
		p.idx,
		p.data,
		pep.participants,
		case when p.data#>>'{picks,0,id}'=pep.participants#>>'{0,id}' then 1 else 0 end score
	from eql.ticket t
	cross join jsonb_array_elements(t.data) with ordinality as p(data, idx)
	join pool_event pep on pep.event_id=p.data->>'id'
	where pool_id=$1) x
	group by ticket_id) results
	where id=results.ticket_id;

	drop table pool_event;

	-- create temp table for tallying ticket totals for each prize tier
	create temp table pool_prize_table
	(
		pool_id uuid NOT NULL,
		score integer NOT NULL,
		odds float,
		ticket_count bigint,
		ticket_total numeric,
		prize_total numeric,
		CONSTRAINT eql_pool_prize_table_pkey PRIMARY KEY (pool_id, score)
	);

	-- get the total number of tickets in the pool to calculate odds for each prize tier
	select count(*) into pool_ticket_count from eql.ticket where pool_id=$1;

	-- tally each prize tier ticket totals
	insert into pool_prize_table (pool_id, score, odds, ticket_count, ticket_total)
		select
			t.pool_id,
			t.score,
			case when count(*)=0 then 0 else pool_ticket_count / count(*) end,
			count(*),
			sum(t.price)
		from eql.ticket t
		join eql.pool p on t.pool_id = p.id
		join eql.draw d on d.id = p.draw_id
		where t.pool_id=$1
		group by t.pool_id, t.score;

	-- update each prize tier based on the operator configuration for this game using the function eql_get_payout_schedule
	-- to get the payout schedule based on operator and the number of valid games in this draw
	update pool_prize_table
	set prize_total = case when (fixed_prize.total::decimal)<0 then 1::numeric else fixed_prize.total end
	from (select pspt.pool_id,
			pspt.score,
			sum(ps.payout * pspt.ticket_count) AS total
		from pool_prize_table pspt
		join eql.pool p on pspt.pool_id = p.id
		join eql.draw d on d.id = p.draw_id
		join lateral eql.eql_get_payout_schedule(p.operator_id, d.valid) ps(score, payout) on ps.score = pspt.score
		where pspt.pool_id=$1
		group by pspt.pool_id, pspt.score) fixed_prize
	where pool_prize_table.pool_id=fixed_prize.pool_id and pool_prize_table.score=fixed_prize.score;

	-- remove any old pool results for this pool
	delete from eql.pool_result where pool_id=$1;

	-- set amount being carried over from prior pool
	select carryover_amount into carryover from eql.pool_result pr join eql.pool p on pr.pool_id=p.prior_pool_id where p.id=$1;

	-- calculat the top prize amounts based on the RTP setting for the pool and the totals for the fixed prize ammounts
	select sum(p.return_to_pool::double precision * pt.ticket_total) + coalesce(carryover,0::numeric) into prize_pool_amount
	from pool_prize_table pt
	join eql.pool p on p.id = pt.pool_id
	where p.id = $1;

	select sum(pool_prize_table.prize_total) into fixed_prize_amount
    from pool_prize_table
	where pool_prize_table.pool_id = $1;

	select eppt.ticket_count into top_prize_count
	from pool_prize_table eppt
	join eql.pool pl on pl.id = eppt.pool_id
	join eql.draw dr on dr.id = pl.draw_id and dr.valid = eppt.score
	where eppt.pool_id = $1;

	insert into eql.pool_result
	select pt.pool_id,
		pool_ticket_count,
		sum(pt.ticket_total),
		prize_pool_amount,
		case when top_prize_count=0 then 0::numeric else (prize_pool_amount - fixed_prize_amount) end,
		case when top_prize_count=0 then 0::numeric else (prize_pool_amount - fixed_prize_amount) / top_prize_count end,
		fixed_prize_amount,
		(select jsonb_agg(row_to_json(pzt.*)::jsonb - 'pool_id') from pool_prize_table pzt)
	from pool_prize_table pt
	join eql.pool p ON p.id = pt.pool_id
	where p.id = $1
	group by pt.pool_id;

	-- make sure the top prize amount is at least $1
	update eql.pool_result
	set single_top_prize=1,
	total_top_prize=(select count(*)::decimal::numeric from pool_prize_table ppt join eql.pool p on p.id=ppt.pool_id join eql.draw d on p.draw_id=d.id where ppt.score=d.valid)
	where single_top_prize::decimal::int<1 and pool_id=$1;

	-- get rid of any entries for tallies greater than the number of valid events (shouldn't happen)
	delete from pool_prize_table
	where score>(select valid from eql.draw d join eql.pool p on p.id=p.draw_id where p.id=$1);

	-- generate the fixed prize table as a JSON structure in the pool result, and add the top prize amounts to the table
	update eql.pool_result e
	set
	fixed_prize_table =
	(select
		json_agg(
		case
			when fpt->>'prize_total' is null then jsonb_set(fpt,'{prize_total}',('"'||total_top_prize::text||'"')::jsonb)
			else fpt
		end)
	from eql.pool_result epr
	cross join jsonb_array_elements(fixed_prize_table) fpt
	where epr.pool_id=$1)
	where e.pool_id=$1;

	-- set the prize amounts and statuses for all tickets in the pool
	update eql.ticket tr
	set
		results_time=current_timestamp,
		prize_amount=results.prize_amount::numeric,
		prize_type=results.prize_type,
		status=results.status
	from (select
		t.id,
		case
			when (fpt.value->>'ticket_count')!='0'
			then round((fpt.value->>'prize_total')::numeric / (fpt.value->>'ticket_count')::numeric)
		end prize_amount,
		case
			when (fpt.value->>'prize_total')!='0' then 'CASH'
			else null
		end prize_type,
		case
			when (fpt.value->>'prize_total')!='0' then 'CASHABLE'
			else 'NOPRIZE'
		end status
	from eql.ticket t
	join eql.pool_result epr on epr.pool_id=t.pool_id
	join jsonb_array_elements(fixed_prize_table) fpt on (fpt->'score')::int=t.score
	where t.pool_id=$1
	) results
	where results.id=tr.id;

	-- mark all tickets without a prize as NOPRIZE
	update eql.ticket set status='NOPRIZE', results_time=current_timestamp where pool_id=$1 and status='ISSUED';

	-- make sure the pool is closed
	update eql.pool set
	    status='CLOSED',
	    "end"=(select min(scheduled) from eql.event e join eql.draw_event de on de.event_id=e.id where de.draw_id=drawid)
	  where id=$1;

	-- make sure the draw is closed
	update eql.draw set
	    status='CLOSED',
	    events_start=(select min(scheduled) from eql.event e join eql.draw_event de on de.event_id=e.id where de.draw_id=drawid),
	    events_end=(select max(scheduled + '2.5 hour'::interval) from eql.event e join eql.draw_event de on de.event_id=e.id where de.draw_id=drawid),
	    results_time=(select max(scheduled + '2.5 hour'::interval) from eql.event e join eql.draw_event de on de.event_id=e.id where de.draw_id=drawid)
	where id=(select draw_id from eql.pool where id=$1);

	-- calculate the carryover to the next pool
	update eql.pool_result
	set
	single_top_prize=round(single_top_prize::numeric)::numeric,
	carryover_amount=pool_amount-(select sum(t.prize_amount) from eql.ticket t where pool_id=$1)
	where pool_id=$1;

	-- return the results
	select row_to_json(pr.*)::jsonb into ret
	from eql.pool_result pr
	where pool_id=$1;

	drop table pool_prize_table;
end if;
return ret;
END;
$_$;


ALTER FUNCTION eql.eql_process_ticket_results(uuid) OWNER TO eql;

--
-- Name: gen_hasura_uuid(); Type: FUNCTION; Schema: hdb_catalog; Owner: eql
--

CREATE FUNCTION hdb_catalog.gen_hasura_uuid() RETURNS uuid
    LANGUAGE sql
    AS $$select gen_random_uuid()$$;


ALTER FUNCTION hdb_catalog.gen_hasura_uuid() OWNER TO eql;

--
-- Name: user_search(text); Type: FUNCTION; Schema: public; Owner: eql
--

CREATE FUNCTION public.user_search(uname text) RETURNS TABLE(usename name, passwd text)
    LANGUAGE sql SECURITY DEFINER
    AS $_$SELECT usename, passwd FROM pg_shadow WHERE usename=$1;$_$;


ALTER FUNCTION public.user_search(uname text) OWNER TO eql;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: audit; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.audit (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_type text NOT NULL,
    user_id text,
    event_time timestamp without time zone DEFAULT now() NOT NULL,
    detail jsonb NOT NULL,
    session_id text,
    message text,
    significance integer DEFAULT 0 NOT NULL,
    resource_type text NOT NULL,
    event_origin text NOT NULL
);


ALTER TABLE eql.audit OWNER TO eql;

--
-- Name: bonus; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.bonus (
    game_instance_id uuid NOT NULL,
    player_id text NOT NULL,
    count integer DEFAULT 1 NOT NULL,
    expiration_time timestamp with time zone NOT NULL,
    value integer NOT NULL,
    created_time timestamp with time zone DEFAULT now() NOT NULL,
    removed_time timestamp with time zone,
    currency text,
    country text,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    external_id text,
    lines integer DEFAULT 5 NOT NULL
);


ALTER TABLE eql.bonus OWNER TO eql;

--
-- Name: game; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.game (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    config jsonb,
    url character varying(300),
    logo text,
    code text,
    type text DEFAULT 'DRAW'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    subtype text,
    studio text,
    integration_type text
);


ALTER TABLE eql.game OWNER TO eql;

--
-- Name: game_instance; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.game_instance (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    game_id uuid NOT NULL,
    operator_id uuid NOT NULL,
    config jsonb,
    version integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text NOT NULL,
    scenario_collection_code text,
    scenario_pool_index integer,
    active boolean DEFAULT true NOT NULL,
    language text DEFAULT 'en'::text,
    currency text DEFAULT 'USD'::text,
    code text NOT NULL,
    content_path_override text,
    operator_game_id text,
    studio_game_id text,
    url text
);


ALTER TABLE eql.game_instance OWNER TO eql;

--
-- Name: ticket; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.ticket (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    vendor_ticket_id character varying(100),
    issued_time timestamp without time zone NOT NULL,
    updated_time timestamp without time zone,
    pool_id uuid,
    location character varying(100),
    status character varying(100),
    tender_type character varying(100),
    price numeric,
    data jsonb,
    terminal_id character varying(100),
    score integer,
    results_time timestamp with time zone,
    transaction_id character varying(100),
    prize_type character varying(100),
    prize_amount numeric,
    prior_ticket_id uuid,
    redemption_time timestamp with time zone,
    redemption_type character varying(100),
    redemption_amount numeric,
    expire_time timestamp with time zone,
    player_id text,
    geo_hash text,
    prize_name text,
    player_status text,
    event_id uuid,
    scenario_pool_id uuid,
    game_instance_id uuid,
    currency text DEFAULT 'USD'::text NOT NULL,
    settled_time timestamp with time zone,
    reversal_time timestamp with time zone,
    info jsonb,
    ip text,
    start_balance numeric,
    end_balance numeric,
    mode text DEFAULT 'D'::text NOT NULL,
    token text,
    bonus_id uuid
);


ALTER TABLE eql.ticket OWNER TO eql;

--
-- Name: coin_in_view; Type: VIEW; Schema: eql; Owner: eql
--

CREATE VIEW eql.coin_in_view AS
 SELECT date(ticket.issued_time) AS date,
    round((sum(ticket.price) / (100)::numeric), 2) AS coin_in
   FROM ((eql.ticket
     JOIN eql.game_instance ON ((ticket.game_instance_id = game_instance.id)))
     JOIN eql.game ON ((game_instance.game_id = game.id)))
  WHERE (ticket.mode = 'M'::text)
  GROUP BY (date(ticket.issued_time));


ALTER TABLE eql.coin_in_view OWNER TO eql;

--
-- Name: draw; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.draw (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    events_start timestamp without time zone,
    events_end timestamp without time zone,
    results_time timestamp without time zone,
    total integer DEFAULT 10,
    cancelled integer DEFAULT 0,
    valid integer DEFAULT 0,
    status character varying(100) DEFAULT 'SCHEDULED'::character varying NOT NULL,
    config jsonb,
    game_instance_id uuid NOT NULL
);


ALTER TABLE eql.draw OWNER TO eql;

--
-- Name: draw_event; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.draw_event (
    draw_id uuid NOT NULL,
    event_id uuid NOT NULL
);


ALTER TABLE eql.draw_event OWNER TO eql;

--
-- Name: event; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.event (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    start timestamp without time zone,
    "end" timestamp without time zone,
    result jsonb,
    organization_id uuid,
    scheduled timestamp without time zone,
    venue_timezone character varying(100),
    venue jsonb,
    status character varying(50),
    identifiers jsonb,
    type text DEFAULT 'MATCH'::text NOT NULL,
    descending boolean DEFAULT false NOT NULL,
    config jsonb,
    parent_event_id uuid,
    sequence integer DEFAULT 0 NOT NULL
);


ALTER TABLE eql.event OWNER TO eql;

--
-- Name: event_participant; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.event_participant (
    event_id uuid NOT NULL,
    member_id uuid NOT NULL,
    rank integer,
    score numeric,
    home boolean,
    data jsonb,
    status text
);


ALTER TABLE eql.event_participant OWNER TO eql;

--
-- Name: feed; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.feed (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(1000),
    api_key character varying(4000),
    base_url character varying(1000),
    provider character varying(1000)
);


ALTER TABLE eql.feed OWNER TO eql;

--
-- Name: feed_data; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.feed_data (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    feed_endpoint_id uuid NOT NULL,
    data jsonb NOT NULL,
    asof date NOT NULL,
    latest boolean,
    fetch_time timestamp without time zone
);


ALTER TABLE eql.feed_data OWNER TO eql;

--
-- Name: feed_endpoint; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.feed_endpoint (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    feed_id uuid NOT NULL,
    data_format character varying(100) NOT NULL,
    request_method character varying(10) NOT NULL,
    path_pattern character varying(1000) NOT NULL,
    params json,
    data_provided character varying
);


ALTER TABLE eql.feed_endpoint OWNER TO eql;

--
-- Name: my_view; Type: VIEW; Schema: eql; Owner: eql
--

CREATE VIEW eql.my_view AS
 SELECT date(t1.issued_time) AS day,
    round((sum(t1.price) / 100.0), 2) AS coin_in,
    ( SELECT round((sum(t2.prize_amount) / 100.0), 2) AS round
           FROM eql.ticket t2
          WHERE ((t2.issued_time >= '2023-12-12 00:00:00'::timestamp without time zone) AND (t2.issued_time < '2023-12-13 00:00:00'::timestamp without time zone) AND (t2.mode = 'M'::text) AND (t2.game_instance_id IN ( SELECT game_instance.id
                   FROM eql.game_instance
                  WHERE (game_instance.game_id IN ( SELECT game.id
                           FROM eql.game
                          WHERE ((game.name)::text = 'Drop the Ball'::text))))))) AS coin_out,
    ( SELECT count(t3.id) AS count
           FROM eql.ticket t3
          WHERE ((t3.issued_time >= '2023-12-12 00:00:00'::timestamp without time zone) AND (t3.issued_time < '2023-12-13 00:00:00'::timestamp without time zone) AND (t3.mode = 'M'::text) AND (t3.game_instance_id IN ( SELECT game_instance.id
                   FROM eql.game_instance
                  WHERE (game_instance.game_id IN ( SELECT game.id
                           FROM eql.game
                          WHERE ((game.name)::text = 'Drop the Ball'::text))))))) AS games_played,
    ( SELECT count(DISTINCT t4.transaction_id) AS count
           FROM eql.ticket t4
          WHERE ((t4.issued_time >= '2023-12-12 00:00:00'::timestamp without time zone) AND (t4.issued_time < '2023-12-13 00:00:00'::timestamp without time zone) AND (t4.mode = 'M'::text) AND (t4.game_instance_id IN ( SELECT game_instance.id
                   FROM eql.game_instance
                  WHERE (game_instance.game_id IN ( SELECT game.id
                           FROM eql.game
                          WHERE ((game.name)::text = 'Drop the Ball'::text))))))) AS played_sessions,
    ( SELECT count(DISTINCT t5.player_id) AS count
           FROM eql.ticket t5
          WHERE ((t5.issued_time >= '2023-12-12 00:00:00'::timestamp without time zone) AND (t5.issued_time < '2023-12-13 00:00:00'::timestamp without time zone) AND (t5.mode = 'M'::text) AND (t5.game_instance_id IN ( SELECT game_instance.id
                   FROM eql.game_instance
                  WHERE (game_instance.game_id IN ( SELECT game.id
                           FROM eql.game
                          WHERE ((game.name)::text = 'Drop the Ball'::text))))))) AS unique_players
   FROM eql.ticket t1
  WHERE ((t1.issued_time >= '2023-12-12 00:00:00'::timestamp without time zone) AND (t1.issued_time < '2023-12-15 00:00:00'::timestamp without time zone) AND (t1.mode = 'M'::text) AND (t1.game_instance_id IN ( SELECT game_instance.id
           FROM eql.game_instance
          WHERE (game_instance.game_id IN ( SELECT game.id
                   FROM eql.game
                  WHERE ((game.name)::text = 'Drop the Ball'::text))))))
  GROUP BY (date(t1.issued_time));


ALTER TABLE eql.my_view OWNER TO eql;

--
-- Name: operator; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.operator (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    name character varying(1000),
    description text,
    code character varying(10) DEFAULT 'INTRALOT'::text,
    frontend text DEFAULT 'INTRALOT'::text,
    backend text DEFAULT 'INTRALOT'::text,
    rng_instance_id uuid,
    config jsonb,
    production_domain text
);


ALTER TABLE eql.operator OWNER TO eql;

--
-- Name: organization; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.organization (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    name character varying(200) NOT NULL,
    description text
);


ALTER TABLE eql.organization OWNER TO eql;

--
-- Name: organization_member; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.organization_member (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    name character varying(1000),
    abbreviation character varying(10),
    identifiers jsonb,
    logo_url text
);


ALTER TABLE eql.organization_member OWNER TO eql;

--
-- Name: pool; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.pool (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    start timestamp without time zone,
    "end" timestamp without time zone,
    draw_id uuid NOT NULL,
    operator_id uuid NOT NULL,
    prior_pool_id uuid,
    ticket_price integer DEFAULT 5 NOT NULL,
    status character varying(100) DEFAULT 'SCHEDULED'::character varying NOT NULL,
    return_to_pool numeric DEFAULT 0.6 NOT NULL,
    test boolean DEFAULT false NOT NULL
);


ALTER TABLE eql.pool OWNER TO eql;

--
-- Name: pool_result; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.pool_result (
    pool_id uuid NOT NULL,
    ticket_count bigint,
    total_revenue numeric,
    total_cost numeric,
    total_prize numeric,
    total_prize_fixed numeric,
    total_prize_parimutuel numeric,
    top_prize numeric,
    carryover numeric,
    prize_table jsonb,
    stats jsonb,
    count_prize_parimutuel integer,
    count_prize_fixed bigint,
    draw_results jsonb,
    count_prize bigint
);


ALTER TABLE eql.pool_result OWNER TO eql;

--
-- Name: report_view; Type: VIEW; Schema: eql; Owner: eql
--

CREATE VIEW eql.report_view AS
 SELECT date(t1.issued_time) AS day,
    round((sum(t1.price) / 100.0), 2) AS coin_in,
    ( SELECT round((sum(t2.prize_amount) / 100.0), 2) AS round
           FROM eql.ticket t2
          WHERE ((t2.mode = 'M'::text) AND (t2.game_instance_id IN ( SELECT game_instance.id
                   FROM eql.game_instance
                  WHERE (game_instance.game_id IN ( SELECT game.id
                           FROM eql.game
                          WHERE ((game.name)::text = 'Drop the Ball'::text))))))) AS coin_out,
    ( SELECT count(t3.id) AS count
           FROM eql.ticket t3
          WHERE ((t3.mode = 'M'::text) AND (t3.game_instance_id IN ( SELECT game_instance.id
                   FROM eql.game_instance
                  WHERE (game_instance.game_id IN ( SELECT game.id
                           FROM eql.game
                          WHERE ((game.name)::text = 'Drop the Ball'::text))))))) AS games_played,
    ( SELECT count(DISTINCT t4.transaction_id) AS count
           FROM eql.ticket t4
          WHERE ((t4.mode = 'M'::text) AND (t4.game_instance_id IN ( SELECT game_instance.id
                   FROM eql.game_instance
                  WHERE (game_instance.game_id IN ( SELECT game.id
                           FROM eql.game
                          WHERE ((game.name)::text = 'Drop the Ball'::text))))))) AS played_sessions,
    ( SELECT count(DISTINCT t5.player_id) AS count
           FROM eql.ticket t5
          WHERE ((t5.mode = 'M'::text) AND (t5.game_instance_id IN ( SELECT game_instance.id
                   FROM eql.game_instance
                  WHERE (game_instance.game_id IN ( SELECT game.id
                           FROM eql.game
                          WHERE ((game.name)::text = 'Drop the Ball'::text))))))) AS unique_players
   FROM eql.ticket t1
  WHERE ((t1.mode = 'M'::text) AND (t1.game_instance_id IN ( SELECT game_instance.id
           FROM eql.game_instance
          WHERE (game_instance.game_id IN ( SELECT game.id
                   FROM eql.game
                  WHERE ((game.name)::text = 'Drop the Ball'::text))))) AND (t1.issued_time >= '2023-12-12 00:00:00'::timestamp without time zone) AND (t1.issued_time < '2023-12-15 00:00:00'::timestamp without time zone))
  GROUP BY (date(t1.issued_time));


ALTER TABLE eql.report_view OWNER TO eql;

--
-- Name: request_sequence; Type: SEQUENCE; Schema: eql; Owner: eql
--

CREATE SEQUENCE eql.request_sequence
    START WITH 1000500
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE eql.request_sequence OWNER TO eql;

--
-- Name: rng; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.rng (
    instance_id uuid NOT NULL,
    drand_round bigint NOT NULL,
    nonce bigint NOT NULL
);


ALTER TABLE eql.rng OWNER TO eql;

--
-- Name: rng_instance; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.rng_instance (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    key text NOT NULL,
    config jsonb
);


ALTER TABLE eql.rng_instance OWNER TO eql;

--
-- Name: scenario; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.scenario (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    index integer NOT NULL,
    payload jsonb NOT NULL,
    collection_code text NOT NULL,
    n integer DEFAULT 1 NOT NULL,
    prize_amount double precision DEFAULT '0'::double precision
);


ALTER TABLE eql.scenario OWNER TO eql;

--
-- Name: scenario_pool; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.scenario_pool (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    game_instance_id uuid NOT NULL,
    scenario_id uuid NOT NULL,
    ticket_id uuid,
    used_time timestamp with time zone,
    index integer DEFAULT 1 NOT NULL
);


ALTER TABLE eql.scenario_pool OWNER TO eql;

--
-- Name: simulation; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.simulation (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    draw_id uuid NOT NULL,
    speed integer DEFAULT 1 NOT NULL,
    data jsonb,
    feed_endpoint_id uuid,
    threshold integer DEFAULT 0 NOT NULL
);


ALTER TABLE eql.simulation OWNER TO eql;

--
-- Name: sportradar; Type: VIEW; Schema: eql; Owner: eql
--

CREATE VIEW eql.sportradar AS
 SELECT (g.value ->> 'id'::text) AS id,
    (g.value ->> 'sr_id'::text) AS sr_id,
    c.id AS event_id,
    s.id AS organization_id,
    api.id AS feed_id,
    endpoint.id AS feed_endpoint_id,
    dt.id AS data_id,
    dt.asof,
    (g.value ->> 'status'::text) AS status,
    ((g.value ->> 'scheduled'::text))::timestamp without time zone AS scheduled,
    (g.value -> 'venue'::text) AS venue,
    ((g.value -> 'time_zones'::text) -> 'venue'::text) AS venue_timezone,
    ((g.value -> 'away'::text) ->> 'name'::text) AS away_name,
    COALESCE(((g.value -> 'away'::text) ->> 'alias'::text), ((g.value -> 'away'::text) ->> 'abbr'::text)) AS away_alias,
    ((g.value -> 'away'::text) ->> 'id'::text) AS away_id,
    ((g.value -> 'away'::text) ->> 'sr_id'::text) AS sr_away_id,
    ateam.id AS eql_away_id,
    ((g.value ->> 'away_points'::text))::integer AS away_points,
    ((g.value -> 'home'::text) ->> 'name'::text) AS home_name,
    COALESCE(((g.value -> 'home'::text) ->> 'alias'::text), ((g.value -> 'home'::text) ->> 'abbr'::text)) AS home_alias,
    ((g.value -> 'home'::text) ->> 'id'::text) AS home_id,
    ((g.value -> 'home'::text) ->> 'sr_id'::text) AS sr_home_id,
    hteam.id AS eql_home_id,
    ((g.value ->> 'home_points'::text))::integer AS home_points
   FROM (((((((eql.organization s
     JOIN eql.feed api ON ((s.id = api.organization_id)))
     JOIN eql.feed_endpoint endpoint ON ((api.id = endpoint.feed_id)))
     JOIN eql.feed_data dt ON (((endpoint.id = dt.feed_endpoint_id) AND (dt.latest = true))))
     CROSS JOIN LATERAL jsonb_array_elements((dt.data -> 'games'::text)) g(value))
     LEFT JOIN eql.organization_member ateam ON (((ateam.id)::text = ((g.value -> 'away'::text) ->> 'id'::text))))
     LEFT JOIN eql.organization_member hteam ON (((hteam.id)::text = ((g.value -> 'home'::text) ->> 'id'::text))))
     LEFT JOIN eql.event c ON (((c.id)::text = (g.value ->> 'id'::text))))
  WHERE (((api.provider)::text = 'sportradar'::text) AND ((endpoint.data_provided)::text = 'schedule'::text))
UNION
 SELECT (g.value ->> 'id'::text) AS id,
    (g.value ->> 'sr_id'::text) AS sr_id,
    c.id AS event_id,
    s.id AS organization_id,
    api.id AS feed_id,
    endpoint.id AS feed_endpoint_id,
    dt.id AS data_id,
    dt.asof,
    (g.value ->> 'status'::text) AS status,
    ((g.value ->> 'scheduled'::text))::timestamp without time zone AS scheduled,
    (g.value -> 'venue'::text) AS venue,
    ((g.value -> 'time_zones'::text) -> 'venue'::text) AS venue_timezone,
    ((g.value -> 'away'::text) ->> 'name'::text) AS away_name,
    COALESCE(((g.value -> 'away'::text) ->> 'alias'::text), ((g.value -> 'away'::text) ->> 'abbr'::text)) AS away_alias,
    ((g.value -> 'away'::text) ->> 'id'::text) AS away_id,
    ((g.value -> 'away'::text) ->> 'sr_id'::text) AS sr_away_id,
    ateam.id AS eql_away_id,
    (((g.value -> 'scoring'::text) ->> 'away_points'::text))::integer AS away_points,
    ((g.value -> 'home'::text) ->> 'name'::text) AS home_name,
    COALESCE(((g.value -> 'home'::text) ->> 'alias'::text), ((g.value -> 'home'::text) ->> 'abbr'::text)) AS home_alias,
    ((g.value -> 'home'::text) ->> 'id'::text) AS home_id,
    ((g.value -> 'home'::text) ->> 'sr_id'::text) AS sr_home_id,
    hteam.id AS eql_home_id,
    (((g.value -> 'scoring'::text) ->> 'home_points'::text))::integer AS home_points
   FROM ((((((((eql.organization s
     JOIN eql.feed api ON ((s.id = api.organization_id)))
     JOIN eql.feed_endpoint endpoint ON ((api.id = endpoint.feed_id)))
     JOIN eql.feed_data dt ON (((endpoint.id = dt.feed_endpoint_id) AND (dt.latest = true))))
     CROSS JOIN LATERAL jsonb_array_elements((dt.data -> 'weeks'::text)) w(value))
     CROSS JOIN LATERAL jsonb_array_elements((w.value -> 'games'::text)) g(value))
     LEFT JOIN eql.organization_member ateam ON (((ateam.id)::text = ((g.value -> 'away'::text) ->> 'id'::text))))
     LEFT JOIN eql.organization_member hteam ON (((hteam.id)::text = ((g.value -> 'home'::text) ->> 'id'::text))))
     LEFT JOIN eql.event c ON (((c.id)::text = (g.value ->> 'id'::text))))
  WHERE (((api.provider)::text = 'sportradar'::text) AND ((endpoint.data_provided)::text = 'schedule'::text));


ALTER TABLE eql.sportradar OWNER TO eql;

--
-- Name: ticket_summary; Type: TABLE; Schema: eql; Owner: eql
--

CREATE TABLE eql.ticket_summary (
    date date NOT NULL,
    hour integer NOT NULL,
    game_instance_id uuid NOT NULL,
    player_id text NOT NULL,
    coin_in integer NOT NULL,
    coin_out integer NOT NULL
);


ALTER TABLE eql.ticket_summary OWNER TO eql;

--
-- Name: ticket_summary_view; Type: VIEW; Schema: eql; Owner: eql
--

CREATE VIEW eql.ticket_summary_view AS
 SELECT date(ticket.issued_time) AS date,
    round((sum(ticket.price) / (100)::numeric), 2) AS coin_in
   FROM ((eql.ticket
     JOIN eql.game_instance ON ((ticket.game_instance_id = game_instance.id)))
     JOIN eql.game ON ((game_instance.game_id = game.id)))
  WHERE (ticket.mode = 'M'::text)
  GROUP BY (date(ticket.issued_time));


ALTER TABLE eql.ticket_summary_view OWNER TO eql;

--
-- Name: transaction_sequence; Type: SEQUENCE; Schema: eql; Owner: eql
--

CREATE SEQUENCE eql.transaction_sequence
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE eql.transaction_sequence OWNER TO eql;

--
-- Name: hdb_action_log; Type: TABLE; Schema: hdb_catalog; Owner: eql
--

CREATE TABLE hdb_catalog.hdb_action_log (
    id uuid DEFAULT hdb_catalog.gen_hasura_uuid() NOT NULL,
    action_name text,
    input_payload jsonb NOT NULL,
    request_headers jsonb NOT NULL,
    session_variables jsonb NOT NULL,
    response_payload jsonb,
    errors jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    response_received_at timestamp with time zone,
    status text NOT NULL,
    CONSTRAINT hdb_action_log_status_check CHECK ((status = ANY (ARRAY['created'::text, 'processing'::text, 'completed'::text, 'error'::text])))
);


ALTER TABLE hdb_catalog.hdb_action_log OWNER TO eql;

--
-- Name: hdb_cron_event_invocation_logs; Type: TABLE; Schema: hdb_catalog; Owner: eql
--

CREATE TABLE hdb_catalog.hdb_cron_event_invocation_logs (
    id text DEFAULT hdb_catalog.gen_hasura_uuid() NOT NULL,
    event_id text,
    status integer,
    request json,
    response json,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE hdb_catalog.hdb_cron_event_invocation_logs OWNER TO eql;

--
-- Name: hdb_cron_events; Type: TABLE; Schema: hdb_catalog; Owner: eql
--

CREATE TABLE hdb_catalog.hdb_cron_events (
    id text DEFAULT hdb_catalog.gen_hasura_uuid() NOT NULL,
    trigger_name text NOT NULL,
    scheduled_time timestamp with time zone NOT NULL,
    status text DEFAULT 'scheduled'::text NOT NULL,
    tries integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    next_retry_at timestamp with time zone,
    CONSTRAINT valid_status CHECK ((status = ANY (ARRAY['scheduled'::text, 'locked'::text, 'delivered'::text, 'error'::text, 'dead'::text])))
);


ALTER TABLE hdb_catalog.hdb_cron_events OWNER TO eql;

--
-- Name: hdb_metadata; Type: TABLE; Schema: hdb_catalog; Owner: eql
--

CREATE TABLE hdb_catalog.hdb_metadata (
    id integer NOT NULL,
    metadata json NOT NULL,
    resource_version integer DEFAULT 1 NOT NULL
);


ALTER TABLE hdb_catalog.hdb_metadata OWNER TO eql;

--
-- Name: hdb_scheduled_event_invocation_logs; Type: TABLE; Schema: hdb_catalog; Owner: eql
--

CREATE TABLE hdb_catalog.hdb_scheduled_event_invocation_logs (
    id text DEFAULT hdb_catalog.gen_hasura_uuid() NOT NULL,
    event_id text,
    status integer,
    request json,
    response json,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE hdb_catalog.hdb_scheduled_event_invocation_logs OWNER TO eql;

--
-- Name: hdb_scheduled_events; Type: TABLE; Schema: hdb_catalog; Owner: eql
--

CREATE TABLE hdb_catalog.hdb_scheduled_events (
    id text DEFAULT hdb_catalog.gen_hasura_uuid() NOT NULL,
    webhook_conf json NOT NULL,
    scheduled_time timestamp with time zone NOT NULL,
    retry_conf json,
    payload json,
    header_conf json,
    status text DEFAULT 'scheduled'::text NOT NULL,
    tries integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    next_retry_at timestamp with time zone,
    comment text,
    CONSTRAINT valid_status CHECK ((status = ANY (ARRAY['scheduled'::text, 'locked'::text, 'delivered'::text, 'error'::text, 'dead'::text])))
);


ALTER TABLE hdb_catalog.hdb_scheduled_events OWNER TO eql;

--
-- Name: hdb_schema_notifications; Type: TABLE; Schema: hdb_catalog; Owner: eql
--

CREATE TABLE hdb_catalog.hdb_schema_notifications (
    id integer NOT NULL,
    notification json NOT NULL,
    resource_version integer DEFAULT 1 NOT NULL,
    instance_id uuid NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT hdb_schema_notifications_id_check CHECK ((id = 1))
);


ALTER TABLE hdb_catalog.hdb_schema_notifications OWNER TO eql;

--
-- Name: hdb_version; Type: TABLE; Schema: hdb_catalog; Owner: eql
--

CREATE TABLE hdb_catalog.hdb_version (
    hasura_uuid uuid DEFAULT hdb_catalog.gen_hasura_uuid() NOT NULL,
    version text NOT NULL,
    upgraded_on timestamp with time zone NOT NULL,
    cli_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    console_state jsonb DEFAULT '{}'::jsonb NOT NULL
);


ALTER TABLE hdb_catalog.hdb_version OWNER TO eql;

--
-- Name: profiles; Type: TABLE; Schema: public; Owner: eql
--

CREATE TABLE public.profiles (
    id integer NOT NULL,
    name text NOT NULL
);


ALTER TABLE public.profiles OWNER TO eql;

--
-- Name: profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: eql
--

CREATE SEQUENCE public.profiles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.profiles_id_seq OWNER TO eql;

--
-- Name: profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: eql
--

ALTER SEQUENCE public.profiles_id_seq OWNED BY public.profiles.id;


--
-- Name: profiles id; Type: DEFAULT; Schema: public; Owner: eql
--

ALTER TABLE ONLY public.profiles ALTER COLUMN id SET DEFAULT nextval('public.profiles_id_seq'::regclass);


--
-- Name: rng_instance app_instance_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.rng_instance
    ADD CONSTRAINT app_instance_pkey PRIMARY KEY (id);


--
-- Name: audit audit_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.audit
    ADD CONSTRAINT audit_pkey PRIMARY KEY (id);


--
-- Name: bonus bonus_id_key; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.bonus
    ADD CONSTRAINT bonus_id_key UNIQUE (id);


--
-- Name: bonus bonus_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.bonus
    ADD CONSTRAINT bonus_pkey PRIMARY KEY (id);


--
-- Name: draw_event eql_draw_events_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.draw_event
    ADD CONSTRAINT eql_draw_events_pkey PRIMARY KEY (draw_id, event_id);


--
-- Name: draw eql_draw_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.draw
    ADD CONSTRAINT eql_draw_pkey PRIMARY KEY (id);


--
-- Name: event eql_event_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.event
    ADD CONSTRAINT eql_event_pkey PRIMARY KEY (id);


--
-- Name: feed_data eql_feed_data_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.feed_data
    ADD CONSTRAINT eql_feed_data_pkey PRIMARY KEY (id);


--
-- Name: feed_endpoint eql_feed_endpoint_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.feed_endpoint
    ADD CONSTRAINT eql_feed_endpoint_pkey PRIMARY KEY (id);


--
-- Name: feed eql_feed_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.feed
    ADD CONSTRAINT eql_feed_pkey PRIMARY KEY (id);


--
-- Name: game eql_game_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.game
    ADD CONSTRAINT eql_game_pkey PRIMARY KEY (id);


--
-- Name: operator eql_operator_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.operator
    ADD CONSTRAINT eql_operator_pkey PRIMARY KEY (id);


--
-- Name: organization_member eql_organization_member_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.organization_member
    ADD CONSTRAINT eql_organization_member_pkey PRIMARY KEY (id);


--
-- Name: organization eql_organization_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.organization
    ADD CONSTRAINT eql_organization_pkey PRIMARY KEY (id);


--
-- Name: pool eql_pool_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.pool
    ADD CONSTRAINT eql_pool_pkey PRIMARY KEY (id);


--
-- Name: pool_result eql_pool_results_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.pool_result
    ADD CONSTRAINT eql_pool_results_pkey PRIMARY KEY (pool_id);


--
-- Name: ticket eql_ticket_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.ticket
    ADD CONSTRAINT eql_ticket_pkey PRIMARY KEY (id, issued_time);


--
-- Name: event_participant event_participant_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.event_participant
    ADD CONSTRAINT event_participant_pkey PRIMARY KEY (event_id, member_id);


--
-- Name: game_instance game_instance_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.game_instance
    ADD CONSTRAINT game_instance_pkey PRIMARY KEY (id);


--
-- Name: rng rng_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.rng
    ADD CONSTRAINT rng_pkey PRIMARY KEY (instance_id, drand_round);


--
-- Name: scenario scenario_index_collection_code_key; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.scenario
    ADD CONSTRAINT scenario_index_collection_code_key UNIQUE (index, collection_code);


--
-- Name: scenario_pool scenario_pool_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.scenario_pool
    ADD CONSTRAINT scenario_pool_pkey PRIMARY KEY (id);


--
-- Name: scenario simulation_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.scenario
    ADD CONSTRAINT simulation_pkey PRIMARY KEY (id);


--
-- Name: simulation simulation_pkey1; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.simulation
    ADD CONSTRAINT simulation_pkey1 PRIMARY KEY (id);


--
-- Name: ticket_summary ticket_summary_pkey; Type: CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.ticket_summary
    ADD CONSTRAINT ticket_summary_pkey PRIMARY KEY (date, hour, game_instance_id, player_id);


--
-- Name: hdb_action_log hdb_action_log_pkey; Type: CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_action_log
    ADD CONSTRAINT hdb_action_log_pkey PRIMARY KEY (id);


--
-- Name: hdb_cron_event_invocation_logs hdb_cron_event_invocation_logs_pkey; Type: CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_cron_event_invocation_logs
    ADD CONSTRAINT hdb_cron_event_invocation_logs_pkey PRIMARY KEY (id);


--
-- Name: hdb_cron_events hdb_cron_events_pkey; Type: CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_cron_events
    ADD CONSTRAINT hdb_cron_events_pkey PRIMARY KEY (id);


--
-- Name: hdb_metadata hdb_metadata_pkey; Type: CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_metadata
    ADD CONSTRAINT hdb_metadata_pkey PRIMARY KEY (id);


--
-- Name: hdb_metadata hdb_metadata_resource_version_key; Type: CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_metadata
    ADD CONSTRAINT hdb_metadata_resource_version_key UNIQUE (resource_version);


--
-- Name: hdb_scheduled_event_invocation_logs hdb_scheduled_event_invocation_logs_pkey; Type: CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_scheduled_event_invocation_logs
    ADD CONSTRAINT hdb_scheduled_event_invocation_logs_pkey PRIMARY KEY (id);


--
-- Name: hdb_scheduled_events hdb_scheduled_events_pkey; Type: CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_scheduled_events
    ADD CONSTRAINT hdb_scheduled_events_pkey PRIMARY KEY (id);


--
-- Name: hdb_schema_notifications hdb_schema_notifications_pkey; Type: CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_schema_notifications
    ADD CONSTRAINT hdb_schema_notifications_pkey PRIMARY KEY (id);


--
-- Name: hdb_version hdb_version_pkey; Type: CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_version
    ADD CONSTRAINT hdb_version_pkey PRIMARY KEY (hasura_uuid);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: eql
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: eql_ticket_transaction_id; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX eql_ticket_transaction_id ON eql.ticket USING btree (transaction_id);


--
-- Name: fki_eql_draw_event_draw; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_draw_event_draw ON eql.draw_event USING btree (draw_id);


--
-- Name: fki_eql_draw_event_event; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_draw_event_event ON eql.draw_event USING btree (event_id);


--
-- Name: fki_eql_event_organization; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_event_organization ON eql.event USING btree (organization_id);


--
-- Name: fki_eql_event_participant_event; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_event_participant_event ON eql.event_participant USING btree (event_id);


--
-- Name: fki_eql_event_participant_member; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_event_participant_member ON eql.event_participant USING btree (member_id);


--
-- Name: fki_eql_feed_data_endpoint; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_feed_data_endpoint ON eql.feed_data USING btree (feed_endpoint_id);


--
-- Name: fki_eql_feed_endpoint_feed; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_feed_endpoint_feed ON eql.feed_endpoint USING btree (feed_id);


--
-- Name: fki_eql_feed_organization; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_feed_organization ON eql.feed USING btree (organization_id);


--
-- Name: fki_eql_org_member_org; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_org_member_org ON eql.organization_member USING btree (organization_id);


--
-- Name: fki_eql_pool_draw; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_pool_draw ON eql.pool USING btree (draw_id);


--
-- Name: fki_eql_pool_operator; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_pool_operator ON eql.pool USING btree (operator_id);


--
-- Name: fki_eql_ticket_pool; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX fki_eql_ticket_pool ON eql.ticket USING btree (pool_id);


--
-- Name: idx_eql_ticket_correct; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX idx_eql_ticket_correct ON eql.ticket USING btree (score);


--
-- Name: scenario_pool_lookup; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX scenario_pool_lookup ON eql.scenario_pool USING btree (game_instance_id, index);


--
-- Name: scenario_ticket; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX scenario_ticket ON eql.scenario_pool USING btree (ticket_id);


--
-- Name: ticket_summary_date; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX ticket_summary_date ON eql.ticket_summary USING btree (date);


--
-- Name: ticket_summary_game_instance_id; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX ticket_summary_game_instance_id ON eql.ticket_summary USING btree (game_instance_id);


--
-- Name: ticket_summary_player_id; Type: INDEX; Schema: eql; Owner: eql
--

CREATE INDEX ticket_summary_player_id ON eql.ticket_summary USING btree (player_id);


--
-- Name: hdb_cron_event_invocation_event_id; Type: INDEX; Schema: hdb_catalog; Owner: eql
--

CREATE INDEX hdb_cron_event_invocation_event_id ON hdb_catalog.hdb_cron_event_invocation_logs USING btree (event_id);


--
-- Name: hdb_cron_event_status; Type: INDEX; Schema: hdb_catalog; Owner: eql
--

CREATE INDEX hdb_cron_event_status ON hdb_catalog.hdb_cron_events USING btree (status);


--
-- Name: hdb_cron_events_unique_scheduled; Type: INDEX; Schema: hdb_catalog; Owner: eql
--

CREATE UNIQUE INDEX hdb_cron_events_unique_scheduled ON hdb_catalog.hdb_cron_events USING btree (trigger_name, scheduled_time) WHERE (status = 'scheduled'::text);


--
-- Name: hdb_scheduled_event_status; Type: INDEX; Schema: hdb_catalog; Owner: eql
--

CREATE INDEX hdb_scheduled_event_status ON hdb_catalog.hdb_scheduled_events USING btree (status);


--
-- Name: hdb_version_one_row; Type: INDEX; Schema: hdb_catalog; Owner: eql
--

CREATE UNIQUE INDEX hdb_version_one_row ON hdb_catalog.hdb_version USING btree (((version IS NOT NULL)));


--
-- Name: bonus bonus_game_instance_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.bonus
    ADD CONSTRAINT bonus_game_instance_id_fkey FOREIGN KEY (game_instance_id) REFERENCES eql.game_instance(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: draw_event eql_draw_event_draw; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.draw_event
    ADD CONSTRAINT eql_draw_event_draw FOREIGN KEY (draw_id) REFERENCES eql.draw(id) NOT VALID;


--
-- Name: draw_event eql_draw_event_event; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.draw_event
    ADD CONSTRAINT eql_draw_event_event FOREIGN KEY (event_id) REFERENCES eql.event(id) NOT VALID;


--
-- Name: event eql_event_organization; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.event
    ADD CONSTRAINT eql_event_organization FOREIGN KEY (organization_id) REFERENCES eql.organization(id) NOT VALID;


--
-- Name: event_participant eql_event_participant_event; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.event_participant
    ADD CONSTRAINT eql_event_participant_event FOREIGN KEY (event_id) REFERENCES eql.event(id) NOT VALID;


--
-- Name: event_participant eql_event_participant_member; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.event_participant
    ADD CONSTRAINT eql_event_participant_member FOREIGN KEY (member_id) REFERENCES eql.organization_member(id) NOT VALID;


--
-- Name: feed_data eql_feed_data_endpoint; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.feed_data
    ADD CONSTRAINT eql_feed_data_endpoint FOREIGN KEY (feed_endpoint_id) REFERENCES eql.feed_endpoint(id) NOT VALID;


--
-- Name: feed_endpoint eql_feed_endpoint_feed; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.feed_endpoint
    ADD CONSTRAINT eql_feed_endpoint_feed FOREIGN KEY (feed_id) REFERENCES eql.feed(id) NOT VALID;


--
-- Name: feed eql_feed_organization; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.feed
    ADD CONSTRAINT eql_feed_organization FOREIGN KEY (organization_id) REFERENCES eql.organization(id) NOT VALID;


--
-- Name: organization_member eql_member_organization; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.organization_member
    ADD CONSTRAINT eql_member_organization FOREIGN KEY (organization_id) REFERENCES eql.organization(id) NOT VALID;


--
-- Name: pool eql_pool_draw; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.pool
    ADD CONSTRAINT eql_pool_draw FOREIGN KEY (draw_id) REFERENCES eql.draw(id) NOT VALID;


--
-- Name: pool eql_pool_operator; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.pool
    ADD CONSTRAINT eql_pool_operator FOREIGN KEY (operator_id) REFERENCES eql.operator(id) NOT VALID;


--
-- Name: ticket eql_ticket_pool; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.ticket
    ADD CONSTRAINT eql_ticket_pool FOREIGN KEY (pool_id) REFERENCES eql.pool(id) NOT VALID;


--
-- Name: event event_parent_event_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.event
    ADD CONSTRAINT event_parent_event_id_fkey FOREIGN KEY (parent_event_id) REFERENCES eql.event(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: game_instance game_instance_game_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.game_instance
    ADD CONSTRAINT game_instance_game_id_fkey FOREIGN KEY (game_id) REFERENCES eql.game(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: game_instance game_instance_operator_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.game_instance
    ADD CONSTRAINT game_instance_operator_id_fkey FOREIGN KEY (operator_id) REFERENCES eql.operator(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: operator operator_app_instance_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.operator
    ADD CONSTRAINT operator_app_instance_id_fkey FOREIGN KEY (rng_instance_id) REFERENCES eql.rng_instance(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: pool_result pool_result_pool_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.pool_result
    ADD CONSTRAINT pool_result_pool_id_fkey FOREIGN KEY (pool_id) REFERENCES eql.pool(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: rng rng_instance_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.rng
    ADD CONSTRAINT rng_instance_id_fkey FOREIGN KEY (instance_id) REFERENCES eql.rng_instance(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: scenario_pool scenario_pool_scenario_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.scenario_pool
    ADD CONSTRAINT scenario_pool_scenario_id_fkey FOREIGN KEY (scenario_id) REFERENCES eql.scenario(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: simulation simulation_draw_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.simulation
    ADD CONSTRAINT simulation_draw_id_fkey FOREIGN KEY (draw_id) REFERENCES eql.draw(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: simulation simulation_feed_endpoint_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.simulation
    ADD CONSTRAINT simulation_feed_endpoint_id_fkey FOREIGN KEY (feed_endpoint_id) REFERENCES eql.feed_endpoint(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: ticket ticket_bonus_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.ticket
    ADD CONSTRAINT ticket_bonus_id_fkey FOREIGN KEY (bonus_id) REFERENCES eql.bonus(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: ticket ticket_event_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.ticket
    ADD CONSTRAINT ticket_event_id_fkey FOREIGN KEY (event_id) REFERENCES eql.event(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: ticket ticket_game_instance_id_fkey; Type: FK CONSTRAINT; Schema: eql; Owner: eql
--

ALTER TABLE ONLY eql.ticket
    ADD CONSTRAINT ticket_game_instance_id_fkey FOREIGN KEY (game_instance_id) REFERENCES eql.game_instance(id) ON UPDATE RESTRICT ON DELETE RESTRICT;


--
-- Name: hdb_cron_event_invocation_logs hdb_cron_event_invocation_logs_event_id_fkey; Type: FK CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_cron_event_invocation_logs
    ADD CONSTRAINT hdb_cron_event_invocation_logs_event_id_fkey FOREIGN KEY (event_id) REFERENCES hdb_catalog.hdb_cron_events(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: hdb_scheduled_event_invocation_logs hdb_scheduled_event_invocation_logs_event_id_fkey; Type: FK CONSTRAINT; Schema: hdb_catalog; Owner: eql
--

ALTER TABLE ONLY hdb_catalog.hdb_scheduled_event_invocation_logs
    ADD CONSTRAINT hdb_scheduled_event_invocation_logs_event_id_fkey FOREIGN KEY (event_id) REFERENCES hdb_catalog.hdb_scheduled_events(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT ALL ON SCHEMA public TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_advance(text, pg_lsn); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_advance(text, pg_lsn) TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_create(text); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_create(text) TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_drop(text); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_drop(text) TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_oid(text); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_oid(text) TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_progress(text, boolean); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_progress(text, boolean) TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_session_is_setup(); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_session_is_setup() TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_session_progress(boolean); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_session_progress(boolean) TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_session_reset(); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_session_reset() TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_session_setup(text); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_session_setup(text) TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_xact_reset(); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_xact_reset() TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_replication_origin_xact_setup(pg_lsn, timestamp with time zone); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_replication_origin_xact_setup(pg_lsn, timestamp with time zone) TO cloudsqlsuperuser;


--
-- Name: FUNCTION pg_show_replication_origin_status(OUT local_id oid, OUT external_id text, OUT remote_lsn pg_lsn, OUT local_lsn pg_lsn); Type: ACL; Schema: pg_catalog; Owner: cloudsqladmin
--

GRANT ALL ON FUNCTION pg_catalog.pg_show_replication_origin_status(OUT local_id oid, OUT external_id text, OUT remote_lsn pg_lsn, OUT local_lsn pg_lsn) TO cloudsqlsuperuser;


--
-- Name: FUNCTION user_search(uname text); Type: ACL; Schema: public; Owner: eql
--

REVOKE ALL ON FUNCTION public.user_search(uname text) FROM PUBLIC;



insert into eql.operator (id, name, code, frontend, backend) values ('369d2b3e-e8cd-491f-b5c8-63bc4ed38e92','Michigan Lottery','MI','NEOGAMES','NEOGAMES');
insert into eql.game (id, name,code, type, active, studio, integration_type) values ('1eb9a7fe-6e10-4ee8-8976-6897fc541e0f','Drop It', 'drop-it', 'INSTANT', true, 'GREENTUBE', 'INTERNAL');
insert into eql.game_instance(id, game_id, operator_id, version, created_at, created_by, scenario_collection_code, scenario_pool_index, active, language, currency, code, operator_game_id)
    values ('6178d5b8-6608-4d21-8041-db505451662b','1eb9a7fe-6e10-4ee8-8976-6897fc541e0f','369d2b3e-e8cd-491f-b5c8-63bc4ed38e92', 1, now(), 'admin', 'GT-DTB-MI', 1, true, 'en', 'USD', '14402', '14402');

--
-- PostgreSQL database dump complete
--
