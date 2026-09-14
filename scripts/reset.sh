#!/usr/bin/bash
# Reset to a recording baseline. You will run this twenty times.
#
#   SNAP=act0-baseline ./scripts/reset.sh
#
# im-train-db is never reverted: nothing in the demo changes it, which is most
# of the benefit of demoting that tier.
set -euo pipefail

VM="${VM:-im-train}"
SNAP="${SNAP:-act0-baseline}"
APP_HOST="${APP_HOST:-im-train.homelab.com}"
DB_HOST="${DB_HOST:-im-train-db.homelab.com}"
SSH_USER="${SSH_USER:-rhel-admin}"

echo "== reverting ${VM} to ${SNAP} =="
virsh snapshot-revert "${VM}" "${SNAP}" --running

echo "== waiting for ssh =="
for _ in $(seq 1 60); do
    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
           "${SSH_USER}@${APP_HOST}" true 2>/dev/null; then
        break
    fi
    sleep 2
done

# Snapshots may predate the timer change. Re-disable every time: an auto-upgrade
# firing between takes will silently undo a rollback you just demonstrated.
echo "== disabling the bootc update timer =="
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${APP_HOST}" \
    "sudo systemctl disable --now bootc-fetch-apply-updates.timer || true"

echo "== reseeding the database =="
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${DB_HOST}" \
    "sudo -u postgres psql -d imtrain -f /opt/seed/seed.sql -q"

echo "== baseline state =="
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${APP_HOST}" "sudo bootc status" || true
curl -fsS "http://${APP_HOST}:8080/api/status" \
  | jq '{os_version, image, digest, jinja2: .dependencies.jinja2,
         remediated: .lightwell.remediated, db: .database.available,
         unsafe_emitted: .probe.unsafe_key_emitted}'

echo
echo "Ready for the next take."
