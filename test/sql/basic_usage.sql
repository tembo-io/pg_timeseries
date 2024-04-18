\set SHOW_CONTEXT never

CREATE EXTENSION timeseries CASCADE;

CREATE TABLE simple ();
SELECT enable_ts_table('simple');

CREATE TABLE hash ( username text ) PARTITION BY HASH (username);
SELECT enable_ts_table('hash');

CREATE TABLE nullable ( anniversary date ) PARTITION BY RANGE (anniversary);
SELECT enable_ts_table('nullable');

CREATE TABLE nondate ( userid integer NOT NULL ) PARTITION BY RANGE (userid);
SELECT enable_ts_table('nondate');

CREATE TABLE multi ( userid integer, subid integer ) PARTITION BY RANGE (userid, subid);
SELECT enable_ts_table('multi');

CREATE TABLE measurements (
  metric_name text,
  metric_value numeric,
  metric_time timestamptz NOT NULL
) PARTITION BY RANGE (metric_time);

SELECT enable_ts_table('measurements', partition_duration := '0 days'::interval);
SELECT enable_ts_table('measurements', partition_lead_time := '0 days'::interval);

SELECT enable_ts_table('measurements');

SELECT partition_duration, partition_lead_time FROM ts_config ORDER BY table_id::text;
SELECT partition_interval, premake FROM part_config WHERE parent_table='public.measurements';

SELECT COUNT(*) > 10 AS has_partitions FROM ts_part_info;

SELECT set_ts_retention_policy('measurements', '90 days');
SELECT retention_duration FROM ts_config WHERE table_id='measurements'::regclass;
SELECT retention FROM part_config WHERE parent_table='public.measurements';

SELECT clear_ts_retention_policy('measurements');
SELECT retention_duration FROM ts_config WHERE table_id='measurements'::regclass;
SELECT retention FROM part_config WHERE parent_table='public.measurements';

SELECT set_ts_lead_time('measurements', '1 day');
SELECT partition_lead_time FROM ts_config WHERE table_id='measurements'::regclass;
SELECT premake FROM part_config WHERE parent_table='public.measurements';

SELECT set_ts_retention_policy('measurements', '1 days');
SELECT run_maintenance();
SELECT COUNT(*) < 10 AS fewer_partitions FROM ts_part_info;
