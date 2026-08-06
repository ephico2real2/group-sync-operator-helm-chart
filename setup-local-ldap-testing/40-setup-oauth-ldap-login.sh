#!/usr/bin/env bash
# Adds the local test directory to the cluster's OAuth CR as an LDAP identity provider, so the same
# directory the operator syncs groups FROM can also be logged in WITH.
#
# Two reasons this exists:
#
#   1. It makes the lab match an enterprise, where the cluster authenticates against the same directory
#      it syncs groups from. Group sync alone never proves that.
#   2. It is the only way to exercise the chart's OAuth DISCOVERY path. With groupSync.url,
#      oauthSecretExtraction.bindDN and sourceSecret.name all left empty, the chart derives them from
#      the first LDAP identity provider in the OAuth CR via Helm's `lookup`. With no LDAP provider on
#      the cluster that branch is unreachable, so it stays untested — see sample-values.yaml.
#
# ADDITIVE, ALWAYS. The existing identity providers are preserved, so the kubeadmin / HTPasswd login
# this lab depends on keeps working. `delete` removes only the provider this script added, by name.
#
#   ./40-setup-oauth-ldap-login.sh status        what the directory offers and what the OAuth CR has now
#   ./40-setup-oauth-ldap-login.sh bind-account  create the bind account, gate group, ACL and Secret
#   ./40-setup-oauth-ldap-login.sh apply         add (or update) the LDAP identity provider
#   ./40-setup-oauth-ldap-login.sh verify        the operator settled, and a real user can bind
#   ./40-setup-oauth-ldap-login.sh delete        remove only our provider, leave the others
#
# Run bind-account before apply on a fresh directory: apply refuses to write a provider whose filter
# matches no user, and the gate group is what makes it match.
#
# LOCAL SIMULATION ONLY — NEVER RUN THIS ON A SHARED OR PRODUCTION CLUSTER.
#
# oauth/cluster is cluster-wide authentication config. Adding a provider makes the authentication
# operator roll the oauth-openshift pods, which briefly interrupts new logins for EVERY user, not just
# this directory's. On a real cluster the identity providers are owned by whoever owns identity
# management, and a directory reachable only inside the cluster has no business being one of them.
#
# ── On restricting login to a group ───────────────────────────────────────────────────────────────
#
# An OpenShift LDAP provider does ONE search, for the user, and its RFC 2255 url carries the filter:
#
#   ldaps://host:port/BASEDN?ATTRIBUTE?SCOPE?FILTER
#
# There is no second lookup that expands a group's members. So a group restriction has to be expressed
# as a condition ON THE USER ENTRY, which means the user entry must carry a membership attribute
# (memberOf on OpenLDAP via the memberof overlay, isMemberOf on Oracle/389-style servers).
#
# That attribute is DN-valued. A DN-syntax attribute declares an EQUALITY matching rule and normally NO
# SUBSTR rule, and a substring assertion against an attribute with no SUBSTR rule is not something the
# server can evaluate — so a pattern like
#
#   (memberOf=cn=app-ocp-rbac-*,ou=Groups,dc=example,dc=com)     <-- NOT a working group filter
#
# does not do what it looks like. Groups must be named ABSOLUTELY, which is exactly what a real
# production config does:
#
#   (isMemberOf=cn=app-ssb-autobahnusers,ou=Groups,o=demo)
#
# For several groups, OR the absolute DNs: (|(memberOf=<dn1>)(memberOf=<dn2>)). LOGIN_GROUPS below
# takes a comma-separated list of group CNs and builds exactly that.
#
# Because a filter that matches nothing is indistinguishable from a directory outage at the login
# prompt, `apply` REFUSES to write a group-restricted provider until it has proved the filter matches
# at least one real user. That check is what makes this safe to trust rather than a guess.

set -euo pipefail

LDAP_NS="${LDAP_NS:-ldap-testing}"
LDAP_SVC="${LDAP_SVC:-openldap-service}"
OPERATOR_NS="${OPERATOR_NS:-group-sync-operator}"

BASE_DN="${BASE_DN:-dc=ephico2real,dc=com}"
GROUPS_BASE_DN="${GROUPS_BASE_DN:-ou=Groups,${BASE_DN}}"

# The directory root, not ou=People, because login identities live in two places: real users under
# ou=People, and the bind service account under ou=TrustedApplications, which is in the gate group so it
# can be used to test login. A base of ou=People cannot see the second one, and the provider would report
# nothing more useful than "invalid credentials".
USERS_BASE_DN="${USERS_BASE_DN:-${BASE_DN}}"

# The attribute a user types at the login prompt. Also OpenShift's preferredUsername.
LOGIN_ATTR="${LOGIN_ATTR:-uid}"

# Optional EXTRA constraint, empty by default. Requiring an objectClass here would mean picking one that
# matches both an inetOrgPerson user and an organizationalRole service account, and no single value does.
# Having the login attribute present is the real requirement; the gate group below is the access control.
USER_OBJECTCLASS="${USER_OBJECTCLASS:-}"

