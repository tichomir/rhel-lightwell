# rhel-lightwell

Demo environment for **Patch to Production** — patching both the operating
system and an application dependency on a RHEL image-mode host, using the same
command, the same gate and the same rollback.

The application half of the patch comes from **Red Hat Lightwell Network**: a
backported security fix delivered into the exact version already pinned in
production, with no upgrade and no code change.

---

## Status

**Built, running, and Acts 0-4 all verified end to end on real hardware.**
Both image-mode guests are provisioned, the OS patch and the application patch
both travel the same path, and the retake loop is six seconds.

| Check | Result |
|---|---|
| `jinja2==2.11.3` installs and works on RHEL 10's Python 3.12.14 | Yes — `asyncsupport` is never reached |
| `xmlattr` emits the unsafe attribute name | Yes — the vulnerable act has something to show |
| Upstream fix cherry-picks cleanly | **No** — resolved patch in `patches/`, see below |
| Backported wheel builds | Yes — `jinja2-2.11.3+rhlw00001-py2.py3-none-any.whl` |
| Full suite, unmodified, against **live PostgreSQL** | **20 passed, 0 skipped** |
| `rhel-bootc` 10.1 **and** 10.2 both published | Yes — the OS delta is real |
| Three images built, pushed, publicly pullable | Yes — verified anonymously |
| Both guests boot image-mode, `bootc status` clean | Yes — RHEL 10.1 |
| App → database across tiers | Yes — PostgreSQL 16.14 |
| Snapshot revert actually discards changes | Yes — tested with a marker file |
| `reset.sh` end to end | **~6 seconds** |
| OS act: `10.1 → 10.2` rebuild, promote, `bootc upgrade` | Yes — `os_version` moves, app unaffected |
| `bootc rollback` and forward again | Yes — **2.9s**, no download |
| grype scans, all four views | Yes — numbers in the runbook are measured |
| Track B index serving over TLS | Yes — `pip index versions` sees only `2.11.3+rhlw00001` |
| Remediated build, unmodified suite | **20 passed** — identical to the vulnerable state |
| App patch deployed via `bootc upgrade` | Yes — **20s / 31.5 MB**, CVE observable gone |
| `/var` survives, db tier never moves | Yes — bookings intact, `rollback: null` on the db |

Still to do: Act 5 is slides. Track A needs `LW00007` before the remediation
scene can be filmed against the real index rather than the lab mirror.

See [RUNBOOK.md](RUNBOOK.md) for the per-act recording script.

### The cherry-pick does not apply

Neither upstream fix commit lands on 2.11.3: 3.1.x carries type annotations,
f-strings and `pass_eval_context` where 2.11.3 has `evalcontextfilter` and
`iteritems()`. The conflicts are era-related rather than semantic — the security
logic is four lines and identical — so the resolved backport is committed as a
patch in `patches/`, with its provenance in the header, and
`make-lightwell-wheel.sh` applies it by default.

The backport must be the **cumulative 3.1.4** behaviour, not just 3.1.3.
`tests/test_cve.py` parametrises over all four illegal characters, and a
space-only backport fails three of them in the remediated state.

---

## This lab

Concrete values for the environment this was built in. Everything is
parameterised, so none of it is load-bearing in the code.

| | |
|---|---|
| Hypervisor | `192.168.1.57`, RHEL 9.8, 20 cores / 124 GB, guest storage on `/home/vms` |
| Builder | `build.homelab.com` / `192.168.122.195`, RHEL 9.8 — also a guest |
| `im-train` | `192.168.122.51`, 2 vCPU / 4 GB / 40 GB |
| `im-train-db` | `192.168.122.52`, 2 vCPU / 4 GB / 30 GB |
| Registry | `quay.io/rhte2023` — `baseos`, `im-train`, `im-train-db`, all public |
| Login | `rhel-admin`, SSH key plus a console password |

Three things about this topology are worth knowing because they cost time to
discover:

**The builder is itself a guest**, so `reset.sh` and `post-provision.sh` drive
libvirt remotely via `VIRSH_URI=qemu+ssh://…`. That needs the remote user in the
`libvirt` group — without it polkit refuses with *"no polkit agent available"*
even though SSH and `sudo` both work perfectly.

**The libvirt network is `<forward mode='route'/>` with no DHCP range**, only
static host entries. So guests get no lease and no default route unless you give
them one. The two demo guests use `ip-dhcp-host` reservations added with
`virsh net-update --live --config`, which needs no network restart and so never
disturbs anything else already running on that network.

