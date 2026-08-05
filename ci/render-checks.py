#!/usr/bin/env python3
"""Assertions for the CI render matrix. usage: check.py <check> <rendered.yaml>"""
import re, sys, yaml

def load(p):
    return [d for d in yaml.safe_load_all(open(p)) if d]

def pod_specs(docs):
    """(name, kind, spec) for every Job/Pod."""
    for d in docs:
        if d.get('kind') == 'Job':
            yield d['metadata']['name'], 'Job', d['spec']['template']['spec']
        elif d.get('kind') == 'Pod':
            yield d['metadata']['name'], 'Pod', d['spec']

def scripts(spec):
    for c in (spec.get('initContainers') or []) + spec['containers']:
        cmd = c.get('command') or []
        if len(cmd) >= 3 and cmd[0].endswith(('bash', 'sh')):
            yield c['name'], cmd[-1]

def rules_for_sa(docs, sa, ns):
    """Every (rule, role_namespace) reachable by ServiceAccount sa in namespace ns."""
    croles = {d['metadata']['name']: d for d in docs if d.get('kind') == 'ClusterRole'}
    roles = {(d['metadata']['namespace'], d['metadata']['name']): d
             for d in docs if d.get('kind') == 'Role'}
    out = []
    for d in docs:
        if d.get('kind') not in ('ClusterRoleBinding', 'RoleBinding'):
            continue
        if not any(s.get('kind') == 'ServiceAccount' and s.get('name') == sa
                   and s.get('namespace') == ns for s in d.get('subjects') or []):
            continue
        ref = d['roleRef']
        if ref['kind'] == 'ClusterRole':
            r = croles.get(ref['name'])
            # A ClusterRole via a RoleBinding only applies in that RoleBinding's namespace.
            scope = d['metadata'].get('namespace') if d['kind'] == 'RoleBinding' else '*'
            if r:
                out += [(rule, scope) for rule in r.get('rules') or []]
        else:
            r = roles.get((d['metadata']['namespace'], ref['name']))
            if r:
                out += [(rule, d['metadata']['namespace']) for rule in r.get('rules') or []]
    return out

def grants(rules, group, resource, verb, name=None, ns=None, unpinned=False):
    for rule, scope in rules:
        if ns is not None and scope not in ('*', ns):
            continue
        if unpinned and rule.get('resourceNames'):
            continue
        if group not in rule.get('apiGroups', []) and '*' not in rule.get('apiGroups', []):
            continue
        if resource not in rule.get('resources', []) and '*' not in rule.get('resources', []):
            continue
        if verb not in rule.get('verbs', []) and '*' not in rule.get('verbs', []):
            continue
        rn = rule.get('resourceNames')
        if rn and name is not None and name not in rn:
            continue
        return True
    return False

# ---------------------------------------------------------------- checks

def oauth_rbac(docs):
    """Any script that reads the cluster OAuth CR must be permitted to."""
    bad = []
    for name, kind, spec in pod_specs(docs):
        sa = spec.get('serviceAccountName')
        ns = None
        for d in docs:
            if d.get('kind') == kind and d['metadata']['name'] == name:
                ns = d['metadata'].get('namespace')
        for ctr, body in scripts(spec):
            if 'oc get oauth cluster' not in body:
                continue
            rules = rules_for_sa(docs, sa, ns)
            if not grants(rules, 'config.openshift.io', 'oauths', 'get', name='cluster', ns=ns):
                bad.append(f"{kind}/{name} container {ctr} runs `oc get oauth cluster` as "
                           f"sa/{sa} in {ns}, which has no get on config.openshift.io/oauths")
    return bad

