# Recording runbook

Every command, in order, with measured timings and the traps that cost takes.

**Status of each act:**

| Act | State |
|---|---|
| 0 — Baseline | **Verified end to end.** Ready to film. |
| 1 — The OS CVE | **Verified end to end**, including rollback and forward again. |
| 2 — The app CVE | **Verified.** Scans run, numbers below are measured, not estimated. |
| 3 — Lightwell remediation | Backport verified; index not yet stood up. **Do not film yet.** |
| 4 — Patch to production | Depends on Act 3. **Not yet verified.** |
| 5 — The clock | Slides only. |

Anything marked unverified below has not been run on this hardware. Treat the
timings in those sections as guesses.

---

## Before you record

```bash
ssh im-builder 'cd ~/rhel-lightwell && git pull && VIRSH_URI=qemu+ssh://tichomir@192.168.122.1/system ./scripts/post-provision.sh'
```

That authorises keys, disables the update timer on both guests, asserts the
baseline is actually filmable, and only then snapshots. It **refuses to
snapshot a broken baseline**, which is the whole reason it exists.

Then check these by hand:

- [ ] Terminal font 18, black background — matches your existing screenshots
- [ ] Browser in a clean profile, no extensions, no unrelated tabs
- [ ] No stray `latest` tags anywhere on screen
- [ ] `date -Is` at the start and end of each act, on screen
- [ ] Pin the base by digest if a rebuild mid-series would be fatal:
      `10.1 = sha256:a16e6053…84a8a`, `10.2 = sha256:eb55df15…9bb1e`

### The two snapshots you have

| Snapshot | State |
|---|---|
| `act0-baseline` | RHEL 10.1, jinja2 2.11.3 vulnerable, db seeded, timer off |
| `act1-done` | RHEL 10.2, jinja2 2.11.3 still vulnerable, rollback to 10.1 available |

Reverting either takes **under a second** and the guest resumes *already
running*, because these are internal snapshots carrying RAM state.

```bash
# reset to the start of the whole demo
ssh im-builder 'cd ~/rhel-lightwell && VIRSH_URI=qemu+ssh://tichomir@192.168.122.1/system SNAP=act0-baseline ./scripts/reset.sh'
```

```bash
# reset to the start of Act 2, skipping Act 1's 4-minute pull
ssh im-builder 'cd ~/rhel-lightwell && VIRSH_URI=qemu+ssh://tichomir@192.168.122.1/system SNAP=act1-done ./scripts/reset.sh'
```

Full reset measured at **6 seconds**: revert, re-disable the timer, reseed the
database, print and verify the baseline.

`im-train-db` is never reverted. Nothing in the demo changes it.

---

## Act 0 — Baseline · ~4 min

Shown, not performed. Open the UI, then the Status page.

```bash
ssh im-train 'curl -sS http://localhost:8080/api/status | jq .'
```

```bash
ssh im-train 'sudo bootc status'
```

**What is on screen:** `os_version 10.1`, `image quay.io/rhte2023/im-train:prod`,
a real digest read from `bootc status --json`, `jinja2 2.11.3`,
`rollback_available false`, `database.available true`,
`probe.unsafe_key_emitted true`.

Nothing on that page is hardcoded. Say so — it is the reason the page is worth
filming, and the reason the changes in Acts 1 and 4 mean anything.

> "Normal Tuesday. One application, everything green. Now two things go wrong
> in the same week."

**Trap:** `rollback_available` is `false` on a fresh baseline and `true` after
Act 1. If it is already `true` in Act 0 you are filming a dirty host — reset.

---

## Act 1 — The OS CVE · ~8 min · **verified**

### Rebuild on 10.2

```bash
ssh im-builder 'cd ~/rhel-lightwell && date -Is && sudo NS=quay.io/rhte2023 VER=1.1 BASE_TAG=10.2 BUILD_DB=no ./scripts/build-and-push.sh'
```

**Measured: 3m20s** including the `rhel-bootc:10.2` pull and push to quay.

`BASE_TAG` is the only thing that changes. Show that — one build argument moves
the entire Standard Operating Environment, and the app image rebuilds on top
unchanged.

### Promote — the change-management gate

```bash
ssh im-builder 'cd ~/rhel-lightwell && sudo NS=quay.io/rhte2023 VER=1.1 ./scripts/promote.sh'
```

One `skopeo copy`. Under a second.

> "In your estate this is a content view promotion in Satellite. Same gate,
> same approval, different tool."

### Upgrade the host