# Comma-separated group CNs. Empty means any directory user may log in. See the header for why these
# are absolute names and not a pattern.
#
# Defaults to the gate group, matching production, where membership in one group is what lets you
# authenticate at all and the app-ocp-rbac-* groups then decide what you can do. Set LOGIN_GROUPS=""
# to let any directory user log in.
LOGIN_GROUPS="${LOGIN_GROUPS:-app-ssb-autobahnusers}"
GATE_LDIF="${GATE_LDIF:-ldap-oauth-login-gate.ldif}"
ACL_LDIF="${ACL_LDIF:-configure-acls.ldif}"
LDAP_ADMIN_PW="${LDAP_ADMIN_PW:-admin123}"

# Which membership attribute the user entry carries. Detected at runtime; this is only the preference
# order for the probe.
MEMBER_ATTRS="${MEMBER_ATTRS:-memberOf isMemberOf}"

# Exported because the python helpers below read it from the environment rather than being handed it
# through string interpolation — an identity provider name interpolated into a python literal would let
# a quote in it break the script.
IDP_NAME="${IDP_NAME:-ldap-local}"
export IDP_NAME

# claim, not add. claim REFUSES a login whose preferred username is already owned by another provider;
# add MERGES it into the existing user. With an HTPasswd `developer` account already on this cluster,
# add would let a directory user called `developer` inherit that account. Production configs often use
# add because their username spaces are known not to collide — this lab's is not.
MAPPING_METHOD="${MAPPING_METHOD:-claim}"

# Both must live in openshift-config: that is where the authentication operator reads identity provider
# material from, and it is not configurable.
#
# ca-config-map is created by 15-bootstrap-cert-manager-ca.sh with key ca.crt, which is the key an LDAP
# identity provider requires — a trusted-CA style ca-bundle.crt would NOT be read.
#
# The bind secret is this script's own (`bind-account` creates it), NOT the ldap-secret that
# 10-setup-oauth-secrets.sh makes for the group-sync flow. Two consumers, two credentials: either can be
# rotated or revoked without taking the other down, which is how a real directory hands out service
# accounts. Point BIND_SECRET/BIND_DN at the group-sync pair if you would rather share one.
BIND_SECRET="${BIND_SECRET:-ldap-oauth-bind-secret}"
BIND_SECRET_KEY="${BIND_SECRET_KEY:-bindPassword}"
CA_CONFIGMAP="${CA_CONFIGMAP:-ca-config-map}"
CA_CONFIGMAP_KEY="${CA_CONFIGMAP_KEY:-ca.crt}"

BIND_DN="${BIND_DN:-cn=ocp-oauth-bind-serviceid,ou=TrustedApplications,${BASE_DN}}"
BIND_PASSWORD="${BIND_PASSWORD:-oauthbindpassword123}"

# auto decides from what the directory is actually serving. Force with ldaps or ldap.
TRANSPORT="${TRANSPORT:-auto}"

# ldaps:// with insecure: true means the handshake happens and then the certificate is not checked,
# which is worse than plain ldap:// because it looks encrypted and authenticated. Off unless asked for.
ALLOW_INSECURE_LDAPS="${ALLOW_INSECURE_LDAPS:-false}"

PROBE_IMAGE="${PROBE_IMAGE:-registry.redhat.io/rhel9/openssl:latest}"

# Anchored to this script, not the caller's working directory — as ./.oauth-backup it followed the cwd,
# so running from the repo root dropped cluster material outside the path .gitignore covers.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/.oauth-backup}"

SAN_FQDN="${LDAP_SVC}.${LDAP_NS}.svc.cluster.local"

log()  { echo "  $*"; }
step() { echo; echo "== $*"; }
die()  { echo "FAILED: $*" >&2; exit 1; }

# Runs ldapsearch inside the directory pod. Read-only, over loopback plain LDAP: this asks the
# directory about its own contents, so transport is irrelevant here and 389 always works internally.
ldap_pod() {
  local pod
  pod=$(oc get pod -n "$LDAP_NS" --no-headers 2>/dev/null | awk '/openldap-server/ && /Running/ {print $1; exit}')
  [ -n "$pod" ] || die "no Running openldap-server pod in ${LDAP_NS}.
  ./30-manage-ldap-server.sh deploy"
  printf '%s' "$pod"
}

# The bind password, read from the secret the identity provider itself will use. Reading it from
# anywhere else would prove the directory works with a credential the provider does not have.
bind_password() {
  local pw
  pw=$(oc get secret "$BIND_SECRET" -n openshift-config \
       -o jsonpath="{.data.${BIND_SECRET_KEY}}" 2>/dev/null | base64 -d 2>/dev/null) || true
  [ -n "$pw" ] || die "openshift-config/${BIND_SECRET} has no key '${BIND_SECRET_KEY}'.
  That is the secret and key an LDAP identity provider reads its bind password from.
  ./10-setup-oauth-secrets.sh creates it."
  printf '%s' "$pw"
}

# search FILTER [attrs...] -> matching entries, LDIF, from inside the directory pod.
search() {
  local filter="$1"; shift
  local pod pw
  pod=$(ldap_pod); pw=$(bind_password)
  oc exec -n "$LDAP_NS" "$pod" -- ldapsearch -x -LLL -o ldif-wrap=no \
     -H ldap://localhost:389 -D "$BIND_DN" -w "$pw" \
     -b "$USERS_BASE_DN" -s sub "$filter" "$@" 2>&1
}

