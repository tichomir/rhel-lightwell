#!/usr/bin/bash
# Everything that has to happen after virt-install, before recording.
#
#   VIRSH_URI=qemu+ssh://user@hypervisor/system ./scripts/post-provision.sh
#
# Run this from the builder after provisioning or reprovisioning either guest.
# Idempotent - safe to re-run, and re-running is the right move if you are not
# sure whether it has been done.
#
# WHY THIS EXISTS, rather than being folded into config.toml:
#
# bootc-image-builder's [[customizations.user]] takes a single `key`, so the
# provisioned guests trust exactly one SSH key - whoever built the image. But
# reset.sh runs FROM the builder and drives both guests over SSH unattended, so
# the builder's key has to be there too. Guest authorized_keys lives under
# /var, which survives reboots and `bootc upgrade` - but NOT a reprovision from
# a fresh qcow2. So this runs once per provision.
#
# The ordering below is not arbitrary. The snapshot must be taken LAST: a key
# or a disabled timer added after the snapshot is erased by the first revert,
# and you find out mid-take.
set -euo pipefail

APP_HOST="${APP_HOST:-im-train.homelab.com}"
DB_HOST="${DB_HOST:-im-train-db.homelab.com}"
SSH_USER="${SSH_USER:-rhel-admin}"
VM="${VM:-im-train}"
SNAP="${SNAP:-act0-baseline}"

VIRSH_URI="${VIRSH_URI:-}"
VIRSH=(virsh)
[[ -n "${VIRSH_URI}" ]] && VIRSH=(virsh -c "${VIRSH_URI}")

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

PUBKEY_FILE="${PUBKEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
[[ -f "${PUBKEY_FILE}" ]] || {
    echo "No public key at ${PUBKEY_FILE}." >&2
    echo "Generate one: ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519" >&2
    exit 1
}
PUBKEY="$(cat "${PUBKEY_FILE}")"

echo "== 1. authorising this host's key on both guests =="
for h in "${APP_HOST}" "${DB_HOST}"; do
    printf '  %-26s ' "${h}"
    # Passed on stdin rather than interpolated into the remote command, so a
    # key with awkward characters cannot be mangled by two layers of shell.
    printf '%s\n' "${PUBKEY}" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${h}" '
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        k=$(cat)
        grep -qxF "$k" ~/.ssh/authorized_keys 2>/dev/null || printf "%s\n" "$k" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        echo "ok ($(wc -l < ~/.ssh/authorized_keys) keys)"'
done

echo "== 2. disabling the bootc update timer on both =="
# The single highest-value step here. Image-mode hosts fetch and apply updates
# every 1-3 hours, and after a `bootc rollback` they will update again unless
# this is off - silently undoing the rollback you just demonstrated, between
# takes, with nothing on screen to tell you.
for h in "${APP_HOST}" "${DB_HOST}"; do
    printf '  %-26s ' "${h}"
    # `systemctl is-enabled` exits 1 for a DISABLED unit - which is the outcome
    # being asked for here. Without the `|| true` this succeeds and then kills
    # the script under set -e, right before the snapshot step.
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${h}" \
        'sudo systemctl disable --now bootc-fetch-apply-updates.timer >/dev/null 2>&1
         systemctl is-enabled bootc-fetch-apply-updates.timer 2>&1 || true'
done

echo "== 3. checking the baseline is actually what you want to film =="
STATUS="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${APP_HOST}" 'curl -fsS http://localhost:8080/api/status')"
jq '{os_version, image, digest, jinja2: .dependencies.jinja2,
     remediated: .lightwell.remediated, db: .database.available,
     unsafe_emitted: .probe.unsafe_key_emitted,
     rollback_available}' <<<"${STATUS}"

# Fail loudly rather than snapshotting a baseline that cannot open the demo.
fault=0
[[ "$(jq -r .database.available        <<<"${STATUS}")" == "true"  ]] || { echo "  database unreachable" >&2; fault=1; }
[[ "$(jq -r .probe.unsafe_key_emitted  <<<"${STATUS}")" == "true"  ]] || { echo "  CVE observable is NOT vulnerable - Act 2 has nothing to show" >&2; fault=1; }
[[ "$(jq -r .lightwell.remediated      <<<"${STATUS}")" == "false" ]] || { echo "  already remediated - this is not a baseline" >&2; fault=1; }
[[ "$(jq -r .image_mode                <<<"${STATUS}")" == "true"  ]] || { echo "  not an image-mode host" >&2; fault=1; }
(( fault == 0 )) || { echo "Baseline is wrong; not snapshotting." >&2; exit 1; }

echo "== 4. snapshotting ${VM} as ${SNAP} =="
# Internal, not --disk-only: reverts in under a second and resumes already
# running, because the snapshot carries RAM state. See reset.sh.
"${VIRSH[@]}" snapshot-delete "${VM}" "${SNAP}" >/dev/null 2>&1 || true
"${VIRSH[@]}" snapshot-create-as "${VM}" "${SNAP}" \
    --description "baseline: $(jq -r '"os "+.os_version+", jinja2 "+.dependencies.jinja2' <<<"${STATUS}")" \
    --atomic
"${VIRSH[@]}" snapshot-list "${VM}"

cat <<NEXT

Baseline is good and snapshotted. Reset between takes with:

  VIRSH_URI=${VIRSH_URI:-<none>} SNAP=${SNAP} ./scripts/reset.sh

im-train-db gets no snapshot on purpose: nothing in the demo changes it, which
is most of the benefit of demoting that tier.
NEXT
