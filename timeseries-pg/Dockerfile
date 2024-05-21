FROM quay.io/tembo/tembo-local

RUN trunk install pg_cron
RUN trunk install pg_partman --version 5.0.1
RUN trunk install hydra_columnar --version 1.1.1
RUN trunk install pg_timeseries

USER root
RUN echo "shared_preload_libraries = 'pg_cron'" >> /var/lib/postgresql/data2/postgresql.conf
USER postgres
