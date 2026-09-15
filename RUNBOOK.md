# Recording runbook

Every command, in order, with measured timings and the traps that cost takes.

**Status of each act:**

| Act | State |
|---|---|
| 0 — Baseline | **Verified end to end.** Ready to film. |
| 1 — The OS CVE | **Verified end to end**, including rollback and forward again. |
| 2 — The app CVE | **Verified.** Scans run, numbers below are measured, not estimated. |
| 3 — Lightwell remediation | **Verified end to end.** TLS index serving, one-line pin, tests green, grype still red. |
| 4 — Patch to production | **Verified end to end.** 20s upgrade, CVE observable gone, `/var` survived, db tier untouched. |
| 5 — The clock | Slides only. |

Every timing below was measured on this hardware. Nothing in Acts 0-4 is an
estimate.

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
- [ ] **The Lightwell index is up.** It runs under systemd via Quadlet and is
      enabled at boot, so this should just be true - verified by rebooting the
      builder and watching it answer 5 seconds later with no intervention.
      Confirm anyway, because a stopped index makes the remediation act fail
      inside the image build with what looks like a missing package:
      ```
      ssh im-builder 'systemctl is-active lightwell-pod.service && curl -sk https://lightwell.homelab.com/simple/jinja2/ | grep -o "jinja2-[^\"<#]*" | head -1'
      ```
      If it is down: `sudo ./scripts/serve-lightwell-mirror.sh`

### The three snapshots you have

| Snapshot | State |
|---|---|
| `act0-baseline` | RHEL 10.1, jinja2 2.11.3 vulnerable, db seeded, timer off |
| `act1-done` | RHEL 10.2, jinja2 2.11.3 still vulnerable, rollback to 10.1 available |
| `act3-done` | RHEL 10.2, jinja2 2.11.3+rhlw00001, probe rejects, remediated |

Reverting any of them takes **under a second** and the guest resumes *already
running*, because these are internal snapshots carrying RAM state.

**To reset to the start of the whole demo, use `reset-demo.sh`, not `reset.sh`:**

```bash
ssh im-builder 'cd ~/rhel-lightwell && VIRSH_URI=qemu+ssh://tichomir@192.168.122.1/system ./scripts/reset-demo.sh'
```

`reset.sh` reverts the **guest only**. A demo run leaves two other pieces of
state behind, and both silently break the next take:

| Left behind | What it does to the next take |
|---|---|
| **`:prod` has moved** — every act ends by moving it | Act 0 opens with an update already pending, and Act 1's `bootc upgrade` jumps straight to the remediated image — four acts collapsed into one |
| **The builder's `pip.conf` points at the Lightwell index** | A "vulnerable" rebuild installs the **remediated** wheel, because PEP 440 lets a plain `==2.11.3` match `2.11.3+rhlw00001` and the lab index serves nothing else. The image gets labelled `vulnerable` and you find out on camera |

`reset-demo.sh` does all three — moves `:prod` back to the vulnerable baseline,
returns the builder to the vulnerable configuration, reverts the guest — then
asserts the result really is a baseline and **refuses to declare readiness if
it is not**. The check that matters most is `bootc upgrade --check` reporting
*No changes*: nothing else catches a stale `:prod`.

**Run it without `sudo`.** The registry write needs root (podman's auth is in
`/root/.docker/config.json`) but `virsh` and the guest SSH need *your* key,
which root does not have. The script escalates for the one step that needs it
and refuses to start as root, because a half-done reset is worse than none.

`build-and-push.sh` now also refuses outright if the pin says vulnerable while
`pip.conf` points at a Lightwell index, so that mislabelled image cannot be
built by accident.

**If the registry is in read-only maintenance** (quay.io does this), the script
changes nothing and tells you so. Acts 0 and 2 need no registry writes and can
still be filmed; Acts 1, 3 and 4 all push and promote, so they cannot.

```bash
# reset to the start of Act 2, skipping Act 1's 4-minute pull
ssh im-builder 'cd ~/rhel-lightwell && VIRSH_URI=qemu+ssh://tichomir@192.168.122.1/system SNAP=act1-done ./scripts/reset.sh'
```

```bash
# jump to the remediated end state, for re-shooting Act 4's verification
ssh im-builder 'cd ~/rhel-lightwell && VIRSH_URI=qemu+ssh://tichomir@192.168.122.1/system SNAP=act3-done ./scripts/reset.sh'
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
  jinja2 3.1.6    SAFE        refuses to render - ValueError: Invalid character in attribute name
  jinja2 2.11.3   VULNERABLE  emits it anyway - ' data-track id="1"'
```

