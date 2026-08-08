# The group filter and the membership attributes, measured

What `filter`, `objectClass`, `groupMembershipAttributes`, `groupUIDAttribute`, `userUIDAttribute` and
`userNameAttributes` actually do — and where they fail quietly.

**Every claim here was run against a live directory and cluster.** Where a number appears, the command
that produced it is next to it. Two of the things below are counter-intuitive and were only settled by
trying them; both had already been guessed at wrongly, which is why this file exists rather than a
paragraph in `values.yaml`.

The reference lab is OpenLDAP with `dc=ephico2real,dc=com`, the group-sync-operator, and CRC.

---

## 1. The two group schemas, and why one entry cannot be both

RFC 4519 defines both group classes as **STRUCTURAL**, each with `SUP top`:

```text
groupOfNames         STRUCTURAL   SUP top   MUST (member, cn)
groupOfUniqueNames   STRUCTURAL   SUP top   MUST (uniqueMember, cn)
```

They are *siblings*, not a chain. RFC 4512 allows an entry exactly one structural object-class chain, so
an entry cannot be both. OpenLDAP enforces it:

```console
$ ldapadd ... <<'LDIF'
dn: cn=probe,ou=Groups,dc=ephico2real,dc=com
objectClass: groupOfNames
objectClass: groupOfUniqueNames
...
LDIF
ldap_add: Object class violation (65)
        additional info: invalid structural object class chain (groupOfNames/groupOfUniqueNames)
```

**So a filter naming both object classes is not asking for a group that is both.** It is asking for the
group *whichever of the two it is*:

```text
(&
  (|(objectClass=groupOfNames)(objectClass=groupOfUniqueNames))
  (cn=app-ssb-autobahnusers)
)
```

reads as: find `app-ssb-autobahnusers` **if it is either type**. That is what makes one sync
configuration work across a directory where some groups use one schema and some the other.

### The one valid way an entry holds both attributes

One structural class plus an **AUXILIARY** class that permits the other attribute. Measured with
`extensibleObject`, which permits any attribute:

```console
$ ldapadd ...
dn: cn=probe,ou=Groups,dc=ephico2real,dc=com
objectClass: groupOfNames          # the structural one
objectClass: extensibleObject      # AUXILIARY — permits uniqueMember too
member: uid=john.doe,ou=People,...
uniqueMember: uid=bob.wilson,ou=People,...
adding new entry "cn=probe,ou=Groups,dc=ephico2real,dc=com"     # accepted
```

A purpose-built auxiliary class is cleaner than `extensibleObject` in production, which permits
everything. The same mechanism is why this lab's LDAP bind account — an `organizationalRole`, not a
person — carries a `uid` and therefore syncs like one.

---

## 2. `groupMembershipAttributes` concatenates. It does not deduplicate

This is the one that surprises people, and the one that source-reading alone gets half-right.

`oc`'s RFC2307 extraction loops the configured attributes and appends:

```go
var ldapMemberUIDs []string
for _, attribute := range e.groupMembershipAttributes {
    ldapMemberUIDs = append(ldapMemberUIDs, group.GetAttributeValues(attribute)...)
}
```

It is concatenation, not a set union. The reasonable next assumption is that something later — building
the OpenShift `Group` — collapses duplicates. **It does not.** Measured with a probe group carrying both
attributes and an overlapping member in each:

| | value |
|---|---|
| `member` | `john.doe`, `jane.smith` |
| `uniqueMember` | `john.doe`, `bob.wilson` |
| **resulting `Group.users`** | `["john.doe","jane.smith","john.doe","bob.wilson"]` |

`john.doe` appears **twice, in the Group object itself**. Four entries for three people.

```console
$ oc get group probe -o jsonpath='{.users}'
["john.doe","jane.smith","john.doe","bob.wilson"]
```

### What that means for this chart

Naming both attributes is right, and it is what the shipped `ldap-clusteraccess-groupsync` item does:

```yaml
groupMembershipAttributes: ["member", "uniqueMember"]
```

