FROM postgres:16 AS builder

RUN apt-get update \
    && apt-get install -y \
	autoconf \
	ca-certificates \
	clang \
	curl \
	gcc \
	git \
	libcurl4-openssl-dev \
	liblz4-dev \
	libssl-dev \
	libzstd-dev \
	make \
	pkg-config \
	postgresql-server-dev-16

WORKDIR /timeseries

# install all extensions
RUN git clone https://github.com/citusdata/pg_cron.git && \
	cd pg_cron && \
	make && make install && \
    cd .. && rm -rf pg_cron

RUN git clone https://github.com/pgpartman/pg_partman.git && \
    cd pg_partman && \
    make && make install && \
    cd .. && rm -rf pg_partman

RUN git clone https://github.com/hydradatabase/hydra && \
    cd hydra/columnar &&  \
    make && make install && \
	cd ../.. && rm -rf hydra

RUN git clone https://github.com/tembo-io/pg_ivm.git && \
	cd pg_ivm && \
	make && make install && \
	cd .. && rm -rf pg_ivm

# build and install timeseries
COPY . .
RUN make && make install || true

FROM postgres:16-bookworm
COPY --from=builder /usr/share/postgresql/16/extension /usr/share/postgresql/16/extension
COPY --from=builder /usr/lib/postgresql/16/lib /usr/lib/postgresql/16/lib

COPY timeseries.conf .
RUN cat timeseries.conf >> /usr/share/postgresql/16/postgresql.conf.sample

USER postgres
