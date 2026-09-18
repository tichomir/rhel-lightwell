# Voice-over script — Patch to Production

Read this aloud. It is written to be spoken, not scanned: short sentences, no
nested clauses, numbers said the way you would say them out loud.

**How to use it.** `[SCREEN]` tells you what should be visible. `[PAUSE]` means
stop talking and let the screen carry it — those are deliberate and the demo is
worse without them. Anything in **MUST SAY** is a claim you cannot skip without
misrepresenting something; everything else you can reword freely.

Total spoken time: roughly 40 minutes, against 50–65 minutes of finished video.
The gap is the waiting — builds, reboots, scans. Narrate over those; the script
marks where.

---

## Cold open · 40 seconds

`[SCREEN: the application in a browser, working]`

> This is a train booking service. It runs on Red Hat Enterprise Linux 10, in
> image mode — which means the whole operating system is a container image, and
> updating it is a registry pull rather than a package transaction.
>
> Over the next hour, two things go wrong with this application in the same
> week. One is an operating system vulnerability. One is a vulnerability in a
> Python library the application depends on.
>
> Today those are two completely different problems, handled by two different
> teams, on two different timescales. By the end of this you will have watched
> them become the same operation — same command, same approval gate, same
> rollback, same day.

`[PAUSE]`

---

## Act 0 — Baseline · ~4 minutes

`[SCREEN: the Status page]`

> Before anything changes, here is what this host says about itself.
>
> Operating system version ten point one. The image it booted, by name and by
> digest. The dependency versions actually installed in the application's
> virtual environment. Whether a rollback is available — it says no, because
> nothing has been upgraded yet.
>
> **MUST SAY:** None of this page is hardcoded. Every field is read at request
> time — the image reference and digest come from `bootc status`, the
> dependency versions from the Python environment itself. That matters, because
> everything I show you later is this same page telling you what changed.

`[SCREEN: bootc status]`

> And here is the platform's own view. One booted deployment, no staged update,
> no rollback. A clean, fully patched, compliant host.
>
> Normal Tuesday.

`[PAUSE]`

---

## Act 1 — The operating system CVE · ~8 minutes

> A CVE lands in the base operating system. Red Hat ships a fixed minor
> release. In image mode, adopting it looks like this.

`[SCREEN: the build command]`

> One build argument changes. `BASE_TAG` goes from ten point one to ten point
> two. That is the entire change — the application layer above it is rebuilt
> untouched, from the same source, with the same dependencies.

`[SCREEN: build running — narrate over it]`

> While that runs, worth saying what is actually happening. This is not
> patching a machine. It is building a new operating system image, in a
> pipeline, with the application already inside it. The machine that will run
> it has not been contacted at all yet.

`[SCREEN: promote.sh]`

> And this is the approval gate. One registry tag move — the `prod` tag now
> points at the new digest.
>
> In your estate this is a content view promotion in Satellite. Same gate, same
> approval, different tool. Nothing has reached the host yet; the host decides
> when to take it.

`[SCREEN: bootc upgrade --check, then bootc upgrade]`

> Now the host. It tracks the `prod` tag, it can see a new digest, and it pulls
> it. Around nine hundred and fifty megabytes, because this is a whole
> operating system.

`[SCREEN: upgrade running — this is the long wait, a couple of minutes]`

> This is the right moment to say what image mode actually gives you. The
> running system is not modified. A second, complete deployment is written
> alongside the first. `/usr` is replaced wholesale and is read-only. `/var` —
> your data, your logs, your database — is untouched and shared.
>
> So the upgrade is not a sequence of package transactions that can half-fail.
> It either becomes the next boot or it does not.

`[SCREEN: bootc status showing staged, then the Status page]`

> And there it is staged, waiting for a reboot. Notice the application's own
> status page knows about it — `staged_pending_reboot`, true. The host knows an
> update is waiting and says so on the page I have been showing all along.

`[SCREEN: reboot, then the Status page]`

> Operating system version ten point two. New kernel. New image digest, and it
> matches the digest I promoted. Rollback now available.
>
> That is a textbook operating system patch. Atomic, versioned, reversible.

`[PAUSE]`

> And now the line that sets up everything that follows.
>
> **MUST SAY:** The Python library is still on the vulnerable version. The
> vulnerability probe still reports the flaw as reachable. A perfect,
> fully-patched operating system upgrade changed nothing at all about whether
> this application can be attacked.

`[SCREEN: bootc rollback, reboot]`