# Which membership attribute, if any, a real user entry actually carries. Empty output means none does,
# and that is the case that makes a group filter silently deny every login.
detect_member_attr() {
  local pod pw out attr
  pod=$(ldap_pod); pw=$(bind_password)
  for attr in $MEMBER_ATTRS; do
    # Asked for explicitly: memberOf is operational on OpenLDAP and is not returned by a bare search.
    out=$(oc exec -n "$LDAP_NS" "$pod" -- ldapsearch -x -LLL -o ldif-wrap=no \
          -H ldap://localhost:389 -D "$BIND_DN" -w "$pw" \
          -b "$USERS_BASE_DN" -s sub "(${LOGIN_ATTR}=*)" "$attr" 2>/dev/null \
          | grep -ci "^${attr}:" || true)
    if [ "${out:-0}" -gt 0 ]; then printf '%s' "$attr"; return 0; fi
  done
  printf ''
}

# Builds the RFC 2255 filter component. Absolute group DNs, ORed — see the header.
build_filter() {
  local member_attr="$1" terms="" cn dn base

  # Requiring the login attribute rather than an objectClass: it is what the provider matches the typed
  # username against, so an entry without it can never log in anyway, and it is the one condition true of
  # both a person and a service account.
  base="(${LOGIN_ATTR}=*)"
  [ -n "$USER_OBJECTCLASS" ] && base="(&(objectClass=${USER_OBJECTCLASS})${base})"

  [ -z "$LOGIN_GROUPS" ] && { printf '%s' "$base"; return 0; }

  local IFS=,
  for cn in $LOGIN_GROUPS; do
    cn="$(printf '%s' "$cn" | tr -d '[:space:]')"
    [ -z "$cn" ] && continue
    # A full DN passes through; a bare CN is qualified against the groups base.
    case "$cn" in
      *=*) dn="$cn" ;;
      *)   dn="cn=${cn},${GROUPS_BASE_DN}" ;;
    esac
    terms="${terms}(${member_attr}=${dn})"
  done
  unset IFS

  [ -n "$terms" ] || { printf '%s' "$base"; return 0; }
  # A single term needs no |, and slapd rejects (|(x)) with one child on some versions.
  if [ "$(printf '%s' "$terms" | grep -o '(' | wc -l | tr -d ' ')" -gt 1 ]; then
    printf '(&%s(|%s))' "$base" "$terms"
  else
    printf '(&%s%s)' "$base" "$terms"
  fi
}

# Is a TCP port open on the Service, from inside the cluster?
port_open() {
  local port="$1"
  oc run "ldap-port-${port}-$$" -n "$LDAP_NS" --rm -i --restart=Never --quiet \
     --image="$PROBE_IMAGE" --command -- \
     timeout 8 bash -c "</dev/tcp/${SAN_FQDN}/${port}" >/dev/null 2>&1
}

# Does the LDAPS certificate verify against the CA the IDENTITY PROVIDER will use? Deliberately checks
# openshift-config/<CA_CONFIGMAP>, not whatever the GroupSync CR trusts: those are different objects and
# either can be stale independently of the other.
ldaps_chain_verifies() {
  # Cleaned up explicitly rather than with `trap ... RETURN`: a RETURN trap set inside a function is not
  # scoped to it, so it fires again when the CALLER returns — at which point $ca is out of scope and
  # `set -u` kills the script with "ca: unbound variable" from a line that looks unrelated.
  local ca b64 rc=1
  ca=$(mktemp -d) || return 1
  if oc extract "configmap/${CA_CONFIGMAP}" -n openshift-config \
       --keys="$CA_CONFIGMAP_KEY" --to="$ca" --confirm >/dev/null 2>&1 \
     && [ -s "${ca}/${CA_CONFIGMAP_KEY}" ]; then
    b64=$(base64 < "${ca}/${CA_CONFIGMAP_KEY}" | tr -d '\n')
    verify_chain_with_ca "$b64" && rc=0
  fi
  rm -rf "$ca"
  return "$rc"
}

verify_chain_with_ca() {
  local b64="$1"

  # The CA travels as an env var rather than a mounted ConfigMap: it lives in openshift-config and a pod
  # cannot mount a ConfigMap from another namespace.
  oc run "ldaps-chain-$$" -n "$LDAP_NS" --rm -i --restart=Never --quiet \
     --image="$PROBE_IMAGE" --env="CA_B64=${b64}" --command -- \
     bash -c "printf '%s' \"\$CA_B64\" | base64 -d > /tmp/ca.crt
              echo | openssl s_client -connect ${SAN_FQDN}:636 -servername ${SAN_FQDN} \
                -CAfile /tmp/ca.crt -verify_return_error 2>&1 | grep -q 'Verify return code: 0 (ok)'" \
     >/dev/null 2>&1
}