def source_secret_rbac(docs):
    """The Job reads the OAuth bindPassword Secret; the read must be granted in THAT namespace.

    When the script bakes a literal SRC_SECRET the grant may be pinned to that name; when the name
    is discovered at runtime (SRC_SECRET=''), only an unpinned grant in that namespace can cover it.
    """
    bad = []
    for name, kind, spec in pod_specs(docs):
        sa, ns = spec.get('serviceAccountName'), None
        for d in docs:
            if d.get('kind') == kind and d['metadata']['name'] == name:
                ns = d['metadata'].get('namespace')
        for ctr, body in scripts(spec):
            lit = re.search(r"^\s*SRC_SECRET='([^']*)'", body, re.M)
            known = lit.group(1) if lit else None
            for m in re.finditer(r'oc get secret \$\{SRC_SECRET\}[^\n]*?-n (\S+)', body):
                sns = m.group(1)
                rules = rules_for_sa(docs, sa, ns)
                if known:
                    ok = grants(rules, '', 'secrets', 'get', name=known, ns=sns)
                    how = f"secrets/{known}"
                else:
                    ok = grants(rules, '', 'secrets', 'get', ns=sns, unpinned=True)
                    how = "secrets (unpinned — the name is discovered at runtime)"
                if not ok:
                    bad.append(f"{kind}/{name} reads the bindPassword Secret in {sns} as sa/{sa}, "
                               f"but nothing grants get on {how} there")
    return bad


def no_cluster_wide_secret_read(docs):
    """No ClusterRole may grant an unpinned read over Secrets — that is every Secret in the cluster."""
    bad = []
    for d in docs:
        if d.get('kind') != 'ClusterRole':
            continue
        for r in d.get('rules') or []:
            if 'secrets' not in r.get('resources', []) and '*' not in r.get('resources', []):
                continue
            reads = sorted(set(r.get('verbs', [])) & {'get', 'list', 'watch', '*'})
            if reads and not r.get('resourceNames'):
                bad.append(f"ClusterRole/{d['metadata']['name']} grants {reads} on secrets "
                           f"cluster-wide with no resourceNames")
    return bad

WRITE = {'create', 'update', 'patch', 'delete', 'deletecollection', '*'}

def no_cluster_wide_credential_write(docs):
    """No ClusterRole may grant an unpinned WRITE over Secrets or ConfigMaps.

    The read check above missed this entirely: it looked only at get/list/watch, so an unpinned
    `create` on secrets AND configmaps sat in the extraction ClusterRole and passed.

    Unpinned is not sloppiness for create specifically — RBAC IGNORES resourceNames for create, so a
    create rule can never be pinned by name. The only thing that can bound it is a namespace, which
    means the rule belongs in a Role. Create-only is narrower than read (it cannot fetch or overwrite
    an existing object) but planting a Secret or ConfigMap under a name something else later mounts is
    a real cluster-wide write primitive.

    Deliberately limited to secrets and configmaps. Unpinned writes on other resources are a separate
    and lower concern — the InstallPlan approver's `patch` on installplans is one, guarded at runtime by
    a check that refuses an InstallPlan not naming this chart's subscription — and folding them in here
    would make this check about scope hygiene in general rather than about credential material.

    resourceNames DOES NOT EXCUSE A RULE HERE, and an earlier version of this check wrongly skipped any
    rule that had them. resourceNames pins the NAME and says nothing about the NAMESPACE, so a pinned rule
    in a ClusterRole grants that name in every namespace. Measured live against a rule reading
    `secrets [get,list,create,update,patch,delete] resourceNames:[ldap-group-sync]`:

        update secrets/ldap-group-sync -n kube-system       yes
        delete secrets/ldap-group-sync -n default           yes
        update secrets/UNRELATED-name  -n kube-system       no    <- the pin works, on the name only

    Overwriting an EXISTING Secret in someone else's namespace is strictly stronger than creating a new
    one where none exists, so the pinned form was the more dangerous of the two. The invariant for this
    chart is therefore simple: a ClusterRole may not write secrets or configmaps at all, pinned or not.
    Everything the Job needs is namespace-bounded.
    """
    bad = []
    for d in docs:
        if d.get('kind') != 'ClusterRole':
            continue
        for r in d.get('rules') or []:
            res = set(r.get('resources', []))
            hit = res & {'secrets', 'configmaps', '*'}
            if not hit:
                continue
            writes = sorted(set(r.get('verbs', [])) & WRITE)
            if not writes:
                continue
            pinned = r.get('resourceNames')
            how = (f"pinned to {pinned} — but resourceNames bounds the NAME, not the NAMESPACE, so those "
                   f"names are writable in EVERY namespace" if pinned else
                   "with no resourceNames, so every such object in every namespace")
            bad.append(f"ClusterRole/{d['metadata']['name']} grants {writes} on {sorted(hit)} {how}. "
                       f"Move it to a Role in the namespace it writes to.")
    return bad