> And the safety net, because you will be asked. Three seconds, no download —
> the previous deployment is still on disk. Back on ten point one, old kernel,
> and the database never noticed.
>
> Everything you just watched me undo took three seconds and no network.

`[SCREEN: bootc rollback again, reboot — forward to 10.2]`

> And forward again, just as cheaply.

---

## Act 2 — The application CVE · ~12 minutes

### Open with this, before any screen

**Read this before anything technical appears. Anyone who has not heard it will
not follow why the next forty minutes matter.**

> This application builds its web pages by filling a template with data, using
> a library called Jinja2.
>
> One of that library's jobs is to turn a set of labels and values into the
> HTML that a browser reads — and it carefully sanitised the values while never
> checking the labels.
>
> A label containing a space makes the browser stop reading early and treat the
> remainder as a second, separate instruction. So whoever supplies that label
> can add an instruction the developer never wrote.
>
> In the worst case that instruction says "run this code", and the browser runs
> it as the person viewing the page — their session, their permissions, their
> data.
>
> The fix only exists in a much newer version of the library, which is why
> patching it normally means an upgrade the application cannot absorb.

`[PAUSE — this is the most important pause in the video]`

### The coverage gap

`[SCREEN: show-coverage-gap.sh]`

> This host carries the same library twice, and that is what makes the point
> quickly.
>
> The first copy is a Red Hat RPM. It arrived with cloud-init, nobody chose
> it, and Red Hat patches it — it is on version three point one point six, and
> it is fixed.
>
> The second copy came from the application's `requirements.txt` at image build
> time. You chose it, you pinned it, and no operating system mechanism has ever
> touched it.
>
> Same library. Same machine. Same vulnerability.

`[SCREEN: the two probe lines]`

> And here is the same test run against both, live, on this machine. The
> patched copy refuses to render — it fails closed, which is the fix. The
> pinned copy emits the malicious label verbatim.
>
> **MUST SAY:** This is not a failure of Red Hat. The operating system vendor
> patched the part they ship. This is the boundary of what an operating system
> subscription has ever covered — and that boundary runs straight through the
> middle of one application.

`[SCREEN: the "why not just use the OS copy" section]`

> The obvious question is why not just use Red Hat's copy. Two honest answers.
>
> First, it is version three point one point six. Using it *is* the migration —
> functions removed, classes relocated, autoescape defaults changed. Same code
> change, same regression cycle, same change board. That is the whole reason
> this demo exists.
>
> Second, it covers a minority of what this application depends on. Of the five
> direct dependencies, Red Hat ships an RPM for two. The rest — the web
> framework, the server, the database driver — have no RPM at all, and neither
> does the transitive tree beneath them.

### What "exploitable" actually means

`[SCREEN: show-injection.sh]`

> Let me make that concrete rather than abstract.
>
> The template author wrote one attribute. An HTML parser reads the output and
> reports two — and the second one was chosen by whoever supplied that label.

`[PAUSE]`

> **MUST SAY:** That injected attribute does nothing. It is inert on purpose.
> Substituting an event handler is what turns this into a working attack, and
> that is a one-word change an attacker makes and I am not going to put in a
> recording that gets forwarded.
>
> And be precise about this application specifically: its interface escapes on
> output, so the flaw does not reach a browser here. What is demonstrated is
> that the library hands its caller markup a browser misreads. Any application
> using that filter for its intended purpose is exposed. Relying on a second
> layer to catch it is not a patching strategy.

### The scanner

`[SCREEN: scan.sh]`

> And here is what a scanner says. Four CVEs in this one library. Every single
> fix is in the three point one line. There is no two point eleven release that
> resolves any of them.
>
> So the options are: upgrade and absorb a migration, accept the risk, or find
> a fourth option. That fourth option is what the rest of this is about.

---

## Act 3 — Lightwell remediation · ~10 minutes

`[SCREEN: curl against the Lightwell index]`

> Red Hat Lightwell Network publishes the fix backported into the version I
> already run. So let me ask the index directly.
>
> A Python package index is just a web page listing filenames. This is the
> shortest possible question: what is on the shelf for this package?
>
> One file. Two point eleven point three — the version I already run in
> production — plus a Lightwell suffix. Same version I pinned. Plus a fix.

`[SCREEN: pip index versions]`

> But a filename on a web page is not the same as something my build can use.
> So let me ask the tool that matters.
>
> This is pip, in a clean throwaway container, pointed at that index. Not the
> builder's configuration — a fresh Python, asking what versions it can see.
>
> One line. And that is the only version this index offers. So when the build
> runs in a minute, that is not a version it *might* pick. It is the only one
> it can.

