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

CREATE TABLE events (
  user_id bigint,
  event_id bigint,
  event_time timestamptz NOT NULL,
  value float
) PARTITION BY RANGE (event_time);
SELECT enable_ts_table('events');

COPY events FROM STDIN WITH (FORMAT 'csv');
1,1,"2020-11-04 15:51:02.226999-08",1.1
1,2,"2020-11-04 15:53:02.226999-08",1.2
1,3,"2020-11-04 15:55:02.226999-08",1.3
1,4,"2020-11-04 15:57:02.226999-08",1.4
1,5,"2020-11-04 15:58:02.226999-08",1.5
1,6,"2020-11-04 15:59:02.226999-08",1.6
2,7,"2020-11-04 15:51:02.226999-08",1.7
2,8,"2020-11-04 15:53:02.226999-08",1.8
2,9,"2020-11-04 15:55:02.226999-08",1.9
2,10,"2020-11-04 15:57:02.226999-08",2.0
2,11,"2020-11-04 15:58:02.226999-08",2.1
2,12,"2020-11-04 15:59:02.226999-08",2.2
\.

SELECT first(value, event_time), user_id FROM events GROUP BY user_id;

SELECT last(value, event_time), user_id FROM events GROUP BY user_id;

SELECT first(event_id, event_time), user_id FROM events GROUP BY user_id;

SELECT last(event_id, event_time), user_id FROM events GROUP BY user_id;

SELECT last(user_id, value) top_performer,
       locf(avg(value)) OVER (ORDER BY event_time),
       event_time
FROM date_bin_table(NULL::events, '1 minute',
                    '[2020-11-04 15:50:00-08, 2020-11-04 16:00:00-08]')
GROUP BY 3
ORDER BY 3;