**`podman login` as root writes to `/run`, which is tmpfs.** Registry
credentials vanish on reboot. Log in with
`REGISTRY_AUTH_FILE=/root/.docker/config.json` so podman finds them afterwards
from its persistent fallback path.

---

## What this is

Two RHEL 10 image-mode VMs on KVM:

| Host | Contents | Role in the demo |
|---|---|---|
| `im-train` | FastAPI app, static UI, Status page | Receives both patches |
| `im-train-db` | PostgreSQL 16 | Built once, never touched — proves blast radius |

Three container images, built on a package-mode builder host and pushed to
public quay.io repositories:

```
baseos:10.x        FROM rhel-bootc  + hardening, SSH, cloud-init
  ├── im-train     + Python venv, pinned dependencies, the app, a systemd unit
  └── im-train-db  + postgresql-server, first-boot initdb
```

The hosts track `im-train:prod`. Promotion is a tag move; `bootc upgrade` on the
host picks up the new digest.

### The one structural decision worth understanding

`pip install` runs **at image build time, inside the bootc image** — see
`images/app/Containerfile`. That is what makes remediating a library an OS image
rebuild, so the application fix travels the same path as an OS fix.

Installing dependencies at runtime would be easier and would destroy the entire
argument. Don't.

---

## Step 1: lock the dependency

Before writing or building anything else:

```bash
make pincheck
```

This asks two questions that can sink the chosen dependency.

**(a) Does the pin install *and work* on RHEL 10's Python 3.12?** Installing is
not enough. Jinja2 2.11's `asyncsupport` module uses `asyncio.coroutine`, which
was **removed in Python 3.11**. If that is reached at import time the pin is
dead, and pip will not tell you — only an actual import and render will, which is
what the script does.

**(b) Does the upstream fix cherry-pick cleanly onto the pinned version?** Not
automated, because the commit differs per CVE and you have to read the advisory.
This decides whether the Track B backport takes ten minutes or an hour. If you
end up resolving conflicts across three files, change candidate — a
half-backport is worse than no demo.

If Jinja2 2.11.3 fails, the swap is small: `app/receipts.py`, `tests/test_cve.py`
and one line of `requirements.txt`. Candidate comparison is in the build guide,
section 2.2.

---

## Local development

```bash
cp .env.example .env          # set IM_TRAIN_DB_URL, or leave it unset
make dev
set -a && . ./.env && set +a
make run                      # http://localhost:8080
make test
```

The app starts without a database. Booking endpoints return 503 and the Status
page shows the database as unreachable, but everything else — including the CVE
observable — works. That matters for a recorded demo: a database hiccup should
cost you one panel, not the whole take.

---

## Building the images

```bash
cp images/app/pip.conf.example images/app/pip.conf     # choose Track A or B
cp images/app/netrc.example    images/app/netrc        # credentials
$EDITOR images/app/pip.conf images/app/netrc

NS=quay.io/<your-namespace> VER=1.0 ./scripts/build-and-push.sh
NS=quay.io/<your-namespace> VER=1.0 ./scripts/promote.sh
```

`pip.conf` and `netrc` are gitignored. `build-and-push.sh` refuses to run without
them, reports whether the build will be `vulnerable` or `remediated`, and records
that in an image label so `skopeo inspect` can answer the question without
booting the host.

Then build the qcow2 and provision, per the build guide sections 6 and 7.

---

## The two Lightwell tracks

**Track B — lab index.** The primary path while entitlement is pending. Builds a
genuine backport (upstream fix cherry-picked onto the pinned version) labelled
with the Lightwell local-version suffix, served from a PEP 503 index:

```bash
FIX_COMMIT=<sha from the GHSA advisory> ./scripts/make-lightwell-wheel.sh
./scripts/serve-lightwell-mirror.sh
```

The fix is real; only the provenance is local.

**Track A — the real index.** Requires SKU `LW00007` on the account and a
Registry Service Account. Verify coverage before relying on it:

```bash
pip config set global.index-url https://packages.redhat.com/lightwell/python/remediated/
pip index versions jinja2
```

### Version suffix: Java and Python differ

Java uses `.rhlw-0000X` appended to the upstream version — a sequential
cumulative-patch counter, documented example `5.3.17.rhlw-00001`.

**Python cannot use that form**; it is not valid PEP 440. Python uses a local
version segment instead — and the obvious transliteration does not survive:

```
2.11.3+rhlw.00001   ->  installs and displays as  2.11.3+rhlw.1
2.11.3+rhlw00001    ->  installs and displays as  2.11.3+rhlw00001
```

