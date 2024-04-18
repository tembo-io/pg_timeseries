-- This table stores the core configuration for the timeseries extension
-- At the moment, pieces of this configuration are duplicated within the
-- partman.part_config table from pg_partman, but all interaction with
-- pg_partman will go through our APIs, so end-users should not notice.
CREATE TABLE @extschema@.ts_config(
  table_id regclass PRIMARY KEY,
  partition_duration interval NOT NULL,
  partition_lead_time interval NOT NULL,
  retention_duration interval,
  compression_duration interval);

-- Enhances an existing table with our time-series best practices. Basically
-- the entry point to this extension. Minimally, a user must create a table
-- range-partitioned using a non-null time-based column before passing that
-- table to this function. After exiting, the table will have partitions
-- managed by pg_partman with the specified width, created a certain amount
-- of time into the future.
--
-- Exceptions are raised for any number of validation and usage issues, but
-- if this function successfully returns, it means time-series enhancements
-- have been applied.
CREATE OR REPLACE FUNCTION @extschema@.enable_ts_table(
  target_table_id regclass,
  partition_duration interval DEFAULT '7 days'::interval,
  partition_lead_time interval DEFAULT '1 mon'::interval,
  initial_table_start timestamptz DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  pruning_enabled bool := current_setting('enable_partition_pruning');
  part_strategy char;
  pkey_attnums int2vector;
  pkey_name name;
  pkey_notnull bool;
  pkey_type_id regtype;
  leading_partitions numeric;
  table_name text;
  partman_success bool;
BEGIN
  PERFORM * FROM @extschema@.ts_config WHERE "table_id"=target_table_id;
  IF FOUND THEN
    RAISE object_not_in_prerequisite_state USING
      MESSAGE = 'table already time-series enabled',
      DETAIL  = 'Time-series enhancements are not idempotent.',
      HINT    = 'See documentation for help modifying time-series settings.';
  END IF;

  INSERT INTO @extschema@.ts_config
    ("table_id",
     "partition_duration",
     "partition_lead_time") VALUES
    (target_table_id,
     partition_duration,
     partition_lead_time);

  IF NOT pruning_enabled THEN
    RAISE WARNING USING
      MESSAGE = 'partition pruning is disabled',
      DETAIL  = 'Time-series queries performance will be degraded.',
      HINT    = format('Set the %L config parameter to %L',
                       'enable_partition_pruning', 'on');
  END IF;

  SELECT partstrat, partattrs
    INTO part_strategy, pkey_attnums
    FROM pg_catalog.pg_partitioned_table
    WHERE partrelid=target_table_id;

  IF part_strategy IS NULL THEN
    RAISE object_not_in_prerequisite_state USING
      MESSAGE = 'could not enable time-series enhancements',
      DETAIL  = 'Target table was not partitioned',
      HINT    = 'Recreate table using PARTITION BY RANGE';
  END IF;

  IF part_strategy <> 'r' THEN
    RAISE object_not_in_prerequisite_state USING
      MESSAGE = 'could not enable time-series enhancements',
      DETAIL  = 'Target table not range-partitioned',
      HINT    = 'Recreate table using PARTITION BY RANGE';
  END IF;

  IF array_length(pkey_attnums, 1) <> 1 THEN
    RAISE object_not_in_prerequisite_state USING
      MESSAGE = 'could not enable time-series enhancements',
      DETAIL  = 'Partition key not single-column',
      HINT    = 'Recreate table using a single-column partition key';
  END IF;

  SELECT attname, attnotnull, atttypid
    INTO pkey_name, pkey_notnull, pkey_type_id
    FROM pg_attribute
    WHERE attrelid = target_table_id
    AND attnum = pkey_attnums[0];

  IF NOT pkey_notnull THEN
    RAISE object_not_in_prerequisite_state USING
      MESSAGE = 'could not enable time-series enhancements',
      DETAIL  = 'Partition column nullable',
      HINT    = 'Use ALTER TABLE to add a NOT NULL constraint to the partition column.';
  END IF;

  IF pkey_type_id != ALL (ARRAY['timestamptz',
                                'timestamp',
                                'date']::regtype[]) THEN
    RAISE feature_not_supported USING
      MESSAGE = 'could not enable time-series enhancements',
      DETAIL  = 'Partition column was not a time type',
      HINT    = 'Only timestamp(tz) and date partition columns are supported';
  END IF;

  IF partition_lead_time = make_interval(0) THEN
    RAISE invalid_parameter_value USING
      MESSAGE = 'unusable partition lead time',
      DETAIL  = 'Partition lead time must be positive',
      HINT    = 'Provide a positive interval for partition creation lead time.';
  END IF;

  IF partition_duration = make_interval(0) THEN
    RAISE invalid_parameter_value USING
      MESSAGE = 'unusable partition duration',
      DETAIL  = 'Partition duration must be positive',
      HINT    = 'Provide a positive interval for partition duration (width).';
  END IF;

  SELECT format('%s.%s', n.nspname, c.relname)
    INTO table_name
    FROM pg_class c
    LEFT JOIN pg_namespace n
      ON n.oid = c.relnamespace
    WHERE c.oid=target_table_id;

  SELECT ceil( date_part('EPOCH', partition_lead_time) /
               date_part('EPOCH', partition_duration))
    INTO leading_partitions;

  SELECT create_parent(
      p_parent_table := table_name,
      p_control := pkey_name::text,
      p_interval := partition_duration::text,
      p_premake := leading_partitions::integer,
      p_start_partition := initial_table_start::text)
    INTO partman_success;

  IF NOT partman_success THEN
    RAISE external_routine_invocation_exception USING
      MESSAGE = 'underlying partition library failure',
      DETAIL  = 'pg_partman failed for an unknown reason',
      HINT    = 'Inspect server logs for more.';
  END IF;
END;
$function$;

-- Though time-series tables default to never dropping old data, calling this
-- function allows a user to specify a retention duration. Partitions whose
-- whose data is entirely older than this offset will be dropped automatically
--
-- In the future, similar functions will manage schedules for moving partitions
-- to non-default TABLESPACEs, issuing CLUSTER commands to reorganize data in
-- non-active partitions along a chosen index.
--
-- Returns the previous retention duration, or NULL if none was set.
CREATE OR REPLACE
FUNCTION @extschema@.set_ts_retention_policy(target_table_id regclass, new_retention interval)
  RETURNS interval
  LANGUAGE plpgsql
AS $function$
DECLARE
  table_name text;
  prev_retention interval;
BEGIN
  SELECT retention_duration
    INTO prev_retention
    FROM @extschema@.ts_config
    WHERE "table_id"=target_table_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE object_not_in_prerequisite_state USING
      MESSAGE = 'could not fetch retention policy',
      DETAIL  = 'Target table was not time-series enhanced',
      HINT    = format('Call %L to enable time-series enhancements', 'enable_ts_table');
  END IF;

  UPDATE @extschema@.ts_config
    SET "retention_duration"=new_retention
    WHERE "table_id"=target_table_id;

  SELECT format('%s.%s', n.nspname, c.relname)
    INTO table_name
    FROM pg_class c
    LEFT JOIN pg_namespace n
      ON n.oid = c.relnamespace
    WHERE c.oid=target_table_id;
  UPDATE part_config
    SET retention=new_retention
    WHERE parent_table=table_name;

  RETURN prev_retention;
END;
$function$;

-- Unsets any retention policy on the specified table. Returns the old policy,
-- if one was set.
CREATE OR REPLACE
FUNCTION @extschema@.clear_ts_retention_policy(target_table_id regclass)
  RETURNS interval
  LANGUAGE plpgsql
AS $function$
DECLARE
  prev_retention interval;
BEGIN
  SELECT set_ts_retention_policy(target_table_id, NULL) INTO prev_retention;

  RETURN prev_retention;
END;
$function$;

-- Modifies the "lead time" for new partition creation. This controls how far
-- ahead of "now" partitions are created. Returns the previously set lead time.
CREATE OR REPLACE
FUNCTION @extschema@.set_ts_lead_time(target_table_id regclass, new_lead_time interval)
  RETURNS interval
  LANGUAGE plpgsql
AS $function$
DECLARE
  table_name text;
  prev_lead_time interval;
  part_duration interval;
  leading_partitions numeric;
BEGIN
  SELECT partition_lead_time,
         partition_duration
    INTO prev_lead_time, part_duration
    FROM @extschema@.ts_config
    WHERE "table_id"=target_table_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE object_not_in_prerequisite_state USING
      MESSAGE = 'could not fetch lead time',
      DETAIL  = 'Target table was not time-series enhanced',
      HINT    = format('Call %L to enable time-series enhancements', 'enable_ts_table');
  END IF;

  IF new_lead_time = make_interval(0) THEN
    RAISE invalid_parameter_value USING
      MESSAGE = 'unusable partition lead time',
      DETAIL  = 'Partition lead time must be positive',
      HINT    = 'Provide a positive interval for partition creation lead time.';
  END IF;

  UPDATE @extschema@.ts_config
    SET "partition_lead_time"=new_lead_time
    WHERE "table_id"=target_table_id;

  SELECT format('%s.%s', n.nspname, c.relname)
    INTO table_name
    FROM pg_class c
    LEFT JOIN pg_namespace n
      ON n.oid = c.relnamespace
    WHERE c.oid=target_table_id;

  SELECT ceil( date_part('EPOCH', new_lead_time) /
               date_part('EPOCH', part_duration))
    INTO leading_partitions;

  UPDATE part_config
    SET premake=leading_partitions
    WHERE parent_table=table_name;

  RETURN prev_lead_time;
END;
$function$;

-- This view will contain a row for each partition of every table managed by
-- this extension. The space used by the table and its indexes is shown, as
-- well as the total relation size as reported by PostgreSQL.
CREATE OR REPLACE VIEW @extschema@.ts_part_info AS
SELECT pt.parentrelid as table_id,
       pt.relid AS part_id,
       pg_get_expr(c.relpartbound, c.oid) AS part_range,
       pg_table_size(pt.relid) AS table_size_bytes,
       pg_indexes_size(pt.relid) AS index_size_bytes,
       pg_total_relation_size(pt.relid) AS total_size_bytes
  FROM @extschema@.ts_config tsc,
       pg_partition_tree(tsc.table_id) pt,
       pg_class c
  WHERE pt.isleaf AND pt.relid = c.oid
  ORDER BY 2 ASC;

-- Unlike the above view, this sums partitions for each time-series table.
CREATE OR REPLACE VIEW @extschema@.ts_table_info AS
SELECT table_id,
       SUM(table_size_bytes) AS table_size_bytes,
       SUM(index_size_bytes) AS index_size_bytes,
       SUM(total_size_bytes) AS total_size_bytes
  FROM @extschema@.ts_part_info GROUP BY 1 ORDER BY 2 ASC;

-- This function sets a compression policy on an existing time-series table, which
-- ensures that all partitions older than a particular offset (from present) are
-- automatically converted to a columnar storage mechanism, which offers some
-- degree of data compression.
--
-- Returns the previous compression duration, or NULL if none was set.
CREATE OR REPLACE FUNCTION @extschema@.set_ts_compression_policy(target_table_id regclass, new_compression interval)
 RETURNS interval
 LANGUAGE plpgsql
AS $function$
DECLARE
  table_name text;
  prev_compression interval;
BEGIN
  SELECT compression_duration
    INTO prev_compression
    FROM @extschema@.ts_config
    WHERE "table_id"=target_table_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE object_not_in_prerequisite_state USING
      MESSAGE = 'could not fetch compression policy',
      DETAIL  = 'Target table was not time-series enhanced',
      HINT    = format('Call %L to enable time-series enhancements', 'enable_ts_table');
  END IF;

  UPDATE @extschema@.ts_config
    SET "compression_duration"=new_compression
    WHERE "table_id"=target_table_id;

  RETURN prev_compression;
END;
$function$;

-- Unsets any compression policy on the specified table. Returns the old policy,
-- if one was set.
CREATE OR REPLACE
FUNCTION @extschema@.clear_ts_compression_policy(target_table_id regclass)
  RETURNS interval
  LANGUAGE plpgsql
AS $function$
DECLARE
  prev_compression interval;
BEGIN
  SELECT set_ts_compression_policy(target_table_id, NULL) INTO prev_compression;

  RETURN prev_compression;
END;
$function$;

-- This function implements the core of compression application: given a target table ID
-- (which must be time-series enabled) and a compression offset, all partitions falling
-- entirely behind the offset (from the present time) will be converted to using columnar
-- storage. This function is "idempotent" in the sense that repeated calls will behave
-- identically given the same wall clock time and arguments.
CREATE OR REPLACE FUNCTION @extschema@.apply_compression_policy(target_table_id regclass, comp_offset interval)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
table_name text;
part_row record;
part_beg timestamptz;
part_end timestamptz;
part_am name;
BEGIN
  IF comp_offset IS NULL THEN
    RETURN;
  END IF;

  SELECT format('%s.%s', n.nspname, c.relname)
  INTO table_name
  FROM pg_class c
  LEFT JOIN pg_namespace n
    ON n.oid = c.relnamespace
  WHERE c.oid=target_table_id;

  FOR part_row IN
    SELECT
      partition_schemaname,
      partition_tablename
    FROM @extschema@.show_partitions(table_name, 'ASC')
    LOOP
      SELECT child_start_time, child_end_time
        INTO part_beg, part_end
        FROM @extschema@.show_partition_info(
          part_row.partition_schemaname || '.' ||
          part_row.partition_tablename);

      SELECT am.amname
        INTO part_am
        FROM pg_class c, pg_am am
        WHERE c.oid = (part_row.partition_schemaname || '.' ||
                       part_row.partition_tablename)::regclass AND
              c.relam = am.oid;

    IF part_am <> 'columnar' AND
       part_end < (now() - comp_offset) THEN
      PERFORM columnar.alter_table_set_access_method(
        part_row.partition_schemaname || '.' ||
        part_row.partition_tablename, 'columnar');
      EXECUTE format('ALTER TABLE %I ATTACH PARTITION %I.%I FOR VALUES FROM (%L) TO (%L)', target_table_id, part_row.partition_schemaname, part_row.partition_tablename, part_beg, part_end);
    END IF;
  END LOOP;
END;
$function$;

-- Since we're using pg_cron, might as well schedule the maintenance through its bgw
-- rather than run a duplicate one through pg_partman.
SELECT cron.schedule('partman-maintenance', '@hourly', $$SELECT partman.run_maintenance();$$);

-- Scan the time-series config table and apply compression policies once an hour.
SELECT cron.schedule('timeseries-compression', '@hourly', $$SELECT @extschema@.apply_compression_policy(table_id, compression_duration) FROM ts_config;$$);