```bash
ssh im-train 'sudo bootc upgrade --check'
```

```bash
ssh im-train 'sudo bootc upgrade'
```

**Measured: 4 minutes.** This is the single biggest dead-air risk in the
recording — 950 MB pulled from quay over the internet. Three ways to handle it,
pick one *before* you roll:

1. **Narrate over it.** This is exactly the four minutes in which to explain the
   promotion gate, Satellite's role, and why `/usr` is replaced while `/var`
   survives. Best option: nothing is faked and the clock stays honest.
2. **Cut it and caption the cut.** Fine, as long as you do not then claim an
   uncut wall-clock number across it.
3. **Stand up a pull-through cache on the builder** so the pull is LAN speed.
   Most work, best result, changes what the image reference says on screen.

Then show the staged deployment before rebooting — this is a good beat:

```bash
ssh im-train 'sudo bootc status'
```

```bash
ssh im-train 'curl -sS http://localhost:8080/api/status | jq "{os_version, image_version, staged_pending_reboot}"'
```

`staged 1.1` / `booted 1.0`, and **the application itself reports
`staged_pending_reboot: true`**. The host knows an upgrade is waiting and says
so on the page you have been showing all along.

```bash
ssh im-train 'sudo systemctl reboot'
```

**Measured: ~40s to a healthy app.**

### Verify

```bash
ssh im-train 'curl -sS http://localhost:8080/api/status | jq .; uname -r'
```

`os_version` **10.2**, `image_version` **1.1**, new digest matching the promoted
tag, `rollback_available` now **true**, kernel `6.12.0-211.53.1.el10_2`.

**The line that sets up Act 2:** `jinja2` is *still* `2.11.3` and
`unsafe_key_emitted` is *still* `true`.

> "Perfect OS patch. Atomic, versioned, reversible. And it changed nothing at
> all about whether this application can be exploited."

### The safety net

```bash
ssh im-train 'sudo bootc rollback && sudo systemctl reboot'
```

**Measured: 2.9s for the rollback command**, no download — the previous
deployment is still on disk. After reboot you are back on 10.1, kernel
`el10_1`, and the database never noticed.

`bootc rollback` reports `Next boot: rollback deployment` rather than showing a
staged entry. Do not be thrown by that on camera; `bootc status` is still the
right thing to show.

Forward again with a second `bootc rollback` and reboot.

> "Everything you just watched me undo took three seconds and no network."

**Trap that will ruin a take:** if the update timer is enabled, the host will
re-upgrade itself after a rollback, on its own, between takes. `reset.sh`
re-disables it every time for exactly this reason.

---

## Act 2 — The app CVE · ~12 min · **verified**

Start from `act1-done` so you are on 10.2 — the host is fully patched, which is
the whole premise.

### The coverage gap, on one screen

```bash
ssh im-train 'sudo bash -s' < scripts/show-coverage-gap.sh
```

This is the strongest thirty seconds available to you, and it was a lucky
accident of packaging. The host carries jinja2 **twice**:

```
  jinja2 3.1.6    REJECTED   ValueError: Invalid character in attribute name
  jinja2 2.11.3   EMITTED    ' data-track id="1"'
```

The first is `python3-jinja2`, an RPM that cloud-init pulled in. Red Hat's, and
patched. The second is in `/opt/app/venv`, from `requirements.txt`. Yours, and
untouched by anything the OS provides.

> "Same machine. Same library. Same CVE. Red Hat patched the copy they ship.
> Nobody patched the copy I ship — and that boundary is exactly what a RHEL
> subscription has always been."

This reframes the whole demo as *not* a criticism of RHEL, which lands far
better with an infrastructure audience.

### The scanner

```bash
ssh im-builder 'cd ~/rhel-lightwell && ./scripts/scan.sh quay.io/rhte2023/im-train:prod app'
```

Measured output — the app's own dependencies, nothing else:

```
  High     starlette 0.38.6       CVE-2024-47874     fix 0.40.0
  High     starlette 0.38.6       CVE-2026-48818     fix 1.1.0
  High     starlette 0.38.6       CVE-2026-54283     fix 1.3.1
  Medium   jinja2 2.11.3          CVE-2024-22195     fix 3.1.3
  Medium   jinja2 2.11.3          CVE-2024-34064     fix 3.1.4
  Medium   jinja2 2.11.3          CVE-2024-56326     fix 3.1.5
  Medium   jinja2 2.11.3          CVE-2025-27516     fix 3.1.6
  ...
```

