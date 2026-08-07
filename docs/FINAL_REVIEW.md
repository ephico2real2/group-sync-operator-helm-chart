# CI review, 2026-08-07 — what was wrong and what was fixed

**Closed.** Eight defects found in the CI tooling, all eight fixed and verified. Shipped in PRs #42, #43
and #44.

Scope was the tooling only — `ci/act-local.sh`, `.github/workflows/ci.yaml`, `ci/url-guard.py`,
`CONTRIBUTING.md`, `docs/RELEASING.md`. **No chart file changed**, so chart `0.11.0` is unaffected and its
version correctly did not move. Confirmed on the live cluster afterwards: release upgraded to rev 14, 64
groups unchanged, both GroupSync CRs present, all four hook Jobs `Complete`, both `helm test` suites
`Succeeded`.

Every defect was reproduced before being fixed and re-verified after. **The theme is one failure mode** —
a check that reports success while verifying nothing. Six of the eight were exactly that.

---

## 1. The local CI runner exited silently on the commonest broken state

`ci/act-local.sh` — `podman_socket()` ended in a pipeline whose exit status escaped the command
substitution, so under `set -o pipefail` it killed the script at the caller's assignment.

A **stopped** podman machine — the ordinary state after a reboot, since machines do not autostart — gave
**exit 125 with zero bytes of output**, and the two `die` messages written for exactly that state were
unreachable.

**Fixed:** `|| true` on both branches, so "nothing found" is empty output and status 0 — what the callers
already assumed. Verified: a stopped machine now prints `no podman machine is running. Start it: podman
machine start podman-machine-default`; no machine at all prints the `systemctl` hint. Healthy path
byte-identical.

## 2. `version-bump` accepted a base it could not resolve

`.github/workflows/ci.yaml` — the job diffs the chart against the PR's base and never checked that base
was usable. Two failures, measured under the `bash -e` GitHub gives every `run:` block:

| `BASE` | behaviour |
|---|---|
| empty | `fatal: bad revision ''` swallowed by an existing `\|\| true` → reported **"no chart content changed"** and exited 0. And `git show ":<path>"` with an empty base reads the **index**, so the previous version came back as the *working* version — the comparison compared a value to itself. |
| unresolvable | **exit 128**, killed at the version read with no explanation. |

**Fixed:** the base is validated as a non-empty, resolvable commit before either diff, and an unresolvable
one now fails loudly — a check that cannot compare anything is broken, not passing. `Chart.yaml` absent at
the base is handled separately as chart creation, verified against this repo's root commit where that file
genuinely does not exist. That also let a `2>/dev/null` come off the `git show`, so a real error there is
no longer hidden.

## 3. Two documents promised a warning that no code implemented

`CONTRIBUTING.md` and `ci/act-local.sh`'s own header both said the runner warns you when a chart edit is
uncommitted — `version-bump` compares commits, so a working-tree change is invisible to it. Nothing
implemented that warning.

**Fixed:** implemented, so both sentences became true rather than being weakened. It uses
`printf '%s\\n' "$VAR" | sed 's/^/      /'` and **not** `printf '      %s\\n' "$VAR"` — the one-argument
form indents only the *first* line of multi-line porcelain, measured under macOS `/bin/bash` 3.2.57.
Verified with a modified file and an untracked file: both listed, both indented.

## 4. A broken shell script passed the shell-syntax check

`.github/workflows/ci.yaml` — two defects in one step.

`bash -n "$f" && echo "ok"` puts the check on the **left side of `&&`, which is exempt from errexit**. A
syntactically broken script printed its error, the loop continued, and the step exited 0. Proven by
appending `if [ ; then` to a shipped script and watching the job report **PASS**.

Separately, the rendered-script loop read a file the extraction wrote, and a zero-length extraction made
the loop iterate zero times and green-tick — the check silently covering nothing.

**Fixed:** both `bash -n` sites split into separate commands so `set -e` sees the failure, plus a
`[ -s ... ]` guard that fails loudly when the extraction matches nothing. Verified: the same broken script
now fails the job with the syntax error named.

## 5. The header claimed a guarantee the workflow does not give