The first is `python3-jinja2`, an RPM that cloud-init pulled in. Red Hat's, and
patched. The second is in `/opt/app/venv`, from `requirements.txt`. Yours, and
untouched by anything the OS provides.

**Explain what SAFE means, or it reads backwards.** The patched library
*refuses to render* — it raises rather than emitting markup a browser will
misparse. A space is illegal in an HTML attribute name, so a browser ends the
name at the space and treats the rest as a **separate attribute** — which is
how an attacker gets to inject one of their own. Failing closed is the fix.

> "Same machine. Same library. Same CVE. Red Hat patched the copy they ship.
> Nobody patched the copy I ship — and that boundary is exactly what a RHEL
> subscription has always been."

This reframes the whole demo as *not* a criticism of RHEL, which lands far
better with an infrastructure audience.

### Then answer the question it provokes

Someone will say: *there is a patched 3.1.6 right there, why not just use it?*

1. **It IS 3.1.6.** Using it *is* the 3.1.x migration — `contextfunction`
   removed, `Markup` moved to markupsafe, autoescape defaults changed. Same
   code change, same regression cycle, same change board. This is the whole
   reason the demo exists, and it is the strongest of the three.
2. **It covers a minority of the dependency set.** Of the five direct pins in
   `requirements.txt`, RHEL 10 ships RPMs for **two**:

   | Pin | RHEL 10 |
   |---|---|
   | `jinja2` | `python3-jinja2` 3.1.6 — exists |
   | `markupsafe` | `python3-markupsafe` 2.1.3 — exists |
   | `fastapi` | no RPM |
   | `uvicorn` | no RPM |
   | `psycopg` | no RPM for psycopg 3 — see below |

   Two of five covered, three not. The transitive tree — starlette, pydantic,
   anyio, h11 — has none either.
3. **Mixing the two sources is worse than either.** Half the dependency tree
   pinned in `requirements.txt` and half tracking the RHEL minor release is the
   worst of both. The venv exists to prevent exactly that.

**Be precise about psycopg.** RHEL 10 *does* ship `python3-psycopg2` (2.9.9).
That is a different package with a different API, not the psycopg 3 this app
uses. Say "no psycopg 3", not "no Postgres driver" — someone will check.

**Do NOT say "the OS markupsafe is 2.1.3 but this app needs 2.0.1."** It is
true and it is circular: the 2.0.1 pin exists *only because* jinja2 is pinned
at 2.11. Take the OS jinja2 3.1.6 and OS markupsafe 2.1.3 works fine with it.
It is not an argument against using the OS copy, and anyone who knows the
ecosystem will spot that.

**Also do not check RPM availability on the image-mode guest.** It has no dnf
repositories at all, so `rpm -q` only tells you what is installed, never what
exists. Check inside a repo-enabled RHEL 10 container.

### What "exploitable" actually means

```bash
ssh im-train 'sudo bash -s' < scripts/show-injection.sh
```

The coverage-gap scene proves the unsafe attribute *name* survives. On its own
that is abstract. This closes the gap by putting an HTML parser on the same
string:

```
  author wrote    1 attribute
  parser reports  2 attributes
     'data-track'    = None
     'data-injected' = '1'   <-- the author never wrote this
```

> "One attribute went in. The parser sees two, and the second one was chosen by
> whoever supplied that key. That is the vulnerability, in full."

**It stops there on purpose, and say so.** The injected attribute is
`data-injected` and it does nothing. Substituting an event-handler attribute is
what makes it stored XSS — a one-word change for an attacker, and one you do
not need to perform to have proved the point. There is no working exploit in
the repository or in the recording, because a recording gets forwarded and
re-shown without you in the room.

Then the line that buys you credibility:

> "And the 7.8 in that grype report is a sandbox escape. That is the serious
> one, and it is deliberately not what I just showed you."

The script refuses to mislead if run on a remediated build — it reports the
`ValueError` and tells you to revert.

**If someone asks "so pop an alert then" — you cannot, and say why.** Audited:
`app/static/app.js` escapes every value it writes to the DOM (`escapeHtml` in
`dl()` and in the booking handler; the receipt uses `textContent`). There is no
unescaped HTML sink, so the filter's output never reaches an HTML context raw.

The precise claim is narrower than "your application is exploitable", and
stronger for being accurate:

> "The library hands its caller markup that a parser misreads. `xmlattr` exists
> to build attributes for insertion into HTML, so a consumer using it as
> intended is exposed. This app happens to escape on output, so it is not —
> defence in depth saved us, and that is not a patching strategy."