# ldaps when 636 verifies against the provider's own CA, ldap when only 389 answers.
decide_transport() {
  case "$TRANSPORT" in
    ldaps|ldap) printf '%s' "$TRANSPORT"; return 0 ;;
    auto) ;;
    *) die "TRANSPORT must be auto, ldaps or ldap — got '${TRANSPORT}'" ;;
  esac

  if port_open 636 && ldaps_chain_verifies; then printf 'ldaps'; return 0; fi

  if port_open 636; then
    if [ "$ALLOW_INSECURE_LDAPS" = "true" ]; then
      printf 'ldaps-insecure'; return 0
    fi
    log "636 is open but its certificate does not verify against openshift-config/${CA_CONFIGMAP}"
    log "  run ./15-bootstrap-cert-manager-ca.sh apply, or set ALLOW_INSECURE_LDAPS=true to skip"
    log "  verification (which makes the TLS look trustworthy while proving nothing)"
  fi

  port_open 389 && { printf 'ldap'; return 0; }
  printf 'none'
}

# Creates the directory-side prerequisites for login: a dedicated bind service account, the gate group,
# the ACL grant that lets the new account read, and the openshift-config Secret holding its password.
# Idempotent — an entry that already exists is left alone rather than treated as an error.
cmd_bind_account() {
  local pod; pod=$(ldap_pod)

  step "bind service account and gate group"
  [ -f "${SCRIPT_DIR}/${GATE_LDIF}" ] || die "${GATE_LDIF} not found next to this script"
  oc cp "${SCRIPT_DIR}/${GATE_LDIF}" "${LDAP_NS}/${pod}:/tmp/gate.ldif" -c openldap >/dev/null 2>&1 \
    || die "could not copy ${GATE_LDIF} into the directory pod"

  # ldapmodify, not ldapadd: the LDIF carries per-record changetypes — `add` for the entries and `modify
  # … replace` afterwards so a directory that already has them converges to the same state instead of
  # being left half-updated. -c continues past the "Already exists (68)" the adds produce on a re-run,
  # which is why 68 is treated as success here.
  local out rc
  out=$(oc exec -c openldap -n "$LDAP_NS" "$pod" -- \
        ldapmodify -c -x -D "cn=admin,${BASE_DN}" -w "$LDAP_ADMIN_PW" -f /tmp/gate.ldif 2>&1) && rc=0 || rc=$?
  printf '%s\n' "$out" | sed 's/^/  /'
  case "$rc" in
    0|68) ;;
    *) printf '%s' "$out" | grep -q 'Already exists' \
         || die "ldapmodify failed (exit ${rc}) — see above" ;;
  esac

  step "ACL: letting ${BIND_DN##cn=} read"
  # The subtree rules end in `by * none`, so a new account sees nothing until it is named there. Without
  # this its searches return "No such object (32)", which reads like missing data rather than a denial.
  [ -f "${SCRIPT_DIR}/${ACL_LDIF}" ] || die "${ACL_LDIF} not found next to this script"
  oc cp "${SCRIPT_DIR}/${ACL_LDIF}" "${LDAP_NS}/${pod}:/tmp/acls.ldif" -c openldap >/dev/null 2>&1
  # EXTERNAL over ldapi:// — the config backend trusts the root peercred identity, so this keeps working
  # even if LDAP_CONFIG_PASSWORD has been rotated away from the manifest's value.
  oc exec -c openldap -n "$LDAP_NS" "$pod" -- \
     ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/acls.ldif 2>&1 | sed 's/^/  /'

  step "openshift-config/${BIND_SECRET}"
  # The authentication operator only reads identity provider material from openshift-config, and that is
  # not configurable. Key must be bindPassword.
  if oc get secret "$BIND_SECRET" -n openshift-config >/dev/null 2>&1; then
    oc set data "secret/${BIND_SECRET}" -n openshift-config \
       --from-literal="${BIND_SECRET_KEY}=${BIND_PASSWORD}" >/dev/null 2>&1 \
      && log "updated" || die "could not update openshift-config/${BIND_SECRET}"
  else
    oc create secret generic "$BIND_SECRET" -n openshift-config \
       --from-literal="${BIND_SECRET_KEY}=${BIND_PASSWORD}" >/dev/null 2>&1 \
      && log "created" || die "could not create openshift-config/${BIND_SECRET}"
  fi

  step "proving the account works with the credential the provider will use"
  # Read back from the Secret rather than using $BIND_PASSWORD, so this fails if the two ever disagree.
  local n
  n=$(search "(${LOGIN_ATTR}=*)" dn 2>/dev/null | grep -c '^dn:' || true)
  [ "${n:-0}" -gt 0 ] || die "the bind account cannot search ${USERS_BASE_DN} with the password in
  openshift-config/${BIND_SECRET}. Check the ACL applied, and that the password matches the directory."
  log "binds and sees ${n} user(s) under ${USERS_BASE_DN}"

  local attr; attr=$(detect_member_attr)
  if [ -n "$attr" ]; then
    log "membership attribute now visible on user entries: ${attr}"
  else
    log "still NO membership attribute on user entries — a group-gated login would deny everyone."
    log "  The memberof overlay only maintains it for the objectClass and attribute it is configured"
    log "  for. Check: olcMemberOfGroupOC / olcMemberOfMemberAD on"
    log "  olcOverlay={0}memberof,olcDatabase={1}mdb,cn=config"
  fi

  log "next: ./40-setup-oauth-ldap-login.sh apply"
}