It means *"I do not care which of the two schemas this group uses."* It is **not** a way to merge two
membership lists on one entry. Concretely:

- **At most one attribute populated** — the normal case, and the only schema-valid one without an
  auxiliary class. Costs nothing: the empty attribute contributes nothing. Verified on the gate group,
  which is `groupOfUniqueNames`: all **8** members sync with both attributes listed.
- **Both populated** — you get duplicates, in proportion to the overlap. If you genuinely maintain both
  on one entry, list only the attribute you consider authoritative.

Anything counting that array is counting entries, not people. `group-sync-dashboard` deduplicates on
read for exactly this reason; before it did, it reported `member_count: 4` above a list of 3.

---

## 3. The silent failure: the wrong membership attribute

**A filter decides which groups are FOUND. `groupMembershipAttributes` decides which members are READ.**
Getting the second wrong produces no error anywhere:

| | |
|---|---|
| CR status | healthy, sync succeeded |
| OpenShift Group | exists, correct name, correct `ldap.uid` |
| members | **zero** |

That is what happens if you point a `groupOfUniqueNames` group at the inherited `["member"]` — which is
exactly what copying another CR's `rfc2307` block does. The failure looks like a working sync, and the
only symptom is a group nobody is in.

The *filter* getting it wrong at least fails visibly: `(&(objectClass=groupOfNames)(cn=…))` against a
`groupOfUniqueNames` group matches nothing, so no Group is created at all.

Check before you configure:

```bash
ldapsearch -x -H ldaps://<host>:636 \
  -D "<bind DN>" -W \
  -b "ou=Groups,dc=example,dc=com" \
  '(&(cn=<your group>)(|(objectClass=groupOfNames)(objectClass=groupOfUniqueNames)))' \
  dn objectClass cn member uniqueMember
```

The `objectClass` lines tell you which schema, and whether both membership attributes are populated. Use
`ldaps://` with the CA your server presents; plain `ldap://` sends the bind password in clear.

---

## 4. The identity attributes, and what each one produces

| key | meaning | measured on the lab |
|---|---|---|
| `groupUIDAttribute: dn` | the group's unique identity is its full DN | `openshift.io/ldap.uid` = `cn=app-ssb-autobahnusers,ou=Groups,dc=ephico2real,dc=com` |
| `groupNameAttributes: [cn]` | the OpenShift Group's name | `app-ssb-autobahnusers` |
| `userUIDAttribute: dn` | a user's unique identity is their full DN | `uid=john.doe,ou=People,dc=ephico2real,dc=com` |
| `userNameAttributes: [uid]` | the username OpenShift shows | `john.doe` |

So a member is carried as a DN and rendered as a username:

```text
identity :  uid=john.doe,ou=People,dc=ephico2real,dc=com
username :  john.doe
```

`groupUIDAttribute: dn` is load-bearing beyond identity. It is what puts the **full DN** in the Group's
`openshift.io/ldap.uid` annotation, which is how `group-sync-dashboard` matches its `clusterAccess.group`
setting to a synced Group. Matching on `cn` would break the moment two branches of a directory both had
a group of the same name.

### The whole flow, end to end

```text
Start LDAP group sync
        │
        ▼
Search base:
ou=Groups,dc=ephico2real,dc=com
        │
        ▼
Search subtree (scope: sub)
        │
        ▼
Apply group filter:
(&
  (|
    (objectClass=groupOfNames)
    (objectClass=groupOfUniqueNames)
  )
  (cn=app-ssb-autobahnusers)
)
        │
        ▼
Find:
cn=app-ssb-autobahnusers
        │
        ├───────────────┐
        │               │
        ▼               ▼
If group is         If group is
groupOfNames        groupOfUniqueNames
        │               │
        ▼               ▼
Read `member`       Read `uniqueMember`
        │               │
        └───────┬───────┘
                │
                ▼
OpenShift checks BOTH configured
membership attributes:

groupMembershipAttributes:
  - member
  - uniqueMember
                │
                ▼
Collect all membership DN values
that actually exist on the entry
                │
                ▼
  APPENDED in the order listed,
  never deduplicated — see §2.
  Normally only one attribute is
  populated, so this is one list.
                │
                ▼
Example:
uid=john,ou=People,dc=ephico2real,dc=com
uid=mary,ou=People,dc=ephico2real,dc=com
                │
                ▼
Use userUIDAttribute: dn
to identify each LDAP user
                │
                ▼
Resolve/read the LDAP user entry
                │
                ▼
Read username from:
userNameAttributes:
  - uid
                │
                ▼
Example:

DN:
uid=john,ou=People,dc=ephico2real,dc=com

uid:
john
                │
                ▼
Create/update OpenShift Group:

app-ssb-autobahnusers
        │
        ├── john
        ├── mary
        └── ...
```