Do not claim a live XSS in this app. A security person will ask to see it, and
the honest answer is better than a walked-back one.

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

## Act 3 — Lightwell remediation · ~10 min · **verified**

Start from `act1-done`. The index runs on the builder and stays up across takes.

### Stand up the index (once, before you record)

```bash
ssh im-builder 'cd ~/rhel-lightwell && sudo ./scripts/make-lightwell-wheel.sh'
```

```bash
ssh im-builder 'cd ~/rhel-lightwell && sudo ./scripts/serve-lightwell-mirror.sh'
```

Serves `https://lightwell.homelab.com/simple/` over TLS. **Keep the diff open in
an editor** — 22 insertions in one file, and fifteen seconds of it on screen is
worth a paragraph of narration:

```bash
ssh im-builder 'cd /tmp/lightwell-backport && git --no-pager diff 2.11.3 -- src/jinja2/filters.py'
```

> "That is the entire patch. Four lines of security logic, in the version I
> already run. Not a new major release with a migration attached to it."

### Show the index has it

```bash
ssh im-builder 'curl -s https://lightwell.homelab.com/simple/jinja2/ | grep -o "jinja2-[^\"<#]*" | head -1'
```

```bash
ssh im-builder 'sudo podman run --rm --network host registry.access.redhat.com/ubi9/python-312 pip index versions jinja2 --index-url https://lightwell.homelab.com/simple/ --trusted-host lightwell.homelab.com'
```

Output is one line: `Available versions: 2.11.3+rhlw00001`. Clean screen.

### The one-line change

```bash
ssh im-builder 'cd ~/rhel-lightwell && sed -i "s/^jinja2==2.11.3$/jinja2==2.11.3+rhlw00001/" requirements.txt && git --no-pager diff requirements.txt'
```

```diff
-jinja2==2.11.3
+jinja2==2.11.3+rhlw00001
```

**The repository stays pinned at `2.11.3` on purpose**, so a fresh clone
reproduces the Act 0 baseline. This edit is made live and not committed.

**Worth knowing, and stronger than the deck claims:** you do not strictly need
this edit at all. Verified on this pip — `jinja2==2.11.3` resolves to
`2.11.3+rhlw00001` when that is the only candidate on the index, because PEP 440
lets a plain `==` specifier match a local version. So the honest framing is:

> "I am changing the line to be explicit and auditable. But I could have changed
> nothing at all — point pip at the Remediated index and the pin I already have
> picks up the backport. That is what drop-in actually means."

### Rebuild

```bash
ssh im-builder 'cd ~/rhel-lightwell && sudo NS=quay.io/rhte2023 VER=1.2 BASE_TAG=10.2 BUILD_DB=no ./scripts/build-and-push.sh'
```

**Measured: 1m22s.** The `baseos` layers are cached, so this is much faster than
Act 1. Watch for `== dependency state: remediated ==` in the first line of
output, and for pip downloading
`jinja2-2.11.3%2Brhlw00001-py2.py3-none-any.whl` from `lightwell.homelab.com`.

### The proof that matters — the unchanged test suite

```bash
ssh im-builder 'sudo podman run --rm --network host --user root --security-opt label=disable -v /home/rhel-admin/rhel-lightwell:/src:ro -e IM_TRAIN_DB_URL="postgresql://imtrain:imtrain@im-train-db.homelab.com:5432/imtrain" -e PIP_INDEX_URL="https://lightwell.homelab.com/simple/" -e PIP_EXTRA_INDEX_URL="https://pypi.org/simple/" -e PIP_TRUSTED_HOST="lightwell.homelab.com" registry.access.redhat.com/ubi9/python-312 bash -c "cp -r /src /tmp/w && cd /tmp/w && python3 -m venv .v && . .v/bin/activate && pip install -q -r requirements-dev.txt && pip show jinja2 | grep -i ^version && python3 -m pytest -q --expect=remediated"'
```

**Measured: `Version: 2.11.3+rhlw00001`, then `20 passed`.**

Against the live database, the vulnerable state gives **20 passed** and the
remediated state gives **20 passed**. Same file, not edited between runs.

> "Same API. Same tests. Same file — I did not touch it. That is the whole
> claim, and it is the only evidence for it that is worth anything, because the
> scanner is about to tell you I failed."

### Then the scanner, still red

```bash
ssh im-builder 'cd ~/rhel-lightwell && ./scripts/scan.sh quay.io/rhte2023/im-train:1.2 jinja2'
```