cmd_status() {
  step "the directory"
  local pod; pod=$(ldap_pod)
  log "pod:            ${pod}"
  log "service DNS:    ${SAN_FQDN}"
  log "389 open:       $(port_open 389 && echo yes || echo no)"
  local has636; has636=$(port_open 636 && echo yes || echo no)
  log "636 open:       ${has636}"
  if [ "$has636" = yes ]; then
    log "636 verifies:   $(ldaps_chain_verifies && echo "yes, against openshift-config/${CA_CONFIGMAP}" \
                             || echo "NO — not against openshift-config/${CA_CONFIGMAP}")"
  fi

  step "what an identity provider needs, and whether it is there"
  log "bind secret:    openshift-config/${BIND_SECRET} key ${BIND_SECRET_KEY} — $(
        oc get secret "$BIND_SECRET" -n openshift-config -o jsonpath="{.data.${BIND_SECRET_KEY}}" \
          >/dev/null 2>&1 && echo present || echo MISSING)"
  log "CA configmap:   openshift-config/${CA_CONFIGMAP} key ${CA_CONFIGMAP_KEY} — $(
        oc get configmap "$CA_CONFIGMAP" -n openshift-config -o jsonpath="{.data}" 2>/dev/null \
          | grep -q "$CA_CONFIGMAP_KEY" && echo present || echo MISSING)"
  log "bind DN:        ${BIND_DN}"
  local bound
  bound=$(search "(${LOGIN_ATTR}=*)" dn 2>&1 | grep -c '^dn:' || true)
  log "bind works:     $([ "${bound:-0}" -gt 0 ] && echo "yes, ${bound} user(s) visible" || echo "NO — see below")
"
  [ "${bound:-0}" -gt 0 ] || search "(${LOGIN_ATTR}=*)" dn 2>&1 | head -3 | sed 's/^/    /'

  step "group restriction"
  local attr; attr=$(detect_member_attr)
  if [ -n "$attr" ]; then
    log "membership attribute on user entries: ${attr} — group restriction is possible"
  else
    log "NO membership attribute on user entries (looked for: ${MEMBER_ATTRS})"
    log "  This directory records membership only on the GROUP, as groupOfNames 'member'. An OpenShift"
    log "  identity provider filters the USER entry, so it cannot see that. Group-restricted login needs"
    log "  slapd's memberof overlay enabled, which osixia does not enable by default."
    log "  Leave LOGIN_GROUPS empty and every directory user may log in."
  fi
  if [ -n "$LOGIN_GROUPS" ]; then
    local f; f=$(build_filter "${attr:-memberOf}")
    log "LOGIN_GROUPS:   ${LOGIN_GROUPS}"
    log "filter:         ${f}"
    local n; n=$(search "$f" dn 2>/dev/null | grep -c '^dn:' || true)
    log "users matched:  ${n:-0} $([ "${n:-0}" -eq 0 ] && echo '<-- apply would refuse this' || echo '')"
  else
    log "LOGIN_GROUPS is empty — any directory user may log in"
  fi

  step "the OAuth CR now"
  oc get oauth cluster -o json 2>/dev/null | python3 -c '
import json, sys, os
name = os.environ["IDP_NAME"]
spec = (json.load(sys.stdin).get("spec") or {})
idps = spec.get("identityProviders") or []
if not idps:
    print("  no identity providers at all")
for p in idps:
    mark = "  <-- ours" if p.get("name") == name else ""
    print("  {:<22} {:<10} mappingMethod={}{}".format(
        p.get("name"), p.get("type"), p.get("mappingMethod", "claim"), mark))
    if p.get("type") == "LDAP":
        l = p.get("ldap") or {}
        print("      url:      {}".format(l.get("url")))
        print("      insecure: {}  ca={}  bindPassword={}".format(
            l.get("insecure"), (l.get("ca") or {}).get("name"),
            (l.get("bindPassword") or {}).get("name")))
' 2>/dev/null || log "could not read oauth/cluster"

  step "authentication operator"
  oc get co authentication \
     -o jsonpath='  available={.status.conditions[?(@.type=="Available")].status} progressing={.status.conditions[?(@.type=="Progressing")].status} degraded={.status.conditions[?(@.type=="Degraded")].status}{"\n"}' \
     2>/dev/null || true
}

