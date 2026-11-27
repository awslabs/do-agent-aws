# Software bill of materials and CVE scan

What every build records about the software it installs, and how it is scanned. Part of the [Do Agent on AWS manual](README.md).

Contents:

- [Software bill of materials](#software-bill-of-materials)
- [CVE scan](#cve-scan)

## Software bill of materials

The image carries its own bill of materials at `/SBOM.txt`: one line per third-party component, `<name> <version> - <license>`,
written by the Dockerfile's LAST step (`RUN /sbom.sh`, so everything `setup.sh` installed is in it; the sandbox kit's dockerfile
runs it again after its own layer). `Container-Root/sbom.sh` runs `/agent/sbom.py` (standard library only) over four sources,
each its own section of the file:

* **apt** - every installed dpkg package, its license from `/usr/share/doc/<package>/copyright`: the DEP-5 `License:` short
  names, else the `/usr/share/common-licenses/` files it points at, else the license names in its text, else the license text
  itself recognised (marked `(license text)`).
* **npm** - every package under a `node_modules` directory in the image (the global tree, the plugins' trees, the vendored
  dashboards' trees), the license its `package.json` declares, else its LICENSE file's first line.
* **Python** - every `*.dist-info` and `*.egg-info` in the image (every site-packages, the hindsight tool environment, the AWS
  CLI's bundled dist), the license its metadata declares.
* **tools** - `Container-Root/setup/third-party.txt`, the hand-maintained registry of what the installers fetch as release
  archives, upstream install scripts, git clones, container-image exports and vendored trees (Node.js, nvm, bun, uv, the AWS
  CLI, kubectl, kubectx, crane, buildctl, headlamp, the hindsight server and hooks, swagger-ui, vibe-kanban's binary, the
  comms engine, the vendored dashboards, the example knowledge pack, the Claude Code plugins and marketplaces, the two
  embedding models), one line each with its license, its upstream and the installer that brings it; a version written as
  `$(command)` is read from the image.
  The same file names the license of a package whose own metadata has none (`dpkg:`, `npm:`, `python:` lines) and the
  installers that bring no third-party code (`none:` lines), so every `setup/install-*.sh` is accounted for.

Package-manager caches are left out (copies of what is listed); `/wd` and anything mounted into the container are never
walked. A component whose license could not be determined is listed as `UNKNOWN (<why>)`, never dropped, and the header
counts them. The header names the image, its build stamp (`AGENT_BUILD`) and the generation time, and what is **not** in the
image and so not in the list: the optional sidecar stacks `./run.sh` starts only when switched on, with their licenses - the
Plane board (`makeplane/*:v1.4.2`, AGPL-3.0; `UI_PLANE`, off by default, see "Plane board"); the body after it is the
same for the same image, sorted, with no timestamp in it.

`./build.sh` copies the file out of the image at the end of every build, as `THIRD-PARTY-LICENSES` at the root of this
repository, next to `LICENSE`: the committed, human-readable list of the third-party software in the image with its licenses
(through a temporary file, so a failed extraction never truncates it; an image without `/SBOM.txt` fails the build with one
line). In a running container: `./exec.sh cat /SBOM.txt`, or `docker cp do-agent-aws:/SBOM.txt .`; `/sbom.sh <file>`
regenerates it. Nothing is written under `/wd`. The CVE scan of the image, and its CycloneDX and SPDX outputs, are the next
section's.

`/test-sbom.sh` proves the file and its header, the shape of every line, the coverage of each source (enumerated by the test
itself, not through `sbom.py`: every installed dpkg package, every `node_modules` package, every dist-info, every registry
component, each exactly once; a planted dist-info is reported missing), that every installer is accounted for (a registry
without a line leaves its installer unaccounted), that a regenerated body is byte-identical, and that the UNKNOWN count is
the header's and within the test's allowance. `./test-build.sh` proves the extraction step of `build.sh` with a docker stub.

## CVE scan

`./build.sh` ends with a CVE scan of the image it built: `./scan.sh` runs [trivy](https://github.com/aquasecurity/trivy) from its
pinned public image (`TRIVY_IMAGE`, by tag and digest) as a container through the Docker
socket, as the invoking user, so a build host needs nothing beyond docker; `TRIVY=<command>` runs a trivy of the host instead. The image
is walked once (`trivy image --scanners vuln`, every package listed) and everything else is converted from that report. Under `cve/`
(`CVE_DIR`; gitignored, because the counts move with trivy's vulnerability database from one day to the next), named after the image
(`do-agent-aws_latest.*`):

* `.trivy.json` - the full report, every severity; `.trivy.txt` - the table of the CRITICAL and HIGH findings.
* `.cdx.json` and `.spdx.json` - the image's bill of materials as CycloneDX and as SPDX, converted from the same report (the
  human-readable one is `THIRD-PARTY-LICENSES`, above).
* `.gate.txt` - one line per CRITICAL finding: `FIXABLE` or `no-fix`, the package and its versions, the CVE, the target.
* `.summary.txt` - the one-screen summary, printed at the end of the build as well: the image and its id, the scanner version and the
  database date, the counts per severity with their without-a-fix split, the gate's verdict, the knobs in effect, the wall time.
* `.gate-pass.txt` - the verdict as a file, written only when a gate passed and removed at the start of every run, so a previous run's
  pass never speaks for this one.
* `.trivy-cache/` - the vulnerability database; trivy refreshes it when it is a day old (remove the directory for a fresh one).

`./scan.sh` alone scans the current image, `./scan.sh <image>` another one; about two minutes for this image on a build host. The
build's preflight warns when the Docker endpoint is not a unix socket this user can write (a `tcp://` `DOCKER_HOST`, another user's
socket): the scan would fail there - `TRIVY=<command>` or `CVE_SCAN=false` then.

**The gate.** `CVE_GATE_SEVERITY=CRITICAL` fails the scan, and with it `./build.sh`, on a CRITICAL finding that has a fixed version
(exit 4); a finding without a fix - nothing to install today - is counted, listed as `no-fix` and does not fail the build
(`CVE_IGNORE_UNFIXED=true`; `false` fails on every finding of that severity). `CVE_MAX_HIGH=<n>` fails when the HIGH findings, counted
the same way, exceed it (exit 5). No report, an empty or unreadable one, a scanner that cannot run: exit 3 with the reason, never a
pass. A failed gate is fixed by bumping or removing the component that carries the CVE (`Container-Root/setup/install-*.sh`,
`setup/harden.sh`), never with a `.trivyignore`: an ignore file makes the count untrue. `CVE_GATE_SEVERITY` ships `CRITICAL`: a build
that would ship a fixable one fails. Set it empty in `.env.local` for
report only - the same report, table and summary, exit 0, no pass record. `CVE_SCAN=false` skips the scan at the end of a build, from `.env.local` or the environment
(`CVE_SCAN=false ./build.sh`).

**Reading the result.** The counts move with the vulnerability database from one day to the next, so this README records none:
run `./scan.sh` for what is open today. What a finding is, and who fixes it (SECURITY.md "Open findings and who is responsible for
each"):

* **A package of the base distribution:** a rebuild takes the distribution's current packages (the build upgrades them,
  `Container-Root/setup.sh`); one the distribution has not fixed yet stays listed as `no-fix` until it does.
* **A library inside a prebuilt release binary** (the Go tools the image installs: kubectl, crane, BuildKit's client, Headlamp,
  gh): fixed by the tool's own release. When a release carries the fix, move its pin in `Container-Root/setup/install-*.sh` (BuildKit's
  daemon image in `.env` moves with its client), rebuild, and check with `./scan.sh`. Until one does, the finding is the project's
  to fix, and what limits it here is what the binary does: a client of endpoints you choose, or a listener only the loopback
  proxy reaches.
* **A package inside an installed plugin or tool environment** (npm, Python): `Container-Root/setup/harden.sh` moves it by name
  within the range the plugin declares; beyond that range the plugin's own release fixes it.
* **A finding in a vendored project** (`Container-Root/opt/<project>/`, each with a `VENDORED.md`): the project's to fix. This
  repository keeps the release byte for byte and imports the project's next one.

Moving a pin is verified the same way every time: rebuild, `./scan.sh`, `./test.sh`. A pin is a version with its checksum or digest,
so a build installs what was tested and a mismatch fails the build.

The scan reads SBOM files shipped inside the image as components (trivy's warning "Third-party SBOM may lead to inaccurate vulnerability
detection"): pip's `pip/_vendor/bom.cdx.json` and a few wheels' `dist-info/sboms/*.cdx.json`. They name code that is in the image
(pip's vendored libraries), so they are kept, not excluded.

`./test-scan.sh`, run by `./test.sh`, proves `scan.sh` with docker and trivy stubbed: one walk as the invoking user through a planted
socket, the three conversions from the report, the summary's scanner, database date and counts, the pass record with the image id,
exit 4, 3 and 5 and the report-only default, each with a planted report. `./test-build.sh` proves the scan is `build.sh`'s last step,
skipped on `CVE_SCAN=false`, and that its exit status is the build's.
