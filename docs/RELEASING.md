# Releasing the chart

## The one thing that catches people

**A green release run does not mean anything was published.**

`chart-releaser` is configured with `skip_existing: true`. If `Chart.yaml`'s `version` is one that has
already been published, it skips the upload, exits 0, and the Actions run shows a green tick. Nothing
went wrong; nothing went out either.

So the rule is:

> **The `Chart.yaml` version bump IS the release trigger.** Merging chart changes without bumping it
> publishes nothing, and tells you it succeeded.

This has happened twice in this repo:

| when | what changed | what shipped |
|---|---|---|
| PRs #14–#18 merged | five fixes, one of them a security fix (a test ServiceAccount could read every Secret in the cluster) | nothing — `Chart.yaml` stayed at `0.3.0`, which was already published |
| PRs #21–#22 merged | two more chart fixes | nothing — `Chart.yaml` stayed at `0.4.0` |

In both cases every Actions run was green and `helm repo update && helm install` kept serving the old
chart, security fix and all.

---

## The process

### 1. Test it, on a real cluster

Offline checks first — these are what CI runs, so failing them locally saves a round trip:

```bash
CHART=charts/group-sync-operator-helm

helm lint "$CHART" -f "$CHART/crc-values.yaml"

# every shipped values file must render, EXCEPT any marked `# requires-cluster: true`,
# which must fail with "no LDAP url could be derived"
for f in "$CHART"/*-values.yaml "$CHART"/environments/*.yaml; do
  helm template release "$CHART" -f "$f" > /dev/null && echo "ok $f"
done

# base values alone MUST fail — groupSync.url has no default on purpose
helm template release "$CHART" 2>&1 | grep 'no LDAP url could be derived'

# the test scripts must ship with content. .helmignore once hid the directory they load from,
# so .Files.Get returned empty, both scripts shipped as 0 bytes, and every suite passed
# without executing a line while the directory was in CrashLoopBackOff
helm template release "$CHART" -f "$CHART/crc-values.yaml" \
  | grep -A5 'test-scripts' | head -20

bash -n "$CHART"/files/*.sh
```

Then install it somewhere real and run the suite. `helm template` cannot catch an RBAC grant that is
missing at runtime, a Job that never completes, or a CA that does not verify:

```bash
helm upgrade --install group-sync "$CHART" -n group-sync-operator --create-namespace \
  --reset-values -f <your-values.yaml> --timeout 12m
helm test group-sync -n group-sync-operator --logs
```

`--reset-values` matters: without it `helm upgrade` reuses the previous revision's user-supplied values,
so a value you stopped passing keeps applying and you are not testing what you think you are.

If the change touches the CA path, exercise more than one mode — the three are genuinely different code
paths (`crc-values.yaml` copies the CA, `crc-injected-values.yaml` uses OpenShift trust injection,
`sample-values.yaml` discovers everything from the cluster's OAuth CR).

### 2. Choose the version

| bump | when | example |
|---|---|---|
| **patch** `0.4.0` → `0.4.1` | the change makes a broken configuration work, and alters nothing anyone was relying on | `helm test` could not pass at all on a discovery-based install; now it can |
| **minor** `0.3.0` → `0.4.0` | behaviour changes for someone whose config you did not touch | a test suite that was always green can now legitimately fail; seven `rfc2307` values that were silently discarded now take effect |
| **major** | a values key is removed or renamed, or a default changes what gets deployed | — |

The test that separates patch from minor: **could this turn someone's working pipeline red, or change
what their cluster runs, without them editing anything?** If yes, it is at least a minor.

### 3. Bump `Chart.yaml` and write the changelog

```yaml
version: 0.4.1        # <- the release trigger
appVersion: "1.1"     # <- only when the OPERATOR version changes, not the chart's
```

Add an `artifacthub.io/changes` entry per change. Valid `kind` values are `added`, `changed`,
`deprecated`, `removed`, `fixed`, `security` — anything else is silently dropped by Artifact Hub.

```yaml
annotations:
  artifacthub.io/changes: |
    - kind: fixed
      description: One sentence, in terms of what the user sees.
```

Two conventions worth keeping:

- **Prefix behaviour changes with `BEHAVIOUR:`.** It is the difference between someone reading the entry
  before upgrading and finding out from a red pipeline afterwards.
- **Do not drop the previous release's entries on a patch.** Artifact Hub shows only the *current*
  release's list, so someone jumping 0.3.x → 0.4.1 would never see the 0.4.0 behaviour changes at all.

Check it parses before pushing — a malformed annotation is accepted by `helm lint` and then shows up as
nothing:

```bash
python3 -c "
import yaml
d = yaml.safe_load(open('charts/group-sync-operator-helm/Chart.yaml'))
ch = yaml.safe_load(d['annotations']['artifacthub.io/changes'])
valid = {'added','changed','deprecated','removed','fixed','security'}
print(d['version'], len(ch), all(e.get('kind') in valid for e in ch))
"
```

### 4. PR, merge, and then **verify it published**

Do not trust the green tick. Confirm the artifact exists:

```bash
helm repo update
helm search repo group-sync-operator-helm --versions | head

curl -s https://ephico2real2.github.io/group-sync-operator-helm-chart/index.yaml \
  | grep -E 'version:|created:'
```

The new version must appear in both. If the run was green and the version is absent, the cause is almost
always that `Chart.yaml` was not bumped.

---

## When the version is merged but not published: republishing

The release run and the merge are separate things. A merge can land on `main` while the release run
fails, or never starts — a GitHub Actions incident, a runner that dies in `Set up job`, an expired token.
`main` then carries a version that no consumer can install, and nothing on the PR or on `main` says so.

**This does not need a commit, an empty commit, or a re-bump.** `helm.yaml` carries a
`workflow_dispatch` trigger for exactly this:

```bash
gh workflow run helm.yaml --ref main
```

It re-runs `validate` (the whole of `ci.yaml`) and then `chart-releaser` against whatever `Chart.yaml`
on `main` currently says. Because `skip_existing: true` is set, running it when nothing is outstanding is
harmless — it publishes nothing and exits 0. So it is safe to reach for whenever you are unsure.

Then **verify, rather than trusting the green tick** — the same discipline as step 4, and for the same
reason. A release run reports success both when it published and when it skipped:

```bash
gh run list --workflow helm.yaml --limit 1

# what a CONSUMER sees, which is the only thing that matters
helm repo add gso https://ephico2real2.github.io/group-sync-operator-helm-chart
helm repo update gso
helm search repo gso/group-sync-operator-helm --versions | head -3
helm pull gso/group-sync-operator-helm --version <the-version>
```

Two checks worth doing beyond "the version appears":

- **`index.yaml` is served from `gh-pages` via GitHub Pages, so there is a second run after the release
  one.** The release can succeed while the `pages build and deployment` run is still going, and until it
  finishes `helm repo update` keeps serving the old index. Wait for it before concluding anything failed.
- **Compare the digest.** `index.yaml`'s `digest` for the version against `shasum -a 256` of the tarball
  you pulled. Equal means the index and the artifact agree; that is the end-to-end proof, and it is the
  one check that would catch a half-written index.

Recorded because it happened: `0.11.0` was merged on 2026-08-06 during a GitHub Actions `major_outage`.
The `Release Charts` run died in `Set up job`, `index.yaml` stayed at `0.10.0`, and the cluster ran a
chart no one else could install. `gh workflow run helm.yaml --ref main` published it once Actions
recovered — no commit, no version change.

---

## What the automation does, and does not

`.github/workflows/helm.yaml`:

- triggers on push to `main`, filtered to `paths: ['charts/**']` — so a docs- or script-only merge
  correctly does not attempt a release
- also on `workflow_dispatch`, which is how you republish without a commit — see the section above
- runs `validate`, which *calls* `ci.yaml` rather than duplicating it, so a release cannot skip the
  checks even on a direct push. One job is the exception, and it matters — see the version-bump note below
- then `chart-releaser-action@v1.6.0` with `skip_existing: true` and `packages_with_index: true`

Things worth knowing:

- **`charts_dir` defaults to `charts`.** This is why the chart lives at
  `charts/group-sync-operator-helm`. While it sat at the repo root the action found nothing to package
  and published nothing.
- **`gh-pages` is machine-owned.** `index.yaml` and the `.tgz` files there are written by
  chart-releaser. Never hand-edit it, and never delete the branch — **`index.yaml` *is* the Helm
  repository**. Deleting it unpublishes every version at once.
- **`*.tgz` must not be in `.gitignore`.** chart-releaser stages the packaged chart with `git add` on
  `gh-pages`; an ignore rule makes the release fail. The repo ignores `.cr-release-packages/` instead.
- **A release can be forced without a commit** via `workflow_dispatch`, which is useful after bumping
  only `Chart.yaml` or retrying a transient failure.
- **A build DOES now fail for a missing version bump — but only on a pull request.** `ci.yaml`'s
  `version-bump` job (the fix for the two incidents above, adversarial-review finding #20) is gated on
  `if: github.event_name == 'pull_request'`, and it diffs against
  `github.event.pull_request.base.sha` — a value that exists in no other event. Measured across the three
  events on 2026-08-06:

  | event | `version-bump` |
  |---|---|
  | `pull_request` | **runs** — chart content changed with no bump fails the check |
  | `push` (a merge landing on `main`) | skipped |
  | `workflow_dispatch` (republishing) | skipped |

  So the real guarantee is: **nothing reaches `main` through a PR without a bump.** A direct push to
  `main`, or a `workflow_dispatch` republish, is not checked — for the republish that is correct, since
  the version is deliberately unchanged. What this means in practice: if branch protection is ever off and
  someone pushes to `main` directly, step 4 is again the only thing standing between a merged fix and a
  silently unpublished one.

## Quick checklist

```
[ ] offline checks pass (lint, every values file renders, base values fails, scripts non-empty, bash -n)
[ ] installed on a real cluster and `helm test` green
[ ] more than one CA mode exercised, if the change touches the CA path
[ ] Chart.yaml version bumped   <- without this, nothing publishes
[ ] artifacthub.io/changes entry per change, BEHAVIOUR: prefixed where it applies
[ ] previous release's entries retained on a patch
[ ] annotation parses, kinds valid
[ ] merged, and the new version CONFIRMED present in `helm search repo` and index.yaml
[ ] if it is absent: `gh workflow run helm.yaml --ref main`, then confirm again — no commit needed
```