`[SCREEN: the patch diff — git diff --stat then the two files]`

> And this is the backport itself. Three files. Sixty-four lines added,
> thirty-five removed.
>
> One file is the version stamp. One carries the two attribute-injection fixes
> and the attribute filter fix. One is the sandbox. Every change is derived
> from the upstream fix commit for that specific CVE, and the repository
> records which commit each one came from.
>
> Four lines of security logic where it matters. Not a new major release with a
> migration attached.

`[SCREEN: switch-track.sh b, then pip.conf]`

> Now the change to the build. Not to the application — to where the build
> looks for packages. One index URL.

`[SCREEN: the requirements.txt diff]`

> And the pin, made explicit so the change is auditable in version control.
>
> **Worth saying:** I did not strictly need this edit. The packaging
> specification lets my existing pin match the backported version, and the
> Lightwell index serves nothing else. Point the build at the index and the pin
> I already have picks up the fix. That is what drop-in actually means.

`[SCREEN: the rebuild, with NOCACHE=yes]`

> And now the same build command as Act 1. Same script, same arguments, one
> different index. Watch the wheel come down from the Lightwell index rather
> than from the public one.

`[SCREEN: the test suite]`

> Here is the claim that matters, and the only evidence for it worth anything.
>
> The full test suite. Twenty-four tests. Not edited between runs — the same
> file passed against the vulnerable build and passes against this one. Same
> API, same behaviour, and the vulnerability probes that failed before now
> pass.

`[SCREEN: pip show inside the image]`

> And the proof the image really contains it. The version inside the image
> carries the Lightwell suffix — and that version does not exist on the public
> index at all. It could only have come from Lightwell.

### Then the scanner, still red

`[SCREEN: scan.sh against the remediated image]`

> And now the most credible ninety seconds in this recording.
>
> The scanner still reports all four. It can see the remediated artifact and it
> still calls it vulnerable.
>
> **MUST SAY:** That is correct behaviour, and no version string could ever fix
> it. The packaging specification gives a local version suffix no ordering
> weight, so my patched build compares as the unpatched one and falls inside
> every published advisory range. Any specification-compliant scanner reports
> it as affected. Three separate tools agree, and all three are right.
>
> So: the tests are green, the vulnerability is closed, and the scanner is red.
> Your scanner report and your actual risk are not the same document.

### The SBOM diff

`[SCREEN: diff-sbom.sh, both diffs on one screen]`

> Here is the part a customer's security team can verify without trusting me at
> all, because it is derived from the shipped artifacts.
>
> The operating system patch moved three hundred and sixty-eight components.
> The dependency fix moved one. The same command, the same gate, the same
> rollback — and two blast radiuses three orders of magnitude apart.
>
> That is not me describing the patch scope. It is the difference between the
> software bills of materials of two images you can pull yourself.

### The VEX, and Trustify

`[SCREEN: Trustify, empty]`

> So if a version number cannot carry the fact that a fix has been applied,
> something else has to. That something is a VEX document — a machine-readable
> statement about which products a vulnerability actually affects.
>
> This is Trustify. It is the upstream project that Red Hat Trusted Profile
> Analyzer is built from — the same engine, different badge.

`[SCREEN: upload the two SBOMs]`

> First the inventory. Two software bills of materials, generated by syft from
> the two images I actually pushed. Three thousand six hundred and sixty-four
> components each, differing by exactly one.
>
> And zero vulnerabilities on both — because an SBOM is an inventory, not a
> risk assessment. It tells you what is in the box. It cannot tell you what is
> wrong with it until something gives it a list to check against.

`[SCREEN: upload the VEX]`

> Now the vendor statement.
>
> **MUST SAY:** I wrote this document. Red Hat does not publish VEX for
> Lightwell content yet — that missing public feed is precisely the gap this
> demo is about. What you are looking at is the *shape* of the statement, not a
> statement Red Hat has made.

`[SCREEN: the SBOMs page — 4 and 0]`

> And there it is. The build from this morning: four vulnerabilities. The build
> I shipped twenty seconds ago: none. One document made the difference, and it
> is now legible to a machine rather than to a person reading release notes.

`[SCREEN: Vulnerabilities → CVE-2024-56326 → Related SBOMs]`

> One CVE, two builds, two different answers. Affected, and fixed. Including
> the highest-scoring one in the set — a sandbox escape at seven point eight.

`[SCREEN: load the public feed]`

