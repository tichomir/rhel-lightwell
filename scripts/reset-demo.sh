#!/usr/bin/bash
# Reset EVERYTHING to the start of Act 0, ready to record.
#
#   VIRSH_URI=qemu+ssh://user@hypervisor/system ./scripts/reset-demo.sh
#
# Run this from the builder before a recording session, WITHOUT sudo.
#
# The privileges are deliberately split, because the two halves need different
# identities and running the whole thing as root breaks the second one:
#
#   registry write   needs root - podman's auth lives in /root/.docker/config.json
#   virsh + ssh      needs YOUR user - root has no SSH key to the hypervisor
#                    or the guests, so as root these fail with "Permission
#                    denied (publickey)" and it looks like a libvirt problem
#
# So the script runs unprivileged and escalates only for the registry step.
#
# WHY THIS EXISTS, AND WHY reset.sh IS NOT ENOUGH
#
# reset.sh reverts the GUEST. It does not touch the two other pieces of state
# that a demo run leaves behind, and both of them silently break the next take:
#
#   1. THE :prod TAG. Every act ends by moving it. After a full run it points at
#      the remediated image. Revert the guest without moving it back and Act 0
#      opens with an update already pending, and Act 1's `bootc upgrade` jumps
#      straight to the remediated build - collapsing four acts into one.
#
#   2. THE BUILDER'S pip.conf. After the remediation act it points at the
#      Lightwell index. Rebuilding a "vulnerable" image in that state installs
#      the REMEDIATED wheel, because PEP 440 lets a plain ==2.11.3 specifier
#      match 2.11.3+rhlw00001 - and the lab index has nothing else. You get a
#      remediated image labelled `vulnerable`, and you find out on camera.
#
# So a reset is three things, not one, and the verification at the end is the
# part that actually protects the take.
set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
    cat >&2 <<'ASROOT'
Do not run this with sudo.

  virsh over qemu+ssh and the ssh calls to the guests use YOUR SSH key. root
  does not have one, so as root they fail with "Permission denied (publickey)"
  after the registry step has already succeeded - a confusing half-done reset.

  Run it as your normal user:
    VIRSH_URI=qemu+ssh://user@hypervisor/system ./scripts/reset-demo.sh

  It escalates with sudo by itself for the one step that needs root.
ASROOT
    exit 2
fi

cd "$(dirname "$0")/.."

NS="${NS:-quay.io/rhte2023}"
BASELINE_VER="${BASELINE_VER:-1.0}"     # the vulnerable 10.1 build
VM="${VM:-im-train}"
SNAP="${SNAP:-act0-baseline}"
APP_HOST="${APP_HOST:-im-train.homelab.com}"
SSH_USER="${SSH_USER:-rhel-admin}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

echo "== 1. moving :prod back to the vulnerable baseline (${BASELINE_VER}) =="
# The guest tracks :prod. If this does not match what the snapshot booted,
# Act 0 is not a baseline.
#
# Stop BEFORE touching the guest if this fails. Reverting the guest while :prod
# still points at a later image leaves a baseline that looks right on the
# Status page and is wrong underneath - which is worse than not resetting.
if ! COPY_ERR=$(sudo skopeo copy "docker://${NS}/im-train:${BASELINE_VER}" \
                                 "docker://${NS}/im-train:prod" 2>&1 >/dev/null); then
    echo
    if grep -qi "read-only\|read only" <<<"${COPY_ERR}"; then
        cat >&2 <<REGISTRY_RO
The registry is in READ-ONLY maintenance. Pulls work, writes are suspended.

  ${NS} returned:
    $(grep -o 'denied:.*' <<<"${COPY_ERR}" | head -1)

  Nothing has been changed. The guest has NOT been reverted, on purpose.

  What you can still record: Act 0 and Act 2 need no registry writes. Revert
  the guest by hand and film them:

    SNAP=act0-baseline ./scripts/reset.sh

  Do not run \`bootc upgrade --check\` on camera while in that state - :prod is
  still ahead of the guest, so it will report an update waiting.

  What you cannot record: Acts 1, 3 and 4 all push and promote. They need the
  registry writable. Re-run this script when it is.
REGISTRY_RO
    else
        echo "Could not move :prod. Nothing has been changed." >&2
        sed 's/^/  /' <<<"${COPY_ERR}" >&2
    fi
    exit 1
fi
PROD_DIGEST=$(sudo skopeo inspect "docker://${NS}/im-train:prod" | jq -r .Digest)
PROD_STATE=$(sudo skopeo inspect "docker://${NS}/im-train:prod" | jq -r '.Labels."net.rhlab.imtrain.dependency-state"')
echo "   :prod -> ${PROD_DIGEST}  (${PROD_STATE})"
[[ "${PROD_STATE}" == "vulnerable" ]] || {
    echo "   REFUSING: :prod is labelled '${PROD_STATE}', not 'vulnerable'." >&2
    echo "   BASELINE_VER=${BASELINE_VER} is the wrong tag for an Act 0 baseline." >&2
    exit 1
}

echo
echo "== 2. putting the builder back in the vulnerable configuration =="
./scripts/switch-track.sh vulnerable | sed 's/^/   /'

echo
echo "== 3. reverting ${VM} to ${SNAP} =="
./scripts/reset.sh

echo
echo "== 4. verifying this is actually a baseline =="
# The checks that matter, in the order they would ruin a take.
STATUS=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${APP_HOST}" 'curl -fsS http://localhost:8080/api/status')
UPGRADE=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${APP_HOST}" 'sudo bootc upgrade --check 2>&1' || true)

fault=0
check() { # label expected actual
    if [[ "$2" == "$3" ]]; then printf '   ok    %-34s %s\n' "$1" "$3"
    else printf '   FAIL  %-34s got %s, want %s\n' "$1" "$3" "$2"; fault=1; fi
}
check "os_version"              "10.1"  "$(jq -r .os_version            <<<"${STATUS}")"
check "dependency is vulnerable" "false" "$(jq -r .lightwell.remediated  <<<"${STATUS}")"
check "CVE observable reachable" "true"  "$(jq -r .probe.unsafe_key_emitted <<<"${STATUS}")"
check "database reachable"      "true"  "$(jq -r .database.available    <<<"${STATUS}")"
check "no rollback yet"         "false" "$(jq -r .rollback_available    <<<"${STATUS}")"
check "nothing staged"          "false" "$(jq -r .staged_pending_reboot <<<"${STATUS}")"

# The one that catches a stale :prod. If bootc sees an update waiting, Act 0
# is not a baseline and Act 1 has already half-happened.
if grep -qi "No changes" <<<"${UPGRADE}"; then
    printf '   ok    %-34s no update pending\n' "bootc agrees with :prod"
else
    printf '   FAIL  %-34s bootc sees an update waiting\n' "bootc agrees with :prod"
    sed 's/^/         /' <<<"${UPGRADE}" | head -4
    fault=1
fi

echo
if (( fault )); then
    echo "NOT READY TO RECORD. Fix the FAILs above." >&2
    exit 1
fi
cat <<'READY'
Ready to record Act 0.

  Status page:  ssh im-train 'curl -sS http://localhost:8080/api/status | jq .'
  bootc:        ssh im-train 'sudo bootc status'

Between takes within an act, the quick revert is enough:
  SNAP=act0-baseline ./scripts/reset.sh

Come back here whenever :prod has moved - which is at the end of every act.
READY