The branch in the middle is how to *read* it, not a decision the operator makes: it checks every
attribute in `groupMembershipAttributes` on whatever entry the filter found. On a group with one of them
populated, the other contributes nothing and the two paths collapse into one.

---

## 5. The directory side is not always free to change

"Make every group `groupOfNames` for consistency" is the obvious next thought. On a directory that gates
authentication through a `memberOf` filter, it can take authentication down.

OpenLDAP's `memberof` overlay is configured per membership attribute. On this lab it tracks
`uniqueMember` only. Measured:

| | count |
|---|---|
| `groupOfNames` groups containing `jane.smith` via `member` | **17** |
| `memberOf` values `jane.smith` actually carries | **1** — the gate group |

```bash
# how many groupOfNames groups list her
ldapsearch -x ... -b "ou=Groups,dc=ephico2real,dc=com" \
  '(&(objectClass=groupOfNames)(member=uid=jane.smith,ou=People,dc=ephico2real,dc=com))' dn
# what memberOf she has
ldapsearch -x ... -b "uid=jane.smith,ou=People,dc=ephico2real,dc=com" '(objectClass=*)' memberOf
```

The identity provider's filter is `(&(uid=*)(memberOf=cn=app-ssb-autobahnusers,…))`. Rewriting that
group as `groupOfNames` would generate no `memberOf`, match nobody, and **refuse every LDAP login** —
including accounts that work today. The narrow overlay configuration is also useful as it stands:
`memberOf` holds exactly the gate membership and nothing else, so the filter is cheap and unambiguous.

Check yours before changing a group's schema:

```bash
ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config '(olcOverlay=*memberof*)' \
  olcMemberOfGroupOC olcMemberOfMemberAD
```

---

## 6. `isMemberOf`, the other spelling

Neither `memberOf` nor `isMemberOf` is defined by an RFC. `memberOf` is OpenLDAP's overlay and Active
Directory; `isMemberOf` is 389-ds and Oracle/Sun DSEE. A filter may legitimately use either.

This matters for anything that *reads* an identity provider's filter to discover the gated group —
`group-sync-dashboard` does, to fill `clusterAccess.group` when it is not set explicitly. A parser that
knew only one spelling would report "no login gate is configured" on half the directories in the world:
a false statement about the cluster rather than a visible failure.

---

## Summary

| | |
|---|---|
| One entry, both structural classes | impossible — OpenLDAP error 65 |
| One entry, both membership attributes | possible via an AUXILIARY class |
| Both attributes configured | concatenated, **never deduplicated**, at any stage |
| Both attributes configured, one populated | correct and free — the intended use |
| Wrong membership attribute | zero members, no error anywhere |
| Wrong objectClass in the filter | no Group at all — at least visible |
| `groupUIDAttribute: dn` | full DN in `openshift.io/ldap.uid` |

**References.** RFC 4519 (group classes), RFC 4512 (one structural chain per entry),
[`oc`'s RFC2307 extraction](https://github.com/openshift/oc/blob/master/pkg/helpers/groupsync/rfc2307/ldapinterface.go),
[OpenLDAP schema guide](https://www.openldap.org/doc/admin24/schema.html) (auxiliary classes).
Chart keys: [DESIGN_custom_groupsync.md](DESIGN_custom_groupsync.md).