PEP 440 normalises local-version segments and strips leading zeros from any
segment that is purely numeric. With the separating dot, `00001` is numeric and
the zeros are gone; without it, `rhlw00001` is alphanumeric and survives intact.
There is no way to keep `+rhlw.00001` on screen.

This is not cosmetic. The version appears on the Status page, in `pip show` and
in the wheel filename, and the deck says `.rhlw-00001`. Pick one string and make
the slide, the lab index and the real index agree, or the terminal and the slide
will contradict each other on camera. `SUFFIX` in `make-lightwell-wheel.sh`
defaults to `+rhlw00001` for that reason.

**Confirm the exact string the real Remediated index publishes before recording**
and set `SUFFIX` to match. Until then this is a guess about someone else's
naming, not a verified fact.

### Switching to the real index, when LW00007 lands

```bash
./scripts/check-track-a.sh      # read-only, safe to run while waiting
./scripts/switch-track.sh a     # writes pip.conf and a netrc template
```

**Only two files differ between the tracks** — `images/app/pip.conf` and
`images/app/netrc`, both gitignored. Nothing else changes: not the
Containerfile, not `build-and-push.sh`, not the tests, not the images, not the
VMs. That was the design intent of having two tracks, and it means the
remediation scene can be re-shot later without rebuilding anything else.

What has to be confirmed before relying on Track A, in order of how likely it
is to bite:

1. **Does the Remediated tier exist at the documented URL?** Probed 2026-09-14,
   unauthenticated: `lightwell/python/validated/` and `lightwell/java/validated/`
   return **401** — they exist and want credentials.
   `lightwell/python/remediated/` returns **404**. Validated answering from the
   same host rules out DNS, egress and TLS, so this is about the URL or about
   availability. Ask before assuming.
2. **Does the catalogue cover `jinja2` at `2.11.3`?** Coverage is per package
   *and* per version and is not published. This is the likeliest blocker.
3. **What exactly is the version string?** It may not be `+rhlw00001`. It
   appears on the Status page, in `pip show` and in the deck, so if it differs
   the lab mirror must be rebuilt to match:
   `SUFFIX=<theirs> ./scripts/make-lightwell-wheel.sh`. `app/sysinfo.py` only
   greps for `rhlw`, so the Status page and the test suite keep working either way.
4. **Rotate the Registry Service Account token** if you ever built with an
   earlier version of this repo — see the note at the end of `RUNBOOK.md`.

**Do not substitute the Validated tier.** It is upstream-parity — signed, SBOM,
SLSA L3, but the *same version*. This demo turns entirely on obtaining a fix
*without* a version change, which only Remediated does.

### What Track B can and cannot do

Worth being precise, because one line of the Act 3 script depends on it.

Real on Track B: the CVEs, the vulnerable pin, and **the fix itself** — 
`patches/0001` derives from the actual upstream commits, and the wheel genuinely
closes the vulnerability. The probe flips and the unmodified test suite passes.

Simulated on Track B: **only the provenance.** The wheel was built locally, so
there is no Red Hat signature, no SBOM and no SLSA L3 attestation.

That means the proposal's Act 3 instruction to *"show the signature and
provenance"* **cannot be performed on Track B**. Describe it verbally and
caption the scene, or hold that beat for Track A. It is also the clearest
statement of what Track A actually buys: not the fix, which is already real, but
Red Hat's attestation of it.

### The integrity rule

The lab index is indistinguishable from the real one on screen. So: never show a
`packages.redhat.com` URL while resolving from `lightwell.homelab.com`. Record
the Lightwell scene against the real index, or caption it unambiguously.

---

## Scanning, and the false positive

```bash
./scripts/scan.sh quay.io/<ns>/im-train:prod
```

**grype will still report the CVE after remediation.** It compares
`2.11.3+rhlw.00001` against "fixed in 3.1.x" and concludes you are still
vulnerable. It has no way to know the fix exists, because the Lightwell security
feed is not yet in the public vulnerability databases — that work is in progress
with osv.dev and is the prerequisite for any scanner to understand `.rhlw`
artifacts.

This is certain, not possible. **Do not try to fix it.** Handled properly it is
the most credible ninety seconds in the recording:

1. Show the scanner still red. Explain why, plainly.
2. Show the test suite green — API compatibility and the CVE observable.
3. Show the VEX statement as where this is heading.
4. Land the point: your scanner report and your actual risk are not the same
   document.

---

## Proving the fix

The scanner cannot prove it, so two things do.

**`tests/test_functional.py` is the most important file here.** The Lightwell
claim is that a backport lands in the version you already run with the API
unchanged. The only honest proof is an unchanged suite passing before and after.
Do not edit it between the vulnerable and remediated states — if you need to, the
remediation broke something, and that is a finding worth more than the demo.