cmd_apply() {
  step "deciding the transport"
  local transport url insecure use_ca
  transport=$(decide_transport)
  case "$transport" in
    ldaps)           url="ldaps://${SAN_FQDN}:636"; insecure=false; use_ca=true
                     log "ldaps — 636 verifies against openshift-config/${CA_CONFIGMAP}" ;;
    ldaps-insecure)  url="ldaps://${SAN_FQDN}:636"; insecure=true;  use_ca=false
                     log "ldaps WITHOUT verification, because ALLOW_INSECURE_LDAPS=true" ;;
    ldap)            url="ldap://${SAN_FQDN}:389";  insecure=true;  use_ca=false
                     log "plain ldap on 389 — 636 is not usable. The bind password crosses the network" \
                         "in the clear, which is acceptable only inside a lab cluster" ;;
    *) die "the directory answers on neither 389 nor 636. Is it running?
  ./30-manage-ldap-server.sh deploy" ;;
  esac

  step "checking the filter matches real users before writing it"
  local attr filter matched
  attr=$(detect_member_attr)
  if [ -n "$LOGIN_GROUPS" ] && [ -z "$attr" ]; then
    die "LOGIN_GROUPS is set, but no membership attribute exists on any user entry (looked for:
  ${MEMBER_ATTRS}). This directory keeps membership on the group as groupOfNames 'member', and an
  OpenShift identity provider only filters the USER entry — so every login would be denied.
  Either leave LOGIN_GROUPS empty, or enable slapd's memberof overlay first.
  ./40-setup-oauth-ldap-login.sh status  shows this too."
  fi
  filter=$(build_filter "${attr:-memberOf}")
  log "filter: ${filter}"

  matched=$(search "$filter" dn 2>/dev/null | grep -c '^dn:' || true)
  [ "${matched:-0}" -gt 0 ] || die "that filter matches NO user in ${USERS_BASE_DN}.
  A provider written with it would refuse every login, and at the login prompt that is
  indistinguishable from the directory being down. Refusing to write it.
  Check LOGIN_GROUPS, USER_OBJECTCLASS and LOGIN_ATTR against what the directory holds:
    ./40-setup-oauth-ldap-login.sh status"
  log "matches ${matched} user(s) — good"

  # basedn?attribute?scope?filter. The attribute is what the user types and becomes preferredUsername.
  local full_url="${url}/${USERS_BASE_DN}?${LOGIN_ATTR}?sub?${filter}"
  log "url: ${full_url}"

  step "backing up oauth/cluster"
  mkdir -p "$BACKUP_DIR"
  local backup="${BACKUP_DIR}/oauth-cluster-$(oc get oauth cluster -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null).yaml"
  oc get oauth cluster -o yaml > "$backup"
  log "saved ${backup}"
  log "to undo by hand: oc apply -f ${backup}"

  step "adding identity provider '${IDP_NAME}'"
  # Rebuilt from the live spec rather than patched blindly: a strategic-merge patch on a LIST replaces
  # it, which would silently drop the HTPasswd provider this lab logs in with. Re-applying is
  # idempotent — a provider with our name is replaced in place, keeping list order stable.
  local patch
  patch=$(oc get oauth cluster -o json 2>/dev/null | \
    IDP_NAME="$IDP_NAME" IDP_URL="$full_url" IDP_INSECURE="$insecure" IDP_USE_CA="$use_ca" \
    IDP_BIND_DN="$BIND_DN" IDP_BIND_SECRET="$BIND_SECRET" IDP_CA="$CA_CONFIGMAP" \
    IDP_MAPPING="$MAPPING_METHOD" IDP_LOGIN_ATTR="$LOGIN_ATTR" python3 -c '
import json, os, sys

live = json.load(sys.stdin)
spec = live.setdefault("spec", {}) or {}
idps = spec.get("identityProviders") or []
name = os.environ["IDP_NAME"]

ldap = {
    "url": os.environ["IDP_URL"],
    "insecure": os.environ["IDP_INSECURE"] == "true",
    "bindDN": os.environ["IDP_BIND_DN"],
    "bindPassword": {"name": os.environ["IDP_BIND_SECRET"]},
    "attributes": {
        "id": ["dn"],
        "preferredUsername": [os.environ["IDP_LOGIN_ATTR"]],
        "name": ["displayName", "cn"],
        "email": ["mail"],
    },
}
if os.environ["IDP_USE_CA"] == "true":
    ldap["ca"] = {"name": os.environ["IDP_CA"]}

ours = {"name": name, "type": "LDAP", "mappingMethod": os.environ["IDP_MAPPING"], "ldap": ldap}

kept = [p for p in idps if p.get("name") != name]
replaced = len(kept) != len(idps)
# Replace in place when it already exists, so list order does not churn between runs.
if replaced:
    out = [ours if p.get("name") == name else p for p in idps]
else:
    out = idps + [ours]

others = [p.get("name") for p in out if p.get("name") != name]
print(json.dumps({"spec": {"identityProviders": out}}))
print("REPLACED" if replaced else "ADDED", file=sys.stderr)
print("PRESERVED " + (",".join(others) if others else "(none)"), file=sys.stderr)
' 2>/tmp/idp-note.$$) || die "could not build the patch"

  sed 's/^/  /' /tmp/idp-note.$$ 2>/dev/null || true
  local preserved
  preserved=$(grep '^PRESERVED' /tmp/idp-note.$$ 2>/dev/null | sed 's/^PRESERVED //')
  rm -f /tmp/idp-note.$$

  # A patch that would leave no other provider means the HTPasswd login is about to disappear.
  case "$preserved" in
    ''|'(none)')
      die "this patch would leave '${IDP_NAME}' as the ONLY identity provider, removing the login this
  lab depends on. Refusing. Read oauth/cluster and work out why it has no other provider." ;;
  esac

  oc patch oauth cluster --type=merge -p "$patch" 2>&1 | sed 's/^/  /'
  log "kubeadmin and the HTPasswd login are untouched: ${preserved} still configured"

  # Said loudly because the console login LOOKS broken afterwards while nothing is wrong. OpenShift skips
  # the provider chooser when there is exactly one identity provider, so a cluster that went straight to a
  # username/password form now asks which provider first — and the chooser lists PROVIDERS, not users.
  # kubeadmin is a USER inside the HTPasswd provider, so no button says "kubeadmin". Here that provider is
  # usually named `developer`, which reads like a username and makes it look like the only account left.
  # The CONSOLE route, deliberately — openshift-console/console, not openshift-authentication/
  # oauth-openshift. They are different objects and it is easy to print one while meaning the other.
  # There is no shortcut URL to offer: a bare https://<oauth-route>/login/<idp> answers 302 to /, because
  # it carries none of the authorize request's state. Measured, not assumed. So the only instruction that
  # works is "open the console and pick a provider".
  local console first_idp
  console=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null)
  first_idp="${preserved%%,*}"
  cat <<CHOOSER

  ⚠  THE CONSOLE LOGIN PAGE CHANGES SHAPE. Nothing is broken when it does.

  It now lists identity PROVIDERS, not users, because a cluster with exactly one provider skips the
  chooser entirely and this one now has two. There is no "kubeadmin" button and there never was one:
  kubeadmin is a USER INSIDE the HTPasswd provider, which on this cluster is named '${first_idp}' — a
  provider name that reads like a username, which is what makes it look like the only account left.

    log in as kubeadmin:   pick '${first_idp}', then type kubeadmin and its password
    a directory user:      pick '${IDP_NAME}'