def ca_coherence(docs):
    """ldaps:// (or insecure=false) => CA on the CR, CA preflight in the Job, CA read granted."""
    bad = []
    jobs = [(n, s) for n, k, s in pod_specs(docs) if k == 'Job']
    for d in docs:
        if d.get('kind') != 'GroupSync':
            continue
        for p in d['spec']['providers']:
            ldap = p['ldap']
            url, insecure = ldap.get('url', ''), ldap.get('insecure', False)
            need = url.startswith('ldaps://') or not insecure
            block = ldap.get('caSecret') or ldap.get('ca')
            if need and not block:
                bad.append(f"GroupSync/{d['metadata']['name']} provider {p['name']}: url={url!r} "
                           f"insecure={insecure} needs CA material but has neither ca nor caSecret")
                continue
            if not need:
                if block:
                    bad.append(f"GroupSync/{d['metadata']['name']}: url={url!r} insecure=True "
                               f"needs no CA yet emits {block}")
                continue
            for f in ('kind', 'name', 'key', 'namespace'):
                if not block.get(f):
                    bad.append(f"GroupSync/{d['metadata']['name']}: CA block field {f} is empty")
            preflight = [n for n, s in jobs
                         for _, b in scripts(s) if 'Checking LDAP CA:' in b]
            if not preflight:
                bad.append(f"GroupSync/{d['metadata']['name']} needs a CA but no Job preflights it")
            for n, s in jobs:
                for _, b in scripts(s):
                    if 'Checking LDAP CA:' not in b:
                        continue
                    sa = s.get('serviceAccountName')
                    jns = [x['metadata'].get('namespace') for x in docs
                           if x.get('kind') == 'Job' and x['metadata']['name'] == n][0]
                    res = 'secrets' if block['kind'] == 'Secret' else 'configmaps'
                    rules = rules_for_sa(docs, sa, jns)
                    if not grants(rules, '', res, 'get', name=block['name'],
                                 ns=block['namespace']):
                        bad.append(f"Job/{n} preflights {res}/{block['name']} in "
                                   f"{block['namespace']} as sa/{sa} with no get there")
    return bad

def ca_copy_kind(docs):
    """The kind the Job writes the copy as must be the kind the CR reads."""
    bad = []
    writes = {}
    for n, k, s in pod_specs(docs):
        for _, b in scripts(s):
            for m in re.finditer(r'oc create (configmap|secret generic) "\$CA_TGT"', b):
                tgt = re.search(r'CA_TGT=(\S+)', b).group(1)
                writes[tgt] = 'ConfigMap' if m.group(1) == 'configmap' else 'Secret'
    for d in docs:
        if d.get('kind') != 'GroupSync':
            continue
        for p in d['spec']['providers']:
            block = p['ldap'].get('caSecret') or p['ldap'].get('ca')
            if block and block['name'] in writes and writes[block['name']] != block['kind']:
                bad.append(f"the Job creates {block['name']} as a {writes[block['name']]} but "
                           f"GroupSync/{d['metadata']['name']} reads it as a {block['kind']}")
    return bad

