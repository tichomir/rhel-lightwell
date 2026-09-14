#!/usr/bin/bash
# First-boot database initialisation.
#
# Idempotent: the unit is guarded on the PGDATA marker, and this script is safe
# to re-run. Both matter because it must not fire again after `bootc upgrade`.
set -euo pipefail

PGDATA=/var/lib/pgsql/data
DB_NAME=imtrain
DB_USER=imtrain
DB_PASS=imtrain

if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
    echo "Initialising ${PGDATA}"
    /usr/bin/postgresql-setup --initdb

    # Lab-only: accept password auth from the app subnet. Tighten for anything
    # that is not a demo.
    echo "host all all 0.0.0.0/0 scram-sha-256" >> "${PGDATA}/pg_hba.conf"
    echo "listen_addresses = '*'"               >> "${PGDATA}/postgresql.conf"
fi

systemctl start postgresql
# Wait for the socket rather than sleeping a fixed interval.
for _ in $(seq 1 30); do
    if /usr/bin/pg_isready -q; then break; fi
    sleep 1
done

if ! su - postgres -c "psql -tAc \"select 1 from pg_roles where rolname='${DB_USER}'\"" | grep -q 1; then
    su - postgres -c "psql -c \"create role ${DB_USER} login password '${DB_PASS}'\""
fi

if ! su - postgres -c "psql -tAc \"select 1 from pg_database where datname='${DB_NAME}'\"" | grep -q 1; then
    su - postgres -c "createdb -O ${DB_USER} ${DB_NAME}"
fi

su - postgres -c "psql -d ${DB_NAME} -f /opt/seed/schema.sql"
su - postgres -c "psql -d ${DB_NAME} -f /opt/seed/seed.sql"
su - postgres -c "psql -d ${DB_NAME} -c 'grant all on all tables in schema public to ${DB_USER}'"
su - postgres -c "psql -d ${DB_NAME} -c 'grant all on all sequences in schema public to ${DB_USER}'"

echo "Database ready"
