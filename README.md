# rhel-lightwell

Demo environment for **Patch to Production** — patching both the operating
system and an application dependency on a RHEL image-mode host, using the same
command, the same gate and the same rollback.

The application half of the patch comes from **Red Hat Lightwell Network**: a
backported security fix delivered into the exact version already pinned in
production, with no upgrade and no code change.

---

## Status

**Unverified.** Everything here was written offline and has not been executed.
`python3 -m py_compile` and `bash -n` pass on every file, which catches syntax
errors and nothing else. The first thing to do is [step 1](#step-1-lock-the-dependency),
which can invalidate the dependency choice the whole repository is built around.

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
version segment instead:

```
2.11.3+rhlw.00001
```

Confirm the exact string the real index uses before recording, and match it in
the lab index so the two tracks are visually interchangeable on camera.

### The integrity rule

The lab index is indistinguishable from the real one on screen. So: never show a
`packages.redhat.com` URL while resolving from `lightwell.rh-lab.labs`. Record
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
