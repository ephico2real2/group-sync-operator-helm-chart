# Adversarial review — validated findings

Three reviewers went over this chart on **2026-08-04/05**: codex (gpt-5.6-sol), fable, and cursor
(grok-4.5-high-fast). Their raw output lived in a session scratchpad, which is ephemeral — this file is
the durable record.

**The numbers are fable's.** 47 findings; 11 were validated and fixed during the review itself. The
remaining 36 were validated afterwards by seven agents reading the claim, testing it against the
then-current `main`, and reporting a verdict with command output. The five highest-severity confirmations
then went to an adversarial pass instructed to refute them.

| verdict | count | meaning |
|---|---|---|
| confirmed | 28 | reproduced against main, with output |
| partly | 7 | real defect, but the described mechanism or blast radius was wrong |
| refuted | 1 | the claim rests on a false premise |

So 35 of 36 were real in some form. Worth stating plainly, because the prediction going in was that
roughly a third would not survive — that was wrong. The severity skews low, though: mostly documentation
and setup-script hygiene rather than anything that breaks an install.

The adversarial pass earned its place. It **lowered** #4 and #15 from high to low (real defects, overstated
consequences) and **raised** #13 to high — which is the one that turned out to matter most.

---

## Fixed during the review itself

Eleven of the 47 were validated and fixed before the batch validation ran, so they carry no verdict below:
**#1** (a private CA key in the repo — kept deliberately, see Scope decisions), **#2** (the test
ServiceAccount could read every Secret in the cluster), **#3**, **#5**, **#6**, **#7**, **#9**, **#14**,
**#20**, **#21**, **#30**.

**#20 deserves singling out**, because it was right twice over: *"nothing checks that Chart.yaml version was
bumped, so a validated chart change can publish nothing and still be green."* That is exactly what happened
— twice. `chart-releaser` runs with `skip_existing: true`, so an already-published version is skipped, the
run exits 0, and the Actions tick is green. The first time it stranded five fixes including #2, the
security one. There is now a CI job that fails a PR changing `charts/**` without a version bump, and
[docs/RELEASING.md](RELEASING.md) leads with the trap.

## Fixed since validation

**#12** — guard_existing_configmap decides whether to overwrite a live CA from a stale per-(ns,name) file   
  Closed by #22. guard_existing_configmap no longer decides from a stale local file, and refuses an unowned
  ConfigMap with no readable ca.crt

**#13** — Extractor ClusterRole grants unpinned secrets/configmaps create cluster-wide, and its namespaces  
  Closed by #26. both unpinned creates moved to namespace-scoped Roles; then every pinned secrets/configmaps
  rule too, after review showed resourceNames does not bound the namespace

**#17** — NOTES.txt's LDAP verification command: ldapsearch is absent from the operator image and the secr  
  Closed by #25. NOTES.txt no longer points at ldapsearch in a distroless image, bindDN/bindPassword keys
  that do not exist, or the raw url — it points at helm test

**#22** — The Role for the discovered source Secret is created in the caCopy namespace, not sourceSecret.n  
  Closed by #22. the discovered bind Secret's Role is created in sourceSecret.namespace

**#25** — A customGroupSyncs item missing groupCn renders a Go format error into the LDAP filter  
  Closed by #25. a customGroupSyncs item with neither groupCn nor filter is refused at render time

---

## Open

Ranked by severity after the adversarial pass. Every entry was reproduced against `main` at validation
time; a few of the file:line references will have shifted since.

### #31 · high · partly, narrowed by the adversarial pass

credentialsSecret and targetSecret are the same object with different keys, so the documented manual and
rotation procedures are silently reverted

**Evidence**

> The defect is real and confirmed on main b4befa9 — three README sites, not two — but the stated mechanism
> rests on a false premise, and the true consequence is worse than 'silently reverted'. CONFIRMED — same
> object: values.yaml:61 groupSync.credentialsSecret.name: ldap-group-sync (namespace group-sync-operator,
> :63) values.yaml:270 oauthSecretExtraction.targetSecret.name: ldap-group-sync (namespace group-sync-
> operator, :271) CONFIRMED — the Job rewrites it with different keys on every install/upgrade
> (01.5:136-140, hook post-install,post-upgrade at :12): oc create secret generic ldap-group-sync --from-
> literal=username="$BIND_DN" --from-literal=password="$BIND_PASSWORD" ... --dry-run=client …

**Adversarial pass**

> README documents three procedures against ldap-group-sync using keys the operator never reads. Confirmed
> at the deployed tag: syncer.go@v0.0.36 defines secretUsernameKey="username"/secretPasswordKey="password",
> and ldap.go's getLdapCredentialValue returns "" for a missing key with no error, so bindDN/bindPassword
> produce an unauthenticated bind. On the live directory that bind gets "No such object