`.github/workflows/ci.yaml` said *"a release can never skip them even on a direct push."* False:
`version-bump` is gated on `pull_request`, and under `workflow_call` the `github` context is the
**caller's** — so the release path skips it. Measured across all three events: `pull_request` runs it,
`push` skips, `workflow_dispatch` skips.

**Fixed:** the gate stays PR-only and the comment now states the real guarantee. Enforcement lives in
branch protection — PRs required, admins included, that job a required check, verified by a rejected
direct push (`GH006`) — and `strict` stops two PRs that chose the same version from racing. Extending the
job to `push` would only add a post-merge repeat of a check that already passed, with base-ref edge cases
to get wrong.

## 6. The one explanation that mattered was never printed

`ci/act-local.sh` — the notices explaining a vacuous run sat after the "all passed" line, which the failure
branch never reaches. So the single state that *guarantees* a failure — an unresolvable base, where
`version-bump`'s `git diff` dies — was the one state whose explanation was discarded. A reader saw a bare
`fatal: bad revision ''` and debugged git-in-a-container instead of reading the line naming the fix.

**Fixed:** both notices print before the outcome is decided, once rather than duplicated into two branches
that would drift. Verified: the remedy, naming `ACT_BASE_REF`, now appears on the failing run.

## 7. The bare-chart-path check could not match the barest forms

`.github/workflows/ci.yaml` — the pattern required an argument between the subcommand and the path, so
`helm <lint> .` (the canonical lint invocation, which takes no release name) was structurally unmatchable.
It also used literal single spaces, so a double-space or tab-separated variant slipped through.

**Fixed:** the argument segment is optional and `[[:space:]]+` replaces the literal spaces. **No file is
excluded** — an earlier attempt excluded this document, because it quotes bad commands as evidence and so
failed the check on its own findings, but silencing a whole file creates a blind spot in the document most
likely to grow more `helm` commands. The illustrative commands here are written `helm <lint> .` instead.

## 8. `url-guard` was blind to four of five ways to read the raw url

`ci/url-guard.py` exists because a template reading the raw `groupSync.url` instead of the resolver gets an
empty string on a discovery-based install, and `helm template` cannot catch it offline. Four bypasses, each
measured against the guard as it stood:

```
{{ $gs := .Values.groupSync }}{{ $gs.url }}     alias — a natural refactor once several keys are read
{{ index .Values.groupSync "url" }}             string-key access; no dotted path exists to match
{{ get $gs "url" }}                             same
{{ printf "%s"
  .Values.groupSync.url }}                      ZERO PARSED ACTIONS
```

The last is structural, not a pattern gap: `actions()` matched `{{(.*?)}}` **one line at a time**, so an
action spanning a newline was invisible before any pattern ran — splitting the *original, already-caught*
raw read across two lines defeated the check entirely.

**Fixed:** a parser change, not another alternative. `actions()` scans the whole text with `re.S` and
derives the line number from the match offset; the comment exclusion is judged on the line the action
*opens* on, since a `#` further in is inside the action. The pattern gained the alias chain and
`index`/`get` matched on the **string key** — matching the key rather than the indexed object is
deliberate, because that object can itself be an alias and chasing it is type inference this script has no
business attempting. Cost: indexing `"url"` on some other object is also flagged, which is acceptable
because a non-groupSync raw `.url` read deserves the same scrutiny, and `ALLOWED_DEFINES` is the escape
hatch.

Verified: the clean chart still passes with 0 problems, all four bypasses now fail with exit 1 when planted
in a real template, an unrelated key is untouched, and both comment forms are still ignored.

---

## How this was reviewed, and what that changed

Two independent reviewers at high reasoning effort over a deliberately narrow scope, then Codex
`gpt-5.6-sol` over their merged findings, then arbitration against the live repo and cluster.

**Five of the eight fixes first proposed were wrong, and the Codex pass caught all five** — in every case
the real defect was larger than the finding described. #4 is the clearest: the zero-length extraction had
been found, but not that `bash -n X && echo` cannot fail the step at all, which was the half that let a
broken script ship. #8 is the other: one more regex was proposed while the parser could not see a
multi-line action at any pattern.

That is what the pass was for, and it is why the fixes above differ from what was first written down. The
working notes — the original findings, the refuted remediations, and each verdict with its evidence — are
in this file's git history if that reasoning is needed again.
