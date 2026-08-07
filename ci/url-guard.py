#!/usr/bin/env python3
"""The LDAP url must reach every consumer through the resolver, never from the raw values field.

needsCa read `.url` directly (bug #17) and both test pods baked `.Values.groupSync.url` (bug M2/#9).
Both are invisible to `helm template`, because the raw field and the resolved url are the same string
whenever a url is set — and offline a url must be set for anything to render. So this is asserted on
the template SOURCE: only ldapUrl / ldapUrlOrEmpty may read the raw field.

usage: url-guard.py <chart-dir>
"""
import re, sys, pathlib

# Four ways to read the raw url, and a pattern that only knew the first two was a guard that looked
# stricter than it was. Each of the last two was MEASURED bypassing the previous version:
#
#   {{ .Values.groupSync.url }}                     caught before
#   {{ with .Values.groupSync }}{{ .url }}          caught before
#   {{ $gs := .Values.groupSync }}{{ $gs.url }}     PASSED — a natural refactor once a template reads
#                                                   several groupSync keys
#   {{ index .Values.groupSync "url" }}             PASSED — no dotted path exists to match
#   {{ get $gs "url" }}                             PASSED — same
#
# `index`/`get` are matched on the STRING KEY rather than on what they are indexing, because the thing
# being indexed can itself be an alias and chasing that is a type inference this script has no business
# attempting. The cost is that indexing "url" on some OTHER object would also be flagged. That is
# acceptable and deliberate: the Risk note on this check has always said a non-groupSync raw `.url` read
# deserves the same scrutiny, and ALLOWED_DEFINES is the escape hatch for a deliberate one.
RAW = re.compile(
    r'\.Values\.groupSync\.url\b'          # the direct read
    r'|(?<![\w.])\.url\b'                   # context-relative, inside a `with`
    r'|\$\w+(?:\.\w+)*\.url\b'            # through a variable alias
    r'|\b(?:index|get)\b[^}]*?"url"'        # string-key access, which no dotted pattern can see
)
ALLOWED_DEFINES = ('group-sync-operator-helm.ldapUrlOrEmpty',)

def actions(text):
    """(line_no, action_body) for every {{ ... }} in the file — comments outside them are ignored.

    Scans the WHOLE TEXT rather than line by line, because a Go template action may span newlines and
    the per-line version could not see one at all. Measured: `{{ printf "%s"\n  .Values.groupSync.url }}`
    yielded ZERO parsed actions, so the guard was blind to it before any pattern ran — a raw read split
    across two lines defeated the check entirely, no cleverness required.

    The line number is the line the action STARTS on, which is what a reader needs to find it, and is
    what the previous behaviour reported for the single-line case.
    """
    lines = text.splitlines()
    for m in re.finditer(r'\{\{(.*?)\}\}', text, re.S):
        body = m.group(1)
        # `text.count` up to the match start gives the 0-based line index of the opening braces.
        ln = text.count('\n', 0, m.start()) + 1
        if body.lstrip().startswith('/*'):
            continue
        # A YAML comment line is not a template action even if it mentions .Values. Judged on the line
        # the action OPENS on: a `#` later in a multi-line action is inside the action, not commenting
        # it out.
        stripped = lines[ln - 1].lstrip() if ln <= len(lines) else ''
        if stripped.startswith('#'):
            continue
        yield ln, body

def define_spans(text):
    """line ranges of each {{- define "x" -}} ... {{- end }} block, keyed by name."""
    spans, stack = {}, []
    for i, line in enumerate(text.splitlines(), 1):
        m = re.search(r'define\s+"([^"]+)"', line)
        if m:
            stack.append((m.group(1), i))
        elif re.match(r'\{\{-?\s*end\s*-?\}\}\s*$', line.strip()) and stack:
            name, start = stack.pop()
            spans.setdefault(name, []).append((start, i))
    return spans

def main(chart):
    bad = []
    for p in sorted(pathlib.Path(chart, 'templates').rglob('*')):
        if not p.is_file() or p.suffix not in ('.yaml', '.tpl', '.txt'):
            continue
        text = p.read_text()
        allowed = []
        for name in ALLOWED_DEFINES:
            allowed += define_spans(text).get(name, [])
        for ln, body in actions(text):
            if not RAW.search(body):
                continue
            if any(a <= ln <= b for a, b in allowed):
                continue
            bad.append(f"{p.relative_to(chart)}:{ln}: reads the raw url — use "
                       f'{{{{ include "group-sync-operator-helm.ldapUrlOrEmpty" . }}}} '
                       f'(or ldapUrl where a url is mandatory): {{{{{body}}}}}')
    for b in bad:
        print(f"  FAIL {b}")
    print(f"{'FAIL' if bad else 'PASS'} url-resolver-guard ({len(bad)} problem(s))")
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