${console:+
    console:               https://${console}}

  Picking '${IDP_NAME}' and typing kubeadmin answers "invalid credentials", because kubeadmin is not in the
  directory. That is the chooser working, not a deleted account. The CLI never sees any of this:

    oc login -u kubeadmin -p <password>
    crc console --credentials          # prints the password on CRC

  To go back to a single login form:  ./40-setup-oauth-ldap-login.sh delete
CHOOSER

  step "waiting for the authentication operator to roll out"
  # Adding a provider rewrites the oauth-openshift config and restarts its pods, so the operator goes
  # Progressing=True and comes back. The patch alone only proves the API server accepted the SHAPE.
  #
  # Two waits, not one. The operator does not react instantly, so a single "Progressing=False and
  # Available=True" check passes immediately against the PRE-CHANGE steady state and reports success
  # while the old pod is still serving — which is exactly what happened here, and made a login attempt
  # moments later fail with "Unable to connect to the server: EOF" against a terminating pod.
  local i prog avail started=no
  for i in $(seq 1 18); do
    prog=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
    [ "$prog" = "True" ] && { started=yes; break; }
    sleep 5
  done
  [ "$started" = yes ] && log "rollout started" || log "no rollout began within 90s — the config was probably already current"

  for i in $(seq 1 90); do
    prog=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
    avail=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
    [ "$prog" = "False" ] && [ "$avail" = "True" ] && break
    sleep 10
  done
  log "available=${avail:-?} progressing=${prog:-?}"

  if [ "$avail" != "True" ]; then
    log "NOT Available yet. The provider is written, but logins will fail until the rollout finishes:"
    log "  oc get pods -n openshift-authentication"
    log "  oc get co authentication -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{\"\\n\"}{end}'"
    log "On a single-node cluster the new pod can sit Pending for a while waiting for room."
  fi

  cat <<NEXT

  The chart can now DISCOVER all of this instead of being told it. That is the path sample-values.yaml
  documents and which no cluster here could previously exercise:

    helm upgrade group-sync ../charts/group-sync-operator-helm -n ${OPERATOR_NS} --reset-values \\
      -f ../charts/group-sync-operator-helm/sample-values.yaml

  Then confirm what it derived:

    oc get groupsync -n ${OPERATOR_NS} -o jsonpath='{.items[0].spec.providers[0].ldap.url}{"\n"}'

  Check the login itself with ./40-setup-oauth-ldap-login.sh verify
NEXT
}

