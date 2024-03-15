# Getting Started with the timeseries Extension

In this guide, you will become familiar with the functions and features of the timeseries extension through a hands-on tutorial using public bikeshare trip data from the Chicago bike share system, Divvy.

## Preparing your database

You'll need a PostgreSQL instance running timeseries `0.1.2` or later. An easy way to have one set up for you is to deploy one from Tembo Cloud [here](https://cloud.tembo.io). The free tier _should_ perform well enough, though slightly more memory may be a good idea.

Once that's up and running, you'll need a client machine with `psql` (to connect to your database) and [the Divvy dataset](TODO), which will total about 4GiB of CSV after decompression. If you need help installing `psql`, instructions can be found [here](TODO).

### Connecting to Tembo

TODO

### Create the time-series table

Since we're starting from scratch, begin by making an empty table. We'll load the data into this shortly using a `\copy` command, after which point our application could continue to `INSERT` new trips in an ongoing fashion.

The `timeseries` extension requires three things of your table. It must:

  * Use PostgreSQL's `PARTITION BY RANGE` syntax to declare itself as partitioned
  * Specify a column with a time type as the partition key (`date`, `timestamp`, `timestamptz`)
  * Restrict the partition column to reject `NULL` values (i.e. include `NOT NULL`)

The data set we're using will fit naturally into the following schema:

```sql
CREATE TABLE IF NOT EXISTS
  divvy_trips (
    ride_id text NOT NULL,
    rideable_type text NULL,
    started_at timestamptz NOT NULL,
    ended_at timestamptz NOT NULL,
    start_station_name text,
    start_station_id text,
    end_station_name text,
    end_station_id text,
    start_lat float,
    start_lng float,
    end_lat float,
    end_lng float,
    member_casual text
  ) PARTITION BY RANGE (started_at);
```

After creating the table, enhancing it with time-series capabilities can be done with a call to `enable_ts_table`. The only required argument is the table name, but optional parameters are also available:

  * `partition_duration` — the size or "width" of each partition, expressed as an `INTERVAL`. Defaults to one week
  * `partition_lead_time` — how far into the future to "premake" new partitions, expressed as an `INTERVAL`. Defaults to one month
  * `initial_table_start` — a`timestamptz` used to determine the start of the table's first partition. Omit this except when backfilling data into a new table

We're doing a backfill, and aur data set goes back _almost_ to 2019, so `2020-01-01T00:00:00Z` will work as `initial_table_start`.

For our purposes, I can tell you that a partition width of `1 month` will perform well enough. `partition_duration` is probably the configuration option that will most affect performance: the next subsection will cover this briefly.

Knowing all this, we can engage time-series behavior for our table:

```sql
SELECT enable_ts_table(
  'divvy_trips',
  partition_duration := '1 month',
  initial_table_start := '2020-01-01');
```

#### Performance and Partition Size

It's a good rule of thumb that a partition fit in memory (indexes and all). In fact, for flexibility, it's best that something like three to five do, for each time-series table in the active workload.

This tutorial will not reflect real-world use (where our analytic queries must live alongside a stream of `INSERT`s), and there is a balance to be struck between having a partition small enough that it remains resident and having it so large the working set thrashes the page cache, so you will need to benchmark scenarios for your specific application.

### Add appropriate indexes

The `timeseries` extension will create an index on the table's partition column if [none exists](TODO), but for our tutorial we'll want a few more.

```sql
CREATE INDEX ON divvy_trips (started_at DESC);
CREATE INDEX ON divvy_trips (start_station_id, started_at DESC);
CREATE INDEX ON divvy_trips (end_station_id, ended_at DESC);
CREATE INDEX ON divvy_trips (rideable_type, started_at DESC);
```

For a backfill like this it's probably going to save some time to create index _after_ data is loaded, but we'll eat that cost in order to discuss the convenience views provided by `timeseries`.

## Timeseries table information

Because viewing the sizes of the data and indexes of a partitioned table can be unwieldy in PostgreSQL (and often requires filtering out irrelevant other tables), `timeseries` provides three relations for viewing information about the tables it manages.

### `ts_config` — time-series config

