#!/usr/bin/bash
# Does this host meet the requirements to build and run the demo?
#
# Run ON the builder/hypervisor, before building anything:
#
#   ssh builder 'bash -s' < scripts/preflight.sh
#
# Read-only: installs nothing, changes nothing. Every check prints PASS, WARN or
# FAIL with the reason, and the exit code is the number of FAILs. A WARN is
# something to decide about; a FAIL will stop the build.
#
# The three checks that actually decide whether the demo is buildable are
# rhel-bootc tag availability (Act 1 needs 10.2), KVM, and free disk.
set -uo pipefail

FAILS=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS+1)); }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

head_ "identity"
echo "  host:   $(hostname -f 2>/dev/null || hostname)"
echo "  kernel: $(uname -r)  $(uname -m)"
echo "  date:   $(date -Is)"

head_ "operating system"
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "  ${NAME} ${VERSION_ID}"
    case "${VERSION_ID}" in
        10*) pass "RHEL 10 - matches the images being built" ;;
        9*)  warn "RHEL 9. Building RHEL 10 bootc images from here usually works, but rehearse it" ;;
        *)   warn "Unexpected version ${VERSION_ID}" ;;
    esac
else
    fail "cannot read /etc/os-release"
fi
printf '  python3: '; python3 -V 2>&1 || fail "no python3"

head_ "virtualisation"
if grep -qE '^flags.*(vmx|svm)' /proc/cpuinfo; then
    pass "CPU virtualisation extensions present"
else
    fail "no vmx/svm in /proc/cpuinfo - this host cannot run KVM guests. If it is
        itself a VM, nested virtualisation must be enabled on its hypervisor"
fi
[[ -e /dev/kvm ]] && pass "/dev/kvm present" || fail "/dev/kvm missing - kvm modules not loaded, or virt not enabled"
if systemctl is-active --quiet libvirtd 2>/dev/null || systemctl is-active --quiet virtqemud 2>/dev/null; then
    pass "libvirt running"
else
    warn "libvirt not active (systemctl enable --now libvirtd)"
fi
echo "  existing guests:"
virsh list --all 2>/dev/null | sed 's/^/    /' || echo "    (virsh unavailable)"

head_ "memory and disk"
MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
echo "  RAM: ${MEM_GB} GB"
if   (( MEM_GB >= 16 )); then pass "enough RAM for the builder plus both guests"
elif (( MEM_GB >= 12 )); then warn "${MEM_GB} GB is tight: 2 guests x 4 GB plus build headroom"
else fail "${MEM_GB} GB is not enough - need 16 GB for builder + 2 guests"
fi
# Container storage and qcow2 output are the two things that fill up.
for d in /var/lib/containers /var/lib/libvirt/images /var/tmp; do
    [[ -d "$d" ]] || { warn "$d does not exist yet"; continue; }
    AVAIL=$(df -BG --output=avail "$d" 2>/dev/null | tail -1 | tr -dc '0-9')
    echo "  ${d}: ${AVAIL:-?} GB free  (fs: $(df --output=target "$d" 2>/dev/null | tail -1))"
done
ROOT_AVAIL=$(df -BG --output=avail /var 2>/dev/null | tail -1 | tr -dc '0-9')
if   (( ${ROOT_AVAIL:-0} >= 250 )); then pass "${ROOT_AVAIL} GB free on /var"
elif (( ${ROOT_AVAIL:-0} >= 150 )); then warn "${ROOT_AVAIL} GB free on /var - workable, but prune images between acts"
else fail "${ROOT_AVAIL:-0} GB free on /var - need ~250 GB for 2 base versions, 3 images, qcow2s and snapshots"
fi

head_ "tooling"
for t in podman buildah skopeo jq git virt-install virsh; do
    printf '  %-14s ' "$t"
    if command -v "$t" >/dev/null 2>&1; then
        echo "$("$t" --version 2>&1 | head -1)"
    else
        echo "MISSING"; fail "$t not installed"
    fi
done
printf '  %-14s ' grype
command -v grype >/dev/null 2>&1 && grype version 2>&1 | head -1 \
    || { echo "MISSING"; warn "grype absent - only needed for the scanning act"; }

