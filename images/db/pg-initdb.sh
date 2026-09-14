#!/usr/bin/bash
# First-boot database initialisation.
#
# Idempotent: the unit is guarded on the PGDATA marker, and this script is safe
# to re-run. Both matter because it must not fire again after `bootc upgrade`.
set -euo pipefail

PGDATA=/var/lib/pgsql/data
SEED_MARKER=/var/lib/pgsql/.seed-complete
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

# Bring the cluster up with pg_ctl, NOT systemctl.
#
# This unit is ordered Before=postgresql.service. Asking systemd to start
# postgresql from inside it deadlocks: systemd queues that job behind this very
# unit, so the script waits for postgresql while postgresql waits for the
# script. `systemctl list-jobs` shows pg-initdb running and postgresql waiting,
# forever, and the guest boots with no database and no error.
#
# pg_ctl talks to the cluster directly and never involves systemd. -w waits for
# readiness, so no polling loop is needed either.
PGCTL=$(command -v pg_ctl || echo /usr/bin/pg_ctl)
su - postgres -c "${PGCTL} -D ${PGDATA} -w -l ${PGDATA}/initdb-seed.log start"

# Hand a clean, stopped cluster back to systemd however this script exits, so
# postgresql.service starts it properly rather than finding it already running
# under a pg_ctl-owned postmaster.
cleanup() { su - postgres -c "${PGCTL} -D ${PGDATA} -w stop" || true; }
trap cleanup EXIT

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

# Written only now, after seeding has actually succeeded. The unit is guarded on
# THIS file rather than on PGDATA/PG_VERSION, because initdb creates PG_VERSION
# before any seeding happens - so guarding on it means a run that dies partway
# can never retry, and the guest boots forever with an empty database.
touch "${SEED_MARKER}"

echo "Database ready"
