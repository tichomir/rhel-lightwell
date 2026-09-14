#!/usr/bin/bash
# Does this host meet the requirements to build and run the demo?
#
# Run ON the builder and/or hypervisor, before building anything:
#
#   ssh im-builder 'sudo bash -s' < scripts/preflight.sh          # ROLE=builder
#   ROLE=hypervisor ssh kvm-host 'sudo bash -s' < scripts/preflight.sh
#
# Read-only: installs nothing, changes nothing. Every check prints PASS, WARN or
# FAIL with the reason, and the exit code is the number of FAILs. A WARN is
# something to decide about; a FAIL will stop the build.
#
# ROLE matters because the two jobs have different requirements, and holding a
# builder to the hypervisor's thresholds produces FAILs that are not real:
#
#   builder     builds and pushes images, serves the Track B index, runs grype.
#               Wants disk and egress. Needs no KVM and no bridge.
#   hypervisor  runs the guests and holds the snapshots. Wants RAM and KVM.
#   both        one host doing everything - the strictest thresholds.
#
# The checks that actually decide whether the demo is buildable are rhel-bootc
# tag availability (the OS act needs two versions), free disk on the builder,
# and KVM on the hypervisor.
set -uo pipefail

ROLE="${ROLE:-builder}"
case "${ROLE}" in
    builder)    MIN_RAM_GB="${MIN_RAM_GB:-6}";  MIN_DISK_GB="${MIN_DISK_GB:-80}"  ;;
    hypervisor) MIN_RAM_GB="${MIN_RAM_GB:-16}"; MIN_DISK_GB="${MIN_DISK_GB:-100}" ;;
    both)       MIN_RAM_GB="${MIN_RAM_GB:-16}"; MIN_DISK_GB="${MIN_DISK_GB:-250}" ;;
    *) echo "ROLE must be builder, hypervisor or both (got '${ROLE}')" >&2; exit 2 ;;
esac
# Only the hypervisor needs to boot guests, so only there are these fatal.
if [[ "${ROLE}" == "builder" ]]; then VIRT_SEV=warn; else VIRT_SEV=fail; fi

FAILS=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS+1)); }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

head_ "identity"
echo "  role:   ${ROLE}  (thresholds: >=${MIN_RAM_GB} GB RAM, >=${MIN_DISK_GB} GB disk)"
echo "  host:   $(hostname -f 2>/dev/null || hostname)"
echo "  kernel: $(uname -r)  $(uname -m)"
echo "  date:   $(date -Is)"

head_ "operating system"
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "  ${NAME} ${VERSION_ID}"
    case "${VERSION_ID}" in
        10*) pass "RHEL 10 - matches the images being built" ;;
        9*)  warn "RHEL 9. Fine for building: podman builds RHEL 10 images regardless,
        and the app's dependencies are installed INSIDE the container, so the
        host's Python version never reaches the image" ;;
        *)   warn "Unexpected version ${VERSION_ID}" ;;
    esac
else
    fail "cannot read /etc/os-release"
fi
printf '  python3: '; python3 -V 2>&1 || fail "no python3"

head_ "virtualisation (${VIRT_SEV} severity for role=${ROLE})"
if grep -qE '^flags.*(vmx|svm)' /proc/cpuinfo; then
    pass "CPU virtualisation extensions present"
else
    $VIRT_SEV "no vmx/svm in /proc/cpuinfo - cannot run KVM guests. If this host is
        itself a VM, nested virtualisation must be enabled on its hypervisor"
fi
[[ -e /dev/kvm ]] && pass "/dev/kvm present" || $VIRT_SEV "/dev/kvm missing - kvm modules not loaded, or virt not enabled"
if systemctl is-active --quiet libvirtd 2>/dev/null || systemctl is-active --quiet virtqemud 2>/dev/null; then
    pass "libvirt running"
else
    warn "libvirt not active (systemctl enable --now libvirtd)"
fi
if [[ "${ROLE}" != "builder" ]]; then
    echo "  existing guests:"
    virsh list --all 2>/dev/null | sed 's/^/    /' || echo "    (virsh unavailable)"
fi

head_ "memory and disk"
MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
echo "  RAM: ${MEM_GB} GB"
if   (( MEM_GB >= MIN_RAM_GB )); then pass "meets the >=${MIN_RAM_GB} GB requirement for role=${ROLE}"
elif (( MEM_GB >= MIN_RAM_GB - 4 )); then warn "${MEM_GB} GB against a ${MIN_RAM_GB} GB target - tight but workable"
else fail "${MEM_GB} GB is not enough - role=${ROLE} needs ${MIN_RAM_GB} GB"
fi
# Container storage and qcow2 output are the two things that fill up.
for d in /var/lib/containers /var/lib/libvirt/images /var/tmp; do
    [[ -d "$d" ]] || { warn "$d does not exist yet"; continue; }
    AVAIL=$(df -BG --output=avail "$d" 2>/dev/null | tail -1 | tr -dc '0-9')
    echo "  ${d}: ${AVAIL:-?} GB free  (fs: $(df --output=target "$d" 2>/dev/null | tail -1))"
done
ROOT_AVAIL=$(df -BG --output=avail /var 2>/dev/null | tail -1 | tr -dc '0-9')
if   (( ${ROOT_AVAIL:-0} >= MIN_DISK_GB )); then pass "${ROOT_AVAIL} GB free on /var (need >=${MIN_DISK_GB})"
elif (( ${ROOT_AVAIL:-0} >= MIN_DISK_GB * 2 / 3 )); then warn "${ROOT_AVAIL} GB free on /var against a ${MIN_DISK_GB} GB target - workable, but prune between acts"
else fail "${ROOT_AVAIL:-0} GB free on /var - role=${ROLE} needs ~${MIN_DISK_GB} GB"
fi

head_ "tooling"
# virt-install and virsh only matter where the guests are actually created.
TOOLS="podman buildah skopeo jq git"
[[ "${ROLE}" != "builder" ]] && TOOLS="${TOOLS} virt-install virsh"
for t in ${TOOLS}; do
    printf '  %-14s ' "$t"
    if command -v "$t" >/dev/null 2>&1; then
        echo "$("$t" --version 2>&1 | head -1)"
    else
        echo "MISSING"; fail "$t not installed"
    fi
done
# On the builder virsh is optional, but it is what lets reset.sh drive snapshots
# remotely over qemu+ssh instead of you shelling into the hypervisor every take.
if [[ "${ROLE}" == "builder" ]]; then
    printf '  %-14s ' virsh
    command -v virsh >/dev/null 2>&1 && echo "$(virsh --version 2>&1)" \
        || { echo "MISSING"; warn "virsh absent - install libvirt-client so reset.sh can drive the hypervisor remotely"; }
fi
# grype installs to /usr/local/bin, which sudo's secure_path excludes - so look
# for it explicitly rather than reporting a missing tool that is actually there.
printf '  %-14s ' grype
GRYPE=$(command -v grype 2>/dev/null || { [[ -x /usr/local/bin/grype ]] && echo /usr/local/bin/grype; })
if [[ -n "${GRYPE}" ]]; then
    echo "$("${GRYPE}" version 2>&1 | awk '/^Version:/{print $2}') at ${GRYPE}"
else
    echo "MISSING"; warn "grype absent - only needed for the scanning act"
fi

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
    elif grep -qi 'Simple Content Access' <<<"${SUB}"; then
        # SCA grants content access regardless of attached subscriptions, so
        # "not current" is not a finding here - dnf and the registry both work.
        pass "registered with Simple Content Access - content available"
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
for h in im-train.homelab.com im-train-db.homelab.com lightwell.homelab.com; do
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