**`tests/test_cve.py`** is one assertion that flips:

```bash
make test-vulnerable     # before
make test-remediated     # after
```

Green in both states, because a red suite on camera reads as a broken demo even
when red is the correct result.

### Why there is no exploit in this repository

The observable is that Jinja2's `xmlattr` filter accepts an attribute *name*
containing a space — illegal in HTML, and enough to terminate the name early and
inject a further attribute. The probe key is `data-track id`. No script, no event
handler, no payload.

Three reasons, and none of them is squeamishness:

1. A working exploit inside a recording that gets forwarded is a liability.
2. A benign assertion re-runs identically on every take. A staged shell prompt
   does not.
3. The claim being made is "untrusted input reaches a context it must not", and
   that is exactly what this demonstrates.

Use the grype report to state the real risk — the sandbox escapes in the same
report are the serious ones — and demonstrate only what is safe to put on screen.
Saying that distinction out loud is more honest and sounds more competent than
implying the XSS is the whole story.

---

## Recording

Two things bite hard.

**Disable the update timer on both VMs, first thing.**

```bash
systemctl disable --now bootc-fetch-apply-updates.timer
```

Image-mode hosts run an update timer every 1–3 hours, and after a `bootc
rollback` the system will automatically update again unless it is off — silently
undoing the rollback you just demonstrated, between takes, with no warning.

**Snapshot `im-train` at every act boundary.**

```bash
virsh snapshot-create-as im-train act0-baseline --disk-only --atomic
SNAP=act0-baseline ./scripts/reset.sh
```

A retake then costs 30 seconds instead of a rebuild. `im-train-db` needs no
snapshots — nothing ever changes it.

---

## Layout

```
app/
  main.py          FastAPI routes. Does NOT use fastapi.templating (see below)
  sysinfo.py       Status page facts: parses bootc status --json, os-release,
                   importlib.metadata. Nothing hardcoded
  receipts.py      Jinja2 rendering — the vulnerable surface
  db.py            psycopg access with a degraded mode
  static/          UI. No framework, no build step, no npm
sql/
  schema.sql       Applied once on first boot
  seed.sql         Deterministic and re-runnable; reset.sh calls it between takes
tests/
  test_functional.py   API-compatibility evidence. Do not edit between acts
  test_cve.py          The observable that flips
  conftest.py          --expect=vulnerable|remediated|auto
images/
  baseos/          Standard Operating Environment
  app/             Application layer + systemd unit
  db/              Database tier + first-boot initdb
patches/
  0001-xmlattr-*.patch     The verified backport. Header records the upstream
                           commits and why a cherry-pick will not do
scripts/
  pincheck.sh              Step 1. Run before anything else
  make-lightwell-wheel.sh  Track B backport
  serve-lightwell-mirror.sh
  build-and-push.sh
  promote.sh               Move :prod — the change-management gate
  scan.sh                  grype, plus an explanation of the false positive
  reset.sh                 Revert to a recording baseline
```

### Two traps encoded in the code

**Never use `fastapi.templating.Jinja2Templates`.** Starlette's templating module
imports `jinja2.pass_context`, which does not exist before Jinja2 3.0. Importing
it breaks the pinned dependency this whole demo is built around. Static assets
are served with `StaticFiles`; Jinja2 appears only in `receipts.py`, where it is
the subject rather than the plumbing.

**`markupsafe` must stay at 2.0.1.** 2.1 removed `soft_unicode`, which Jinja2
2.11 imports at module load. Without the pin you get an ImportError on the first
request.

---

## Out of scope

**Satellite.** Discussed in the demo, not built. In a real estate it replaces
quay.io as the registry, syncs `rhel-bootc` in through the trusted channel, and
replaces the `:prod` tag move with a content view promotion. It **cannot** sync
or serve Lightwell PyPI or Maven content today — upstream Pulp has
`pulp_python` and `pulp_maven`, neither is in the product. Worth turning into a
named customer feature request.

**AAP, Event-Driven Ansible, TPA, the Lightwell Deep Agent, ServiceNow.**
Described in the closing act, not built. See `lightwell-demo.rhdp.net` for the
automated end state this complements.

**OpenShift.** Not in the picture. That is the point.

---

## Recording

[RUNBOOK.md](RUNBOOK.md) — every command per act, with measured timings, the
lines worth saying, and the traps that cost takes. It also lists the
corrections this build found in the proposal and build guide, including four
places where the deck and the terminal would have contradicted each other on
camera.