```
  CVE              SEVERITY CVSS  INSTALLED          FIXED IN
  CVE-2024-22195   Medium   5.4   2.11.3+rhlw00001   3.1.3
  CVE-2024-34064   Medium   5.4   2.11.3+rhlw00001   3.1.4
  CVE-2024-56326   Medium   7.8   2.11.3+rhlw00001   3.1.5
  CVE-2025-27516   Medium   5.4   2.11.3+rhlw00001   3.1.6
```

Note the `INSTALLED` column. The scanner **sees** the remediated artifact and
still calls it vulnerable, because there is no public security feed telling it
what `+rhlw00001` contains.

Do not hide this. Run it deliberately, and land the four points in order:

1. The scanner is still red. Here is exactly why.
2. The test suite is green, and the CVE observable is gone — show the probe.
3. A VEX statement is where this is heading: a machine-readable assertion that
   this artifact is remediated.
4. **Your scanner report and your actual risk are not the same document.**

If you made the Act 2 point about 161 Go-module false positives in Red Hat's
own binaries, you can now close the loop: same tool, same blind spot, and you
called it ten minutes ago.

### The integrity rule

Never show a `packages.redhat.com` URL while resolving from
`lightwell.homelab.com`. The lab index is deliberately indistinguishable from
the real one on camera, which is exactly why this matters. Either wait for
LW00007 and film this scene against Track A, or caption it unambiguously.

---

## Act 4 — Patch to production · ~8 min · **verified**

```bash
ssh im-builder 'cd ~/rhel-lightwell && sudo NS=quay.io/rhte2023 VER=1.2 ./scripts/promote.sh'
```

```bash
ssh im-train 'sudo bootc upgrade'
```

**Measured: 20 seconds.** This is the best surprise in the whole demo. Act 1
pulled 950 MB and took four minutes; this changed **8 layers and 31.5 MB**,
because every base OS layer was already on disk.

> "The OS patch was a 950-megabyte pull. The application patch is thirty-one
> megabytes and twenty seconds — same command, same tag, same rollback."

```bash
ssh im-train 'sudo systemctl reboot'
```

### The money screen

```bash
ssh im-train 'curl -sS http://localhost:8080/api/status | jq .'
```

Measured, all on one page:

| Field | Value |
|---|---|
| `os_version` | `10.2` — **unchanged**. The OS did not move. |
| `image_version` | `1.2` |
| `jinja2` | **`2.11.3+rhlw00001`** |
| `lightwell.remediated` | **`true`** |
| `probe.unsafe_key_emitted` | **`false`** |
| `probe.rejected_with` | `ValueError: Invalid character in attribute name` |
| `database.available` | `true` |
| `rollback_available` | `true` |

### Persistence and blast radius

```bash
ssh im-train 'curl -sS http://localhost:8080/api/bookings | jq -c "[.[] | {reference, passenger_name}]"'
```

Bookings are still there. `/var` survived while `/usr` was replaced.

```bash
ssh im-train-db 'sudo bootc status'
```

`rollback: null` — this tier has **never been upgraded**. Different tier,
independent lifecycle, zero blast radius, and it is on screen rather than
claimed.

> "From the platform team's point of view, an application CVE fix and an OS CVE
> fix are now the same operation. And the tier I did not touch, I did not touch."

---

## Act 5 — The clock · slides

Elapsed time on screen against 45–90 days for high-risk and 40+ days average.

Measured, real numbers from this environment:

| Step | Time |
|---|---|
| Rebuild on a **new base OS** and push | 1m–3m20s |
| Rebuild with a **remediated dependency** and push | 37s–1m22s |
| Promote (`skopeo copy`) | under 1s |
| `bootc upgrade` — OS change, 950 MB | **2m51s–4m** |
| `bootc upgrade` — **app dependency only, ~27–31 MB** | **15–20s** |
| Reboot to healthy app | ~40s |
| `bootc rollback` | 2.9s |
| Backported wheel: patch, build, publish | ~30s |
| Full environment reset (`reset-demo.sh`) | 22s |
| Quick revert between takes (`reset.sh`) | 6s |

Ranges are from two full dry runs on consecutive days. The spread is real and
worth knowing before you commit to a number on camera:

- **Builds** are fast when `baseos` is already cached and slow when the
  `rhel-bootc` base has to be pulled fresh (~1.6 GB). The first build of a
  session is the slow one.