> And now the honest half, which costs twenty seconds and is worth more than
> anything else in this act.
>
> I have just added the public open source vulnerability database — the recall
> list every scanner looks things up in. It has never heard of this backport,
> so it still matches the version range and calls both builds affected. Every
> row just moved.
>
> Nothing about the artifact changed. All four are genuinely fixed, the tests
> prove it against the upstream proof of concept, and the public feed still
> says otherwise — because a version number cannot carry that fact.
>
> **That gap, between what the vendor knows and what the feed knows, is exactly
> what the Lightwell security feed closes.** And notice the VEX still says
> fixed. The mechanism works. It just needs publishing.

`[PAUSE]`

---

## Act 4 — Patch to production · ~8 minutes

`[SCREEN: promote.sh]`

> Same gate as Act 1. One tag move.

`[SCREEN: bootc upgrade]`

> And the best surprise in the whole demo. The operating system patch was a
> nine hundred and fifty megabyte pull. This is twenty-seven megabytes and
> about twelve seconds — because every base layer is already on disk.
>
> Read the *added* layers line, not the total. Seven layers. Twenty-seven
> megabytes.

`[SCREEN: reboot, then the Status page]`

> And the money screen.
>
> Operating system version: ten point two — unchanged. The operating system did
> not move. Image version one point two. The library is on the remediated
> build. The application reports itself remediated. And the vulnerability probe
> is no longer reachable — it reports the library refusing to render, with the
> exact error.

`[SCREEN: bookings]`

> The booking data is still there. `/usr` was replaced; `/var` survived.

`[SCREEN: bootc status on the database host]`

> And the tier I did not touch, I did not touch. The database host has never
> been upgraded — no staged deployment, no rollback, because nothing was ever
> applied to it. Different tier, independent lifecycle, zero blast radius. On
> screen, rather than claimed.

`[SCREEN: bootc rollback]`

> And the same three-second safety net as the operating system patch. The
> dependency fix reverts independently, and the operating system stays where it
> is.
>
> **MUST SAY:** From the platform team's point of view, an application CVE fix
> and an operating system CVE fix are now the same operation.

---

## Act 5 — The clock · ~5 minutes, slides

`[SCREEN: the elapsed-time slide]`

> Everything you just watched was one session, timestamped at the start and end
> of every act.
>
> Rebuild on a new base operating system, and push: minutes. Promote: under a
> second. The operating system upgrade on the host: a couple of minutes.
> Rebuild with a remediated dependency: under a minute. Deploy it: twelve
> seconds. Roll it back: three.
>
> Industry average time to remediate a known vulnerability is over forty days.
> For high-risk vulnerabilities, forty-five to ninety.
>
> Not because the fix is hard to write. Because the fix means an upgrade, and
> the upgrade means a migration, and the migration means a project.

`[PAUSE]`

> What removed that was not speed. It was removing the migration from the
> critical path — and then making the application fix travel the same road the
> operating system fix already travels. The same registry, the same promotion
> gate, the same command on the host, the same rollback.
>
> One mechanism. Two kinds of problem. Same day.

---

## What to say if asked — keep these ready

**"Is this a real Red Hat Lightwell index?"**
> No. This is a local index serving a wheel I backported myself from the
> upstream fix commits, because Lightwell coverage for this exact package and
> version has to be verified against the real catalogue and I could not do that
> here. The mechanism is identical; the provenance is mine. I will say that
> every time it is on screen.

**"Did Red Hat issue that VEX?"**
> No. I wrote it. Red Hat does not publish VEX for Lightwell content yet, and
> that is the gap this demo is about.

**"Does the backport fix all four CVEs?"**
> Yes, and each one is verified against the proof-of-concept template from the
> upstream fix commit — not a test I wrote myself. The library's own test suite
> gives the identical result before and after the patch, so the fix adds
> nothing and breaks nothing.

**"Can you show the exploit?"**
> No, deliberately. A working exploit in a recording that gets forwarded is a
> liability that outlives the demo. What I show is an HTML parser reporting an
> attribute the author never wrote, which is the security claim in full.

**"Does Lightwell fix everything?"**
> It fixes what can be fixed in the version you already run, the same day.
> Coverage is per package and per version and you look it up. What it cannot
> fix, it tells you about — which is how you know the green ones are real.

**"Does this replace our scanner?"**
> No. Trustify is where the answer goes after your scanner produces it, and it
> is the only place a vendor statement can change that answer. The SBOMs here
> were generated by syft, which is the scanner's own sibling.