cmd_verify() {
  step "is the provider on the OAuth CR?"
  local found
  found=$(oc get oauth cluster -o json 2>/dev/null | IDP_NAME="$IDP_NAME" python3 -c '
import json, os, sys
name = os.environ["IDP_NAME"]
for p in (json.load(sys.stdin).get("spec") or {}).get("identityProviders") or []:
    if p.get("name") == name:
        l = p.get("ldap") or {}
        print("{}|{}|{}".format(l.get("url"), l.get("insecure"), (l.get("ca") or {}).get("name")))
        break
' 2>/dev/null)
  [ -n "$found" ] || die "no identity provider named '${IDP_NAME}' on oauth/cluster. Run apply."
  log "url:      ${found%%|*}"
  log "insecure: $(printf '%s' "$found" | cut -d'|' -f2)   ca: $(printf '%s' "$found" | cut -d'|' -f3)"

  step "authentication operator"
  oc get co authentication \
     -o jsonpath='  available={.status.conditions[?(@.type=="Available")].status} progressing={.status.conditions[?(@.type=="Progressing")].status} degraded={.status.conditions[?(@.type=="Degraded")].status}{"\n"}' 2>/dev/null
  local degraded
  degraded=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null)
  if [ "$degraded" = "True" ]; then
    oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}{"\n"}' 2>/dev/null | sed 's/^/    /'
    die "the authentication operator is Degraded. The provider is written but login will not work."
  fi

  step "can a real user actually bind?"
  # The decisive check, and the one that catches what a config review cannot: the provider can be
  # perfectly formed while every password in the directory is unusable.
  local pod pw user
  pod=$(ldap_pod); pw=$(bind_password)
  user=$(search "(${LOGIN_ATTR}=*)" "$LOGIN_ATTR" 2>/dev/null | awk -F': ' "/^${LOGIN_ATTR}:/ {print \$2; exit}")
  [ -n "$user" ] || die "no user with a ${LOGIN_ATTR} attribute under ${USERS_BASE_DN}"
  log "trying ${LOGIN_ATTR}=${user}"

  local udn
  udn=$(search "(${LOGIN_ATTR}=${user})" dn 2>/dev/null | awk -F': ' '/^dn:/ {print $2; exit}')
  log "dn:  ${udn}"

  # Whether the stored password is even usable. A password imported as {SSHA}<plaintext> is not a
  # valid SSHA hash — the base64 body decodes to the wrong length — so slapd rejects every bind
  # against it, and the login prompt just says invalid credentials with nothing in the logs to explain
  # why. Checked explicitly because it is otherwise invisible.
  local stored
  stored=$(oc exec -n "$LDAP_NS" "$pod" -- ldapsearch -x -LLL -o ldif-wrap=no \
           -H ldap://localhost:389 -D "$BIND_DN" -w "$pw" \
           -b "$udn" -s base '(objectClass=*)' userPassword 2>/dev/null \
           | awk -F': ' '/^userPassword/ {print $2; exit}')
  if [ -n "$stored" ]; then
    local decoded scheme
    decoded=$(printf '%s' "$stored" | base64 -d 2>/dev/null || printf '%s' "$stored")
    scheme=$(printf '%s' "$decoded" | sed -n 's/^{\([A-Za-z0-9]*\)}.*/\1/p')
    if [ -n "$scheme" ]; then
      log "password scheme: {${scheme}}"
      local body; body=$(printf '%s' "$decoded" | sed "s/^{${scheme}}//")
      if [ "$scheme" = "SSHA" ] && ! printf '%s' "$body" | base64 -d >/dev/null 2>&1; then
        log "  the {SSHA} body is not valid base64, so it is not a real hash — most likely the LDIF"
        log "  stored {SSHA}<plaintext> literally. slapd will reject EVERY bind for this user."
        log "  Fix one user to test login with:"
        log "    oc exec -n ${LDAP_NS} ${pod} -- ldappasswd -x -D 'cn=admin,${BASE_DN}' -w admin123 \\"
        log "      -s '<newpassword>' '${udn}'"
      fi
    else
      log "password scheme: none — stored in cleartext, which binds fine in a lab"
    fi
  else
    log "userPassword is not readable by the bind account, so it cannot be inspected here"
  fi

  log "an end-to-end login is the real proof, and needs a password only you know:"
  log "  oc login -u ${user} -p '<password>' --server=$(oc whoami --show-server 2>/dev/null)"
  log "  then: oc whoami   and   oc get groups -o name | head"
  log "your current session (kubeadmin) is unaffected by any of this"
}

cmd_delete() {
  step "removing identity provider '${IDP_NAME}'"
  local patch
  patch=$(oc get oauth cluster -o json 2>/dev/null | IDP_NAME="$IDP_NAME" python3 -c '
import json, os, sys
name = os.environ["IDP_NAME"]
idps = (json.load(sys.stdin).get("spec") or {}).get("identityProviders") or []
kept = [p for p in idps if p.get("name") != name]
if len(kept) == len(idps):
    print("ABSENT", file=sys.stderr); raise SystemExit(3)
if not kept:
    print("LAST", file=sys.stderr); raise SystemExit(4)
print(json.dumps({"spec": {"identityProviders": kept}}))
print("REMOVED, keeping: " + ",".join(p.get("name") for p in kept), file=sys.stderr)
' 2>/tmp/del-note.$$) && rc=0 || rc=$?

  case "${rc:-0}" in
    0) sed 's/^/  /' /tmp/del-note.$$ 2>/dev/null; rm -f /tmp/del-note.$$
       oc patch oauth cluster --type=merge -p "$patch" 2>&1 | sed 's/^/  /' ;;
    3) rm -f /tmp/del-note.$$; log "no provider named '${IDP_NAME}' — nothing to do"; return 0 ;;
    4) rm -f /tmp/del-note.$$
       die "'${IDP_NAME}' is the only identity provider left. Removing it would leave the cluster with
  no way to log in. Add the HTPasswd provider back first." ;;
    *) rm -f /tmp/del-note.$$; die "could not build the removal patch" ;;
  esac

  log "the bind secret and CA ConfigMap in openshift-config are left alone — 10-setup-oauth-secrets.sh"
  log "and 15-bootstrap-cert-manager-ca.sh own those, and the chart still reads them"
}

case "${1:-status}" in
  status)       cmd_status ;;
  bind-account) cmd_bind_account ;;
  apply)        cmd_apply ;;
  verify)       cmd_verify ;;
  delete)       cmd_delete ;;
  *) die "unknown command '${1}'. Use: status | bind-account | apply | verify | delete" ;;
esac
