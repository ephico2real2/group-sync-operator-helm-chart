# Review — public LDAPS on 443 for Keycloak (#71)

**Implementer: OB1-lite (Opus 5.5). Reviewers: Grok 4.6 High Fast (Cursor, with a shell, read-only on the lab),
Codex gpt-5.6-sol xhigh, Codex Astra gpt-6-astra high. Arbiter: Claude.** Each reviewer worked on its own
`git archive` export; every verdict cites a command it ran or a file:line it read. Part of
ephico2real2/envoy-tutorial#6.

## The use case, so a finding can be judged against it

Keycloak (Java 21, JNDI) must reach this directory on its public name, `ldaps://ldaps-ldap-testing.apps-crc.testing:443`,
as a client outside the cluster would. Measured before any design: only a **passthrough** Route carries LDAPS
through the router (edge and an `openshift-default` Ingress answered an LDAP bind with `HTTP/1.1 400`), and the
JVM sends SNI; the one blocker was the certificate, which named only the Service. Keycloak requires strict
hostname checking for LDAP.

**The constraints:** the directory is live — the OpenShift OAuth login (`ldap-local`) and the group-sync operator
use it — so nothing may drop their ACL grants, delete the serving Secret, or restart slapd without cause.
`ldap-route` stays exactly as it is (the operator's setup uses it).

## Rounds

| Pass | Commit | Seats | Outcome |
|---|---|---|---|
| Spec | — (on `89a92f6`) | Grok | F1 host = SAN from one variable; F2 roll on a new certificate; F3 never a partial `olcAccess` replace; F5 no CronJob; F6 stronger proofs; F7 never delete the Secret to force a renewal; F8 prove `ldap-local` with a real token |
| Code | `a146b79` | Grok, Codex, Codex Astra | A1–A9 accepted; two findings rejected (below) |
| Second pass | `86370c0` | Grok, Codex | F1 cleanup trap and failed revocation, F2 missing-server exit status — accepted |
| Third pass | `5fe232b` | Grok | confirmed; no new findings |

## Code review of `a146b79`

Confirmed by all three: the ACL modify is exact and atomic (live `{1}`/`{2}` equal the delete values byte for
byte; one Modify, all-or-nothing, fails closed on a re-run); the bind entry is valid and re-runnable; an empty
served serial dies instead of restarting; at most one rollout per `apply`, none when serials match.

| # | Finding | Seats | Decision |
|---|---|---|---|
| A1 | no real `ldap-local` token proof | all three | Accepted |
| A2 | no script creates `keycloak-bind-serviceid` | all three | Accepted — `40 … bind-account` |
| A3 | GroupSync freshness compared as strings | all three | Accepted — parsed, strictly after |
| A4 | `30-manage-ldap-server.sh:411` advertised the plain route as LDAPS | all three | Accepted |
| A5 | the in-pod serial probe had no timeout | Codex | Accepted |
| A6 | an unreadable Deployment/Route taken as absent | Astra | Accepted — NotFound vs error |
| A7 | `90-verify` false-success paths | Astra | Accepted |
| A8 | the forced-renewal recipe did not wait | Astra | Accepted |
| A9 | Path A broken by the new block; verify before Helm; `helm install` on re-run | Codex | Accepted in part — the block skips without cert-manager/Route; verify after Helm; `upgrade --install` |
| — | "the wire chain is only the leaf, so the CA fetch fails" | Codex | **Rejected with measurement** — slapd sends leaf and root on 636 (measured three times, including by running the README recipe); one README line added for leaf-only servers |
| — | "`15 … delete` removes the serving Secret" | Codex, Astra | **Rejected — out of scope**: the pre-existing PKI teardown; F7 is about forcing a renewal |

## Second and third passes

| Finding | Seats | Decision |
|---|---|---|
| F1 the token proof had no EXIT/INT/TERM trap; a failed `oc logout` was swallowed | Grok, Codex | Accepted — revoked and removed on every path, a failed revocation fails; confirmed on bash 3.2 and 5.3 |
| F2 `LDAP Server: Not running` / `Service account access: Failed` did not fail the run | Codex | Accepted — confirmed exit 1, no "all checks passed" |

## Not provable before the deploy

The real `ldap-local` login (it writes an `OAuthAccessToken`), the SAN re-issue and the one rollout, the Keycloak
JNDI probe bound as `keycloak-bind-serviceid`, and a forced renewal: these are the deploy walk's evidence, posted
on #71.