**Suggested fix** (the reviewer's, not validated as the right one)

  Two changes. (1) README: replace all three blocks. Say the chart manages ldap-group-sync and document
  rotation as the actual mechanism — rotate the password in openshift-config/<sourceSecret>, then helm
  upgrade. Keep a manual recipe only under an explicit 'oauthSecretExtraction.enabled: false' heading, and
  use keys username/password there so every path agrees with the operator. Fix the same wrong

### #8 · medium · confirmed

The shipped argocd-application.yaml renders nothing: no groupSync.url, and ldapUrl fails on an offline
render

**Evidence**

> argocd-application.yaml on main (byte-identical to the working tree) still has only
> `source.helm.valueFiles: [values.yaml]` plus the new `skipCrds: true` from PR #18. grep for
> `parameters|groupSync.url|values:` in that file: no match. values.yaml:83 is `url: ""`.
> _helpers.tpl:213-219 `ldapUrl` calls `fail` when nothing resolves. customGroupSyncs defaults to enabled:
> true with item bda-rbac-groupsync enabled, so the fail is reached with pure defaults. Rendered the exact
> artifact ArgoCD would pull, not just the git tree: $ helm pull group-sync-operator-helm --repo
> https://ephico2real2.github.io/group-sync-operator-helm-chart --version 0.4.0 $ helm template group-sync-
> operator ./group-sync-oper…

**Adversarial pass**

> The shipped argocd-application.yaml can never render: it supplies no groupSync.url, and every GroupSync CR
> the chart emits routes through _helpers.tpl:83 -> ldapUrl, which calls `fail` when nothing resolves.
> Correction to the stated mechanism: the trigger is NOT specific to customGroupSyncs' default bda-rbac-
> groupsync item. groupSync.enabled also defaults to true, so with customGroupSyncs.enabled=

**Suggested fix** (the reviewer's, not validated as the right one)

  Give the Application a url, e.g. source: helm: parameters: - name: groupSync.url value:
  "ldaps://ldap.example.com:636" with a comment that lookup cannot resolve it in a repo-server render, and
  drop the redundant `valueFiles: [values.yaml]`. Pin targetRevision to a chart version (0.4.0) or a semver
  range instead of HEAD. Then have CI assert the inverse of the existing ci.yaml:65-77 check: rendering

### #18 · medium · confirmed

values.yaml says the wait budget covers all three checks together; the code gives each check the full
budget, and activeDeadlineSeconds truncates it

**Evidence**

> Untouched since 8dff7dc: `git diff --stat 8dff7dc main` over the finding's files reports changes only to
> NOTES.txt and the 15-bootstrap script, so values.yaml, 02.2-operator-wait-job.yaml and 01.7-installplan-
> approver.yaml are byte-identical to the reviewed commit. The doc claim, values.yaml:367-370 (finding cited
> :366-368): # Applies to all three checks together (CSV Succeeded, Deployment available, CRD Established),
> # not per check. 300s covers a cold catalog pull on a slow cluster. The code, templates/02.2-operator-
> wait-job.yaml: ATTEMPTS={{ div .Values.operatorWait.waitSeconds 5 }} computed once at :58, INTERVAL=5 at
> :59, then three independent loops `for i in $(seq 1 "$ATTEMPTS")` at :1…

**Suggested fix** (the reviewer's, not validated as the right one)

  Pick one and make the doc match. Preferred: keep per-check budgets and raise the deadline -
  activeDeadlineSeconds: {{ add (mul 3 .Values.operatorWait.waitSeconds) 120 }} at 02.2:35 and {{ add (mul 2
  .Values.installPlanApprover.waitSeconds) 120 }} at 01.7:75 - then rewrite values.yaml:367-368 to say the
  budget is per check. Otherwise set ATTEMPTS={{ div .Values.operatorWait.waitSeconds 15 }} to mak

### #24 · medium · confirmed

99-cleanup-everything.sh aborts halfway when run from anywhere but its own directory, then claims full
success

**Evidence**

> All three sub-claims verified on current main; setup-local-ldap-testing/99-cleanup-everything.sh is byte-
> identical to main and every cited line number matches (set -e at :11, rm -f at :66/:73, kubectl block
> :82-101, summary :115-119). I did NOT run the script itself - it is destructive against the live cluster -
> so I tested each mechanism in isolation. (a) CONFIRMED. `--ignore-not-found` covers a missing resource,
> not a missing file: cd /private/tmp && kubectl delete -f 01-ldap-server-definitely-absent.yaml --ignore-
> not-found=true error: the path "01-ldap-server-definitely-absent.yaml" does not exist exit=1 and set -e
> kills the script there: bash -c 'set -e; cd /private/tmp; kubectl delete -…

**Suggested fix** (the reviewer's, not validated as the right one)

  Add `cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"` at the top - the pattern 15-bootstrap-cert-
  manager-ca.sh:80 already uses (`SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"`).
  Replace kubectl with oc at :82-97 for consistency with the rest of the file. Track each step's outcome in
  a variable and gate the :115-119 summary lines on it, so a skipped or failed step is not

### #32 · medium · confirmed

README Quick start's "minimal" values file fails the install it is offered for (missing openshift-config/ca-
config-map)

**Evidence**

> Every link in the chain reproduces on main (working tree is main-identical for all files involved — `git
> diff --stat main HEAD` shows only the two test templates differ). (1) The example is still there verbatim,
> README.md:33-42, introduced as "A minimal `my-cluster-values.yaml` for a directory the cluster does
> **not** authenticate against": `groupSync.url: "ldaps://ldap.example.com:636"`,
> `oauthSecretExtraction.bindDN`, `sourceSecret.name: ldap-secret`. Nothing about a CA ConfigMap. (2)
> needsCa is true. main's helper (_helpers.tpl:73-75, post-PR#17) is `{{- if or (hasPrefix "ldaps://"
> (include "...ldapUrlOrEmpty" .)) (not .insecure) -}}true`. With url set explicitly, ldapUrlOrEmpty returns
> i…

**Suggested fix** (the reviewer's, not validated as the right one)

  In README.md:33-42, either add the prerequisite line above the block (`oc create configmap my-ldap-ca -n
  openshift-config --from-file=ca.crt=root-ca.pem`) plus `oauthSecretExtraction.caCopy.sourceCa.name: my-
  ldap-ca`, or add one sentence after the block: "This also needs the source CA in `openshift-config` — see
  [Detailed CA Certificate Setup](#detailed-ca-certificate-setup); skip it only if the c

### #34 · medium · confirmed

README documents subscription.installPlanApproval as Automatic while values.yaml ships Manual, and CI's
README check structurally cannot see subscription.* rows

**Evidence**

> Both halves reproduce exactly, including the reviewer's numbers. The wrong row, README.md:725 on main: |
> subscription.installPlanApproval | Install plan approval | Automatic | $ git show main:charts/group-sync-
> operator-helm/values.yaml | grep -n installPlanApproval 230: installPlanApproval: Manual
> values.yaml:213-230 is a 17-line rationale for Manual ("MANUAL BY DEFAULT, and that is a deliberate choice
> with a cost... Manual is the upgrade gate"). It inverts a control, not just a value. 01.7-installplan-
> approver.yaml:11 is `{{- if and .Values.installPlanApprover.enabled (eq
> .Values.subscription.installPlanApproval "Manual") }}`. Measured: $ helm template r charts/group-sync-
> operator-helm --se…

**Suggested fix** (the reviewer's, not validated as the right one)

  Change README.md:725's default to `Manual`. In ci.yaml:168, replace the prefix alternation with a generic
  top-level-key match, e.g. `^\| ([a-zA-Z][\w.]*\.[\w.\[\]]+) \|[^|]*\| ([^|]+)\|`, and skip only paths
  containing `[]` (which `dig` cannot resolve) so a new top-level block is covered the day it is added.

### #39 · medium · confirmed

clean-restart waits for Ready on a run-to-completion Pod, so set -e kills it before the scale-back

**Evidence**

> Code, current main, `setup-local-ldap-testing/30-manage-ldap-server.sh` (byte-identical to main): :11 set
> -e :590 kubectl scale deployment openldap-server -n $NAMESPACE --replicas=0 :595 cat <<EOF | kubectl apply
> -f - (pod pvc-cleaner, restartPolicy: Never, command ['sh','-c','rm -rf /data/* && echo "PVC cleaned
> successfully"']) :617 kubectl wait --for=condition=ready pod pvc-cleaner -n $NAMESPACE --timeout=60s :618
> kubectl logs pvc-cleaner :619 kubectl delete pod pvc-cleaner :622 kubectl scale deployment openldap-server
> -n $NAMESPACE --replicas=1 :683 clean-restart) clean_restart ;; <- plain call, errexit fully in force A
> completed Pod is permanently not-Ready, verified against a genuinely …

**Suggested fix** (the reviewer's, not validated as the right one)

  Two edits. (1) Wait for the right condition at :617: `kubectl wait
  --for=jsonpath='{.status.phase}'=Succeeded pod pvc-cleaner -n "$NAMESPACE" --timeout=60s`. (2) Make the
  scale-back unconditional so a cleaner failure can never leave the directory down — add `trap 'kubectl
  scale deployment openldap-server -n "$NAMESPACE" --replicas=1' RETURN` at the top of clean_restart (after
  the confirmation prom

