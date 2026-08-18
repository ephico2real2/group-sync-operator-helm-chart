# Review — provenanceRelabel (chart 0.12.2, uncommitted)

**Reviewer: Fable 5. Arbiter: Claude.** Fable writes findings here. Claude accepts or rejects each one
against the use case below, and only ACCEPTED items get implemented.

## The use case, so a finding can be judged against it

This chart installs the redhat-cop group-sync-operator via OLM and creates GroupSync CRs. The operator
stamps every Group it syncs with
`group-sync-operator.redhat-cop.io/sync-provider=<groupsync-cr-name>_<provider-name>`, and **it rewrites a
Group only when that Group's LDAP membership changes**.

So renaming a `customGroupSyncs` item renames its CR — Helm deletes the old, creates the new — and every
Group it synced keeps the OLD name in that label. Measured on this cluster: **22 of 66 Groups**, and a
forced sync via `setup-local-ldap-testing/60-force-groupsync.sh` did not move them (it reported a fresh
`lastSyncSuccessTime` while the sample Group's `sync-time` stayed put).

The new feature repairs that: a **declared** rename (`groupSync.previousNames`, or an item's
`previousNames`) drives a post-upgrade hook Job that rewrites the label value.

**The constraint everything turns on: the label KEY is load-bearing, the VALUE is not.**

- Every RBAC-granting selector matches the key with `operator: Exists` and narrows by the Group's *name* —
  verified across the sibling repo's `11-baseline-groupconfig-rbac.yaml:85`,
  `13-custom-groupconfig-rbac.yaml:91` and six reference policies. Nothing matches the value.
- **Removing the key revokes access.** The GroupConfig stops matching and the `groupconfig-controller`
  finalizer deletes the ClusterRoleBindings it created. No Kyverno rule mutates Groups, so nothing re-adds
  it.
- What a stale VALUE breaks is attribution **and alerting**: the dashboard rebuilds `<cr>_<provider>` and
  compares (`gsd/poller.py:69`), so a mismatched value means the Group is credited to no CR
  (`store.py:2438`) and its stale-group alert cannot fire (`state.py:307`).

**Constraints on any proposed fix — a finding that violates these is out of scope:**

1. **The bash must be readable by a junior/mid-level DevOps engineer.** Plain `for` loops, `cut`, arrays
   with an index. No `IFS` juggling, no herestring parsing, no clever parameter expansion. This was an
   explicit instruction and a first draft was rewritten for it.
2. **The mapping is DECLARED, never inferred.** Do not propose deriving the new owner from a CR's LDAP
   filter or from group-name patterns. Nothing on the cluster records that one CR succeeded another, and
   two CRs can match one Group.
3. **No heredocs in `files/*.sh`.** The script ships through `.Files.Get … | indent 4`, which indents every
   line including a heredoc terminator, so the terminator stops terminating.
4. **Never remove the label key, and never gain a `delete` verb.** See above.
5. **Chart conventions are CI-enforced**: README `| Parameter | Description | Default |` rows must match
   values.yaml, any change under `charts/` needs a Chart.yaml version bump, `files/*.sh` are `bash -n`'d
   and must be ≥500 bytes.
6. **Comments say WHY, not WHAT**, and must keep every measured number.
7. **Already-accepted trade-offs are not findings**: the ClusterRole can patch any Group (narrowed by the
   script's runtime ownership guard, the same bargain `01.7-installplan-approver.yaml` makes with `patch
   installplans`), and the feature renders nothing at all unless a rename is declared.

## Files in scope

```
charts/group-sync-operator-helm/files/relabel-provenance.sh              the logic
charts/group-sync-operator-helm/templates/01.9-provenance-relabel-*.yaml configmap, rbac, job
charts/group-sync-operator-helm/templates/_helpers.tpl                   provenanceRenames, provenanceRelabelEnabled
charts/group-sync-operator-helm/values.yaml                              provenanceRelabel, previousNames
charts/group-sync-operator-helm/crc-values.yaml                          the two declared renames
charts/group-sync-operator-helm/Chart.yaml                               0.12.2 + changelog
README.md, setup-local-ldap-testing/README.md                            selector fixes
```

## What is already verified — challenge it, don't redo it

- The script against a stub `oc`, 10 scenarios: empty RENAMES exits 0; malformed pair fails; non-numeric
  LIMIT fails before anything; an old CR that is still live is skipped; a new CR that is not live fails;
  dry run makes **zero** `oc label` calls; apply makes exactly one per Group; the cap aborts with zero
  calls; a failed CR list aborts rather than reporting "nothing to do"; a failed `oc label` exits non-zero.
  Also: a Group owned by a live CR was not touched, multi-provider CRs produce one value per provider, and
  **zero** label removals were ever emitted.
- The rendered ConfigMap script is byte-identical to the source and passes `bash -n`.
- With no rename declared, **0** objects render. With renames declared, all five render at wave 2 / wave 4
  and hook weight 7.
- `oc label … --overwrite` issues **GET then PATCH** (measured `-v=6`), so the ClusterRole carries `get` on
  groups. This was found and fixed during implementation — it is the same missing-verb shape that made a
  sibling chart's sweeper delete healthy RoleBindings this morning.

## Claims to verify — one verdict each: CONFIRMED / REFUTED / FIX-INADEQUATE

Prefer **refutation**. "Cannot refute" is fine only if you say what you actually checked.

**The script — `files/relabel-provenance.sh`**

- **S1** Any REMAINING place where an error, an empty result, or a missing field becomes a decision. The
  missing-`get` bug above is this shape and it was found late; assume there is another. Include
  `grep -qxF` against an empty `LIVE_CRS`, the `$(oc …)` captures, and what happens if `oc` prints a
  warning on stderr with rc=0.
- **S2** **The ownership guard.** Construct a case where a Group that a LIVE CR owns gets relabelled, or
  where a Group is relabelled to a value naming a CR that does not own it. Consider a declared
  `previousNames` entry that equals another item's current `name`, and two items declaring the same
  previous name.
- **S3** **Word splitting and injection.** `for pair in ${RENAMES//,/ }`, `for provider in $PROVIDERS`,
  `for group in $MATCHED` all rely on names having no spaces. Can a values file put something in
  `previousNames` that injects an extra argument into `oc label`, or that breaks the loop? Say whether Helm
  quoting (`| quote` on the env value) closes it.
- **S4** **The cap.** Is `TOTAL` right when two mappings or two providers touch the same Group? Can a Group
  be relabelled twice in one run, or counted twice against `limit`?
- **S5** **Idempotence and re-run safety.** A second run after a successful one, and a run where some
  Groups are already correct. Does anything relabel a Group to the value it already has?
- **S6** Exit codes and the summary. After a partial failure, does the final log state something a reader
  would misbelieve?

**The templates**

- **T1** Can the Job ever render without its ConfigMap or ServiceAccount, or land before them — under plain
  Helm **and** under ArgoCD, where the ConfigMap/RBAC are wave 2 and the Job is a wave-4 Sync hook? The
  chart's Application sets `prune` and `selfHeal`.
- **T2** Hook weight 7 against the existing ladder (`-1` approver, `0` operator-wait, `5` extraction, `6`
  CA, `10`/`20` tests). Is anything the Job depends on not finished by 7? Is the Argo annotation set
  consistent with the other four Jobs?
- **T3** RBAC minimality and sufficiency, now that `get` is in. Is any granted verb unused, and is any
  needed verb still missing? Check what `oc get groups -l`, `oc get groupsync <name>` and `oc label` each
  actually require.
- **T4** `provenanceRenames` and `provenanceRelabelEnabled` in `_helpers.tpl`: a values shape that makes
  them disagree, produce a malformed `RENAMES`, or render the Job while `RENAMES` is empty. Disabled items,
  `customGroupSyncs.enabled: false` with items present, `groupSync.enabled: false`, `previousNames` set to
  a string rather than a list.

**Values, docs, changelog**

- **V1** Anything in the new values comments, README table or Chart.yaml entry that is **factually wrong**,
  overstated, or would go stale. Every measured number should be checkable.
- **V2** Anything a reader would still get wrong about renaming after this change — including whether the
  hazard is documented where someone actually renames an item.

## Required form for every finding

````
> **Fable:** S1 — CONFIRMED
> **Where:** file:line or symbol
> **Trigger:** the concrete values/state/sequence, not "could race"
> **Consequence:** what a reader of the Job log or `oc get` would believe that is false
> **Fix (complete, ready to apply):**
> ```bash
> # the whole replacement block, in the same readable style, comments preserved
> ```
> **Proof:** the command you ran and its output
````

Then Claude appends `**Claude: ACCEPT**` or `**Claude: REJECT** — reason`.

Measure rather than reason: `helm lint`, `helm template`, the stub-`oc` harness at
`/private/tmp/claude-501/-Users-olasumbo-gitRepos-group-sync-dashboard/325dfd2f-469e-4bd4-b279-331704911184/scratchpad/relabel-harness/`
(a `bin/oc` stub plus fixtures in env vars), and read-only `oc` against the live CRC cluster. **Do not write
to the cluster**: no `oc label`/`apply`/`patch`/`delete`, no `helm install`/`upgrade`. Use
`--dry-run=server` and `--as=` impersonation instead. Add NEW findings as `N1`, `N2`, … for anything the
claims above did not ask about.

---

## Fable — pass 1

_(Fable writes below this line.)_

> **Fable:** S1 — REFUTED, then superseded by the operator's ruling (recorded so the history reads right)
> **Where:** `files/relabel-provenance.sh:53-83` (Step 1, now the one-call `-A` read)
> **Trigger — the three states this finding went through:** (1) I measured that the original Step 1's bare `oc get groupsync` was namespace-scoped — `GET .../namespaces/<ns>/groupsyncs?limit=500`, and from a foreign-namespace context it returns EMPTY with rc=0 while 3 CRs are live — and demonstrated in the stub harness that a same-named CR outside the pod's namespace read as "gone", relabelling a Group it owned. (2) The arbiter refuted the consequence and I verified that refutation independently rather than taking it on trust: ownership requires reconciliation, and reconciliation is bounded by the watch — `WATCH_NAMESPACE=group-sync-operator,openshift-config` measured on both containers of the live deployment, set by this chart itself (`subscription.watchNamespaces`, values.yaml:345, injected via the Subscription's `spec.config.env` over the CSV's fieldRef to `olm.targetNamespaces`); OperatorGroup targets `["group-sync-operator"]`; CSV `group-sync-operator.v0.0.36` installModes OwnNamespace/SingleNamespace only; the operator's RBAC on groupsyncs is cluster-wide (CSV-owned ClusterRole), so the watch, not RBAC, is the boundary. A CR outside the watched set is inert and owns nothing, so the namespaced list covered every possible owner under this chart's shipped values. (3) The operator overruled the fix-rejection: the mechanism finding was right, the balance-of-risk argument against `-A` was not, and the shipped Step 1 is `-A` **plus the provider read folded into the same call** — the per-rename `oc get groupsync "$new_cr"` lookup is gone, which matters more than the flag, because that second call was itself namespace-bound.
> **Consequence:** none remaining. The shipped code answers "does the CR named in this Group's label still exist" as a fact about the cluster, matching the cluster-scoped Groups it judges; under the verified single-namespace contract the old and new reads return the same set, and if the contract is ever broken the failure direction is safe (seeing MORE CRs can only make the still-live guard refuse, which it logs). A synced Group records nothing about its owner's namespace (measured: labels carry only `sync-provider=<cr>_<provider>` plus `openshift.io/ldap.host`; annotations only sync-time/uid/url; no `ownerReferences`), so a name-only cluster-wide test is also the only test the data supports.
> **Fix (already shipped in lines 56-83; nothing further):** my earlier proposed "DELIBERATELY NOT --all-namespaces" comment is withdrawn. The new Step-1 surface (awk parsing, folded lookup) is audited under N2 below.
> **Proof:**
>
> ```
> $ oc get groupsync -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; echo rc=$?   # from ns "default"
> rc=0                                                       <- empty, success, while:
> $ oc get groupsync -A --no-headers | wc -l                 -> 3
> $ oc get deployment ... WATCH_NAMESPACE                    -> group-sync-operator,openshift-config (both containers)
> $ oc get operatorgroup ... targets                         -> ["group-sync-operator"]
> $ oc get csv group-sync-operator.v0.0.36 ... installModes  -> OwnNamespace t, SingleNamespace t, MultiNamespace f, AllNamespaces f
> $ oc get group bda-rbac-flink-alpha-apps -o jsonpath='{.metadata.labels}{.metadata.ownerReferences}'
> {"group-sync-operator.redhat-cop.io/sync-provider":"bda-rbac-groupsync_ldap","openshift.io/ldap.host":"..."}  (no ownerReferences)
> ```

> **Fable:** S2 — CONFIRMED (on the surviving cases; the cross-namespace case is out of scope per the ruling)
> **Where:** `files/relabel-provenance.sh:95-146` (the pair loop collects per pair with no memory of earlier pairs) and `:171-189` (the apply loop executes every queued entry)
> **Trigger:** two declared renames share one previous name. Concrete values shape: a second tenant item copy-pastes the first one's `previousNames: ["bda-rbac-groupsync"]`, or the same old name is listed under both `groupSync.previousNames` and an item. `RENAMES="gone=cr-a,gone=cr-b"` with both new CRs live and one Group `g1` carrying `gone_ldap`: the collection loop queries the same selector once per pair, queues `g1` twice, and the apply loop relabels it twice — `cr-a_ldap` then `cr-b_ldap`, last writer wins, ordered by nothing but values-file position. The OTHER construction the claim asks about — a `previousNames` entry equal to another item's current name — is guarded: the still-live check skips it (measured: `RENAMES="cr-b=cr-a"` with both live logs the skip and makes zero label calls).
> **Consequence:** the log reads `relabelled g1: gone_ldap -> cr-a_ldap`, `relabelled g1: gone_ldap -> cr-b_ldap`, `relabelled 2 of 2 Group(s)`, exit 0 — a reader believes two Groups were repaired and that the final owner is the declared one; in fact ONE Group exists, its final owner is whichever pair happened to come last, and at least one of the two claims credited a CR that does not own it. The dashboard then attributes the Group to the wrong CR with no alert, which is the exact failure this feature exists to end.
> **Fix (complete, ready to apply):** replaces `files/relabel-provenance.sh:88-106` (the array init through the both-sides-named check). Note it includes S3's `*=*=*` case arm; if S3 is rejected, keep today's two-arm `case` — the duplicate-name stanza is independent of it.
>
> ```bash
> GROUP_NAMES=()
> OLD_VALUES=()
> NEW_VALUES=()
> SKIPPED=0
> SEEN_OLD_NAMES=""
>
> # Splitting on spaces is safe here: every name involved is a Kubernetes object name, so it cannot
> # contain a space. Commas become spaces and the loop stays a plain `for`.
> for pair in ${RENAMES//,/ }; do
>   case "$pair" in
>     # `cut -d= -f2` of "a=b=c" is "b": a stray '=' inside a previousNames entry would silently rewrite
>     # the declared mapping instead of failing, so refuse it here.
>     *=*=*) fail "malformed rename '${pair}' — a name cannot contain '=', write previousNames entries as bare old names" ;;
>     *=*) : ;;
>     *) fail "malformed rename '${pair}' — expected old=new" ;;
>   esac
>
>   old_cr="$(echo "$pair" | cut -d= -f1)"
>   new_cr="$(echo "$pair" | cut -d= -f2)"
>
>   if [ -z "$old_cr" ] || [ -z "$new_cr" ]; then
>     fail "malformed rename '${pair}' — both sides must be named"
>   fi
>
>   # The same previous name declared twice is two claims on the same Groups: whichever pair ran last
>   # would win silently, the cap would count the same Group once per claim, and the log would show it
>   # "relabelled" twice. Refuse the ambiguity before anything is relabelled.
>   for seen in $SEEN_OLD_NAMES; do
>     if [ "$seen" = "$old_cr" ]; then
>       fail "the previous name '${old_cr}' appears in more than one rename, so its Groups would have two claimed owners — declare each old name exactly once"
>     fi
>   done
>   SEEN_OLD_NAMES="$SEEN_OLD_NAMES $old_cr"
> ```
>
> **Proof:** stub harness, current script, then the block above applied:
>
> ```
> $ STUB_LIVE_CRS="cr-a cr-b" STUB_PROVIDERS=ldap STUB_GROUPS="g1:gone_ldap" RENAMES="gone=cr-a,gone=cr-b" bash relabel-provenance.sh
> [provenance-relabel] relabelled g1: gone_ldap -> cr-a_ldap
> [provenance-relabel] relabelled g1: gone_ldap -> cr-b_ldap
> [provenance-relabel] relabelled 2 of 2 Group(s)        rc=0, calls log: two oc label calls on the same Group
>   ... with fix:
> [provenance-relabel] FAILED: the previous name 'gone' appears in more than one rename, so its Groups would have two claimed owners — declare each old name exactly once
>   rc=1, zero oc label calls (measured)
> $ STUB_LIVE_CRS="cr-a cr-b" ... RENAMES="cr-b=cr-a" bash relabel-provenance.sh     # other construction: guard HOLDS today
> [provenance-relabel] skip cr-b -> cr-a: 'cr-b' is still a live CR, so its Groups are owned, not orphaned   (zero label calls)
> ```
>
> Behaviour preservation with the block applied: all ten originally-verified scenarios re-ran unchanged (empty RENAMES rc=0; malformed rc=1; bad LIMIT rc=1; still-live skip 0 labels; new-not-live rc=1; dry run 0 labels; cap abort 0 labels; failed list rc=1; failed label rc=1; multi-provider one value per provider; zero removals). `bash -n` clean.

> **Fable:** S3 — CONFIRMED (the multi-`=` truncation; the injection half of the claim is REFUTED with measurements)
> **Where:** `files/relabel-provenance.sh:96-102` — the `case` accepts any pair containing `=`, then `cut -d= -f1`/`-f2` keep only the first two fields
> **Trigger:** a `previousNames` entry containing `=`. The likely real-world shape is the RENAMES syntax leaking into values: `previousNames: ["bda-rbac-groupsync=bdp-oud-group-rbac-groupsync"]` on an item named `X` renders `RENAMES="bda-rbac-groupsync=bdp-oud-group-rbac-groupsync=X"` (measured render below). `cut -f2` silently discards the third field, so the declared successor `X` is dropped and the pair is treated as `bda-rbac-groupsync -> bdp-oud-group-rbac-groupsync` — which passes every guard whenever the middle token names a live CR.
> **Consequence:** `oc get groups -l ...` shows the Groups moved to the MIDDLE token's CR, not to the declared successor — the reader believes the declaration was applied as written; it was silently rewritten. Measured: `RENAMES="old=new=current"` with `new` and `current` both live relabelled `g1` to `new_ldap`, exit 0, although the declared new owner was `current`.
> **Injection half, refuted with measurements:** (i) every `oc` argument in the script is a quoted expansion, so a hostile token becomes one argument, never two — the stub calls log shows single arguments throughout; (ii) Helm's `| quote` makes RENAMES one YAML scalar, so values cannot smuggle extra env or args; (iii) a glob/invalid character in a previous name dies loudly at the API, not silently: measured live, selector value `bda-*_ldap` -> `Error from server (BadRequest): ... a valid label must be ...` -> the script's `|| fail` aborts; (iv) a space inside a token just splits it into two tokens, each of which either fails the `case` or queries a value that matches nothing (measured in the stub: two harmless zero-match queries). With T4's render-time validation below, none of these shapes can even reach the Job.
> **Fix (complete, ready to apply):** the whole `case` statement (replaces `files/relabel-provenance.sh:96-99`); already included inside S2's block above — apply once.
>
> ```bash
>   case "$pair" in
>     # `cut -d= -f2` of "a=b=c" is "b": a stray '=' inside a previousNames entry would silently rewrite
>     # the declared mapping instead of failing, so refuse it here.
>     *=*=*) fail "malformed rename '${pair}' — a name cannot contain '=', write previousNames entries as bare old names" ;;
>     *=*) : ;;
>     *) fail "malformed rename '${pair}' — expected old=new" ;;
>   esac
> ```
>
> **Proof:**
>
> ```
> $ helm template gs . --set groupSync.url=ldaps://x:636 --set 'groupSync.previousNames[0]=old=new' | grep -A1 "name: RENAMES"
>               value: "old=new=ldap-groupsync"                      <- the helper emits the triple happily
> $ STUB_LIVE_CRS="new current" STUB_PROVIDERS=ldap STUB_GROUPS="g1:old_ldap" RENAMES="old=new=current" bash relabel-provenance.sh
> [provenance-relabel] relabelled g1: old_ldap -> new_ldap           <- declared successor was "current"; rc=0
>   ... with fix: FAILED: malformed rename 'old=new=current' — a name cannot contain '=' ...   rc=1, zero label calls
> $ oc get groups -l 'group-sync-operator.redhat-cop.io/sync-provider=bda-*_ldap'
> Error from server (BadRequest): ... Invalid value: "bda-*_ldap" ...    <- glob chars fail loudly, not silently
> ```

> **Fable:** S4 — CONFIRMED (same root cause as S2's duplicate case; one fix covers both)
> **Where:** `files/relabel-provenance.sh:139-142` (the arrays grow once per match per PAIR) and `:148,156` (`TOTAL` and the cap count array entries, not distinct Groups)
> **Trigger:** the same previous name declared twice (S2's trigger). Each duplicate pair re-queries the same selector and re-queues the same Groups, so `TOTAL` counts them once per claim. Concrete against this cluster's real numbers: declaring the `bda-rbac-groupsync` rename twice makes TOTAL = 21x2 + 1 = 43 > 25, so the cap aborts a repair whose true size is 22. Two PROVIDERS cannot do this: each provider queries a different exact value (`old_p1` vs `old_p2`) and one Group holds one value, so provider fan-out never double-counts (measured: multi-provider run emits exactly one label call per Group).
> **Consequence:** either the same Group is relabelled twice and `relabelled 2 of 2 Group(s)` overstates the repair (measured), or the cap message `refusing to relabel 43 Groups, which exceeds LIMIT=25` makes the reader believe 43 distinct Groups were about to change owner when 22 exist — and the legitimate repair is blocked.
> **Fix:** exactly S2's block (the `SEEN_OLD_NAMES` stanza); no separate change. With duplicates refused before collection, `TOTAL` can only count distinct Groups, because within one pair the per-provider selectors are disjoint exact values.
> **Proof:** the S2 measurements above — `relabelled 2 of 2 Group(s)` for one Group on the current script; `FAILED: ... appears in more than one rename` with zero label calls under the fix; the multi-provider regression emitting `new_ldap`/`new_azure` once each.

> **Fable:** S5 — REFUTED (no idempotence defect; what I checked)
> **Where:** `files/relabel-provenance.sh:134` (the selector is an exact value match), `:108-111` (old==new skipped)
> **Trigger checked (three re-run shapes, stub harness, current script):** (1) a second run after a successful repair — every Group now carries `new_ldap`, the selector `...=old_ldap` matches nothing: rc=0, ZERO `oc label` calls, log `nothing to relabel`; (2) a partially-correct cluster (some Groups already `new_ldap`, some still `old_ldap`) — only the stale ones match; correct ones are untouched by construction, because a Group carrying `new_value` can no longer match `old_value`; (3) relabel-to-self — requires `old_cr = new_cr`, which line 108 skips before any query (`skip X: the previous name is the current name`). `previousNames` left permanently in values is therefore harmless, as the values comment claims: every later run is shape (1).
> **Consequence:** none — nothing a reader would misbelieve.
> **Fix:** none — the claim is refuted; no change required.
> **Proof:**
>
> ```
> $ STUB_LIVE_CRS=new STUB_PROVIDERS=ldap STUB_GROUPS="g1:new_ldap g2:new_ldap" RENAMES=old=new bash relabel-provenance.sh
> [provenance-relabel] old_ldap -> new_ldap: 0 Group(s)
> [provenance-relabel] nothing to relabel ...    rc=0, label calls: 0
> ```

> **Fable:** S6 — CONFIRMED (minor, log-honesty only)
> **Where:** `files/relabel-provenance.sh:196-200` — the final summary reports `CHANGED of TOTAL` and never mentions `SKIPPED`
> **Trigger:** one credible rename plus one premature one in the same run (previousNames written before the actual rename shipped, so the old CR is still live). Measured: `RENAMES="still-live=new,gone=new"` — the skip is logged once, mid-run, at line 3 of the output; the run then ends `relabelled 1 of 1 Group(s)`, exit 0.
> **Consequence:** a reader of the final line plus the exit code — which is what a CI gate or a human skimming `oc logs --tail` sees — believes every declared rename was applied. One was not, and its Groups still carry the old value.
> **Fix (complete, ready to apply):** replaces `files/relabel-provenance.sh:196-200` (final summary through `exit 0`).
>
> ```bash
> log "relabelled ${CHANGED} of ${TOTAL} Group(s)"
> if [ "$SKIPPED" -gt 0 ]; then
>   # Without this line, a reader of the final log plus exit 0 believes every declared rename was applied.
>   log "NOTE: ${SKIPPED} declared rename(s) skipped because the old CR is still live — those Groups were not touched; check whether previousNames is ahead of the actual rename"
> fi
> if [ "$FAILURES" -gt 0 ]; then
>   fail "${FAILURES} Group(s) could not be relabelled and keep their old value; each is logged above"
> fi
> exit 0
> ```
>
> **Proof:** current script ends `relabelled 1 of 1 Group(s)` with no skip mention; with the block applied the same fixtures end:
>
> ```
> [provenance-relabel] relabelled 1 of 1 Group(s)
> [provenance-relabel] NOTE: 1 declared rename(s) skipped because the old CR is still live — those Groups were not touched; check whether previousNames is ahead of the actual rename
> ```
>
> Partial-failure wording was also checked and is accurate: a failed `oc label` logs `ERROR relabelling <g>; it keeps <old>`, the summary counts honestly (`relabelled 0 of 1 Group(s)`), and the run exits 1 via `fail` (measured: rc=1).

> **Fable:** T1 — REFUTED (what I checked)
> **Where:** the shared gate `provenanceRelabelEnabled` in all three `01.9-*` templates (`configmap.yaml:9`, `rbac.yaml:19`, `job.yaml:15`)
> **Checked:** (1) all five objects render together or not at all — one helper gates them; measured: default render emits 0 objects from the 01.9 templates, crc-values renders all five (SA, ClusterRole, ClusterRoleBinding, ConfigMap, Job). (2) Ordering under plain Helm: the ConfigMap/SA/RBAC are ordinary release resources, applied in the main sync; the Job is a `post-install,post-upgrade` hook, which Helm runs only after the main apply succeeds — including the upgrade that first introduces the feature. (3) Under ArgoCD: CM/SA/RBAC are tracked resources at wave 2, the CRs sit at wave 3, the Job is a Sync-phase hook at wave 4; waves run in order within the sync, so the mount and the RBAC exist before the pod starts. `prune`/`selfHeal` act on the tracked wave-2 objects only when the rename is removed from values, at which point the Job (deleted at HookSucceeded) is already gone — nothing orphans. (4) The comment-only documents emitted when the gate is closed (`helm template` shows `# Source:` plus header comments, zero `kind:`) match this chart's existing comments-outside-the-gate convention (01.8, 02.2) and parse as empty documents.
> **Fix:** none — refuted.
> **Proof:** `helm template gs . --set groupSync.url=... | awk 'BEGIN{RS="---"} /01\.9-provenance/ && /kind:/ {n++} END{print n+0}'` -> `0`; same with `-f crc-values.yaml` -> 5 objects and `RENAMES="bda-rbac-groupsync=bdp-oud-group-rbac-groupsync,ldap-clusteraccess-groupsync=autobahnusers-onboarding-groupsync"`; gate variants (`provenanceRelabel.enabled=false`, `groupSync.enabled=false`, `customGroupSyncs.enabled=false`, item `enabled: false`) each render 0 objects.

> **Fable:** T2 — REFUTED (one wording nit deferred to V1)
> **Where:** `01.9-provenance-relabel-job.yaml:23-31` (annotations), `:8-11` (the weight-7 comment)
> **Checked:** (1) what the Job actually needs by weight 7: the CRD served and the operator installed (approver at -1, readiness wait at 0) and the GroupSync CRs present — CRs are main-manifest resources under plain Helm (applied before any post hook) and wave 3 under Argo (before the Job's wave 4). Both hold. The extraction (5) and CA (6) Jobs are NOT dependencies — the script reads no credentials and no certificates — so nothing it needs is unfinished at 7; running before the tests (10/20) is correct so a test run sees repaired provenance. (2) Annotation-set consistency: the new Job's set (`argocd.argoproj.io/hook: Sync`, `hook-delete-policy: BeforeHookCreation,HookSucceeded`, `sync-options: SkipDryRunOnMissingResource=true,Replace=true`, `helm.sh/hook: post-install,post-upgrade`, `helm.sh/hook-delete-policy: before-hook-creation`) is consistent with the two existing Argo-hook Jobs (01.7 approver, 02.2 operator-wait); 01.5/01.6 use plain waves without Argo hook annotations, a pre-existing mixed convention this Job did not create.
> **Consequence/nit:** the header comment says weight 7 puts it "after everything it depends on" and then lists extraction (5) and CA (6) — a reader debugging a failed extraction would wrongly hold this Job hostage to it. That is a comment fix, bundled under V1.
> **Fix:** none here — refuted; the comment correction is V1's.
> **Proof:** `grep -n "hook\|sync-wave" templates/01.7-... templates/02.2-... templates/01.9-...-job.yaml` — matching annotation sets; `templates/02-groupsync.yaml:15` and `custom-groupsync.yaml:87` carry `sync-wave: "3"`.

> **Fable:** T3 — CONFIRMED (a verb went unused when the second lookup was folded away; sufficiency itself verified)
> **Where:** `templates/01.9-provenance-relabel-rbac.yaml:51-55` (the groupsyncs rule still grants `get, list`)
> **Trigger:** the one-call refactor removed the script's only named read. The current script's complete `oc` surface is: `oc get groupsync -A` (verb: `list`, measured URL `/apis/redhatcop.redhat.io/v1alpha1/groupsyncs?limit=500`), `oc get groups -l k=v` (verb: `list`, measured URL `/apis/user.openshift.io/v1/groups?labelSelector=...`), and `oc label group <name> --overwrite` (verbs: `get` then `patch`, measured with `--dry-run=server -v=6`: `GET /apis/user.openshift.io/v1/groups/<name>` then `PATCH ...?dryRun=All&fieldManager=kubectl-label`). Nothing issues a named groupsync GET any more — `grep -c 'oc get groupsync' files/relabel-provenance.sh` matches only line 72.
> **Consequence:** the rule's own comment tells the reader every verb is exercised ("Read-only, and the whole basis of the decision") — `get` on groupsyncs is exercised by nothing. On the groups rule the opposite discipline is already right: `get` there is REQUIRED (the measured GET-before-PATCH), and its do-not-tighten comment must stay exactly as is.
> **Fix (complete, ready to apply):** replaces the groupsyncs rule and its comment, `templates/01.9-provenance-relabel-rbac.yaml:51-55`. The groups rule above it is untouched.
>
> ```yaml
> # Read-only, and the whole basis of the decision: a rename is only credible when the OLD CR is absent
> # from the list, and the replacement value is built from the NEW CR's provider names — both taken from
> # the SAME single `oc get groupsync -A` read, so `list` is the only verb the script exercises on
> # groupsyncs. The per-CR `oc get groupsync <name>` lookup that needed `get` was folded into that read;
> # if a named lookup ever returns, re-add `get` and re-verify with -v=6, exactly as the groups rule
> # above demands.
> - apiGroups: ["redhatcop.redhat.io"]
>   resources: ["groupsyncs"]
>   verbs: ["list"]
> ```
>
> **Proof:**
>
> ```
> $ oc label group bda-rbac-flink-alpha-apps group-sync-operator.redhat-cop.io/sync-provider=bdp-oud-group-rbac-groupsync_ldap \
>     --overwrite --dry-run=server -v=6 | grep round_trippers
> GET   https://.../apis/user.openshift.io/v1/groups/bda-rbac-flink-alpha-apps 200 OK
> PATCH https://.../apis/user.openshift.io/v1/groups/bda-rbac-flink-alpha-apps?dryRun=All&fieldManager=kubectl-label 200 OK
>   (nothing persisted: value still bda-rbac-groupsync_ldap, stale count still 21)
> $ oc get groupsync -A -v=6 | grep -Eo "GET https[^ ]*groupsyncs[^ ]*"   -> /apis/redhatcop.redhat.io/v1alpha1/groupsyncs?limit=500   (list)
> $ grep -n 'oc get groupsync' files/relabel-provenance.sh               -> line 72 only (the -A list)
> ```

> **Fable:** T4 — CONFIRMED
> **Where:** `templates/_helpers.tpl`, `provenanceRenames` (the `define` under the "declared renames" comment; the render errors below cite `_helpers.tpl:324`)
> **Trigger, three measured shapes:** (1) `previousNames: "old-name"` (a string — YAML without brackets) -> render dies with `range can't iterate over old-name` pointing at `rbac.yaml:19` via `_helpers.tpl:324`, which tells the operator nothing about which value to fix; (2) `previousNames: [""]` -> renders `RENAMES="=ldap-groupsync"`, a Job that can only fail at runtime (`both sides must be named`) — the upgrade succeeds and the failure surfaces later, in the hook; (3) `previousNames: ["old=new"]` -> renders `RENAMES="old=new=ldap-groupsync"`, feeding S3's silent truncation. `provenanceRenames` and `provenanceRelabelEnabled` cannot otherwise disagree — Enabled is `and .Values.provenanceRelabel.enabled (include ...provenanceRenames...)`, so the Job renders iff RENAMES is non-empty (measured across the four gate variants, each 0 objects); and a disabled item's `previousNames` is correctly ignored, matching `custom-groupsync.yaml:14`, which skips the same item's CR (`if .enabled` — both treat a missing `enabled` as off).
> **Consequence:** an operator who declared a rename believes they declared a rename; the render either fails with a message that does not name the mistake, or succeeds and ships a Job that must fail — or silently rewrites the mapping (S3).
> **Fix (complete, ready to apply):** replaces the whole `provenanceRenames` define (keep the comment block above it as is; `provenanceRelabelEnabled` is unchanged). Validation lives here so every bad shape dies at render time with the value named; the script keeps its own checks because it is documented as runnable outside the cluster.
>
> ```
> {{- define "group-sync-operator-helm.provenanceRenames" -}}
> {{- $renames := list -}}
> {{- $seenOld := list -}}
> {{- if .Values.groupSync.enabled -}}
> {{- $prevs := .Values.groupSync.previousNames | default list -}}
> {{- if not (kindIs "slice" $prevs) -}}
> {{- fail (printf "groupSync.previousNames must be a LIST of former CR names, e.g. [\"old-name\"] — got a %s" (kindOf $prevs)) -}}
> {{- end -}}
> {{- range $prev := $prevs -}}
> {{- $prev = $prev | toString -}}
> {{- if not (regexMatch "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$" $prev) -}}
> {{- fail (printf "groupSync.previousNames entry %q is not a Kubernetes object name — write the bare former CR name, nothing else" $prev) -}}
> {{- end -}}
> {{- if has $prev $seenOld -}}
> {{- fail (printf "previous name %q is declared more than once, so its Groups would have two claimed owners" $prev) -}}
> {{- end -}}
> {{- $seenOld = append $seenOld $prev -}}
> {{- $renames = append $renames (printf "%s=%s" $prev $.Values.groupSync.name) -}}
> {{- end -}}
> {{- end -}}
> {{- if .Values.customGroupSyncs.enabled -}}
> {{- range $item := (.Values.customGroupSyncs.items | default list) -}}
> {{- if $item.enabled -}}
> {{- $prevs := $item.previousNames | default list -}}
> {{- if not (kindIs "slice" $prevs) -}}
> {{- fail (printf "customGroupSyncs item %q: previousNames must be a LIST of former CR names — got a %s" $item.name (kindOf $prevs)) -}}
> {{- end -}}
> {{- range $prev := $prevs -}}
> {{- $prev = $prev | toString -}}
> {{- if not (regexMatch "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$" $prev) -}}
> {{- fail (printf "customGroupSyncs item %q: previousNames entry %q is not a Kubernetes object name — write the bare former CR name, nothing else" $item.name $prev) -}}
> {{- end -}}
> {{- if has $prev $seenOld -}}
> {{- fail (printf "previous name %q is declared more than once, so its Groups would have two claimed owners" $prev) -}}
> {{- end -}}
> {{- $seenOld = append $seenOld $prev -}}
> {{- $renames = append $renames (printf "%s=%s" $prev $item.name) -}}
> {{- end -}}
> {{- end -}}
> {{- end -}}
> {{- end -}}
> {{- join "," $renames -}}
> {{- end }}
> ```
>
> **Proof (all measured against a chart copy with the block applied; `helm lint` passes):**
>
> ```
> string shape   -> Error: ... groupSync.previousNames must be a LIST of former CR names, e.g. ["old-name"] — got a string
> [""]           -> Error: ... previousNames entry "" is not a Kubernetes object name — write the bare former CR name, nothing else
> ["old=new"]    -> Error: ... previousNames entry "old=new" is not a Kubernetes object name ...
> ["OldName"]    -> Error: ... previousNames entry "OldName" is not a Kubernetes object name ...
> duplicate across groupSync + an item -> Error: ... previous name "gone" is declared more than once ...
> crc-values     -> RENAMES unchanged: "bda-rbac-groupsync=bdp-oud-group-rbac-groupsync,ldap-clusteraccess-groupsync=autobahnusers-onboarding-groupsync"
> valid entry    -> "old-name=ldap-groupsync"; default render still emits 0 objects
> ```

> **Fable:** V1 — CONFIRMED (two wording fixes; every measured number checked out)
> **Where:** `Chart.yaml` (the 0.12.2 `- kind: added` changelog entry) and `01.9-provenance-relabel-job.yaml:8-11`
> **Trigger/what is wrong:** (1) the changelog says "a post-upgrade hook Job at weight 7 corrects exactly those Groups" — the annotation is `post-install,post-upgrade`, and the install path is real: Groups survive `helm uninstall` (nothing deletes them), so a reinstall that declares `previousNames` repairs on install. A reader planning a reinstall would wrongly conclude they must upgrade to trigger the repair. (2) The Job header lists the credentials extraction (5) and the CA (6) among "everything it depends on" — they are sequence, not dependencies (see T2).
> **Numbers audit (all check out, nothing stale):** 22 of 66 — measured live: 21 Groups carry `bda-rbac-groupsync_ldap` + 1 carries `ldap-clusteraccess-groupsync_ldap` = 22, of 66 total Groups (64 carry the label at all); crc-values' "21 Groups" and "one Group" comments match; `limit: 25` sits above 22 and below 66 as its comment claims; the README table rows match values.yaml defaults key-for-key (enabled true, dryRun false, limit 25, backoffLimit 0, deadline 300, ttl 300, ose-cli v4.14, IfNotPresent, previousNames []); Chart.yaml bumped 0.12.1 -> 0.12.2; the rendered ConfigMap script is byte-identical to `files/relabel-provenance.sh` (re-measured after the Step-1 rewrite) and `bash -n` passes at 9757 bytes >= the 500-byte CI floor.
> **Fix (complete, ready to apply):** two replacements.
> (a) In the Chart.yaml 0.12.2 changelog entry, this phrase — `write the old name in groupSync.previousNames or an item's previousNames and a post-upgrade hook Job at weight 7 corrects exactly those Groups.` — becomes:
>
> ```
> write the old name in groupSync.previousNames or an item's previousNames and a post-install/post-upgrade hook Job at weight 7 corrects exactly those Groups - a reinstall repairs too, because Groups survive an uninstall.
> ```
>
> (b) replaces `01.9-provenance-relabel-job.yaml:8-11` (the WEIGHT 7 paragraph; the surrounding comment lines stay):
>
> ```
> # WEIGHT 7 puts it after what it actually needs: the InstallPlan approver (-1) and the readiness wait (0)
> # guarantee the CRD is served, and the GroupSync CRs it reads are ordinary manifest resources, applied
> # before any post hook (wave 3 under ArgoCD, before this Job's wave 4). The extraction (5) and CA (6)
> # Jobs are sequence, not dependencies — this Job reads no credentials and no certificates. Before the
> # tests (10/20), so a test run sees repaired provenance.
> ```
>
> **Proof:** `oc get groups -l ...=bda-rbac-groupsync_ldap --no-headers | wc -l` -> 21; `...=ldap-clusteraccess-groupsync_ldap` -> 1; `oc get groups --no-headers | wc -l` -> 66; label-carrying total -> 64; README/values compared row-by-row; render-vs-file compare printed `identical: True`.

> **Fable:** V2 — CONFIRMED
> **Where:** `values.yaml:46-47` — `providerName: ldap` carries a one-line WHAT comment and no rename warning, while the rename hazard is documented at `groupSync.name` (values.yaml:29-34), the commented item example, crc-values, the README section, and the changelog
> **Trigger:** rename `groupSync.providerName` (say `ldap` -> `openldap`) with or without a CR rename. The ownership label's value is `<cr-name>_<provider-name>`, so every synced Group's value goes stale exactly as in a CR rename — and `previousNames` CANNOT repair it: the script derives the stale value from the live CR's CURRENT provider names, and the old provider name is recorded nowhere once the CR is rewritten. Measured in the stub harness: old value `old_ldap` on the Group, new CR's provider `openldap` -> the run queries `old_openldap`, matches 0 Groups, and exits 0 reporting `provenance already matches the live CRs` (the false half of that message is N1). The blast radius is the primary CR only: custom items pin their provider name to `ldap` in the template (`custom-groupsync.yaml:76`).
> **Consequence:** a reader of values.yaml concludes renaming the provider is free, or that `previousNames` will cover it; after doing it, the Job log tells them provenance matches while every Group the CR owns is stale and the dashboard credits them to no CR with no alert.
> **Fix (complete, ready to apply):** replaces `values.yaml:46-47` (the comment line plus the key).
>
> ```yaml
>   # Name of the LDAP provider in the GroupSync configuration.
>   #
>   # RENAMING THIS HAS THE SAME COST AS RENAMING THE CR — the ownership label's value is
>   # <cr-name>_<provider-name>, so a new provider name orphans every synced Group's value exactly like a
>   # CR rename does (measured there: 22 of 66 Groups). Worse, previousNames CANNOT repair it: the relabel
>   # Job derives the stale value from the live CR's provider names, and the old provider name is recorded
>   # nowhere once the CR is rewritten — the Job finds nothing to fix and exits 0. If you must rename it,
>   # plan on relabelling by hand. (customGroupSyncs items pin their provider name to "ldap" in the
>   # template, so this knob affects the primary CR only.)
>   providerName: ldap
> ```
>
> **Proof:** the scenario run under N1 below; `custom-groupsync.yaml:76`: `{{- $_ := set $cfg "providerName" "ldap" }}`; values.yaml shows the hazard documented at `name` (lines 29-34) and absent at `providerName` (lines 46-47).

> **Fable:** N1 — CONFIRMED (new finding: the zero-match exit overclaims)
> **Where:** `files/relabel-provenance.sh:151` — `"nothing to relabel (... skipped as still-live); provenance already matches the live CRs"` — and `:144`, where a pair's zero matches is logged only as `0 Group(s)`
> **Trigger:** any run where a declared pair matches nothing for a reason other than "already repaired". The concrete case is V2's provider rename: Groups carry `old_ldap`, the new CR's provider is `openldap`, the run queries `old_openldap`, finds 0, and exits 0 claiming provenance matches — measured. The same wording also fires on a plain second run, where it happens to be true — which is exactly why it is dangerous: the reader cannot tell the two apart from the log.
> **Consequence:** a reader of the Job log believes the repair is complete and attribution is correct; 22 Groups can still be stale, the dashboard still credits them to no CR, and the stale-group alert still cannot fire — the feature reports success at the one moment it silently did nothing.
> **Fix (complete, ready to apply):** two blocks. (a) replaces the provider loop, `files/relabel-provenance.sh:130-145`:
>
> ```bash
>   pair_found=0
>   for provider in $PROVIDERS; do
>     old_value="${old_cr}_${provider}"
>     new_value="${new_cr}_${provider}"
>
>     MATCHED="$(oc get groups -l "${LABEL_KEY}=${old_value}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" \
>       || fail "cannot list Groups labelled ${LABEL_KEY}=${old_value} — the API's error is above"
>
>     found=0
>     for group in $MATCHED; do
>       GROUP_NAMES+=("$group")
>       OLD_VALUES+=("$old_value")
>       NEW_VALUES+=("$new_value")
>       found=$((found + 1))
>     done
>     log "${old_value} -> ${new_value}: ${found} Group(s)"
>     pair_found=$((pair_found + found))
>   done
>
>   if [ "$pair_found" -eq 0 ]; then
>     # Zero matches is what "already repaired" looks like — but it is ALSO what a renamed provider looks
>     # like: the stale value's suffix is the OLD CR's provider name, and only the NEW CR's providers can
>     # be read, so a rename that changed the provider name too leaves its stale values unfindable here.
>     log "NOTE: ${old_cr} -> ${new_cr}: no Group carries ${old_cr}_<provider> for any provider of ${new_cr} — already repaired, or the provider name changed with the rename (a value stamped by the old provider name cannot be derived and stays stale)"
>   fi
> ```
>
> (b) replaces the zero-total exit, `files/relabel-provenance.sh:150-153` — the claim shrinks to what was actually verified:
>
> ```bash
> if [ "$TOTAL" -eq 0 ]; then
>   log "nothing to relabel (${SKIPPED} rename(s) skipped as still-live); no Group carries a declared old value"
>   exit 0
> fi
> ```
>
> **Proof:** current script vs fixed, same fixtures (`STUB_LIVE_CRS="new:openldap"`, Group `g1` carries `old_ldap`, `RENAMES=old=new`):
>
> ```
> current: [provenance-relabel] old_openldap -> new_openldap: 0 Group(s)
>          [provenance-relabel] nothing to relabel (0 rename(s) skipped as still-live); provenance already matches the live CRs   <- false; g1 is stale
> fixed:   [provenance-relabel] NOTE: old -> new: no Group carries old_<provider> for any provider of new — already repaired, or the provider name changed with the rename (a value stamped by the old provider name cannot be derived and stays stale)
>          [provenance-relabel] nothing to relabel (0 rename(s) skipped as still-live); no Group carries a declared old value
> ```
>
> Regression with both blocks applied: all ten scenarios unchanged, `bash -n` clean.

> **Fable:** N2 — REFUTED (audit of the new Step-1 surface, requested after the one-call rewrite: no defect)
> **Where:** `files/relabel-provenance.sh:72-83` — the one-call `-A` read, `is_live_cr` (awk `$1` + `grep -qxF`), `providers_of` (awk `$1 == want { $1 = ""; print }`)
> **Checked, each measured in the stub harness or bounded by verified charsets:**
>
> 1. **Prefix names do not bleed.** `$1 == want` is exact string comparison and `grep -qxF` matches fixed-string full lines; live CRs `corp` (provider `ldap`) and `corp-extra` (provider `azure`) with `RENAMES="gone=corp"` queried only `gone_ldap` — `gone_azure` was never queried.
> 2. **A CR with no providers still fails loudly.** Its line is the bare name, `providers_of` returns an empty field list, and the existing `[ -z "$(echo $PROVIDERS)" ]` check fires: measured, `FAILED: GroupSync/new declares no named providers...`, zero label calls. The removed per-CR lookup took no validation with it: liveness still comes from the (still `|| fail`-guarded) list, the no-providers check survives at lines 126-128, and the transient named-get failure path no longer exists at all — one snapshot is also more self-consistent than two reads were.
> 3. **`$1 = ""` leaves a leading separator** in `providers_of` output; the consumer is an unquoted `for provider in $PROVIDERS`, whose word-splitting discards leading blanks — measured throughout (every multi-provider run emits exactly one value per provider, `new_ldap` and `new_azure` once each).
> 4. **The one-call read cannot silently truncate:** the client aggregates paginated LIST responses (the `?limit=500` chunking) before jsonpath is applied, and a failed list still hits `|| fail` (measured: `STUB_LIST_RC=1` -> rc=1, zero labels). A warning on stderr with rc=0 does not pollute the capture (measured; `$(...)` takes stdout only).
> 5. **`awk -v want=` backslash expansion** cannot trigger — a Kubernetes object name cannot contain `\`.
> 6. **Two boundaries recorded, not findings:** (a) two same-named CRs in different namespaces would make `providers_of` print both lines' providers merged — unreachable under the verified deployment contract (CRs live only in the watched operator namespace; the operator has ruled cross-namespace CRs will not happen); (b) `is_live_cr` pipes through `grep -q` under `set -o pipefail`, so on inputs larger than the pipe buffer an early match could surface awk's SIGPIPE (141) and read as "not live" — arithmetic bound: needs CR_LINES > 64KiB, roughly >1,500 CRs; this cluster's is 3 CRs (about 66 bytes), and the single-namespace contract keeps it there.
>
> **Fix:** none — no defect in scope.
> **Proof:**
>
> ```
> $ STUB_LIVE_CRS="corp:ldap corp-extra:azure" STUB_GROUPS="g1:gone_ldap g2:gone_azure" RENAMES="gone=corp" bash relabel-provenance.sh
> [provenance-relabel] gone_ldap -> corp_ldap: 1 Group(s)          <- one query, one label call, azure never queried
> $ STUB_LIVE_CRS="new:" STUB_GROUPS="g1:old_ldap" RENAMES="old=new" bash relabel-provenance.sh
> [provenance-relabel] FAILED: GroupSync/new declares no named providers, so no label value can be derived   (zero label calls)
> ```

---

## Claude — adjudication (S1–T4)

Read in full, and each verdict checked against the current file rather than the version Fable first opened.
Verdicts on V1, V2, N1, N2 follow when they land.

| claim | Fable | verdict | outcome |
|---|---|---|---|
| S1 namespace-scoped CR list | REFUTED/superseded | **ACCEPT** | no change; the `-A` + folded read already shipped |
| S2 duplicate previous name | CONFIRMED | **ACCEPT** | apply the `SEEN_OLD_NAMES` block |
| S3 multi-`=` truncation | CONFIRMED (injection refuted) | **ACCEPT** | ships inside S2's block |
| S4 cap double-counts | CONFIRMED | **ACCEPT** | no separate change; S2's block closes it |
| S5 idempotence | REFUTED | **ACCEPT** | no change |
| S6 summary omits skips | CONFIRMED | **ACCEPT** | apply the summary block |
| T1 render/ordering | REFUTED | **ACCEPT** | no change |
| T2 hook weight 7 | REFUTED | **ACCEPT** | comment nit deferred to V1 |
| T3 unused `get` on groupsyncs | CONFIRMED | **ACCEPT** | drop to `list` |
| T4 render-time value validation | CONFIRMED | **ACCEPT** | replace `provenanceRenames` |

Notes on three of them, where the reasoning matters more than the verdict:

**S2/S4 are the same defect and it is the serious one.** Two declared renames sharing a previous name queue
the same Group twice, relabel it twice, and the log says `relabelled 2 of 2 Group(s)` for one Group whose
final owner is decided by values-file order. That is mis-attribution produced by the tool built to end
mis-attribution. Accepted as written.

**S3's injection half being refuted is worth as much as the confirmation.** Every `oc` argument is a quoted
expansion, Helm's `| quote` makes RENAMES a single scalar, and a glob in a label selector fails loudly at
the API (`Invalid value: "bda-*_ldap"`). So the surviving problem is narrow and specific — a stray `=`
silently rewriting the mapping — and the fix is one `case` arm rather than input sanitising.

**T3 is the mirror of this morning's bug, pointed the other way.** The groups rule needs `get` because
`oc label` does GET-then-PATCH; the groupsyncs rule no longer needs it because folding the two reads into
one `-A` call removed the only named lookup. Same discipline, opposite conclusion: grant what is
exercised, and say which measurement proves it.

**Both S2's script guard and T4's render guard are kept, deliberately.** They are not duplicates: T4 stops a
bad values file at render, which is where an operator sees it, and S2 keeps the script correct when run by
hand outside the cluster — which values.yaml documents as supported. Neither makes the other redundant.

### Claude — adjudication (V1, V2, N1, N2)

| claim | Fable | verdict | outcome |
|---|---|---|---|
| V1 changelog + Job header wording | CONFIRMED | **ACCEPT** | apply both replacements |
| V2 `providerName` rename undocumented | CONFIRMED | **ACCEPT** | apply the values stanza |
| N1 zero-match exit overclaims | CONFIRMED | **ACCEPT** | apply both blocks |
| N2 audit of the new Step-1 surface | REFUTED | **ACCEPT** | no change |

**N1 is the one I would have missed, and it is the same discipline this whole day has been about.** The
zero-match exit said "provenance already matches the live CRs" — a claim wider than what was checked. Zero
matches means "no Group carries a declared old value", which is *also* what a renamed provider looks like.
The fix narrows the sentence to what the code actually verified and names the other cause. Claiming more
than was measured is precisely the failure mode that let this morning's sweeper bug survive its own
verification.

**V2 is a real gap and its honest answer is "you cannot fix this here."** Renaming `providerName` orphans
values exactly like renaming the CR, but `previousNames` structurally cannot repair it: the script derives
the stale value from the live CR's *current* provider names, and the old provider name is recorded nowhere
once the CR is rewritten. So the values comment documents the cost and says to relabel by hand. The
durable fix belongs in the operator (upstream #466), not here — which is the right division.

**V1's Job-header overstatement was mine.** I wrote that weight 7 sits after "everything it depends on" and
then listed the extraction (5) and CA (6) Jobs, which this Job does not depend on at all — it reads no
credentials and no certificates. Left alone, it would send someone debugging a failed extraction looking
for a dependency that does not exist.

Applying: S2+S3 (one block), S6, T3, T4, V1(a), V1(b), V2, N1(a), N1(b). No change for S1, S4, S5, T1, T2, N2.