- **`bootc upgrade` for the OS act** ranged from **1m to 4m** across three
  runs, and the reason is worth exploiting: once the guest has pulled those
  layers, a later upgrade to the same digest reuses its local bootc storage and
  drops to about a minute.

  **So do a full dry run before you record.** It is recommended anyway, and it
  has the side effect of warming the guest's layer store — which turns the
  biggest dead-air moment in the demo from four minutes into one. Do not prune
  between the dry run and the take.
- **`bootc upgrade` for the app act** is consistently 15–20s because only the
  application layers move. That number is safe to quote.

So a genuine patch-to-production is **under ten minutes of wall clock**, and
the rollback is three seconds. Those are real and you can show them uncut.

Do not splice and then claim a wall-clock number across the cut. Someone will
ask, and you want to be able to say the take is uncut.

---

## A determinism trap worth knowing

`tests/test_functional.py` books a ticket against the **live** demo database,
and Act 3's proof is running that suite unchanged. Until this was fixed, every
run left an `Integration Test` booking behind — so the booking list on the Act 4
screen grew by one per take and no two takes matched.

A `cleanup_bookings` fixture now removes what the tests create. If you add a
test that writes to the database, use it, or the same drift comes back.

Verify at any time — this should print exactly one row:

```bash
ssh im-train 'curl -sS http://localhost:8080/api/bookings | jq -c "[.[].reference]"'
```

---

## What to say is out of scope

Deck slide 14 carries this. State it before someone asks, so the boundaries
come from you rather than from a sceptic in the third row.

**Described, not built**

| | |
|---|---|
| The automation layer | Event-Driven Ansible, AAP, Trusted Profile Analyzer, the Lightwell Deep Agent, ServiceNow change records. Act 5 describes it; the RHDP demo builds it. |
| CI/CD | Every build was run by hand from a shell. No pipeline, no Tekton, no GitLab. |
| Satellite | Its own slide — see the Satellite section of the deck. |

**Simplified to one of everything**

| | |
|---|---|
| One host, not a fleet | No remote execution across many hosts, no inventory or reporting at scale. |
| A minor OS bump, 10.1 to 10.2 | Not a RHEL 9 to 10 major upgrade, which is a different exercise. |
| A direct dependency | The vulnerable library is named in `requirements.txt`. The harder and more realistic case is a transitive one — which is where SBOMs and TPA start to matter. |

The transitive-dependency point is the one a good architect will raise on your
behalf. Better to have said it first.

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
| Registry auth gone after a reboot | `podman login` writes to `/run`, which is tmpfs | Re-login with `REGISTRY_AUTH_FILE=/root/.docker/config.json`. Already done on this builder and verified across a reboot |
| Lightwell index not answering | systemd units not started | `systemctl status lightwell-pod lightwell-pypi lightwell-tls`. Units live in `/etc/containers/systemd/`; after editing them, `systemctl daemon-reload` regenerates |
| `virsh` fails over `qemu+ssh` | Remote user not in `libvirt` group | `sudo usermod -aG libvirt <user>` — SSH and sudo working is not enough, polkit needs the group |
| Guest has no network after reprovision | libvirt network is routed with no DHCP range | Reservations exist for these two MACs; a *new* guest needs `virsh net-update default add ip-dhcp-host` |
| App fails on first boot after a rebuild | SELinux labels on `/opt/app` | `semanage fcontext` + `restorecon` are in the Containerfile, but verify in rehearsal, not on camera |
| grype still reports the CVE after remediation | No Lightwell data in public vulnerability feeds | **Expected. Do not fix it.** It is Act 3's best moment |

---

## One thing found late, worth knowing

The app Containerfile used to `COPY` the index credentials in and `rm` them in a
later layer. That leaks: a `COPY` writes the file into its own layer, and the
later removal only hides it from the final filesystem. Recoverable in two
commands:

```bash
skopeo copy containers-storage:quay.io/rhte2023/im-train:1.2 dir:/tmp/x
grep -rl 'password' /tmp/x
```

On a bootc base it is worse than it looks, because `/root` is a symlink to
`/var/roothome` — so the credential lands at `var/roothome/.netrc`, which is
neither the path the `rm` appears to target nor the path you would think to
check.

These images go to **public** quay repositories. With the lab mirror that
published `demo/demo`. With Track A it would have published a real Red Hat
Registry Service Account token.

Now fixed: credentials go in as `--mount=type=secret`, which is never committed
to a layer, and the fix is verified by the same grep finding nothing.

**If you switch to Track A, rotate the service account token first.** The
earlier `im-train:1.2` manifest was pushed to a public repo before this was
fixed, and even though the tag has been overwritten, treat anything that was in
that file as disclosed.