This table stores information about how time-series tables were created and is queried or modified by `timeseries`' code any time its functions are called. Here's how it should look for us:

```sql
user@[local] postgres ❯❯❯ SELECT * FROM ts_config;
┌─[ RECORD 1 ]────────┬─────────────┐
│ table_id            │ divvy_trips │
│ partition_duration  │ 1 mon       │
│ partition_lead_time │ 1 mon       │
│ retention_duration  │ ∅           │
└─────────────────────┴─────────────┘
```

`retention_duration` specifies when to drop old data. We'll come to that later.

### `ts_table_info` — time-series table info

If you need a "big picture" of the data and index usage for your time-series table, check this view: it contains columns that sum across all partitions. Throw this value into a monitoring system to keep on top of your total disk usage for each time-series table.

```sql
user@[local] postgres ❯❯❯ SELECT * FROM ts_table_info;
┌─[ RECORD 1 ]─────┬─────────────┐
│ table_id         │ divvy_trips │
│ table_size_bytes │ 434176      │
│ index_size_bytes │ 1736704     │
│ total_size_bytes │ 2170880     │
└──────────────────┴─────────────┘
```

_Hint: these views keep the sizes as numeric types, which makes arithmetic and aggregation easier at the cost of human-readability. Rewrite the above query using [`pg_size_pretty`](https://www.postgresql.org/docs/current/functions-admin.html#id-1.5.8.33.9.3.2.2.7.1.1.1) to add e.g. `GB`, `MB` suffixes, if you wish_.

### `ts_part_info` — time-series partition info

When picking `partition_duration`, it is crucial to double-check your work using this view. It's essentially identical to the table-based view (in fact, it feeds it), but shows data on a per-partition basis.

```sql
user@[local] postgres ❯❯❯ SELECT * FROM ts_part_info ;
┌─[ RECORD 1 ]─────┬────────────────────────────────────────────┐
│ table_id         │ divvy_trips                                │
│ part_id          │ divvy_trips_p20200101                      │
│ part_range       │ FOR VALUES FROM ('2020-01-01 00:00:00-07')…│
│                  │… TO ('2020-02-01 00:00:00-07')             │
│ table_size_bytes │ 8192                                       │
│ index_size_bytes │ 32768                                      │
│ total_size_bytes │ 40960                                      │
├─[ RECORD 2 ]─────┼────────────────────────────────────────────┤
│ table_id         │ divvy_trips                                │
│ part_id          │ divvy_trips_p20200201                      │
│ part_range       │ FOR VALUES FROM ('2020-02-01 00:00:00-07')…│
│                  │… TO ('2020-03-01 00:00:00-07')             │
│ table_size_bytes │ 8192                                       │
│ index_size_bytes │ 32768                                      │
│ total_size_bytes │ 40960                                      │
├─[ ...   ... ]────┼────────────────────────────────────────────┤
│ (add'l records)  │ (add'l records)                            │
├─[ RECORD XX ]────┼────────────────────────────────────────────┤
│ table_id         │ divvy_trips                                │
│ part_id          │ divvy_trips_default                        │
│ part_range       │ DEFAULT                                    │
│ table_size_bytes │ 8192                                       │
│ index_size_bytes │ 32768                                      │
│ total_size_bytes │ 40960                                      │
└──────────────────┴────────────────────────────────────────────┘
```

We'll return to these after loading our data.

## Load and inspect data

NOTE: sub-one minute load time for data (on free tier)
NOTE: sub-five minute run time for guide

The CSV should load with a simple `\copy` command.

```sql
user@[local] postgres ❯❯❯ \copy divvy_trips
  from 202004--202402-divvy-tripdata.csv
  with (header on, format csv);
COPY 20465490
```

### Bulk load considerations

There are important considerations in the bulk-loading of data which can improve both ingestion time and post-ingest query performance, but they apply equally to most PostgreSQL data loads and so are out of scope for this document. Search for information about how to best configure WAL, indexes, and how to order the data itself for more.

### Inspect informational views

Let's check the table size now:

```sql
user@[local] postgres ❯❯❯ SELECT
  table_id,
  pg_size_pretty(table_size_bytes) AS table_size,
  pg_size_pretty(index_size_bytes) AS index_size,
  pg_size_pretty(total_size_bytes) AS total_size
  FROM ts_table_info;
┌─────────────┬────────────┬────────────┬────────────┐
│  table_id   │ table_size │ index_size │ total_size │
├─────────────┼────────────┼────────────┼────────────┤
│ divvy_trips │ 3549 MB    │ 3301 MB    │ 6849 MB    │
└─────────────┴────────────┴────────────┴────────────┘
```

All right, we're looking at about six gigs, split somewhat evenly between indexes and data. But are the partitions similar sizes?

```sql
jason@[local] postgres ❯❯❯ SELECT
  part_range,
  pg_size_pretty(total_size_bytes) AS part_size
  FROM ts_part_info
  ORDER BY total_size_bytes DESC
  LIMIT 5;
┌───────────────────────────────────────────────────────────────┬───────────┐
│                                part_range                     │ part_size │
├───────────────────────────────────────────────────────────────┼───────────┤
│ FROM ('2021-07-01 00:00:00-06') TO ('2021-08-01 00:00:00-06') │ 277 MB    │
│ FROM ('2022-07-01 00:00:00-06') TO ('2022-08-01 00:00:00-06') │ 277 MB    │
│ FROM ('2021-08-01 00:00:00-06') TO ('2021-09-01 00:00:00-06') │ 271 MB    │
│ FROM ('2022-08-01 00:00:00-06') TO ('2022-09-01 00:00:00-06') │ 263 MB    │
│ FROM ('2022-06-01 00:00:00-06') TO ('2022-07-01 00:00:00-06') │ 258 MB    │
└───────────────────────────────────────────────────────────────┴───────────┘
```

The largest appear to be roughly 100MB and covering time ranges in the summer, a nice manageable size (especially once parallel queries start hitting many at once). But the smallest? Note the `WHERE` clause needed to filter out entirely empty partitions (which are related to the size of empty tables and indexes).

```sql
SELECT
  part_range,
  pg_size_pretty(total_size_bytes) AS part_size
  FROM ts_part_info
  WHERE total_size_bytes > pg_size_bytes('1MB')
  ORDER BY total_size_bytes ASC
  LIMIT 5;
┌───────────────────────────────────────────────────────────────┬───────────┐
│                                part_range                     │ part_size │
├───────────────────────────────────────────────────────────────┼───────────┤
│ FROM ('2021-02-01 00:00:00-07') TO ('2021-03-01 00:00:00-07') │ 18 MB     │
│ FROM ('2020-04-01 00:00:00-06') TO ('2020-05-01 00:00:00-06') │ 28 MB     │
│ FROM ('2021-01-01 00:00:00-07') TO ('2021-02-01 00:00:00-07') │ 34 MB     │
│ FROM ('2022-01-01 00:00:00-07') TO ('2022-02-01 00:00:00-07') │ 36 MB     │
│ FROM ('2022-02-01 00:00:00-07') TO ('2022-03-01 00:00:00-07') │ 39 MB     │
└───────────────────────────────────────────────────────────────┴───────────┘
```

These are fully ten times smaller than the largest, in several cases. While not exactly surprising that a bike share in Chicago sees less utilization in January and February (and during, uhhhh, the onset of the COVID-19 lockdown), it's neat to see the seasonality of this data in the partition sizes themselves.

### `EXPLAIN` partition pruning

Before we begin writing more complex theories, let's see what the planner comes up with for a count of queries during a certain quarter…

```sql
user@[local] postgres ❯❯❯ SELECT COUNT(*)
  FROM divvy_trips
  WHERE started_at > '2022-01-01'
  AND started_at < '2022-04-01';
┌────────┐
│ count  │
├────────┤
│ 503421 │
└────────┘
```

This took less than 40ms on my install. How does that work?

```sql
user@[local] postgres ❯❯❯ EXPLAIN SELECT COUNT(*)
  FROM divvy_trips
  WHERE started_at > '2022-01-01'
  AND started_at < '2022-04-01';
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                               QUERY PLAN                                                │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Finalize Aggregate  (cost=16941.10..16941.11 rows=1 width=8)                                            │
│   ->  Gather  (cost=16940.89..16941.10 rows=2 width=8)                                                  │
│         Workers Planned: 2                                                                              │
│         ->  Partial Aggregate  (cost=15940.89..15940.90 rows=1 width=8)                                 │
│               ->  Parallel Append  (cost=0.29..15416.49 rows=209759 width=0)                            │
│                     ->  Parallel Index Only Scan using divvy_trips_p20220201_started_at_idx on divvy_tr…│
│…ips_p20220201 divvy_trips_2  (cost=0.29..3298.08 rows=48170 width=0)                                    │
│                           Index Cond: ((started_at > '2022-01-01 00:00:00-07'::timestamp with time zone…│
│…) AND (started_at < '2022-04-01 00:00:00-06'::timestamp with time zone))                                │
│                     ->  Parallel Index Only Scan using divvy_trips_p20220101_started_at_idx on divvy_tr…│
│…ips_p20220101 divvy_trips_1  (cost=0.29..3006.35 rows=43238 width=0)                                    │
│                           Index Cond: ((started_at > '2022-01-01 00:00:00-07'::timestamp with time zone…│
│…) AND (started_at < '2022-04-01 00:00:00-06'::timestamp with time zone))                                │
│                     ->  Parallel Seq Scan on divvy_trips_p20220301 divvy_trips_3  (cost=0.00..8063.26 r…│
│…ows=118351 width=0)                                                                                     │
│                           Filter: ((started_at > '2022-01-01 00:00:00-07'::timestamp with time zone) AN…│
│…D (started_at < '2022-04-01 00:00:00-06'::timestamp with time zone))                                    │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

There's a lot going on here, but the important things to note are:
  * the `COUNT` aggregate has been broken into an append and gather job using two workers
  * only three partitions are referenced by this plan

That's what we expect, but it's good to see.

## Digging into the data

With our data loaded up, we're ready for some more interesting queries. Start by figuring out which days of the week had the most rides in 2023. The `dow` option to `extract` starts the week at `0` on Sunday.

```sql
user@[local] postgres ❯❯❯ SELECT
  extract(dow from started_at) AS weekday_idx,
  COUNT(*) AS total_rides FROM divvy_trips
  WHERE started_at BETWEEN '2023-01-01' AND '2024-01-01'
  GROUP BY weekday_idx
  ORDER BY weekday_idx;
┌─────────────┬─────────────┐
│ weekday_idx │ total_rides │
├─────────────┼─────────────┤
│           0 │      744578 │
│           1 │      729404 │
│           2 │      822978 │
│           3 │      835625 │
│           4 │      860202 │
│           5 │      843524 │
│           6 │      883566 │
└─────────────┴─────────────┘
```

It's pretty clear ridership falls on Sundays and Mondays but really picks up going into the weekends. What about hourly trends? Which stations have the highest ridership during the mornings? Because of more modern stationless bikes, not all rides have an originating station, so we need to include a filter for that.

```sql
user@[local] postgres ❯❯❯ SELECT
  start_station_id,
  COUNT(*) as checkouts
  FROM divvy_trips
  WHERE start_station_id IS NOT NULL
  AND started_at BETWEEN '2023-01-01' AND '2024-01-01'
  AND date_part('hour', started_at) BETWEEN 6 AND 10
  GROUP BY start_station_id ORDER BY checkouts DESC limit 10;
┌──────────────────┬───────────┐
│ start_station_id │ checkouts │
├──────────────────┼───────────┤
│ WL-012           │     11768 │
│ KA1503000043     │      9800 │
│ TA1305000032     │      9495 │
│ TA1307000039     │      9410 │
│ 638              │      7202 │
│ KA1504000135     │      7032 │
│ 13011            │      6888 │
│ SL-005           │      6855 │
│ 13022            │      6750 │
│ TA1306000012     │      6427 │
└──────────────────┴───────────┘
```

This could be useful information when deciding where to redeploy bikes from maintenance holds overnight going into the morning rush. Let's compare this to the most popular endpoints during evening hours…

```sql
user@[local] postgres ❯❯❯ SELECT
  end_station_id,
  COUNT(*) as checkins
  FROM divvy_trips
  WHERE end_station_id IS NOT NULL
  AND started_at BETWEEN '2023-01-01' AND '2024-01-01'
  AND date_part('hour', started_at) BETWEEN 17 AND 21
  GROUP BY end_station_id ORDER BY checkins DESC limit 10;
┌────────────────┬──────────┐
│ end_station_id │ checkins │
├────────────────┼──────────┤
│ 13022          │    17120 │
│ LF-005         │    15629 │
│ TA1307000039   │    12918 │
│ TA1308000050   │    12239 │
│ KA1504000135   │    11565 │
│ 13137          │    11284 │
│ 13300          │     9982 │
│ 13146          │     9919 │
│ 13042          │     9815 │
│ TA1307000134   │     9753 │
└────────────────┴──────────┘
```

While this list shares _some_ elements with the morning hot spots, there are several stations here to consider as sources for bicycles that will be needed elsewhere the next day.

What about the adoption and use of the different kinds of bicycles? This query is hand-written to perform a pivot for the sake of output readability:

```sql
user@[local] postgres ❯❯❯ SELECT
  date_trunc('month', started_at)::date AS month,
  SUM(CASE WHEN rideable_type = 'classic_bike' THEN 1 ELSE 0 END) AS classic,
  SUM(CASE WHEN rideable_type = 'docked_bike' THEN 1 ELSE 0 END) AS docked,
  SUM(CASE WHEN rideable_type = 'electric_bike' THEN 1 ELSE 0 END) AS electric
  FROM divvy_trips
  WHERE started_at BETWEEN '2022-01-01' AND '2023-01-01'
  GROUP BY month
  ORDER BY month ASC;
┌────────────┬─────────┬────────┬──────────┐
│   month    │ classic │ docked │ electric │
├────────────┼─────────┼────────┼──────────┤
│ 2022-01-01 │   55067 │    961 │    47742 │
│ 2022-02-01 │   59414 │   1361 │    54834 │
│ 2022-03-01 │  134439 │   8358 │   141245 │
│ 2022-04-01 │  166712 │  12116 │   192421 │
│ 2022-05-01 │  324046 │  26409 │   284403 │
│ 2022-06-01 │  406660 │  30640 │   331904 │
│ 2022-07-01 │  373173 │  31055 │   419260 │
│ 2022-08-01 │  344050 │  26323 │   415559 │
│ 2022-09-01 │  306142 │  19826 │   375371 │
│ 2022-10-01 │  213560 │  12614 │   332511 │
│ 2022-11-01 │  144601 │   5886 │   187248 │
│ 2022-12-01 │   73350 │   1925 │   106531 │
└────────────┴─────────┴────────┴──────────┘
```

We probably want some insight into the duration of rides. Let's generate a table of deciles…

```sql
user@[local] postgres ❯❯❯
WITH rides AS (
  SELECT (ended_at - started_at) AS duration
  FROM divvy_trips
  WHERE ended_at > started_at
  AND started_at BETWEEN '2023-01-01' AND '2024-01-01'
), deciles AS (
  SELECT rides.duration AS duration,
  ntile(10) OVER (ORDER BY rides.duration) AS decile FROM rides
) SELECT (10 * decile) AS "%ile",
  MAX(duration) AS duration
  FROM deciles
  GROUP BY decile
  ORDER BY decile ASC;
┌──────┬──────────────────┐
│ %ile │     duration     │
├──────┼──────────────────┤
│   10 │ 00:03:12         │
│   20 │ 00:04:43         │
│   30 │ 00:06:09         │
│   40 │ 00:07:43         │
│   50 │ 00:09:32         │
│   60 │ 00:11:47         │
│   70 │ 00:14:51         │
│   80 │ 00:19:37         │
│   90 │ 00:29:10         │
│  100 │ 68 days 09:29:04 │
└──────┴──────────────────┘
```

The 100th percentile is likely bad data, but the rest is interesting! Most rides are under ten minutes, but one in ten exceeds a half-hour. Putting this in to a `MATERIALIZED VIEW` and refreshing it weekly might make a nice source for an office dashboard or other visualization.