TEST_ENV = {'GROUPSYNC_URL': 'url', 'GROUPSYNC_INSECURE': 'insecure',
            'CA_NAME': 'ca.name', 'CA_NAMESPACE': 'ca.namespace',
            'CA_KEY': 'ca.key', 'CA_KIND': 'ca.kind'}

def test_pods(docs):
    for d in docs:
        if d.get('kind') != 'Pod':
            continue
        if 'test' in (d['metadata'].get('annotations') or {}).get('helm.sh/hook', ''):
            yield d

def test_env_matches_cr(docs):
    """Every helm-test Pod must be told what the CR actually got.

    The CR to compare against is whichever one the pods name in GROUPSYNC_NAME — not a hardcoded name,
    because groupSync.name is an overridable value and pinning it here would make the check silently
    inapplicable the moment someone renamed the CR. With exactly one CR there is nothing to
    disambiguate, so that one is used.
    """
    crs = [d for d in docs if d.get('kind') == 'GroupSync']
    if not crs:
        return []
    named = {e.get('value') for p in test_pods(docs) for c in p['spec']['containers']
             for e in (c.get('env') or []) if e['name'] == 'GROUPSYNC_NAME'}
    named -= {None, ''}
    if named:
        primary = next((d for d in crs if d['metadata']['name'] in named), None)
        if primary is None:
            return [f"test pods target GROUPSYNC_NAME={sorted(named)} but no such GroupSync renders; "
                    f"rendered: {sorted(d['metadata']['name'] for d in crs)}"]
    elif len(crs) == 1:
        primary = crs[0]
    else:
        # Several CRs and nothing says which the pods are about. Say so rather than guess — the fix is
        # for the test pods to carry GROUPSYNC_NAME.
        return [f"{len(crs)} GroupSync CRs render and no test pod carries GROUPSYNC_NAME, so which one "
                f"the suite verifies is ambiguous: {sorted(d['metadata']['name'] for d in crs)}"]
    ldap = primary['spec']['providers'][0]['ldap']
    block = ldap.get('caSecret') or ldap.get('ca') or {}
    want = {'url': str(ldap.get('url', '')), 'insecure': str(ldap.get('insecure', False)).lower(),
            'ca.name': block.get('name', ''), 'ca.namespace': block.get('namespace', ''),
            'ca.key': block.get('key', ''), 'ca.kind': block.get('kind', '')}
    bad = []
    for d in test_pods(docs):
        for c in d['spec']['containers']:
            env = {e['name']: str(e.get('value', '')) for e in c.get('env') or []}
            for k, field in TEST_ENV.items():
                if k not in env or not want.get(field):
                    continue
                got = env[k].lower() if field == 'insecure' else env[k]
                if got != want[field]:
                    bad.append(f"Pod/{d['metadata']['name']}: {k}={env[k]!r} but the CR's "
                               f"{field} is {want[field]!r}")
    return bad

def no_artifacts(docs):
    return []  # text-level, see no_artifacts_text

def no_artifacts_text(path):
    bad = []
    for i, line in enumerate(open(path), 1):
        if '%!' in line or '<no value>' in line:
            bad.append(f"line {i}: Go template artifact: {line.strip()}")
    return bad

CHECKS = {'oauth-rbac': oauth_rbac, 'source-secret-rbac': source_secret_rbac,
          'ca-coherence': ca_coherence, 'ca-copy-kind': ca_copy_kind,
          'test-env-matches-cr': test_env_matches_cr,
          'no-cluster-wide-secret-read': no_cluster_wide_secret_read,
          'no-cluster-wide-credential-write': no_cluster_wide_credential_write}

if __name__ == '__main__':
    name, path = sys.argv[1], sys.argv[2]
    bad = no_artifacts_text(path) if name == 'no-artifacts' else CHECKS[name](load(path))
    for b in bad:
        print(f"  FAIL {b}")
    print(f"{'FAIL' if bad else 'PASS'} {name} ({len(bad)} problem(s))")
    sys.exit(1 if bad else 0)
