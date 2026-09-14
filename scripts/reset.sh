#!/usr/bin/bash
# Reset to a recording baseline. You will run this twenty times.
#
#   SNAP=act0-baseline ./scripts/reset.sh
#
# im-train-db is never reverted: nothing in the demo changes it, which is most
# of the benefit of demoting that tier.
#
# Use INTERNAL snapshots, not `--disk-only`:
#
#   virsh snapshot-create-as im-train act0-baseline --atomic
#
# Measured on this lab: internal revert is ~0.8s and the guest resumes already
# running, because the snapshot carries RAM state - no boot, no wait for the
# app to come back. `--disk-only` works too (libvirt 11.x can revert external
# snapshots, which older versions could not) but it costs a boot cycle and adds
# an overlay to the disk chain at every act boundary, so by Act 4 you are
# several layers deep and flattening means blockcommit.
set -euo pipefail

VM="${VM:-im-train}"
SNAP="${SNAP:-act0-baseline}"
APP_HOST="${APP_HOST:-im-train.homelab.com}"
DB_HOST="${DB_HOST:-im-train-db.homelab.com}"
SSH_USER="${SSH_USER:-rhel-admin}"

# Where libvirt lives. Empty means this host. Run this from the builder and it
# has to reach the hypervisor instead:
#
#   VIRSH_URI=qemu+ssh://user@hypervisor/system ./scripts/reset.sh
#
# That needs an SSH key to the hypervisor and the remote user in the `libvirt`
# group - without the group, polkit refuses with "no polkit agent available"
# even though SSH and sudo both work.
VIRSH_URI="${VIRSH_URI:-}"
VIRSH=(virsh)
[[ -n "${VIRSH_URI}" ]] && VIRSH=(virsh -c "${VIRSH_URI}")

echo "== reverting ${VM} to ${SNAP} =="
"${VIRSH[@]}" snapshot-revert "${VM}" "${SNAP}" --running

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
# Fetched from the app host itself rather than from here: the guests sit on the
# libvirt network with localOnly DNS, so im-train.homelab.com resolves for them
# and not necessarily for whatever machine you are running this from.
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${APP_HOST}" \
    "curl -fsS http://localhost:8080/api/status" \
  | jq '{os_version, image, digest, jinja2: .dependencies.jinja2,
         remediated: .lightwell.remediated, db: .database.available,
         unsafe_emitted: .probe.unsafe_key_emitted}'

echo
echo "Ready for the next take."