**Use starlette deliberately.** It is the perfect foil: High severity, and the
fix is a minor version bump you would just do. jinja2 is Medium, and the fix is
only in 3.1.x — a migration. Two findings, same application, same screen, and
only one of them has an easy answer.

```bash
ssh im-builder 'cd ~/rhel-lightwell && ./scripts/scan.sh quay.io/rhte2023/im-train:prod jinja2'
```

```
  CVE              SEVERITY CVSS  INSTALLED  FIXED IN
  CVE-2024-22195   Medium   5.4   2.11.3     3.1.3
  CVE-2024-34064   Medium   5.4   2.11.3     3.1.4
  CVE-2024-56326   Medium   7.8   2.11.3     3.1.5
  CVE-2025-27516   Medium   5.4   2.11.3     3.1.6
```

**Correction to the deck:** these are **Medium**, not "high severity". The deck
says high; the terminal will say Medium and the audience will believe the
terminal. The worst is CVE-2024-56326 at CVSS **7.8** — a sandbox escape, and
the genuinely serious one. Say that precisely:

> "Four CVEs. The two I am going to demonstrate are the benign ones, because I
> am not putting a working sandbox escape in a recording that gets forwarded.
> The 7.8 in that list is the one that should worry you."

That distinction is more honest *and* sounds more competent than implying the
XSS is the whole story.

### Optional: the triage view

```bash
ssh im-builder 'cd ~/rhel-lightwell && ./scripts/scan.sh quay.io/rhte2023/im-train:prod triage'
```

Measured on the full image: **21,063 matches** — 20,041 `not-fixed`, 821
`wont-fix`, **193 actionable**. Of those 193, 161 are Go modules where grype
reads the upstream version out of a Red Hat-built binary and cannot see the
backport.

**Do not claim "the scanner report on the OS is clean".** It is 21,000 lines
long and anyone who has run a scanner knows it. The honest version is better:

> "Twenty-one thousand findings. Two hundred I can act on. And a hundred and
> sixty of those are the scanner reading a version string out of a Red Hat
> binary and not knowing the fix is already in there. Remember that — it is
> about to happen to me again in ten minutes."

That plants Act 3's false positive as a known property of scanners rather than
an excuse you invent when it happens.

### The three options

Walk them with the evidence already on screen:

1. **Upgrade to 3.1.x** — Python 2 support dropped, `contextfunction` removed,
   `Markup` relocated, autoescape defaults changed. A migration and a full
   regression cycle. In a bank: a change board and a re-certification.
2. **Patch it yourself** — you now maintain a fork of Jinja2 forever, and you
   own every future CVE in it.
3. **Accept the risk** — against a time-to-exploit curve measured in hours.

---

## Act 3 — Lightwell remediation · **NOT YET BUILT**

The backport itself is verified: `patches/0001-xmlattr-reject-invalid-attribute-names.patch`
applies to 2.11.3, builds a wheel, and the unmodified test suite passes against
it. What does not exist yet is the served index.

Remaining work:

```bash
ssh im-builder 'cd ~/rhel-lightwell && sudo ./scripts/make-lightwell-wheel.sh'
ssh im-builder 'cd ~/rhel-lightwell && sudo ./scripts/serve-lightwell-mirror.sh'
```

Then `images/app/pip.conf` switches to the Lightwell block, `requirements.txt`
pins `jinja2==2.11.3+rhlw00001`, and the image rebuilds.

**Two things to settle before filming this act:**

1. **`pip.conf` and the mirror disagree on protocol.** The example points at
   `https://lightwell.homelab.com/simple/`; the mirror serves plain HTTP on
   8080. Needs a TLS proxy, or the URL changed to `http://…:8080`.
2. **Podman build containers do not inherit `/etc/hosts`.** The `pip install`
   runs *inside* the build, so resolving `lightwell.homelab.com` needs
   `--add-host lightwell.homelab.com:192.168.122.195` on the `podman build`.
   `build-and-push.sh` does not do this yet.

**The integrity rule:** never show a `packages.redhat.com` URL while resolving
from `lightwell.homelab.com`. Either wait for LW00007 and film against the real
index, or caption this scene unambiguously as a lab mirror.

---

## Act 4 — Patch to production · **NOT YET VERIFIED**

Will reuse Act 1's mechanism exactly — that is the point of it. Expected:

```bash
ssh im-builder 'cd ~/rhel-lightwell && sudo NS=quay.io/rhte2023 VER=1.2 BASE_TAG=10.2 BUILD_DB=no ./scripts/build-and-push.sh'
ssh im-builder 'cd ~/rhel-lightwell && sudo NS=quay.io/rhte2023 VER=1.2 ./scripts/promote.sh'
ssh im-train 'sudo bootc upgrade && sudo systemctl reboot'
```

