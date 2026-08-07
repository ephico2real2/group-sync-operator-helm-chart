# Final review — findings, solutions, and adjudication

Status: **CLOSED — all 8 findings applied.**

All eight are applied. Five were marked FIX-INADEQUATE by Codex, meaning the defect was real but the
remediation written below was not sufficient — in every one of those five the real defect was larger than
the finding, and the applied fix differs from what this document originally proposed. Read the
`> **Codex:**` marker under a finding before treating its Solution block as what shipped.

Codex marked all 8: **2 CONFIRMED-and-applied, 1 CONFIRMED-outstanding (6), 5 FIX-INADEQUATE** (2, 3,
4, 7, 8 — the defect is real but the remediation as written is wrong, so each needs re-deriving from
Codex's marker rather than applying).

A finalization review of the work landed on 2026-08-06/07 (chart `0.11.0` published; PRs #30–#40). Two
Fable reviewers ran at high effort over deliberately narrow scopes, each with a 12-item ignore list of
settled decisions. Every finding below was then **re-verified independently** by the arbiter before
being written down; the verification command and its real output are recorded per finding.

**Scope.** Only what is new and under-reviewed: `ci/act-local.sh`, `.github/workflows/ci.yaml`,
`.github/workflows/helm.yaml`, `ci/url-guard.py`, `ci/render-checks.py`, `CONTRIBUTING.md`,
`docs/RELEASING.md`. The chart itself has been through several adversarial rounds and is deployed and
verified on a live cluster (64 groups, two CRs, both CA paths, `helm test` green) — it is not re-audited
here.

**Out of scope, by owner decision** — raising any of these counts as a false positive:
`customGroupSyncs` design (empty `items` default is deliberate; flipping `enabled` was already reviewed
and rejected), `subscription.resources` semantics (OLM replaces the CSV's sizing on every container;
only `null` clears it; ceiling is headroom/2 — all measured), operator CRD behaviour (prune, anonymous
bind, AD — parked), `proxy/cluster.spec.trustedCA` staying unmanaged, the lab-created `ldap-secret`,
kubeadmin, `ca-key.pem`, the `fullnameOverride` collision, `clean_restart` re-import, `$NAMESPACE`
quoting, architectural redesigns, and new CI jobs/frameworks.

## Verdict table

| # | Severity | Where | Arbiter verification | Disposition |
|---|---|---|---|---|
| [1](#1) | **high** | `ci/act-local.sh:89,91` | **confirmed** — exit 125, 0 bytes output | fix |
| [2](#2) | medium | `ci.yaml:162` | **confirmed** — `appVersion` edit invisible | fix |
| [3](#3) | medium | `CONTRIBUTING.md:71`, `act-local.sh:29` | **confirmed** — no such code path | fix |
| [4](#4) | medium | `ci.yaml:305` | confirmed structurally | fix |
| [5](#5) | medium | `ci.yaml:151`, `ci.yaml:3-5` | **confirmed** — measured on 3 events | partly done (#40); decision needed |
| [6](#6) | medium | `ci/act-local.sh:377` | **confirmed** — remedy never printed | fix |
| [7](#7) | low | `ci.yaml:386` | **confirmed** — `helm <lint> .` unmatchable | fix |
| [8](#8) | low | `ci/url-guard.py:13` | **confirmed** — alias bypasses | fix |

---

<a id="1"></a>
## 1. Broken or stopped podman makes the script exit **silently**; both `die` messages are dead code

- **Severity**: high
- **Location**: `ci/act-local.sh:89,91` (cause); `:106,136` (the assignments that die); `:139-141` (the
  messages that never print)
- **Introduced**: the `podman_socket()` refactor in commit `20ee2ee`, while fixing the
  builder/DOCKER_HOST mismatch. The pre-refactor inline version did not have this shape.

**Claim.** `podman_socket()` ends in a pipeline whose exit status escapes the command substitution. When
podman is installed but cannot serve a socket — no machine, or **a machine that exists but is stopped,
which is the normal state after a reboot since podman machines do not autostart** — `podman info` exits
125, `pipefail` makes the function return 125, and `pod_sock="$(podman_socket)"` / `sock="$(podman_socket)"`
fail under `set -e`. The script exits **125 having printed nothing**: podman's stderr is discarded by the
`2>/dev/null`, and the `die` messages written for exactly these states are unreachable — control dies one
line before them.

**Arbiter verification.**

```
$ bash -c 'set -euo pipefail; f() { false | sed "s/x/y/"; }; v="$(f)"; echo NEVER'
  exit=1                      # mechanism, in isolation

$ env -u DOCKER_HOST PATH="$STUB:$PATH" ./ci/act-local.sh --list     # stub = machine exists, stopped
  exit=125
  output bytes=0
  output: []
```

**Impact.** A verification tool that exits mute, in the single most common broken state. A contributor
following `CONTRIBUTING.md` step 4 after a reboot gets no error and no hint — only `$?=125` if they think
to look. This is the same failure class as every other bug in this file's history: something reporting
nothing while verifying nothing.

**Solution.** Make `podman_socket()` what its callers already assume — a discovery helper whose "nothing
found" is *empty output and status 0*. Append `|| true` to both pipelines, the file's established idiom:

```bash
podman_socket() {
  command -v podman >/dev/null 2>&1 || return 0
  pod_machine="$(podman machine list --format '{{.Name}}|{{.Running}}' 2>/dev/null | awk -F'|' '$2=="true"{print $1; exit}')"
  if [ -n "$pod_machine" ]; then
    # `|| true` on both branches: a podman that cannot answer must read as "no socket found" (empty
    # output), not as a failing status. That status escapes the command substitution and kills the
    # script under set -e BEFORE the callers' own no-socket diagnostics can run — measured: exit 125
    # with zero output, and the two die messages below unreachable.
    podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' "${pod_machine%\*}" 2>/dev/null | head -1 || true
  else
    podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null | sed 's|^unix://||' || true
  fi
}
```

Correct because every caller already handles the empty string: `:107` falls through to `BUILDER=docker`,
and `:137-141` branch on `[ -z "$sock" ]` into the two `die`s. Nothing changes on the healthy path — the
pipelines succeed and `|| true` never fires. It only lets the existing, already-reviewed error handling
run.

**Risk.** If `podman machine inspect` failed while a machine *is* running, the empty result routes to the
`:141` die whose "no podman machine is running" wording would be slightly off — loud and adjacent, versus
mute today. Verify: `./ci/act-local.sh --list` on a healthy machine prints the same `🔌 podman:` line, and
one real job still passes.

> **Codex:** **CONFIRMED** — Re-run on the current host: `./ci/act-local.sh --list` exited 125 with 0
> output bytes. Under macOS `/bin/bash` 3.2.57, the original helper also exited 125; the proposed helper
> returned an empty socket and status 0 when both `podman machine list` and `podman info` returned 125,
> and did the same when a running machine was listed but `machine inspect` returned 125. The prior passes
> did not force failures through the earlier assignment at `:87` or the inspect branch at `:89`; neither
> is another escaping path for the two current callers (`:106`, `:136`), which both invoke the function
> in command substitution. The scope concern is real but harmless here: a sentinel
> `pod_machine=caller-sentinel` remained unchanged after `sock="$(podman_socket)"`, proving the function's
> assignment is lost in the subshell. No caller uses it; `:145-146` explicitly avoids putting the machine
> name in the log. Thus the two terminal `|| true` clauses are sufficient for the current call sites and
> do not leave a wrong log line.

---

<a id="2"></a>
## 2. `version-bump` is blind to `Chart.yaml`-only content changes (`appVersion`, `artifacthub.io/changes`)

- **Severity**: medium
- **Location**: `.github/workflows/ci.yaml:162`

**Claim.** `changed=$(git diff --name-only "$BASE" HEAD -- "$CHART" | grep -v '/Chart.yaml$' || true)`
excludes **all** of `Chart.yaml`, so that a version-only bump is not asked to bump again. But `Chart.yaml`
also carries `appVersion` and `artifacthub.io/changes` — the changelog Artifact Hub displays, which
`RELEASING.md` §3 spends twenty lines telling contributors to maintain. Editing those without a version
bump reports "no chart content changed" and exits 0; `helm.yaml` then triggers on `charts/**`,
`skip_existing` skips the already-published version, and the correction never ships. Green everywhere. The
job's own name — "Chart changes bump the chart version" — is not what it checks.

**Arbiter verification.** A synthetic base differing from HEAD *only* in `appVersion`, version identical
both sides:

```
files differing BASE..HEAD: [charts/group-sync-operator-helm/Chart.yaml]
appVersion at BASE: "1.0"   at HEAD: "1.1"
version    at BASE: 0.11.0  at HEAD: 0.11.0

CURRENT logic  -> "no chart content changed", EXIT 0     <-- appVersion change INVISIBLE
proposed fix   -> counts as changed => version comparison runs => 0.11.0 vs 0.11.0 => FAILS correctly
```

*(An earlier attempt at this test used a `sed` pattern that matched nothing, so the synthetic base was
identical to HEAD and the run proved nothing. Recorded because the first result looked like a
confirmation.)*

**Solution.** Count `Chart.yaml` as changed unless its diff is confined to the `version:` line. After
`ci.yaml:162`:

```yaml
          changed=$(git diff --name-only "$BASE" HEAD -- "$CHART" | grep -v '/Chart.yaml$' || true)
          # Chart.yaml is stripped above only so a version-only bump is not asked to bump AGAIN. Its
          # OTHER fields — artifacthub.io/changes, appVersion — ship inside the .tgz like any template,
          # and editing them without a bump publishes nothing. So Chart.yaml still counts as a content
          # change unless the version line is the only thing that differs.
          if ! diff -q <(git show "$BASE:$CHART/Chart.yaml" 2>/dev/null | grep -v '^version:') \
                       <(grep -v '^version:' "$CHART/Chart.yaml") >/dev/null; then
            changed="$changed $CHART/Chart.yaml"
          fi
          changed=${changed# }
```

Reviewer-measured on all three cases: annotation-only → fails; version-only bump → passes; content +
bump → passes. The space-joined append works with the existing unquoted `printf '  %s\n' $changed`.

**Risk.** A `Chart.yaml` absent at `$BASE` makes `git show` print nothing, the diff non-empty, and the job
proceed with `was` empty — passing as "was bumped", same as today. Whitespace-only edits now demand a
bump, which is consistent with the `.tgz` digest changing.

> **Codex:** **FIX-INADEQUATE** — Process substitution is not the problem: this workflow has no `shell:`
> or `defaults.run.shell` override, GitHub documents an unspecified Linux shell as `bash -e {0}`, and the
> block itself enables `pipefail`; `diff -q <(...) <(...)` returned 0 under `/bin/bash` 3.2.57. See
> [GitHub's shell table](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsshell).
> The missed defect is base validation, and the stated Risk is wrong under Actions' inherited `-e`.
> Running the exact proposed block gave: empty `BASE` -> `fatal: bad revision ''`, then **exit 0** as “no
> chart content changed” (because `git show ":$CHART/Chart.yaml"` reads the index); nonexistent `BASE` ->
> exit 128; and the repository's root commit, where this `Chart.yaml` did not exist -> exit 128. The latter
> two die at `was=$(git show ... | awk ...)` under `-e -o pipefail`, not pass as “was bumped.” Validate
> that `BASE` is a non-empty commit before either diff, then handle an absent base-side `Chart.yaml`
> explicitly as chart creation without running the failing `git show` assignment. Only after that is the
> stripped `Chart.yaml` comparison safe and non-vacuous.

---

<a id="3"></a>
## 3. `CONTRIBUTING.md` and the script header promise a warning that no code implements

- **Severity**: medium
- **Location**: `CONTRIBUTING.md:71-74`; the same claim at `ci/act-local.sh:29-30`
- **Author**: the arbiter, in PR #38. This is a false claim I wrote.

**Claim.** `CONTRIBUTING.md` says of the two named weaknesses: "**both of which the script tells you
about**: `version-bump` compares **commits**, so a chart edit you have not committed is invisible to it;
and on the default branch the merge-base is `HEAD`…". Only the *second* is implemented (`VACUOUS_REASON`).
No code path inspects the working tree.

**Arbiter verification.**

```
$ sed -n '71p' CONTRIBUTING.md
   Two ways it is still weaker than the GitHub run, both of which the script tells you about:

$ grep -nE 'porcelain|uncommitted|dirty|git status' ci/act-local.sh
   (no output — only comments mention it)
```

Reviewer B additionally demonstrated it live in a clone: an uncommitted `values.yaml` edit, one commit
ahead of main so the merge-base warning cannot fire → `▶ version-bump ✅ pass`, no warning of any kind.

**Impact.** A contributor edits the chart, runs the local CI as step 4 instructs, sees green, and trusts
the doc's claim that this exact blind spot would have been flagged.

**Solution.** Implement the promised warning — it keeps every existing sentence true, rather than
weakening the docs. After `HEAD_SHA=` (`:221`):

```bash
# The header's FIRST weakness, detected so the summary can call it out as promised: version-bump
# compares COMMITS, so a chart edit still sitting in the working tree is invisible to it.
UNCOMMITTED_CHART="$(git status --porcelain -- charts/ 2>/dev/null || true)"
```

and after the existing `VACUOUS_REASON` block (`:377-381`), in the same idiom:

```bash
if [ -n "$UNCOMMITTED_CHART" ]; then
  case " ${JOBS[*]} " in
    *" version-bump "*)
      echo
      echo "⚠️  uncommitted changes under charts/ — version-bump compares COMMITS, so these were invisible to it:"
      printf '      %s\n' "$UNCOMMITTED_CHART" ;;
  esac
fi
```

`--porcelain` includes untracked files (`??`), equally invisible to a commit diff. The `if`-around-`case`
shape matches the existing block so `set -u` cannot trip on an empty array.

> **Arbiter note.** Reviewer B's version used `sed 's/^/      /' <<<"$UNCOMMITTED_CHART"`. `<<<` is a
> bashism that works in 3.2, but this file is deliberately 3.2-clean and uses `printf` elsewhere; the
> `printf` form above is preferred. **To confirm in the Codex pass: does `printf '      %s\n'` preserve
> multi-line porcelain output correctly, or does it need the `sed` form?**

**Risk.** None to job execution — print-only, after the pass/fail decision.

> **Codex:** **FIX-INADEQUATE** — Tested under macOS `/bin/bash` 3.2.57 with three porcelain lines. The
> proposed one-argument `printf` indented line 1 only; lines 2 and 3 began with `??` and `A` in column 1.
> A Bash-3.2-clean form that indents every line is
> `printf '%s\n' "$UNCOMMITTED_CHART" | sed 's/^/      /'`; the same test showed all three lines with the
> six-space prefix. There is a second incompleteness: the proposed block is after `:358-374`, so it is
> skipped whenever any selected job fails, recreating finding 6's control-flow bug. Capture the status
> after `HEAD_SHA` as proposed, but print this warning after the job loop and before the `FAILED` branch
> exits (or deliberately mirror it into both outcomes).

---

<a id="4"></a>
## 4. The rendered-script syntax check passes vacuously if the extraction matches nothing

- **Severity**: medium
- **Location**: `.github/workflows/ci.yaml:305-307` (zero-iteration loop); extraction at `:288-304`

**Claim.** The step writes matched scripts to `/tmp/scripts.txt`, then
`while read -r s; do bash -n ...; done < /tmp/scripts.txt`. The extraction matches only containers whose
`command` has ≥3 entries and starts with `*bash`/`*sh` (`:299`). If the chart ever changes how it writes
container commands — `args:` instead of `command:`, a two-entry `sh -c` with the body elsewhere — the
python matches zero scripts, the file is empty, the loop iterates zero times, and the step green-ticks
having syntax-checked **nothing**. The sibling step ("ConfigMap data is non-empty", `:267-269`) already
guards its own empty case; this one does not.

**Arbiter verification.**

```
$ sed -n '288,308p' .github/workflows/ci.yaml | grep -nE 'scripts.txt|while|-s |error'
  1:          python3 - <<'PY' > /tmp/scripts.txt
  18:          while read -r s; do
  20:          done < /tmp/scripts.txt
```

No `-s` guard between the write and the loop. Reviewer-measured: the current render extracts **7**
scripts, so zero is never a legitimate result here.

**Solution.** The same guard idiom the job's other step uses, in shell — the python's stdout is redirected
into `/tmp/scripts.txt`, so an `::error::` printed there would land in the file, not the log. Between
`:304` and `:305`:

```yaml
          # Zero extracted scripts is not a pass — it means the extraction above no longer matches how
          # the chart writes container commands, and nothing would be syntax-checked. Same rule as the
          # ConfigMap step: an empty input fails loudly instead of iterating zero times.
          if ! [ -s /tmp/scripts.txt ]; then
            echo "::error::no rendered Job/Pod script matched the extraction — the syntax check ran"
            echo "::error::against nothing. Update the command-matching in this step to fit the chart."
            exit 1
          fi
          while read -r s; do
            bash -n "/tmp/$s" && echo "  ok  rendered: $s"
          done < /tmp/scripts.txt
```

**Risk.** A values configuration legitimately rendering zero Jobs/Pods would now fail — but this step
always renders `crc-values.yaml` (`:260`), which ships 7 scripts and always enables hooks and tests, so
zero is always a defect here.

> **Codex:** **FIX-INADEQUATE** — The directed placement check passes: current rendering extracted 7
> scripts, and a zero-output Python heredoc followed by the proposed shell guard printed the `::error::`
> to the terminal while the redirected file remained 0 bytes. The guard is outside the redirection. What
> both passes missed is a second vacuous-success path in the same step: `:286` and `:306` use
> `bash -n ... && echo`. Under `bash -e`, a failing left side of `&&` is exempt from errexit. With an
> invalid script followed by a valid one, both the source-file `for` shape and rendered-script `while`
> shape printed the syntax error, continued, printed `SURVIVED`, and exited 0. Add the `-s` guard, but
> also put `bash -n "$f"` / `bash -n "/tmp/$s"` and their success `echo` on separate commands (or use an
> explicit `if/else`); otherwise any non-final bad script can still green-tick.

---

<a id="5"></a>
## 5. The release gate does not run `version-bump`, and the docs described it wrongly in both directions

- **Severity**: medium
- **Location**: `ci.yaml:151` (the gate), `ci.yaml:3-5` (overclaiming comment), `docs/RELEASING.md:159`
  (stale claim — **already fixed in PR #40**)

**Claim.** `version-bump` is gated `if: github.event_name == 'pull_request'`. When `helm.yaml` calls
`ci.yaml` via `workflow_call`, the `github` context — `event_name` included — is the **caller's**: per
GitHub's reusable-workflows reference, *"When a reusable workflow is triggered by a caller workflow, the
github context is always associated with the caller workflow."* `helm.yaml` triggers on `push` and
`workflow_dispatch`, so in the release path the `if` is false and the job is skipped. A skipped job does
not fail the called workflow, so `validate` succeeds and `release` runs.

**Arbiter verification** — measured on all three real events, not inferred:

| event | run | `version-bump` |
|---|---|---|
| `pull_request` | 31137859687 | **runs** |
| `push` to `main` | 31137979424 | skipped |
| `workflow_dispatch` | 31140558926 | skipped |

So the real guarantee is: **nothing reaches `main` through a PR without a bump.** A direct push to `main`
with an unbumped chart change passes standalone CI (skipped), passes the release gate (skipped), and
`chart-releaser` publishes nothing — all green. That is the incident mode `RELEASING.md`'s own table
records as having happened twice.

**Already done.** PR #40 rewrote `RELEASING.md:159` with the measured three-event table and qualified the
adjacent "cannot skip the checks even on a direct push" claim there.

**Still open — two options, owner's call.**

**Option A — make the gate real** (Reviewer B's proposal, two lines):

```yaml
  version-bump:
    name: Chart changes bump the chart version
    # Runs on pull_request AND push: helm.yaml's release gate calls this workflow from a push-to-main
    # context, and the github context — event_name included — is always the CALLER's, so a
    # pull_request-only gate silently drops this job from exactly the run that publishes.
    # workflow_dispatch has no diff base and stays skipped.
    if: github.event_name == 'pull_request' || github.event_name == 'push'
    ...
        env:
          # A PR diffs against its base; a push (including the release gate) against the previous head.
          BASE: ${{ github.event.pull_request.base.sha || github.event.before }}
```

**Option B — keep it PR-only** (relying on branch protection) and fix only `ci.yaml:3-5`'s overclaim.

> **Arbiter position, for Codex to attack.** I lean **B plus the comment fix**, and I want this
> challenged. Reasons: (i) Option A fires *after* merge, when the alarm cannot prevent anything — it only
> blocks the release, which `skip_existing` already makes a no-op; (ii) `github.event.before` is
> unreliable — unreachable after a force-push, and all-zeroes on a branch's first push — so the job would
> pass vacuously in exactly the cases a push-path guard is for, reintroducing finding #4's shape; (iii)
> every change in this repo arrives by PR, where the gate already works. **Codex: is (ii) accurate for
> `github.event.before` on a merge-commit push to a protected branch? And does Option A create a
> two-racing-PRs failure that Option B does not?**

> **Codex:** **CONFIRMED** — Choose Option B, but not for the arbiter's original reason (ii). GitHub
> defines push `before` as the tip of the updated ref before the push and `after` as its tip afterward,
> and exposes separate `created` and `forced` flags; for an ordinary merge-commit push to an existing
> `main`, `before` is therefore the correct pre-merge base. See the official
> [push payload](https://docs.github.com/en/webhooks/webhook-events-and-payloads#push). A newly created ref
> does use the all-zero object ID because no prior tip exists (GitHub identifies this case with
> `created: true` and documents a separate
> [new-branch diff rule](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#git-diff-comparisons)),
> but the already-existing `main` cannot have a “first push.” A force push can make `before`
> non-ancestral and potentially absent from a fresh checkout; “is unreachable” was too categorical, and
> it is immaterial here because GitHub
> [blocks force pushes on protected branches by default](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches#allow-force-pushes).
> Given the new facts — PRs required, admins enforced, the named job required, a measured GH006 rejection,
> and `strict: true` — B now has an actual enforced premise. GitHub defines `strict` as requiring the PR
> branch to be up to date before merge
> ([API reference](https://docs.github.com/en/rest/branches/branch-protection#update-branch-protection)),
> so two PRs that both chose the same version cannot race through: after the first merge, the second must
> update and its required version-bump check reruns against the new base. Option A does not create a novel
> racing-PR failure; without strictness its post-merge failure would correctly catch the collision. It is
> now redundant post-merge defense with extra base edge cases, so keep the job PR-only and fix only
> `ci.yaml:3-5`'s overclaim. Revisit A only if PR/admin enforcement or the required check is relaxed, and
> then land finding 2's explicit base validation first.

---

<a id="6"></a>
## 6. The `VACUOUS_REASON` remedy is only printed on the all-pass path, which an empty base can never reach

- **Severity**: medium
- **Location**: `ci/act-local.sh:377-381` (only printer); `:358-374` (failure path, exits first);
  `:225-227` (the reason being lost)

**Claim.** With no merge-base — shallow clone, unrelated history, or a typo'd `ACT_BASE_REF` — `:226`
composes exactly the right diagnosis *including the remedy*. But that state **guarantees** version-bump
fails: the payload carries `"sha":""`, `git diff --name-only "" HEAD` prints `fatal: bad revision ''`, and
the fatal-detector correctly fails the job. The failure path exits at `:373`, before the printer at
`:377`. So the one line naming the cause and the fix is computed and then discarded, in the only scenario
where it matters.

**Arbiter verification.**

```
$ ACT_BASE_REF=does-not-exist ./ci/act-local.sh version-bump
🌿 diffing against does-not-exist (none) for version-bump
▶  version-bump   ❌ FAIL   …   (act exited 0, but git failed inside the job)
[CI/…]   | fatal: bad revision ''

$ … | grep -c 'Pass one: ACT_BASE_REF'
0        # the remedy is computed but never printed
```

**Impact.** The verdict is right; the diagnosis is wrong by omission. The user sees a bare
`fatal: bad revision ''` and starts debugging git-in-a-container, when the script knew the cause and the
one-line remedy before launching a container. On a shallow clone this hits the default invocation.

**Solution.** Mirror the existing printer into the failure path, keyed on `FAILED`, before `exit 1`:

```bash
  # An empty base sha CAN only fail: version-bump's git diff dies on it and the fatal: detector
  # (correctly) reports the job. The reason — and the ACT_BASE_REF remedy — was computed at payload
  # time; without this it would only ever print after "all passed", which this state never reaches.
  if [ -n "$VACUOUS_REASON" ]; then
    case " ${FAILED[*]} " in
      *" version-bump "*) echo; echo "⚠️  $VACUOUS_REASON" ;;
    esac
  fi
  exit 1
```

Changes no verdict, no exit code, and no output on any run where version-bump did not fail or the reason
is empty.

> **Codex:** **CONFIRMED** — `ci/act-local.sh:358-374` unconditionally exits before the only current
> printer at `:377-381`, and finding 2's proposed comparison does not remove this trigger: with empty
> `BASE` its first `git diff` still emitted `fatal: bad revision ''`, which the local runner's `:345`
> detector classifies as failure. The missed interaction is finding 3: adding its new warning after
> `:381` would put a second diagnostic behind the same exit. Apply the two reporting fixes together by
> placing both conditional notices after the job loop and before the failure branch, or mirror both
> deliberately. Finding 1 changes only whether broken-podman preflight reaches its existing `die`; it
> does not change this post-job control flow.

---

<a id="7"></a>
## 7. The bare-chart-path check cannot match the barest forms: `helm <lint> .`, `helm <template> . -f …`

- **Severity**: low
- **Location**: `.github/workflows/ci.yaml:386`

**Claim.** The pattern requires a `[[:space:]]` before the dot *in addition to* the space after the
subcommand — i.e. at least one argument between them. `helm <lint> .` (the canonical lint invocation; lint
takes no release name), `helm <template> .`, and `helm <template> . -f values.yaml` are structurally
unmatchable. So a doc could reacquire a bare chart path in precisely the form most likely to be written,
with green CI.

**Arbiter verification** — control table, old pattern vs proposed:

```
  helm <lint> .                        old=0 new=1
  helm <template> .                    old=0 new=1
  helm <template> . -f values.yaml     old=0 new=1
  helm <install> rel .                 old=1 new=1
  helm <upgrade> rel ..                old=1 new=1
```

**Solution.** Make the segment between subcommand and path optional (`ci.yaml:386`):

```yaml
          # The segment between the subcommand and the path is OPTIONAL: `helm <lint> .` has no
          # release-name argument at all, and the old mandatory `.*[[:space:]]` made that form — the
          # likeliest way a bare path comes back — structurally unmatchable.
          hits=$(grep -rnE 'helm (install|upgrade|template|lint) (.*[[:space:]])?\.{1,2}([[:space:]]|\\|$)' \
                   --include='*.md' --include='*.yaml' --include='*.txt' --include='*.sh' . \
                   | grep -v '^\./\.git' || true)
```

**Risk.** Prose ending in a standalone ` . ` right after a helm subcommand could now match;
reviewer-measured zero such lines repo-wide, so no false positives on the current tree. **Codex: re-run
that repo-wide check — it must still hold after PR #40 added new `helm` commands to `RELEASING.md`.**

> **Codex:** **FIX-INADEQUATE** — The exact proposed grep on the current working tree produced **7 hits**,
> all in this document at lines 382, 389, and 396-400 before this markup; excluding only the currently
> untracked `docs/FINAL_REVIEW.md` produced 0, so PR #40's `RELEASING.md` commands add no hit. Thus “zero
> repo-wide” is no longer true, although GitHub CI sees the seven only if this report is committed. The
> regex also still misses ordinary whitespace variants: tested results were `helm <lint> .`=1,
> `helm  lint .`=0, tab-separated `helm<TAB>lint .`=0, and a backslash-newline split=0. Use
> `[[:space:]]+` around the subcommand instead of literal single spaces, and before committing this report
> rewrite its illustrative bad commands so the subcommand and `.` are not one executable-looking string
> (excluding an entire review file would create a needless blind spot). The optional argument segment is
> still the right core correction, but it cannot be applied as written to the current tree.

---

<a id="8"></a>
## 8. `url-guard` misses raw url reads through a variable alias

- **Severity**: low
- **Location**: `ci/url-guard.py:13`

**Claim.** `RAW` matches `.Values.groupSync.url` and bare context-relative `.url`, but not a read via an
intermediate variable. `{{ $gs := .Values.groupSync }}{{ $gs.url }}` — a natural refactor when a template
reads several `groupSync` keys — reintroduces the exact bug class the guard exists to stop (the raw-url
read that `helm template` cannot catch offline) and passes.

**Arbiter verification.**

```
  old=True   new=True    {{ .Values.groupSync.url }}
  old=False  new=True    {{ $gs := .Values.groupSync }}{{ $gs.url }}      <-- bypass
  old=True   new=True    {{ with .Values.groupSync }}{{ .url }}
```

**Solution.** Add a third alternative for variable-rooted chains (`ci/url-guard.py:13`):

```python
# $var-rooted chains too: {{ $gs := .Values.groupSync }}{{ $gs.url }} is the same raw read through an
# alias, and the two forms below cannot see it.
RAW = re.compile(r'\.Values\.groupSync\.url\b|(?<![\w.])\.url\b|\$\w+(?:\.\w+)*\.url\b')
```

Reviewer-validated: 0 problems on the clean tree (no false positives), and the alias case fails with the
standard message.

**Risk.** A future template legitimately reading a *non-groupSync* object's `.url` through a variable
would be flagged; none exists today, and such a read would deserve the same scrutiny. The allowed-defines
mechanism is the existing escape hatch.

> **Codex:** **FIX-INADEQUATE** — Applying the proposed regex in memory and running
> `main('charts/group-sync-operator-helm')` produced `PASS url-resolver-guard (0 problem(s))`, so it has no
> current-template false positive and it catches `$gs.url`. It does not close the bypass class. Through
> the real `actions()` parser, `{{ index .Values.groupSync "url" }}` and
> `{{ get $gs "url" }}` each produced 0 regex hits, while a multi-line action containing the original raw
> `.Values.groupSync.url` produced **0 parsed actions** because `actions()` applies `{{(.*?)}}` one line at
> a time (`ci/url-guard.py:18-21`). The fix must cover `index`/`get` URL access and parse actions across
> newlines (with line numbers and comment exclusions preserved), not merely add the dotted-variable
> alternative. Add those three bypasses as regression cases; the existing allowed-define escape hatch
> contains any intentional false positive.

---

## Directed follow-up (known, not a discovery): the PyYAML dependency

`ci.yaml`'s `docs` and `test-scripts` jobs `import yaml` (`:262, :289, :320`) without installing it,
relying on the runner image; `render-matrix` installs it explicitly at `:33`. The minimal fix is to
declare it the same way — add `- run: pip install --quiet pyyaml` to both jobs. On GitHub it is a fast
no-op; it turns an undeclared assumption into a declared one and makes `act-local.sh`'s custom image a
convenience rather than load-bearing (its `PIP_BREAK_SYSTEM_PACKAGES=1` must stay, or the in-job install
hits PEP 668 locally).

Reviewer B inventoried every other tool both workflows invoke — helm (via `azure/setup-helm` in each job
that calls it), git, python3, pip, bash, awk/grep/sed — and reports **PyYAML is the only undeclared
runner-image dependency** in either workflow.

---

## Checked and found sound

Recorded because it tells the arbiter what is already trustworthy.

**`ci/act-local.sh`** — the `fatal:` detector end to end in both directions against act 0.2.89's real
rendering (the `]   | ` three-space prefix is byte-correct; no legitimate step line in these five jobs
begins with `fatal: `); bash 3.2 compatibility including the empty-array-under-`set -u` landmine at every
`[@]` site; argument parsing (unknown job, empty string, unknown option, repeated job); `--help` and path
anchoring from three directories; the DANGLING_HEAD guard's `check-ignore` premise (`.gitignore:30 tmp/`
does match `.git/refs/heads/tmp/x`; `refs/heads/main` does not), plus its detached-HEAD, packed-ref and
worktree behaviour; runtime-detection consistency including `CONTAINER_BUILDER=frobnicate`, `tcp://`/`ssh://`
hosts, and multiple podman machines; the mktemp/trap hygiene; BSD vs GNU flags on every external command.

**Workflows** — the README-parameter check (34 rows, 0 mismatches; zero rows currently rely on its
lenient substring branch); `render-matrix`'s `must_render`/`must_fail` shift arithmetic and all 9 check
names existing in `render-checks.py`; the chart job's explicit zero-file guard; `version-bump`'s PR-event
semantics with `fetch-depth: 0`; `helm.yaml`'s release plumbing (`charts_dir` default matching the chart
location, `skip_existing` + `packages_with_index` pairing, `needs: validate`, `contents: write`); and every
`ci.yaml` line number cited in `act-local.sh`'s comments (`:151`, `:262/289/320`, `:33`) — all accurate,
no drifted citation.

**One hypothesis explicitly retracted** by Reviewer B: `source-secret-rbac` appeared vacuous on a first
`grep -c`, but a second pass with the check's actual regex showed the probe line *is* matched (rendered
line 2083). The zero was a BSD-grep artifact of the reviewer's own command.

**One oddity weighed and left below the bar**: `docker context inspect --format '{{.Endpoints.docker.Host}}'`
prints the literal `<no value>` and exits 0 for a context missing that key, so such a context would export
`DOCKER_HOST="<no value>"`. No normal CLI flow produces one, and the next docker/act call would die
immediately and loudly.

---

## Codex pass

Codex GPT-5.6 at highest effort: append your markers **inline** under each finding as
`> **Codex:** …`, and add a `## Codex — additional findings` section at the end for anything new. Attack
in particular the two questions marked for you above (finding 3's `printf` vs `sed`, finding 5's
`github.event.before` reliability and the Option A/B choice), and the arbiter's verification method
anywhere it looks thin. Do not re-raise anything on the out-of-scope list.

## Codex — additional findings

### C1. Both syntax loops can mask a failing non-final script

- **Severity**: medium
- **Location**: `.github/workflows/ci.yaml:285-287,305-307`
- **Claim**: `bash -n ... && echo` suppresses errexit for `bash -n` because it is the non-final command of
  an AND-list. The loop then continues, and a later valid script makes the loop and step return 0.
- **Trigger**: Any source or rendered script with invalid Bash syntax that sorts before at least one valid
  script. The current render has seven scripts, so “non-final” is the common position, not an edge case.
- **Evidence**: Under `/bin/bash -e -o pipefail`, both the workflow's `for`-loop shape and its `while`-loop
  shape were fed invalid `if` followed by valid `:`. Each printed `syntax error: unexpected end of file`,
  then `SURVIVED ... loop`, and exited 0. Splitting `bash -n -c "$body"` and `echo` into separate commands
  stopped immediately with status 2. The real current extraction returned seven named scripts.
- **Impact**: The step can claim “Shell syntax” passed despite visibly detecting invalid syntax; only a bad
  final script reliably controls the step status.
- **Solution**: In both loops, make `bash -n` its own command and put the success `echo` on the following
  line. The existing `set -euo pipefail` then does the intended work. Apply this with finding 4's `-s`
  guard.
- **Risk**: None beyond turning a previously masked syntax error into the intended red check.

### C2. The URL guard still has parser-level and accessor-level blind spots

- **Severity**: low
- **Location**: `ci/url-guard.py:13,16-27`
- **Claim**: Adding `$var.url` to `RAW` covers only one spelling. Helm permits function access (`index`,
  `get`) and multi-line template actions; neither reaches the proposed regex through the current parser.
- **Trigger**: `{{ index .Values.groupSync "url" }}`, `{{ get $gs "url" }}`, or a `{{ ... }}` action whose
  raw URL expression is on a different line from one or both delimiters.
- **Evidence**: With the proposed regex installed in memory, the current chart returned 0 problems and the
  dotted alias test returned one hit. The direct `index` and aliased `get` cases returned 0 hits; the
  multi-line direct read returned `actions=0`, proving the loss occurs before regex matching.
- **Impact**: A natural template refactor can still reintroduce the raw/resolved URL split while the guard
  reports PASS.
- **Solution**: Parse `{{ ... }}` actions over the complete file with DOTALL while deriving the starting
  line number, retain the existing YAML/template-comment exclusions, and extend the guarded forms to
  `index`/`get` reads of `"url"`. Add all three demonstrated bypasses as tests before relying on the wider
  regex.
- **Risk**: Function-form reads through unrelated variables may add false positives. The current chart has
  zero, and `ALLOWED_DEFINES` is already the local exception mechanism.

### C3. The fixes have a required integration order

- **Severity**: medium
- **Location**: `ci/act-local.sh:85-147,219-230,345-381`; `.github/workflows/ci.yaml:149-179,284-307,378-394`;
  `ci/url-guard.py:13-27`; `docs/FINAL_REVIEW.md`
- **Claim**: These patches are not independent. Applying them mechanically in finding order can leave the
  local verifier unable to reach later diagnostics, install finding 3 behind finding 6's exit, or make the
  docs job reject this review before the other fixes can be verified.
- **Trigger**: Partial application, especially #3 without coordinating #6, #7 while this report's seven
  command examples remain in the checked tree, or Option A from #5 before #2 validates a push base.
- **Evidence**: The current preflight exits 125/0 bytes before any job; both proposed notices target the
  `:358-381` split; the proposed #7 grep returned seven hits in this report; and the proposed #2 logic
  returned 0 on empty `BASE` and 128 when the base-side chart was absent.
- **Impact**: An individually plausible patch series can still be silent locally, red in docs CI, or
  vacuous on a newly added event path.
- **Solution**: Apply and verify in this order: (1) #1, so local runs fail loudly; (2) #2's content check
  **with** explicit base validation, while retaining #5 Option B; (3) #3 and #6 together, printing both
  notices before the failure exit and using the tested `printf | sed`; (4) #4 plus C1; (5) #7 with flexible
  horizontal whitespace and this report's examples neutralized if it will be committed; (6) #8 plus C2.
  Then run the proposed grep, `python3 ci/url-guard.py charts/group-sync-operator-helm`, `helm lint`, the
  render/syntax step, and one real `act-local.sh` job.
- **Risk**: None; this changes sequencing and verification only, not architecture.
