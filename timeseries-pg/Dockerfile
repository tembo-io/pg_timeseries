FROM postgres:16.3 as builder

RUN apt-get update \
    && apt-get install -y \
	ca-certificates \
	clang \
	curl \
	gcc \
	git \
	libssl-dev \
	make \
	pkg-config \
	postgresql-server-dev-16

WORKDIR /timeseries

# Install Rust dependencies
USER root
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
RUN $HOME/.cargo/bin/rustup default stable
# install trunk cli
RUN $HOME/.cargo/bin/cargo install pg-trunk
# install all extensions
RUN git clone https://github.com/citusdata/pg_cron.git && \
	cd pg_cron && \
	make && make install && \
    cd .. && rm -rf pg_cron

RUN git clone https://github.com/pgpartman/pg_partman.git && \
    cd pg_partman && \
    make && make install && \
    cd .. && rm -rf pg_partman

RUN apt install -y libcurl4-openssl-dev liblz4-dev libzstd-dev autoconf

RUN git clone https://github.com/hydradatabase/hydra && \
    cd hydra/columnar &&  \
    ./configure && \
    make && make install

# build and install timeseries
COPY . .
RUN make && make install || true

FROM postgres:16.3-bookworm
COPY --from=builder /usr/share/postgresql/16/extension /usr/share/postgresql/16/extension
COPY --from=builder /usr/lib/postgresql/16/lib /usr/lib/postgresql/16/lib

COPY timeseries.conf /usr/share/postgresql/16/postgresql.conf.sample
USER postgres
