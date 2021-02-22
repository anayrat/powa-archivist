-- complain if script is sourced in psql, rather than via CREATE EXTENSION
--\echo Use "ALTER EXTENSION powa" to load this file. \quit

CREATE OR REPLACE FUNCTION powa_prevent_concurrent_snapshot(_srvid integer = 0)
RETURNS void
AS $PROC$
DECLARE
    v_state   text;
    v_msg     text;
    v_detail  text;
    v_hint    text;
    v_context text;
BEGIN
    BEGIN
        PERFORM 1
        FROM powa_snapshot_metas
        WHERE srvid = _srvid
        FOR UPDATE NOWAIT;
    EXCEPTION
    WHEN lock_not_available THEN
        RAISE EXCEPTION 'Could not lock the powa_snapshot_metas record, '
        'a concurrent snapshot is probably running';
    WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_state   = RETURNED_SQLSTATE,
            v_msg     = MESSAGE_TEXT,
            v_detail  = PG_EXCEPTION_DETAIL,
            v_hint    = PG_EXCEPTION_HINT,
            v_context = PG_EXCEPTION_CONTEXT;
        RAISE EXCEPTION 'Failed to lock the powa_snapshot_metas record:
            state  : %
            message: %
            detail : %
            hint   : %
            context: %', v_state, v_msg, v_detail, v_hint, v_context;
    END;
END;
$PROC$ language plpgsql; /* end of powa_prevent_concurrent_snapshot() */

CREATE OR REPLACE FUNCTION powa_qualstats_aggregate_constvalues_current(
    IN _srvid integer,
    IN _ts_from timestamptz DEFAULT '-infinity'::timestamptz,
    IN _ts_to timestamptz DEFAULT 'infinity'::timestamptz,
    OUT srvid integer,
    OUT qualid bigint,
    OUT queryid bigint,
    OUT dbid oid,
    OUT userid oid,
    OUT tstzrange tstzrange,
    OUT mu qual_values[],
    OUT mf qual_values[],
    OUT lf qual_values[],
    OUT me qual_values[],
    OUT mer qual_values[],
    OUT men qual_values[])
RETURNS SETOF record STABLE AS $_$
SELECT
    -- Ordered aggregate of top 20 metrics for each kind of stats (most executed, most filetered, least filtered...)
    srvid, qualid, queryid, dbid, userid,
    tstzrange(min(min_constvalues_ts) , max(max_constvalues_ts) ,'[]') ,
    array_agg((constvalues, sum_occurences, sum_execution_count, sum_nbfiltered, avg_mean_err_estimate_ratio, avg_mean_err_estimate_num)::qual_values ORDER BY occurences_rank ASC) FILTER (WHERE occurences_rank <=20)  mu,
    array_agg((constvalues, sum_occurences, sum_execution_count, sum_nbfiltered, avg_mean_err_estimate_ratio, avg_mean_err_estimate_num)::qual_values ORDER BY filtered_rank ASC) FILTER (WHERE filtered_rank <=20)  mf,
    array_agg((constvalues, sum_occurences, sum_execution_count, sum_nbfiltered, avg_mean_err_estimate_ratio, avg_mean_err_estimate_num)::qual_values ORDER BY filtered_rank DESC) FILTER (WHERE filtered_rank >= nb_lines - 20)  lf, -- Keep last 20 lines from the same window function
    array_agg((constvalues, sum_occurences, sum_execution_count, sum_nbfiltered, avg_mean_err_estimate_ratio, avg_mean_err_estimate_num)::qual_values ORDER BY execution_rank ASC) FILTER (WHERE execution_rank <=20)  me,
    array_agg((constvalues, sum_occurences, sum_execution_count, sum_nbfiltered, avg_mean_err_estimate_ratio, avg_mean_err_estimate_num)::qual_values ORDER BY err_estimate_ratio_rank ASC) FILTER (WHERE err_estimate_ratio_rank <=20)  mer,
    array_agg((constvalues, sum_occurences, sum_execution_count, sum_nbfiltered, avg_mean_err_estimate_ratio, avg_mean_err_estimate_num)::qual_values ORDER BY err_estimate_num_rank ASC) FILTER (WHERE err_estimate_num_rank <=20)  men
FROM (
    -- Establish rank for different stats (occurences, execution...) of each constvalues
    SELECT srvid, qualid, queryid, dbid, userid,
        min(mints) OVER (W) min_constvalues_ts, max(maxts) OVER (W) max_constvalues_ts,
        constvalues, sum_occurences, sum_execution_count, sum_nbfiltered, avg_mean_err_estimate_ratio, avg_mean_err_estimate_num,
        row_number() OVER (W ORDER BY sum_occurences DESC) occurences_rank,
        row_number() OVER (W ORDER BY CASE WHEN sum_execution_count = 0 THEN 0 ELSE sum_nbfiltered / sum_execution_count::numeric END DESC) filtered_rank,
        row_number() OVER (W ORDER BY sum_execution_count DESC) execution_rank,
        row_number() OVER (W ORDER BY avg_mean_err_estimate_ratio DESC) err_estimate_ratio_rank,
        row_number() OVER (W ORDER BY avg_mean_err_estimate_num DESC) err_estimate_num_rank,
        sum(1) OVER (W) nb_lines

    FROM (
        -- We group by constvalues and perform some aggregate to have stats on distinct constvalues
        SELECT srvid, qualid, queryid, dbid, userid,constvalues,
            min(ts) mints, max(ts) maxts ,
            sum(occurences) as sum_occurences,
            sum(nbfiltered) as sum_nbfiltered,
            sum(execution_count) as sum_execution_count,
            avg(mean_err_estimate_ratio) as avg_mean_err_estimate_ratio,
            avg(mean_err_estimate_num) as avg_mean_err_estimate_num
        FROM powa_qualstats_constvalues_history_current
        WHERE srvid = _srvid
          AND ts >= _ts_from AND ts <= _ts_to
        GROUP BY srvid, qualid, queryid, dbid, userid,constvalues
        ) distinct_constvalues
    WINDOW W AS (PARTITION BY srvid, qualid, queryid, dbid, userid)
    ) ranked_constvalues
GROUP BY srvid, qualid, queryid, dbid, userid
;
$_$ LANGUAGE sql; /* end of powa_qualstats_aggregate_constvalues_current */

