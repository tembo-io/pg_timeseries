# Tembo Time-Series API

The purpose of this extension is to provide a cohesive user experience around the creation, maintenance, and use of time-series tables.

[![Tembo Cloud Try Free](https://tembo.io/tryFreeButton.svg)](https://cloud.tembo.io/sign-up)

[![Static Badge](https://img.shields.io/badge/%40tembo-community?logo=slack&label=slack)](https://join.slack.com/t/tembocommunity/shared_invite/zt-277pu7chi-NHtvHWvLhHwyK0Y5Y6vTPw)
[![OSSRank](https://shields.io/endpoint?url=https://ossrank.com/shield/4022)](https://ossrank.com/p/4022)

## Installation

### Running with docker

Start a Docker container running Postgres with `pg_timeseries` pre-installed.

```bash
docker run -d --name pg-timeseries -p 5432:5432 -e POSTGRES_PASSWORD=postgres quay.io/tembo/timeseries-pg:latest
```

Then connect to the database and enable the extension:

```bash
psql postgres://postgres:postgres@localhost:5432/postgres
```

```sql
CREATE EXTENSION timeseries CASCADE;
```

```text
NOTICE:  installing required extension "columnar"
NOTICE:  installing required extension "pg_cron"
NOTICE:  installing required extension "pg_partman"
CREATE EXTENSION
```

## Getting Started

Once you have determined which table needs time-series enhancement, simply call the `enable_ts_table` function with your table name and the name of the column that stores the time for each row:

```sql
SELECT enable_ts_table('sensor_readings');
```

With this one call, several things will happen:

  * The table will be restructured as a series of partitions using PostgreSQL's [native PARTITION features](https://www.postgresql.org/docs/current/ddl-partitioning.html)
  * Each partition covers a particular range of time (one week by default)
  * New partitions will be created for some time in the future (one month by default)
  * Once an hour, a maintenance job will create any missing partitions as well as needed future ones

## Using your tables

So you've got a table. Now what?

### Indexes

The time-series tables you create start out life as little more than typical [partitioned PostgreSQL tables](https://www.postgresql.org/docs/current/ddl-partitioning.html). But this simplicity also means all of PostgreSQL's existing functionality will "just work" with them. A fairly important piece of a time-series table is an index along the time dimension.

[Traditional B-Tree indexes](https://www.postgresql.org/docs/current/btree-intro.html) work well for time-series data, but you may wish to benchmark [BRIN indexes](https://www.postgresql.org/docs/current/brin-intro.html) as well, as they may perform better in specific query scenarios (often queries with _many_ results). Start with B-Tree if you don't anticipate more than a million records in each partition (by default, partitions are one week long).

### Partition Sizing

Related to the above information on indexes is the question of partition size. Because calculating the total size of partitioned tables can be tedious, Tembo's extension provides several easy-to-use views surfacing this information.

To examine the table (data), index, and total size for each of your partitions, simple query the time-series partition information view, `ts_part_info`. A general rule of thumb is that each partition should be able to fit within roughly one quarter of your available memory. This assumes that not much apart from the time-series workload is going on, and things like parallel workers may complicate matters, but work on getting partition total size down to around a quarter of your memory and you're off to a good start.

### Retention

On the other hand, you may be worried about plugging a firehose of data into your storage layer to begin with… While the `ts_table_info` view may allay your fears, at some point you _will_ want to remove some of your time-series data.

Fortunately, it's incredibly easy to simply drop time-series partitions on a schedule. Call `set_ts_retention_policy` with your time-series table and an interval (say, `'90 days'`) to establish such a policy. Once an hour, any partitions falling entirely outside the retention window will be dropped. Use `clear_ts_retention_policy` to revert to the default behavior (infinite retention). Each of these functions will return the previous retention policy when called.

### Compression

Sometimes you know older data isn't queried very often, but still don't want to commit to just dropping older partitions. In this case, compression may be what you desire.

By calling `set_ts_compression_policy` on a time-series table with an appropriate interval (perhaps`'1 month'`), this extension will take care of compressing partitions (using a columnar storage method) older than the specified interval, once an hour. As with the retention policy functionality, a function is also provided for clearing any existing policy (existing partitions will not be decompressed, however).

### Analytics Helpers

This extension includes several functions intended to make writing correct time-series queries easier. Certain concepts can be difficult to express in standard SQL and helper functions can aid in readability and maintainability.

#### `first` and `last`

These two functions help clean up the syntax of a fairly common pattern: a query is grouped by one dimension, but a user wants to know what the first or last row in a group is when ordered by a _different_ dimension.

For instance, you might have a cloud computing platform reporting metrics and wish to know the latest (in time) CPU utilization metric for each machine in the platform:

```sql
SELECT machine_id,
       last(cpu_util, recorded_at)
FROM events
GROUP BY machine_id;
```

#### `date_bin_table`

This function automates the tedium of aligning time-series values to a given width, or "stride", and makes sure to include NULL rows for any time periods where the source table has no data points.

It must be called against a time-series table, but apart from that consideration using it is pretty straightforward:

```sql
SELECT * FROM date_bin_table(NULL::target_table, '1 hour', '[2024-02-01 00:00, 2024-02-02 15:00]');
```

The output of this query will differ from simply hitting the target table directly in three ways:

  * Rows will be sorted by time, ascending
  * The time column's values will be binned to the provided width
  * Extra rows will be added for periods with no data. They will include the time stamp for that bin and NULL in all other columns



## Roadmap

While `timeseries` is still in its early days, we have a concrete vision for the features we will be including in the future. Feedback on the importance of a given feature to customer use cases will help us better prioritize the following lists.

This list is somewhat ordered by likelihood of near-term delivery, or maybe difficulty, but that property is only loosely intended and no guarantee of priority. Again, feedback from users will take precedence.

  - Assorted "analytic" functions frequently associated with time-series workloads
  - Periodic `REFRESH MATERIALIZED VIEW` — set schedules for background refresh of materialized views (useful for dashboarding, etc.)
  - Roll-off to `TABLESPACE` — as data ages, it will be moved into a specified table space
  - Use of "tiered storage", i.e. moving older partitions to be stored in S3 rather than on-disk
  - Automatic `CLUSTER BY`/repack for non-live partitions
  - Migration tools — adapters for existing time-scale installations to ease migration and promote best practices in new table configuration
  - "Approximate" functions — maintain statistics within known error bounds without rescanning all data
  - Change partition width — modify partition width of existing table (for future data)
  - "Roll-up and roll-off" — as data ages, combine multiple rows into single summary rows
  - Incremental view maintenance — define views which stay up-to-date with incoming data without the performance hit of a `REFRESH`
  - Repartition — modify partition width of existing table data