head_ "selinux"
command -v getenforce >/dev/null 2>&1 && {
    S=$(getenforce)
    echo "  ${S}"
    [[ "$S" == "Enforcing" ]] && pass "Enforcing - the honest configuration to demo on" \
        || warn "${S} - the guests will still enforce; fine for building"
}

head_ "subscription and registry.redhat.io"
if command -v subscription-manager >/dev/null 2>&1; then
    # sudo -n so this never blocks on a password prompt; if sudo itself needs
    # one, that is the finding, and step 2 of the access setup covers it.
    SUB=$( { sudo -n subscription-manager status || subscription-manager status; } 2>/dev/null )
    if grep -qi 'Overall Status: *Current' <<<"${SUB}"; then
        pass "subscription current"
    elif [[ -z "${SUB}" ]]; then
        warn "could not read subscription status (passwordless sudo not set up yet?)"
    else
        warn "subscription not reported current - needed to pull rhel-bootc"
        sed 's/^/    /' <<<"${SUB}" | head -5
    fi
else
    warn "no subscription-manager - not a registered RHEL host?"
fi

# THE CHECK THAT DECIDES ACT 1. The OS patch is a 10.1 -> 10.2 delta; without
# both tags there is no delta to demonstrate.
head_ "rhel-bootc tags (Act 1 depends on this)"
if command -v skopeo >/dev/null 2>&1; then
    TAGS=$(skopeo list-tags docker://registry.redhat.io/rhel10/rhel-bootc 2>&1)
    if echo "$TAGS" | grep -q '"Tags"'; then
        echo "$TAGS" | jq -r '.Tags[]' 2>/dev/null | grep -E '^10\.' | sort -V | sed 's/^/    /'
        for want in 10.1 10.2; do
            if echo "$TAGS" | jq -r '.Tags[]' 2>/dev/null | grep -qx "$want"; then
                pass "rhel-bootc:${want} available"
            else
                fail "rhel-bootc:${want} NOT available - Act 1 needs both 10.1 and 10.2.
        If 10.2 is unreleased, the OS delta has to come from somewhere else"
            fi
        done
    else
        fail "cannot list tags - not logged in to registry.redhat.io?
        Fix: podman login registry.redhat.io   (registry service account)"
        echo "$TAGS" | sed 's/^/    /' | head -3
    fi
fi

head_ "registry logins"
for reg in registry.redhat.io quay.io; do
    printf '  %-22s ' "$reg"
    if podman login --get-login "$reg" >/dev/null 2>&1; then
        echo "logged in as $(podman login --get-login "$reg" 2>/dev/null)"
    else
        echo "NOT logged in"
        [[ "$reg" == quay.io ]] && fail "podman login quay.io - needed to push the three images" \
                                || fail "podman login registry.redhat.io - needed to pull rhel-bootc"
    fi
done

head_ "egress"
for url in registry.redhat.io quay.io pypi.org github.com; do
    printf '  %-22s ' "$url"
    curl -sS -o /dev/null -m 10 -w '%{http_code}\n' "https://${url}" 2>&1 || { echo "unreachable"; fail "no egress to ${url}"; }
done

head_ "networking"
echo "  bridges:"
ip -br link show type bridge 2>/dev/null | sed 's/^/    /' || echo "    (none)"
ip -br link show type bridge 2>/dev/null | grep -q . \
    && pass "at least one bridge exists" \
    || warn "no bridge found - virt-install --network bridge=br0 will fail. Either create br0 or use the default NAT network"
echo "  resolving the demo hostnames:"
for h in im-train.rh-lab.labs im-train-db.rh-lab.labs lightwell.rh-lab.labs; do
    printf '    %-26s ' "$h"
    getent hosts "$h" 2>/dev/null | awk '{print $1}' | head -1 || echo "does not resolve (needs DNS or /etc/hosts)"
done

printf '\n\033[1m== summary ==\033[0m\n'
if (( FAILS == 0 )); then
    printf '  \033[32mNo blocking failures.\033[0m Review any WARNs above, then start the build.\n'
else
    printf '  \033[31m%d blocking failure(s).\033[0m Each one stops the build; fix before proceeding.\n' "$FAILS"
fi
exit "$FAILS"
