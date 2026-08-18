# Testing a fork build of group-sync-operator on a real cluster

How to take a code change in our fork of `group-sync-operator`, turn it into an image, a bundle and a
catalog, install it with OLM through this chart, prove it works, and put the cluster back.

Written for someone who has not done it before. Every command here was run end to end on CRC 4.18 to
validate the adoption fix for
[redhat-cop/group-sync-operator#466](https://github.com/redhat-cop/group-sync-operator/issues/466). The
mistakes are documented too, because each one cost time and will cost you the same time if you rediscover
them.

**Why this exists.** OLM gives no supported way to override an operator's own image: `Subscription.spec.config`
has no image field (checked against the CRD schema), and `RELATED_IMAGE_*` is an *operand* hint read by the
already-running operator, so it cannot change the image OLM launched. Patching the installed CSV works but
reverts whenever OLM installs a fresh CSV from the catalog. Building our own catalog is the durable answer:
OLM installs from what we tell it to trust, so nothing has to be re-patched.

---

## 0. Before you start

| need | check | notes |
|---|---|---|
Docker running | `docker info` | podman also works, but see the OOM note in step 2 |
quay write access | `docker login quay.io` | you need **three** repos, all public |
`oc` logged in as admin | `oc whoami` | you will delete and recreate a Subscription and a CSV |
`operator-sdk` | `operator-sdk version` | v1.42.0 used here; the Makefile downloads `opm` itself |
Go | `go version` | must satisfy `go.mod` — see the toolchain note in step 2 |

Three quay repos, **created in advance and public**:

```
quay.io/<you>/group-sync-operator            the operator image
quay.io/<you>/group-sync-operator-bundle     the bundle
quay.io/<you>/group-sync-operator-catalog    the catalog
```

> Public matters. A private bundle needs a pull secret for OLM's unpack Job, and a private catalog needs one
> on the CatalogSource. Public keeps it to zero extra moving parts. Quay will **not** auto-create these for a
> robot account: a push to a repo that does not exist fails with `unauthorized`, which reads like a
> credentials problem and is not one. Check with
> `curl -s -o /dev/null -w '%{http_code}' https://quay.io/api/v1/repository/<you>/<repo>` — **200** public,
> **401** exists but private, **404** absent.

---

## 1. Commit the change first

```bash
cd ~/gitRepos/group-sync-operator
git checkout -b fix/<your-change>
# ... make the change, add tests ...
go build ./... && go test ./...
git commit -s                     # -s matters: the maintainers sign off, and 15 of the last 40 commits do
git push -u origin fix/<your-change>
```

**Commit before you build.** The image gets tagged with the commit hash, and a hash that names a commit
without your change is worse than no tag at all. This was nearly shipped here: `git rev-parse --short HEAD`
still read `f39330d` (upstream's merge commit) while the fix sat uncommitted in the worktree.

---

## 2. Build and push the operator image

```bash
export repo=<you>                                  # e.g. ephico2real
export SHA=$(git rev-parse --short HEAD)
export IMG=quay.io/$repo/group-sync-operator:$SHA

make docker-build IMG=$IMG                          # runs the test suite first, by design
docker tag  "${IMG}" "quay.io/$repo/group-sync-operator:latest"
docker push "${IMG}"
docker push "quay.io/$repo/group-sync-operator:latest"
```

Push **both** tags: the hash so a running pod can be traced to code, `latest` for convenience.

Three traps, all hit here:

- **`make docker-build` depends on `test`**, so a Go toolchain problem stops the image build. If you see
  `compile: version "go1.25.8" does not match go tool version "go1.25.5"`, the toolchain download was
  mid-flight or `make` resolved a different `go`. Fix by exporting it into make's environment:
  `GOTOOLCHAIN=go1.25.8 make docker-build IMG=$IMG`.
- **The in-container build needs memory.** On podman with a 2 GiB VM it dies on `msgraph-sdk-go` with
  `compile: signal: killed` — that is an OOM, not a code error. Docker Desktop with 7.7 GiB completed in
  ~7½ minutes. Either raise the VM (`podman machine set --memory 8192`) or use Docker.
- **Quote your variables with braces.** `"$REPO:latest"` in zsh applies the `:l` history modifier and
  silently produces `group-sync-operat**oratest**`, whose push fails `unauthorized` because that repo does
  not exist. Always `"${REPO}:latest"`.

Verify the digest is really on quay before moving on:

```bash
curl -s "https://quay.io/api/v1/repository/$repo/group-sync-operator/tag/?specificTag=$SHA&onlyActiveTags=true" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tags"][0]["manifest_digest"])'
```

---

## 3. Build the bundle

```bash
export VERSION=0.0.37                               # MUST be higher than the installed CSV
export BUNDLE=quay.io/$repo/group-sync-operator-bundle:v$VERSION

make manifests
make bundle IMG=$IMG VERSION=$VERSION
make bundle-build BUNDLE_IMG=$BUNDLE
docker push $BUNDLE
operator-sdk bundle validate $BUNDLE --select-optional name=operatorhubv2
```

**The version must beat what is installed.** The Makefile defaults to `VERSION ?= 0.0.1`, which is *older*
than the installed `v0.0.36`, so OLM would never upgrade and it would look as though the catalog was broken.
Check first: `oc get csv -n group-sync-operator | grep group-sync`.

**Point the bundle at the hash tag, not `latest`.** `make bundle IMG=...:$SHA` writes that reference into the
CSV, so "which code is running" has exactly one answer later.

Read back what was generated — do not assume:

```bash
python3 -c "
import yaml,glob
d=yaml.safe_load(open(glob.glob('bundle/manifests/*clusterserviceversion.yaml')[0]))
print(d['metadata']['name'], d['spec']['version'])
print({m['type']:m['supported'] for m in d['spec']['installModes']})
print(d['spec']['install']['spec']['deployments'][0]['spec']['template']['spec']['containers'][0]['image'])"
```

**Mind the install modes.** This operator's `config/manifests` base declares **AllNamespaces only**, while the
published community bundle for v0.0.36 declares `OwnNamespace`/`SingleNamespace`. That difference decides
step 5. Do **not** hand-edit the generated CSV to match the old one: if the result is going into an upstream
PR, the bundle must be what upstream's own config produces, or a reviewer can fairly ask whether the install
mode changed the outcome.

---

## 4. Build the catalog

```bash
export CATALOG=quay.io/$repo/group-sync-operator-catalog:v$VERSION
make catalog-build CATALOG_IMG=$CATALOG BUNDLE_IMGS=$BUNDLE
docker push $CATALOG
```

`make catalog-build` downloads `opm` (v1.55.0) into `./bin` and runs `opm index add --mode semver`. With no
`FROM_INDEX_OPT` the catalog contains only your bundle, which is what you want: the channel head is
unambiguously your version.

Then publish it to the cluster:

```bash
oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: group-sync-operator-fork
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/<you>/group-sync-operator-catalog:v0.0.37
  displayName: Group Sync Operator (fork)
  publisher: <you>
  updateStrategy:
    registryPoll:
      interval: 10m
YAML
```

Wait for it, and confirm it advertises your version:

```bash
oc get catalogsource group-sync-operator-fork -n openshift-marketplace \
  -o jsonpath='{.status.connectionState.lastObservedState}{"\n"}'          # want READY

oc get packagemanifest -n openshift-marketplace -l catalog=group-sync-operator-fork \
  -o jsonpath='{range .items[*]}{.metadata.name} {range .status.channels[*]}{.name}:{.currentCSV}{end}{"\n"}{end}'
```

`TRANSIENT_FAILURE` for the first ~45s is normal — the registry pod is still starting. It went
`TRANSIENT_FAILURE` → `READY` at t+48s here.

---

## 5. Install it through this chart

The chart carries a temporary overlay for exactly this, on branch `test/fork-catalog-0.0.37`:

```yaml
# charts/group-sync-operator-helm/fork-catalog-values.yaml
operatorGroup:
  allNamespaces: true        # v0.0.37 declares only the AllNamespaces install mode
subscription:
  source: group-sync-operator-fork
  sourceNamespace: openshift-marketplace
  startingCSV: group-sync-operator.v0.0.37
  installPlanApproval: Automatic
```

**You must uninstall the old CSV first.** Leaving it causes:

```
InterOperatorGroupOwnerConflict — intersecting operatorgroups provide the same apis
```

because the OperatorGroup covering the namespace and the old CSV both claim the `GroupSync` API. Scaling the
old deployment to 0 does **not** help — the *CSV* is the API provider, not the pod. Check the claims on the
CRD if you are unsure:

```bash
oc get crd groupsyncs.redhatcop.redhat.io -o jsonpath='{.metadata.labels}{"\n"}'
# operators.coreos.com/group-sync-operator.<namespace>: ""   <- one per claiming CSV
```

So:

```bash
# 1. save what you are removing — both are chart templates, so helm can restore them
oc get subscription group-sync-operator -n group-sync-operator -o yaml > /tmp/restore-subscription.yaml
oc get operatorgroup group-sync-operator-group -n group-sync-operator -o yaml > /tmp/restore-operatorgroup.yaml

# 2. remove the old install
oc delete subscription group-sync-operator -n group-sync-operator
oc delete csv group-sync-operator.v0.0.36  -n group-sync-operator

# 3. install the fork through the chart
helm upgrade group-sync charts/group-sync-operator-helm -n group-sync-operator \
  -f charts/group-sync-operator-helm/crc-values.yaml \
  -f charts/group-sync-operator-helm/fork-catalog-values.yaml \
  --wait --timeout 10m
```

Confirm the running pod is your build, by **digest**, not by tag:

```bash
oc get csv group-sync-operator.v0.0.37 -n group-sync-operator -o jsonpath='{.status.phase}{"\n"}'   # Succeeded
p=$(oc get pods -n group-sync-operator -o name | grep controller | head -1)
oc get $p -n group-sync-operator -o jsonpath='{.status.containerStatuses[?(@.name=="manager")].imageID}{"\n"}'
```

> `operatorGroup.allNamespaces` does not widen what the operator watches. `subscription.watchNamespaces` sets
> `WATCH_NAMESPACE` on the deployment, which overrides the CSV's fieldRef to `olm.targetNamespaces`. Verify:
> `oc get deployment ... -o jsonpath='{...env[?(@.name=="WATCH_NAMESPACE")].value}'`.

---

## 6. Prove it works

Take a snapshot **before** you change anything. Counts are not enough — record UIDs and resourceVersions,
because a delete-and-recreate produces identical counts.

```bash
oc get groups -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.labels.group-sync-operator\.redhat-cop\.io/sync-provider}|{.metadata.annotations.group-sync-operator\.redhat-cop\.io/sync-time}|{.metadata.resourceVersion}{"\n"}{end}' | sort > /tmp/before.txt

oc get clusterrolebinding,rolebinding -A -l app.kubernetes.io/managed-by=namespace-configuration-operator \
  -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' | sort | shasum -a 256
```

Then create the condition under test. For the adoption fix that means renaming a CR:

```bash
helm upgrade group-sync charts/group-sync-operator-helm -n group-sync-operator \
  -f .../crc-values.yaml -f .../fork-catalog-values.yaml -f /tmp/rename.yaml --wait
```

**Then force a reconcile, and understand why you must.** Immediately after a rename you will see *skips*,
not adoptions:

```
19:34:42   21x "Group Provider Label Did Not Match Expected Provider Label"
19:39:58   21x "Adopting Group Whose GroupSync No Longer Exists"
```

Those skips are **correct**: helm creates the new CR before deleting the old one, and during that overlap the
old owner is still live, so the guard refuses — which is the contention protection working. Adoption happens
on the **next reconcile after the old CR is gone**, and this CR runs hourly, so nothing appears until you
trigger one:

```bash
./setup-local-ldap-testing/60-force-groupsync.sh <renamed-cr> group-sync-operator
```

Do not read "0 adoptions" in the first minutes as a failure. That misreading happened here and cost a
diagnosis.

Then check all four, not just the label:

```bash
oc get groups -o jsonpath='...same as above...' | sort > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt        # label repaired, sync-time advanced, resourceVersion CHANGED
```

| what | why it matters |
|---|---|
label now names a live CR | the actual fix |
`sync-time` advanced | the Group was written, not just relabelled by something else |
`resourceVersion` **changed** | proof an `Update` was issued — in the bug report it stayed frozen across a forced sync |
RBAC uid-hash **unchanged** | no grant was deleted and recreated behind a matching count |
`oc auth can-i` unchanged | access is genuinely intact, in both directions |
second forced sync adopts 0 | idempotent |

---

## 7. Put the cluster back

Do this in order. Leaving a private build running on a shared cluster is the failure mode to avoid.

```bash
# 1. back to the published catalog and single-namespace OperatorGroup (drop the overlay)
helm upgrade group-sync charts/group-sync-operator-helm -n group-sync-operator \
  -f charts/group-sync-operator-helm/crc-values.yaml --wait --timeout 10m

# 2. remove the fork CSV so OLM installs the published one
oc delete csv group-sync-operator.v0.0.37 -n group-sync-operator --ignore-not-found

# 3. with installPlanApproval: Manual, approve the InstallPlan for the published version
oc get installplan -n group-sync-operator
oc patch installplan <name> -n group-sync-operator --type=merge -p '{"spec":{"approved":true}}'

# 4. delete the CatalogSource
oc delete catalogsource group-sync-operator-fork -n openshift-marketplace

# 5. verify
oc get csv -n group-sync-operator | grep group-sync          # expect the published version, Succeeded
oc get deployment group-sync-operator-controller-manager -n group-sync-operator \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}{"\n"}'   # expect quay.io/redhat-cop/...
oc get groups --no-headers | wc -l                            # expect the original count
```

Also revert any rename you made for the test, and re-check the RBAC uid-hash matches your snapshot.

**Do not leave behind:** the CatalogSource, the fork Subscription/CSV, any `BuildConfig`/`ImageStream` if you
experimented with in-cluster builds, and the multi-hundred-MB `bin/manager` in the fork worktree.

---

## What not to do, and why

| tempting | what happens |
|---|---|
Patch the installed CSV's image | Works, and reverts whenever OLM installs a fresh CSV from the catalog — an operator upgrade or a CSV recreate. Needs a re-patching CronJob to stay put. |
`Subscription.spec.config.env` with `RELATED_IMAGE_*` | Cannot change the operator's own image. `env` is injected into a pod OLM already created from the CSV image; the variable is read by code inside that image. Only useful for **operand** images, and this operator has no operands — it creates `Group` objects, not pods. |
A side Deployment running the image | Bypasses OLM entirely, so it proves the code but not that it installs. It also runs a second controller against the same CRs unless you scale the first to 0. |
`operator-sdk run bundle` | Creates its own OperatorGroup (`operator-sdk-og`) and CatalogSource. Fine in a fresh `oc new-project`; in a namespace that already has a chart-managed OperatorGroup and Subscription it collides. |
Editing the generated CSV's `installModes` | Makes the install easy and the evidence weaker — you are no longer testing what upstream's config produces. |
`oc start-build` in-cluster | No local container runtime needed, but the image never leaves the cluster's internal registry, so it cannot go in a bundle a maintainer could pull. |
