# Review — the shop users for the Keycloak lab (ephico2real2/envoy-tutorial#8)

**Implementer: OB1-lite (Opus 5.5). Reviewers: Grok 4.6 High Fast (Cursor, with a shell, read-only on the lab),
Codex gpt-5.6-sol xhigh, Codex Astra gpt-6-astra high. Arbiter: Claude.** Decisions are recorded on
ephico2real2/envoy-tutorial#8.

## The use case

Module 17 of envoy-tutorial checks tokens from realm `corp`, which Keycloak federates from this directory and gates
on `app-ssb-autobahnusers`. Two ordinary LDAP users mirror module 16's alice and bob:

| User | gate | `app-ocp-rbac-ocp-keycloak-admin` | module 17 `/api` | `/admin` |
|---|---|---|---|---|
| `shop.alice` | yes | no | 200 | 403 |
| `shop.bob` | yes | yes | 200 | 200 |

## Findings and decisions

| Finding | Seats | Decision |
|---|---|---|
| one `ldapmodify -c` over the file can hide an earlier real failure; the header's exit-code rule was wrong | Codex, Astra | Accepted — `40-setup-oauth-ldap-login.sh shop-users` applies record by record, each result checked (user add 0/68, replace 0, membership add 0/20) |
| re-applying `ldap-oauth-login-gate.ldif` replaces the gate's `uniqueMember` list and drops the shop users | all three | Accepted — `bind-account` re-applies `ldap-shop-users.ldif` right after the gate; the shop DNs are not added to the gate file (ordering) |
| the shop users become OpenShift-login capable (the same gate is `ldap-local`'s filter; the onboarding GroupSync lists them) | all three | Accepted as intended; recorded in the LDIF header and envoy-tutorial's access matrix |

Second pass (Grok, Codex): confirmed; no findings on this repository.

## Evidence

Live: both users bind with the lab password; `memberOf` includes the gate; `shop.bob` is a `member` of
keycloak-admin; a forced GroupSync lists him in the OpenShift group; `90-verify-all-resources.sh` passes; a real
re-run of `shop-users` returned `68 68 0 0 20 20 20` and exited 0 with the directory unchanged (checksum).