### #40 · medium · partly

set -e makes the `if [ $? -eq 0 ]` error branches dead code in 30-manage-ldap-server.sh and 20-import-ldap-
data.sh

**Evidence**

> OVERALL: the dead-code mechanism is confirmed at every site claimed (9 + 2 = 11). Two stated consequences
> are wrong, and the severity is overstated. Per-item: (a) 30-manage-ldap-server.sh — all nine sites
> verified present at the exact cited lines. `grep -n 'if \[ \$? ' 30-manage-ldap-server.sh` → 249, 265,
> 277, 306, 322, 338, 350, 390, 434; count=9. `set -e` at :11; every function is called plainly from the
> case at :634-687 (no if/&&/||/! wrapper), so the errexit exemption does not apply. Mechanism reproduced
> live in a faithful harness (function called plainly from a case, real failing kubectl exec): $ oc exec -c
> openldap -n ldap-testing openldap-server-b584b4898-grr8n -- ldapsearch -x -H ld…

**Suggested fix** (the reviewer's, not validated as the right one)

  Capture the status out of the `if`, at all eleven sites: `set +e; <cmd>; rc=$?; set -e` then `case $rc in
  0) ... ;; 68) echo 'entries already exist — continuing' ;; *) exit 1 ;; esac`. Concretely for 20-import-
  ldap-data.sh, replace :76-93 and :109-125 with that shape so re-import tolerates 68 (LDAP_ALREADY_EXISTS)
  instead of exiting 1, and consider adding `-c` to the ldapadd at :76 so it continues

### #41 · medium · confirmed

90-verify-all-resources.sh: four defects that make it report false results

**Evidence**

> OVERALL confirmed — all four sub-defects are real in current main (file byte-identical to main). (d) fires
> right now on this healthy cluster; (a), (b) and (c) are genuine but latent under today's conditions, which
> the finding itself scopes correctly. Per-item: (a) `grep -c ... || echo "0"` → "0\n0", then :122
> arithmetic aborts. CONFIRMED. Idiom at :110, :111, :112, :119, :120, :121; only :111/:119/:120/:121 feed
> the arithmetic at :122. `set -e` at :3. $ V=$(printf "" | grep -c "^cn:" || echo "0"); printf 'V=[%s]
> bytes=%s\n' "$V" "$(printf '%s' "$V"|wc -c)" V=[0\n0] bytes=3 $ bash -c 'set -e; X=$(printf "" | grep -c
> "^cn:" || echo "0"); Y=$((10 - X)); echo REACHED'; echo rc=$? bash: 0\n0: syn…

**Suggested fix** (the reviewer's, not validated as the right one)

  (a) `$( ... | grep -c "^cn:" || true )` at :110, :111, :112, :119, :120, :121 — grep -c already prints 0;
  better still, drop `2>/dev/null` or add an explicit failure check so a broken ldapsearch is reported
  instead of silently counted as zero. (b) at :66-67 capture once with `LDAP_POD=$(kubectl get pods ... -o
  jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $1}')` and branch on `[ -

### #42 · medium · confirmed

`30-manage-ldap-server.sh` `web` and `web-delete` apply/delete manifests that do not exist in the repo

**Evidence**

> Reproduced against main (b4befa9; the file is byte-identical on main and on disk — `git diff --stat
> main..HEAD` touches only two chart test templates). References vs. reality: ``` $ grep -n 'ldap-
> rbac\.yaml\|[^0-9-]phpldapadmin\.yaml' 30-manage-ldap-server.sh 535: kubectl apply -f ldap-rbac.yaml 536:
> kubectl apply -f phpldapadmin.yaml 571: kubectl delete -f phpldapadmin.yaml --ignore-not-found=true $ ls
> -1 *.yaml 01-ldap-server.yaml 02-phpldapadmin.yaml 03-ldap-bootstrap-job.yaml $ git ls-files | grep -i
> 'ldap-rbac' setup-local-ldap-testing/ldap-rbac-groups-spar-trno.ldif <- an LDIF, not a manifest ``` So
> `ldap-rbac.yaml` exists nowhere in the tree and `phpldapadmin.yaml` is really `02-phpld…

**Suggested fix** (the reviewer's, not validated as the right one)

  Point :536 and :571 at `02-phpldapadmin.yaml`, and delete :535 (there is no RBAC manifest to apply;
  `deploy_ldap` needs none). Combine with the SCRIPT_DIR anchoring from finding 43 so both resolve
  regardless of CWD.

### #45 · medium · confirmed

`50-simulate-ldap-operations.sh` prints green confirmations for operations that did not happen

**Evidence**

> All three headline defects reproduce; two secondary line citations in (c) are misattributed and (a) is
> internally inconsistent about `set -e`. (a) force_groupsync :105-116 — CONFIRMED in substance. :111
> discards stdout, stderr AND status (`>/dev/null 2>&1`); :115 prints the green "triggered" whenever the
> patch call returns 0, without ever checking that a sync occurred. :586 only *warns* when the CR is missing
> and main continues into :111, which then patches a nonexistent CR — `oc get groupsync does-not-exist` ->
> `Error from server (NotFound)`, exit 1, so the patch fails the same way and `set -e` (:3) kills the
> interactive session with zero output. (I could not execute the patch — mutation is…

**Suggested fix** (the reviewer's, not validated as the right one)

  (a) Have force_groupsync delegate to 60-force-groupsync.sh, which already does the generation bump plus
  the poll on lastSyncSuccessTime, and reconcile the contradictory comment at :107 (and README.md:436/439)
  with 60-force-groupsync.sh:4-7. (b) Use `--no-headers`, test `[ -z "$out" ]` explicitly, and drop `head
  -20` or raise it above the group count (42 lines today). (c) In remove_user_from_group,

### #4 · low · confirmed, narrowed by the adversarial pass

InstallPlan approver ClusterRole omits clusterserviceversions, so csv_phase() is permanently empty and two
escape paths are dead

**Evidence**

> Baseline: working tree is on branch fix/tests-use-the-resolved-url (PR #21, HEAD 67c1af7); origin/main is
> b4befa9. `diff -q` against a pristine `git archive origin/main` extract says SAME for 01.7-installplan-
> approver.yaml, so what I read IS main. Template: charts/group-sync-operator-
> helm/templates/01.7-installplan-approver.yaml:30-37 grants only installplans (get,list,watch,patch) and
> subscriptions (get,list,watch). No clusterserviceversions. The script still calls `oc get csv` at :119
> (csv_phase) and :160 (orphan hint). Live cluster (chart 0.4.0, release group-sync rev 47): $ oc auth can-i
> get clusterserviceversions.operators.coreos.com -n group-sync-operator --as=system:serviceaccount:gro…

**Adversarial pass**

> The RBAC omission is real and reproduces, but the finding's remedy is net-negative and its severity is
> overstated. Accurate version: the installplan-approver ClusterRole (01.7:30-37) omits
> clusterserviceversions, so csv_phase() (:119-121) receives a Forbidden that `2>/dev/null` discards and
> returns empty forever. The only CERTAIN harm is diagnostic: the swallowed Forbidden is indistinguishable
> fro

**Suggested fix** (the reviewer's, not validated as the right one)

  Add clusterserviceversions to the rule block at 01.7:32-37 (`get`, `list`) -- and, per finding 15, do it
  in a namespaced Role rather than the ClusterRole. Drop `2>/dev/null` from csv_phase (:119) and the hint
  (:160), or log one `oc auth can-i list clusterserviceversions -n $NAMESPACE` result at startup, so a
  Forbidden is never again indistinguishable from "OLM has staged nothing".

### #11 · low · confirmed

cmd_trust_cluster writes openshift-config/$TRUST_BUNDLE_CM before the guard that refuses a foreign trust
bundle, and that ConfigMap gets no guard/backup at all

**Evidence**

> Still present on main (b4befa9); PR #15 fixed cmd_delete (finding 3), not cmd_trust_cluster. Line numbers
> moved from the finding's :343-357 to :349-369. Source order in /Users/olasumbo/gitRepos/group-sync-
> operator-helm-chart/setup-local-ldap-testing/15-bootstrap-cert-manager-ca.sh: :355-359 step "publishing
> the root to openshift-config/${TRUST_BUNDLE_CM}" ; oc create configmap "$TRUST_BUNDLE_CM" -n openshift-
> config --from-file=ca-bundle.crt=... --dry-run=client -o yaml | oc label --local ... | oc apply -f -
> :362-369 current=$(oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}') ; if [ -n "$current" ] && [
> "$current" != "$TRUST_BUNDLE_CM" ]; then die "proxy/cluster already trusts Config…

**Suggested fix** (the reviewer's, not validated as the right one)

  Move the :362-369 proxy check and the :371-373 backup above the ConfigMap write at :355-359, and route
  $TRUST_BUNDLE_CM through guard_existing_configmap with the key parameterised (it uses ca-bundle.crt, not
  ca.crt) so it gets the same ownership/expiry check and backup as ca-config-map.

### #15 · low · confirmed, narrowed by the adversarial pass

InstallPlan approver uses ClusterRole + ClusterRoleBinding where a namespaced Role would do, granting
installplan patch in every namespace

**Evidence**

> 01.7-installplan-approver.yaml:22-54 is a ClusterRole + ClusterRoleBinding. Live: $ oc get
> clusterrolebinding group-sync-operator-installplan-approver -o jsonpath='{.kind} ->
> {.roleRef.kind}/{.roleRef.name}' ClusterRoleBinding -> ClusterRole/group-sync-operator-installplan-
> approver $ A=system:serviceaccount:group-sync-operator:group-sync-operator-installplan-approver $ oc auth
> can-i patch installplans.operators.coreos.com -n <ns> --as=$A openshift-operators: yes | openshift-gitops:
> yes | default: yes | kube-system: yes Nothing in the script needs cluster scope. I read all 229 lines:
> every API call is namespaced to $NAMESPACE -- :103 (subscription), :107 (installplan), :119 (csv), :136
> (subsc…

**Adversarial pass**

> The over-scoping is real and reproduces on current main: 01.7-installplan-approver.yaml:22-54 renders a
> ClusterRole + ClusterRoleBinding granting `installplans get/list/watch/patch` in every namespace, with
> default values (installPlanApprover.enabled: true at values.yaml:339, subscription.installPlanApproval
> default Manual), and nothing the Job does needs cluster scope — the Subscription is hardco

**Suggested fix** (the reviewer's, not validated as the right one)

  Convert 01.7:22-54 to a Role + RoleBinding in {{ .Values.groupSync.namespace }} (same annotations, same
  rules, plus the clusterserviceversions rule from finding 4 -- which is also namespaced). Optionally reduce
  standing exposure further by giving the RBAC the same helm.sh/hook + hook-delete-policy treatment as the
  Job so it does not persist for the life of the release; that trade should be measure

### #16 · low · confirmed

CI's bare-chart-path check does not cover NOTES.txt (or *.sh), which contain bare `.`/`..` helm commands

**Evidence**

> The gap is real on main. .github/workflows/ci.yaml:190-201 greps with `--include='*.md'
> --include='*.yaml'` only, and NOTES.txt is neither. Running the check's exact grep from the repo root
> today finds nothing (exit 1, clean), so nothing else covers those files. NOTES.txt still prints five
> bare-`.` commands (charts/group-sync-operator-helm/templates/NOTES.txt): :39 helm install {{ .Release.Name
> }} . --set oauthSecretExtraction.enabled=true :45 helm install {{ .Release.Name }} . --set
> groupSync.enabled=false :48 helm upgrade {{ .Release.Name }} . --set groupSync.enabled=true :51 helm
> install {{ .Release.Name }} . --set oauthSecretExtraction.enabled=true :114 helm upgrade {{ .Release.Name
> }} .…

**Suggested fix** (the reviewer's, not validated as the right one)

  At ci.yaml:193 add `--include='*.txt' --include='*.sh'` AND loosen the pattern so a templated release name
  does not defeat it (e.g. 'helm (install|upgrade|template|lint) .*[[:space:]]\.{1,2}([[:space:]]|\\|$)'),
  then verify it reports the five NOTES.txt lines and the two script lines before fixing them to
  charts/group-sync-operator-helm (and ../charts/group-sync-operator-helm + the chart-dir value

### #19 · low · partly

helm lint exits 0 on a chart that cannot render, so the CI lint step asserts nothing

**Evidence**

> The observable half reproduces exactly on main (.github/workflows/ci.yaml:23-24 is byte-identical to
> main). `helm lint <chart>` with no values file: engine.go:227: [INFO] Fail: groupSync.url is empty and no
> LDAP url could be derived from the cluster OAuth CR. engine.go:227: [INFO] Fail: groupSync.url is empty
> and no LDAP url could be derived ... ==> Linting .../charts/group-sync-operator-helm 1 chart(s) linted, 0
> chart(s) failed exit=0 Two [INFO] Fail lines, "0 chart(s) failed", exit 0 - as claimed. BUT the stated
> mechanism is REFUTED. The claim "The CI step ... therefore cannot fail on a template error" is false. I
> injected a genuine template error (`{{ .Values.doesNotExist.nope }}`) into a…

**Suggested fix** (the reviewer's, not validated as the right one)

  Do not adopt `--strict` - it is proven not to fix this. If you want lint to also catch a `fail`-guard
  regression, grep its output: `out=$(helm lint "$CHART" -f "$CHART/crc-values.yaml" 2>&1); echo "$out";
  grep -q '\[INFO\] Fail' <<<"$out" && { echo '::error::a fail guard fired during lint'; exit 1; }`.
  Otherwise leave ci.yaml:23-24 alone; the coverage the finding says is missing lives at ci.yaml:3

### #23 · low · confirmed

10-setup-oauth-secrets.sh base64-decodes a plaintext ConfigMap value, so its own verification always warns

**Evidence**

> Reproduced live. setup-local-ldap-testing/10-setup-oauth-secrets.sh is byte-identical to main; line 114 is
> verbatim: if oc get configmap ca-config-map-test -n openshift-config -o jsonpath='{.data.ca\.crt}' |
> base64 -d 2>/dev/null | openssl x509 -noout -text >/dev/null 2>&1; then The premise the finding rests on
> is correct - the value is in .data, not .binaryData, so it is plain text: oc get cm ca-config-map-test -n
> openshift-config -o json | python3 -c "..." data keys: ['ca.crt'] binaryData keys: [] oc get cm ca-config-
> map-test -n openshift-config -o jsonpath='{.data.ca\.crt}' | head -c 27 -----BEGIN CERTIFICATE-----
> Running the script's exact condition against the real ConfigMap it checks: …

**Suggested fix** (the reviewer's, not validated as the right one)

  Delete `| base64 -d 2>/dev/null` from setup-local-ldap-testing/10-setup-oauth-secrets.sh:114, leaving `...
  -o jsonpath='{.data.ca\.crt}' | openssl x509 -noout -text >/dev/null 2>&1`.

### #26 · low · confirmed

argocd-application.yaml sets RespectIgnoreDifferences=true but ships no ignoreDifferences entry, which the
chart itself states is required

**Evidence**

> Validated against main b4befa9 (working tree was on fix/tests-use-the-resolved-url; main extracted via
> `git archive main`, which differs only in templates/tests/*.yaml). (1) The repo states the prerequisite in
> TWO places, and grep finds zero actual `ignoreDifferences:` keys anywhere: $ grep -rn 'ignoreDifferences'
> <main-tree> charts/group-sync-operator-helm/templates/01.4-trusted-ca-configmap.yaml:26: # NOT sufficient
> alone: the Argo Application also needs an ignoreDifferences entry for this CA_CERTIFICATE_FLOW.md:118:
> 'That is **not sufficient alone** — the Application also needs an `ignoreDifferences` entry for this
> ConfigMap's `data`, which the chart cannot set. Without both, Argo reverts…

**Suggested fix** (the reviewer's, not validated as the right one)

  Add to argocd-application.yaml spec (sibling of syncPolicy): ignoreDifferences: - group: "" kind:
  ConfigMap name: ldap-trusted-ca namespace: group-sync-operator jsonPointers: ["/data"] and cross-reference
  it from the comment at 01.4:26-27 and CA_CERTIFICATE_FLOW.md:118 so the three stay linked. Note in the
  Application that the entry is only needed when trustedCA.injected.enabled is true.

### #27 · low · confirmed

values.yaml documents ttlSecondsAfterFinished: 300 for the extraction Job; the template line is a YAML
comment, so the knob is inert

**Evidence**

> Validated against main b4befa9, and proven on the live cluster. (1) The documented knob, verbatim: $ sed
> -n '322p' charts/group-sync-operator-helm/values.yaml ttlSecondsAfterFinished: 300 # cleanup job after 5
> minutes (2) The only template line that would consume it is commented out: $ grep -rn
> ttlSecondsAfterFinished charts/group-sync-operator-helm/templates/ 01.5-oauth-secret-extraction-
> job.yaml:16: # ttlSecondsAfterFinished: {{ .Values.oauthSecretExtraction.ttlSecondsAfterFinished }} #
> Commented out to keep Job for audit purposes 01.7-installplan-approver.yaml:76: ttlSecondsAfterFinished:
> {{ .Values.installPlanApprover.ttlSecondsAfterFinished }} 02.2-operator-wait-job.yaml:36: ttlSecondsA…

**Suggested fix** (the reviewer's, not validated as the right one)

  Pick one and make the docs match. Either delete oauthSecretExtraction.ttlSecondsAfterFinished from
  values.yaml:322 and say in its place that this Job is deliberately kept for audit (also fix operator-
  health-test.sh:366), or uncomment 01.5:16 and default the value to 0 with the audit note. Leaving a
  documented knob that the template ignores is the one option to avoid.

### #28 · low · confirmed

qa-values.yaml's documented install command installs from the Helm repo while passing -f qa-values.yaml, a
file that is inside the tarball and not on the user's disk

**Evidence**

> Validated against main b4befa9 and reproduced read-only. (1) The command, verbatim from charts/group-sync-
> operator-helm/qa-values.yaml: :21 # helm install group-sync group-sync-operator/group-sync-operator-helm \
> :22 # -n group-sync-operator --create-namespace \ :23 # -f qa-values.yaml :24 # helm test group-sync -n
> group-sync-operator --logs Line 21 sources the chart from the Helm repo; line 23 passes a bare relative
> path. (2) qa-values.yaml ships INSIDE the chart tarball, so it is not in the user's working directory
> (packaged into scratchpad, repo untouched): $ helm package <main-tree>/charts/group-sync-operator-helm -d
> <scratchpad>/pkg $ tar -tzf group-sync-operator-helm-0.4.0.tgz | grep v…

**Suggested fix** (the reviewer's, not validated as the right one)

  In qa-values.yaml:21-24 either (a) prepend `helm show values group-sync-operator/group-sync-operator-helm
  > my-qa-values.yaml`, then `-f my-qa-values.yaml` with a note to paste this file's settings into it, or
  (b) switch the source to the local chart path the sibling files use: `helm install group-sync
  charts/group-sync-operator-helm ... -f charts/group-sync-operator-helm/qa-values.yaml`. The `hel

### #29 · low · confirmed

Twelve small chart/CI correctness and hygiene items

**Evidence**

> Overall: 10 of 12 sub-items confirmed exactly as written against main b4befa9; item 10 is already_fixed;
> item 4's mechanism is wrong (partly). Per item: [1] CONFIRMED. 01.2-oauth-extraction-
> clusterrole.yaml:16-19 (secrets get,list + resourceNames [sourceSecret.name]) and :22-25 (secrets
> get,list,create,update,patch,delete + resourceNames [targetSecret.name]). The file admits it at :81 'RBAC
> does not honour resourceNames for list'. Proven inert on the live cluster against the installed
> ClusterRole (["secrets"] ["get","list"] names=["ldap-secret"]): $ SA=system:serviceaccount:group-sync-
> operator:oauth-secret-extractor $ oc auth can-i get secret/ldap-secret -n openshift-config --as=$SA -> yes
> $…

**Suggested fix** (the reviewer's, not validated as the right one)

  Highest value first: [12] default customGroupSyncs.enabled to false (or ship the bda-rbac item commented
  out like the second example at values.yaml:196-198). [7] name the cluster-scoped test objects `{{ include
  "group-sync-operator-helm.fullname" . }}-{{ .Values.groupSync.namespace }}-test-role/-binding`. [5] anchor
  the ownership match on the `${SUBSCRIPTION}.v` prefix, matching csv_phase at 01.7:

### #33 · low · confirmed

README's "fast-track demo/testing" note misstates all three defaults it names, and contradicts its own table
6 lines below

**Evidence**

> The note is at README.md:638-640 on main (moved from :591-593 by PR #18's ArgoCD section; `git diff main
> -- README.md` is empty, so the working tree is main): > **Note:** the shipped `values.yaml` is a **fast-
> track demo/testing** configuration — > an in-cluster test LDAP over plain `ldap://`, a `*/2` schedule, and
> `insecure: true`. > Re-point these at your real LDAP (and use `ldaps://` + a CA) for production. All three
> claims are false against main's values.yaml: $ git show main:charts/group-sync-operator-helm/values.yaml |
> sed -n '33p;83p;92p' schedule: "*/30 * * * *" # :33 -- note says "*/2" url: "" # :83 -- note says "an in-
> cluster test LDAP over plain ldap://" insecure: false # :92 -- no…

**Suggested fix** (the reviewer's, not validated as the right one)

  Delete README.md:638-640 and change the :642 header from "Default (demo)" to "Default". Replace with one
  sentence: "The shipped defaults are deliberately incomplete rather than a demo — `groupSync.url` is empty
  so each cluster supplies it or it is derived from the OAuth CR (see values.yaml:65-83). Start from the
  Quick start above."

### #35 · low · confirmed

docs/DESIGN_custom_groupsync.md validation row 3: a command that fails, expecting 3 GroupSync objects when 2
render

**Evidence**

> The row is unchanged on main, docs/DESIGN_custom_groupsync.md:159, under "## 7. How we prove it works
> (validation)" whose preamble (:153) is "Run in order; each step must pass before the next.": | 3 | Renders
> cleanly | `helm template ../charts/group-sync-operator-helm -n group-sync-operator` | 3 GroupSync objects,
> valid YAML | Sub-claim (a) — the command fails. Ran it verbatim (relative path adjusted to repo root; no
> `-f`, as documented): $ helm template charts/group-sync-operator-helm -n group-sync-operator Error:
> execution error at (group-sync-operator-helm/templates/custom-groupsync.yaml:33:3): groupSync.url is empty
> and no LDAP url could be derived from the cluster OAuth CR. Either set g…

**Suggested fix** (the reviewer's, not validated as the right one)

  docs/DESIGN_custom_groupsync.md:159 → command `helm template release ../charts/group-sync-operator-helm -f
  ../charts/group-sync-operator-helm/crc-values.yaml -n group-sync-operator`, Pass = "2 GroupSync objects
  (`ldap-groupsync`, `bda-rbac-groupsync`), valid YAML".

### #36 · low · confirmed

README's "Why This Chart Doesn't Use Hooks" is false; the adjacent bullet links an absolute path in the
author's home directory; README's "essential components" note is stale

**Evidence**

> All three sub-claims hold on main. (1) The bullets, README.md:860-864 (moved from :815-817): ## Related
> Learning Materials For learning about Helm hooks and advanced deployment patterns: - **Helm Hooks Demo**:
> Check `/Users/olasumbo/gitRepos/hooks-demo/` for complete working examples and comprehensive documentation
> - **Why This Chart Doesn't Use Hooks**: We chose proper resource ordering and ArgoCD sync waves for better
> maintainability and production use (2) The chart uses Helm hooks extensively — exactly the five files the
> reviewer named, at the line numbers cited. Enumerated with `git show main:<f> | grep -n 'helm.sh/hook'`
> over every template: 01.5-oauth-secret-extraction-job.yaml:12 helm…

**Suggested fix** (the reviewer's, not validated as the right one)

  Delete README.md:860-864 outright (the linked directory is not publishable, and the claim is false).
  Rewrite README.md:752-753 as: "Ordering uses both `helm.sh/hook` (so plain `helm install` blocks on the
  wait Jobs) and `argocd.argoproj.io/sync-wave` (so Argo runs them inside the sync) — see 02.2-operator-
  wait-job.yaml:8-10 and the 'Install ordering' section above."

### #37 · low · confirmed

README's "View sync logs" command selects chart-created pods, not the OLM operator Deployment

**Evidence**

> Doc (current main, line drifted from :800 to :847). `sed -n '830,850p' README.md`: "1. View sync logs:"
> ```bash oc logs -l app.kubernetes.io/name=group-sync-operator-helm -n group-sync-operator ``` Code: the
> label comes from `charts/group-sync-operator-helm/templates/_helpers.tpl:41` — `app.kubernetes.io/name: {{
> include "group-sync-operator-helm.name" . }}` inside the `...labels` helper, which only chart-rendered
> objects include. Live proof — `oc get pods -n group-sync-operator --show-labels`: group-sync-operator-
> controller-manager-747bf95595-wrfxl Running control-plane=group-sync-operator,pod-template-hash=747bf95595
> group-sync-operator-oauth-secret-extraction-glg9f Completed ...,app.kuber…

**Suggested fix** (the reviewer's, not validated as the right one)

  README.md:847 → `oc logs -n group-sync-operator deployment/group-sync-operator-controller-manager -c
  manager --tail=100`. That form is already used at README.md:414 and :854, so this makes the
  Troubleshooting section agree with the section above it. (`-l control-plane=group-sync-operator` also
  works and matches the test scripts, but the deployment form is what the rest of the README already teache

### #38 · low · confirmed

DESIGN_custom_groupsync.md §6.3 says the customGroupSyncs master switch defaults to false; it ships true

**Evidence**

> Doc, verbatim `sed -n '145,150p' docs/DESIGN_custom_groupsync.md`: ### 6.3 The values block The
> `customGroupSyncs` block from §4 is added to `values.yaml`, with comments and a default of `enabled:
> false` for the master switch (safe default — off until a team opts in). The demo values turn it on with
> the two example items. Code, `charts/group-sync-operator-helm/values.yaml`: 182: customGroupSyncs: 184:
> enabled: true <- master switch, ships ON 188: enabled: true 189: groupCn: "bda-rbac-*" "The demo values
> turn it on" rests on a false premise: there is no demo values file. `ls charts/group-sync-operator-
> helm/*.yaml` → Chart.yaml, crc-injected-values.yaml, crc-values.yaml, qa-values.yaml, values…

**Suggested fix** (the reviewer's, not validated as the right one)

  Pick one side and make them agree. Cheapest and safest: set `values.yaml:184` to `enabled: false` and
  comment out the bda-rbac item at :187-192 the same way :196-198 already comments out the second example.
  That satisfies the doc, lets `qa-values.yaml:52-53` drop its override, and stops every default install
  creating a CR for a group pattern the cluster does not have. If instead the intent is to s

### #43 · low · partly

Relative manifest paths make the destructive subcommands abort halfway

**Evidence**

> The underlying observation is real; the described mechanism and blast radius are wrong, and one of the two
> cited scripts already guards against it. CONFIRMED — no directory anchoring, and the precedent claim is
> accurate: ``` $ grep -n 'SCRIPT_DIR\|dirname\|BASH_SOURCE\|^cd ' 30-manage-ldap-server.sh 20-import-ldap-
> data.sh 50-simulate-ldap-operations.sh NONE FOUND $ grep -n 'SCRIPT_DIR\|dirname' 15-bootstrap-cert-
> manager-ca.sh 80:SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
> 81:BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/.ca-configmap-backup}" ``` And from the repo root every
> referenced file is unresolvable: ``` 01-ldap-server.yaml ABSENT from CWD 02-phpldapadmin.yaml ABSENT fr…

**Suggested fix** (the reviewer's, not validated as the right one)

  Add `SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"` (copy :80 of 15-bootstrap-cert-
  manager-ca.sh) to 30-manage-ldap-server.sh and 20-import-ldap-data.sh and prefix every manifest/LDIF path
  with it. Keep 20-import's `-f` guards — they are the correct pattern, not the bug.

### #44 · low · partly

`extract_ca_cert` deletes then recreates a ConfigMap in `openshift-config`, non-atomically and unguarded

**Evidence**

> Every code-level sub-claim reproduces exactly at the quoted lines; the function name, the trigger command
> and the blast radius are all wrong. CONFIRMED (code as quoted, verbatim at :427-432, :421-423, :399-406):
> - Non-atomic delete-then-create in a namespace the script does not own (:427 `kubectl delete configmap ca-
> config-map-test -n openshift-config`, then :430-432 `kubectl create configmap ... -n openshift-config`),
> while the same file already knows the atomic idiom at :62-63 (`kubectl create ... --dry-run=client -o yaml
> | kubectl apply -f -`). - :421-423 will `kubectl create namespace openshift-config` on the strength of a
> failed `kubectl get`. - The `-z "$CERT_DATA"` handler at :403-406…

**Suggested fix** (the reviewer's, not validated as the right one)

  Replace :427-432 with the single atomic pipeline already used at :62-63; delete :421-423 (openshift-config
  always exists on OpenShift); add `set -o pipefail` and split :399-401 so the `kubectl exec` status and the
  `openssl` status are checked separately, making :403-406 reachable. Same for the dead `$?` branches at
  :390 and :434/:462-465.

### #46 · low · confirmed

`60-force-groupsync.sh`'s pageSize toggle destroys any value that is not 0 or 1000, and breaks when the
field is absent

**Evidence**

> Both defects hold, and the premise most at risk of being wrong — the "absent field yields empty, not an
> error" step — checked out empirically. Defect 1, the toggle is not a toggle (:23). Reproduced: ``` $ bash
> -c 'set -euo pipefail; current="500"; toggled=$([ "$current" = "0" ] && echo 1000 || echo 0); echo
> "pageSize 500 -> $toggled"' pageSize 500 -> 0 ``` Any value other than `0` becomes `0`; on the next run
> `0` becomes `1000`, so an original `500` is unrecoverable. The header comment :9-11 asserts the toggle is
> "between 0 and 1000" and nothing at :22-23 verifies that. Defect 2, the absent-field path. The critical
> premise is confirmed — kubectl/oc jsonpath returns EMPTY with exit 0 (it does…

**Suggested fix** (the reviewer's, not validated as the right one)

  Use `"op":"add"` at :27 so it works whether or not pageSize is set, and make the toggle explicit: assert
  `case "$current" in ''|0|1000) ;; *) die "pageSize is $current; refusing to overwrite it" ;; esac` before
  computing `toggled=$([ "${current:-0}" = "0" ] && echo 1000 || echo 0)`. Wrap :21 with a friendly
  existence check, and move the `sleep 2` to the top of the loop body.

### #47 · low · partly

Smaller setup-script items (grab-bag of 6)

**Evidence**

> Overall: partly — items 1, 2, 4 and 5 confirmed as described; item 3 confirmed on ordering but its
> pipefail sub-claim is weakened; item 6 confirmed on /tmp hygiene but its return-path claim is refuted.
> Severity low/nit as the finding itself grades it. Per item: 1. `20-import-ldap-data.sh:70` — CONFIRMED,
> including the arithmetic. :70 has no `|| true`; `grep -c` on zero matches prints 0 and exits 1 (`printf
> "hello\n" | grep -c nomatch` -> `0`, exit=1), kubectl exec propagates the remote status, and `set -e`
> (:11) kills the script. The count is wrong by exactly the factor claimed: ``` grep -c 'app-ocp-rbac-'
> ldap-structure-combined.ldif = 42 grep -c '^dn: cn=app-ocp-rbac-' ldap-structure-combi…

**Suggested fix** (the reviewer's, not validated as the right one)

  1. Add `|| true` at :70 and count `'^dn: cn=app-ocp-rbac-'`; replace the `|| echo "0"` idiom at :150/:170
  with `|| true` plus `${VAR:-0}`. 2. Prompt in `delete_all` as `clean_restart` does at :582, and quote
  `"$NAMESPACE"`. 3. Move :62-63 above :59. 4. Append `|| true` to :366. 5. Use `awk '{print $NF}'
  <<<"$fullname"` and validate the `read` input is non-empty. 6. Use `mktemp` plus `trap 'rm -f "

### #10 · refuted

Claim that the extraction Job is an ordinary ArgoCD manifest that never re-runs and breaks the sync on a
spec change

> The annotation facts are exactly as stated: 01.5-oauth-secret-extraction-job.yaml:10-14 carries
> argocd.argoproj.io/sync-wave: "2", helm.sh/hook: post-install,post-upgrade, helm.sh/hook-weight: "5",
> helm.sh/hook-delete-policy: before-hook-creation, and no argocd.argoproj.io/hook. `grep -l
> argocd.argoproj.io/hook templates/*.yaml` returns only 01.7 and 02.2. Confirmed against the rendered
> output too. The inference is what fails. ArgoCD does not require its own hook annotation -- it maps
> Helm's: -

---

## Not from the reviewers

Two defects came from the CI render-matrix design work rather than any reviewer, and both are fixed:

- `groupSync.ca.kind=Secret` with the copy written as a ConfigMap — the operator looked for an object
  nobody created. Refused at render time (#25).
- `trustedCA.injected.enabled=true` created a labelled ConfigMap and repointed nothing, so OpenShift
  filled a 149-certificate bundle that was never read. Now resolves the CA for the CR, the Job's
  preflight, the RBAC and both test pods from one switch (#26).

And one from a later review of that work: `subscription.name` supplied the Subscription object's name
while `spec.name` was hardcoded, so they could diverge — and the hook Jobs match CSV names, which come
from the package. Both now come from one value (#27).

## Scope decisions

- **Active Directory support** — parked.
- **`setup-local-ldap-testing/ca-key.pem`** — deliberately kept; it is a test-cluster CA.
- **`proxy/cluster.spec.trustedCA`** — kept, and must stay unmanaged by the chart. On a real cluster it
  belongs to whoever owns identity management.
- **`customGroupSyncs.items[].namespace`** — left alone. It is documented and honoured but a CR outside
  `WATCH_NAMESPACE` is never reconciled. Plumbing item namespaces into `WATCH_NAMESPACE` would add
  coupling for a capability nobody uses; every GroupSync lives in the release namespace. If it ever
  matters, guard it or drop the knob.

