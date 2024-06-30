# API Reference

While the Guide and README provide a more narrative-based approach to covering this extension's functionality, users can consult this document when something more like a reference is needed.

## Basic Functionality, Tables and Views

These functions are for creating and managing time-series tables

### `enable_ts_table`

Designates an existing table as a time-series table and creates an initial set of partitions.

#### Arguments

  * `target_table_id` (`regclass`), **required** — an existing table to enhance with time-series functionality
  * `partition_duration` (`interval`), _default `7 days`_ — the duration of time covered by a single partition
  * `partition_lead_time` (`interval`), _default `1 mon`_ — how far in advance (from `now`) to make future partitions
  * `initial_table_start` (`timestamptz`), _default `NULL`_ — the timestamp of the earliest partition to create. If `NULL`, four partitions (before `now`) will be created by default

#### Considerations

`target_table_id` must point to a table that has been declaratively partitioned using PostgreSQL's partitioning features. It must be partitioned on a time-like column (`date`, `timestamp`, `timestamptz`) which has a `NOT NULL` constraint.

If any of the above prerequisites are not met, error messages will guide the user toward correcting the problems.

#### Returns

`void`. If any problems are encountered, an error will be raised.

### `set_ts_lead_time`

Modifies "lead time" for new partition creation for a table.

#### Arguments

  * `target_table_id` (`regclass`), **required** — a time-series enhanced table
  * `new_lead_time` (`interval`), **required** — a new lead time for the time-series table


#### Returns

`interval`. The previous lead time for this table.

### `ts_config`

This table contains information about time-series tables.

#### Columns

  * `table_id` (`regclass`, `NOT NULL`) — a table with time-series enhancements
  * `partition_duration` (`interval`, `NOT NULL`) — the width of partitions within this table
  * `partition_lead_time` (`interval`, `NOT NULL`) — how far in advance to create partitions for this table
  * `retention_duration` (`interval`) — how far back to retain partitions. If `NULL`, keep partitions forever
  * `compression_duration` (`interval`) — how far back to keep partitions uncompressed. After this point, they will have their storage changed to `columnar`. If `NULL`, compression is never automatically applied

### `ts_table_info`

Provides usage information about time-series tables

#### Columns

  * `table_id` (`regclass`) — a table with time-series enhancements
  * `table_size_bytes` (`numeric`) — data size for the table
  * `index_size_bytes` (`numeric`) — index size for the table
  * `total_size_bytes` (`numeric`) — total size for the table

### `ts_part_info`

Provides usage information about individual time-series partitions

#### Columns

  * `table_id` (`regclass`) — a table with time-series enhancements
  * `part_id` (`regclass`) — a partition of a time-series table
  * `part_range` (`text`) — the time range covered by this partition
  * `table_size_bytes` (`bigint`) — data size for the partition
  * `index_size_bytes` (`bigint`) — index size for the partition
  * `total_size_bytes` (`bigint`) — total size for the partition
  * `access_method` (`name`) — access method used by the partition (e.g. `heap` or `columnar`)

## Retention

### `set_ts_retention_policy`

Sets the retention policy for a time-series table. Lazily applied on an hourly schedule.

#### Arguments

  * `target_table_id` (`regclass`), **required** — the time-series enhanced table whose retention schedule is to be modified
  * `new_retention` (`interval`), **required** — the new retention duration for the time-series table

#### Returns

`interval`, the previous policy for this table, or `NULL` if none was set.

### `clear_ts_retention_policy`

Clears the retention policy for a table (so its data will never be dropped).

#### Arguments

  * `target_table_id` (`regclass`), **required** — the time-series enhanced table whose retention schedule is to be cleared

#### Returns

`interval`, the previous policy for this table, or `NULL` if none was set.

## Compression

### `set_ts_compression_policy`

Sets the compression policy for a time-series table. Lazily applied on an hourly schedule.

#### Arguments

  * `target_table_id` (`regclass`), **required** — the time-series enhanced table whose compression schedule is to be modified
  * `new_compression` (`interval`), **required** — the new compression duration for the time-series table

#### Returns

`interval`, the previous policy for this table, or `NULL` if none was set.

### `clear_ts_compression_policy`

Clears the compression policy for a table (so its data will never be dropped).

#### Arguments

  * `target_table_id` (`regclass`), **required** — the time-series enhanced table whose compression schedule is to be cleared

#### Returns

`interval`, the previous policy for this table, or `NULL` if none was set.

## Object Store Tier (AWS S3)

### `set_ts_tier_policy`

Sets the tier policy for a time-series table. Lazily applied every fortnightly.

#### Arguments

  * `target_table_id` (`regclass`), **required** — the time-series enhanced table whose tier schedule is to be modified
  * `new_compression` (`interval`), **required** — the new tier duration for the time-series table

#### Returns

`interval`, the previous policy for this table, or `NULL` if none was set.

### `clear_ts_tier_policy`

Clears the tier policy for a table.

#### Arguments

  * `target_table_id` (`regclass`), **required** — the time-series enhanced table whose tier schedule is to be cleared

#### Returns

`interval`, the previous policy for this table, or `NULL` if none was set.


## Analytics Functions

These functions are not related to the maintenance of time-series tables, but do sometimes rely on the related metadata to function. They are intended to make time-series queries easier to read and maintain.

### `first`/`last`

These aggregates return a column's value in the first or last row as sorted by a different column. For instance, `first(name, birthdate)` would return the name of the person with the first birthday in a set.

Most often used with a `GROUP BY` clause.

#### Arguments

  * `value` (_any type_), **required** — the column (or expression) whose value should be returned
  * `rank` (_any type_), **required** — the column (or expression) to be used to sort the input rows

#### Returns

_type of `value`_. In short, the aggregate finds the lowest (`first`) or highest (`last`) row in the input rows and returns the `value` expression from that row.

### `date_bin_table`

This set-returning function (table function) wraps a time-series table in order to bin all time values to a specified stride. For instance, by asking for `1 hour` bins, all time data will be aligned to the hour.

Bins for which the source table has no data will still be emitted, but with `NULL` in every non-time column. To limit how many such rows are returned, an explicit `range` argument is used. Furthermore, the bin alignment will begin at the start point of this range.

#### Arguments

  * `target_table_elem` (_any table type_), **required** — an element cast to the type of the target table. Idiomatically written as `NULL::target_table`, this helps PostgreSQL determine the shape of output rows. `target_table` must be a table with time-series enhancements
  * `time_stride` (`interval`), **required** — the "stride" or width of the output bins, e.g. `'1 day'`, `'15 minutes`', etc.
  * `time_range` (`tstzrange`), **required** — the desired range of data to return. Date bins are aligned to the start of this range

#### Returns

`SETOF target_table_elem%TYPE`. In other words, the output of this function may be treated as a table with the same schema as its first argument. Rows are not aggregated: only binning and `NULL` imputation are performed. A common use of this function is to treat it like a table and place it in the `FROM` clause of a query before performing other aggregation.

### `locf`

_Last-Observation-Carried-Forward_. This is a window function that operates over time-series data, replacing any missing data with the most recently seen non-`NULL` value.

#### Arguments

  * `value` (_any type_), **required** — input to the window function

#### Returns

`value` if `value` is not `NULL`

The most recent non-`NULL` value if `value` is `NULL`