Then: `os_version` **unchanged** at 10.2, `jinja2` now `2.11.3+rhlw00001`,
`remediated: true`, `probe.unsafe_key_emitted` **false**, bookings still in the
database because `/var` survived while `/usr` was replaced.

```bash
ssh im-train-db 'sudo bootc status'
```

Shows the database tier never moved. Different tier, independent lifecycle,
zero blast radius.

And re-run the tests unchanged — that is the proof that matters:

```bash
ssh im-builder 'cd ~/rhel-lightwell && sudo podman run --rm --network host --user root --security-opt label=disable -v /home/rhel-admin/rhel-lightwell:/src:ro -e IM_TRAIN_DB_URL="postgresql://imtrain:imtrain@im-train-db.homelab.com:5432/imtrain" registry.access.redhat.com/ubi9/python-312 bash -c "cp -r /src /tmp/w && cd /tmp/w && python3 -m venv .v && . .v/bin/activate && pip install -q -r requirements-dev.txt && python3 -m pytest -q --expect=remediated"'
```

Baseline for comparison: the same command with `--expect=vulnerable` currently
gives **20 passed, 0 skipped** against the live database.

**Then re-run grype and show it still red.** Do not hide this.

---

## Act 5 — The clock · slides

Elapsed time on screen against 45–90 days for high-risk and 40+ days average.

Measured, real numbers from this environment:

| Step | Time |
|---|---|
| Rebuild image on a new base and push | 3m20s |
| Promote (`skopeo copy`) | under 1s |
| `bootc upgrade` (950 MB pull) | 4m |
| Reboot to healthy app | ~40s |
| `bootc rollback` | 2.9s |
| Full environment reset between takes | 6s |

So a genuine patch-to-production is **under ten minutes of wall clock**, and
the rollback is three seconds. Those are real and you can show them uncut.

Do not splice and then claim a wall-clock number across the cut. Someone will
ask, and you want to be able to say the take is uncut.

---

## Corrections to the existing documents

Things the proposal and build guide get wrong, found by running them:

| Document says | Reality |
|---|---|
| "four CVEs, high severity" | **Medium**, CVSS 5.4 — except CVE-2024-56326 at 7.8 |
| "your scanner report on the OS is clean" | 21,063 findings, 1 Critical, 1,072 High |
| `2.11.3+rhlw.00001` | Impossible. PEP 440 normalises it to `+rhlw.1`. Use `+rhlw00001` |
| The upstream fix "cherry-picks cleanly" | It does not. Resolved patch is in `patches/` |
| `bootc update` (several slides) | Not a command. `bootc upgrade` |
| Snapshot with `--disk-only` | Works, but internal snapshots revert in 0.8s and skip the boot |
| `rh-lab.labs` hostnames | This lab serves `homelab.com` |

---

## When something breaks mid-session

| Symptom | Cause | Fix |
|---|---|---|
| `bootc upgrade` says no update | `:prod` not moved, or digest unchanged | `skopeo inspect docker://quay.io/rhte2023/im-train:prod`, compare with `bootc status --json` |
| Rollback silently undone | Update timer re-enabled | `reset.sh` handles it; otherwise `systemctl disable --now bootc-fetch-apply-updates.timer` |
| Status page shows db unavailable | `im-train-db` down, or DNS | `ssh im-train-db 'sudo -u postgres pg_isready'` — the app degrades to 503 on booking endpoints and keeps everything else working, so this costs one panel, not the take |
| Registry auth gone after a reboot | `podman login` writes to `/run`, which is tmpfs | Re-login with `REGISTRY_AUTH_FILE=/root/.docker/config.json` |
| `virsh` fails over `qemu+ssh` | Remote user not in `libvirt` group | `sudo usermod -aG libvirt <user>` — SSH and sudo working is not enough, polkit needs the group |
| Guest has no network after reprovision | libvirt network is routed with no DHCP range | Reservations exist for these two MACs; a *new* guest needs `virsh net-update default add ip-dhcp-host` |
| App fails on first boot after a rebuild | SELinux labels on `/opt/app` | `semanage fcontext` + `restorecon` are in the Containerfile, but verify in rehearsal, not on camera |
| grype still reports the CVE after remediation | No Lightwell data in public vulnerability feeds | **Expected. Do not fix it.** It is Act 3's best moment |
