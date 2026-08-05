#!/usr/bin/env python3
"""The LDAP url must reach every consumer through the resolver, never from the raw values field.

needsCa read `.url` directly (bug #17) and both test pods baked `.Values.groupSync.url` (bug M2/#9).
Both are invisible to `helm template`, because the raw field and the resolved url are the same string
whenever a url is set — and offline a url must be set for anything to render. So this is asserted on
the template SOURCE: only ldapUrl / ldapUrlOrEmpty may read the raw field.

usage: url-guard.py <chart-dir>
"""
import re, sys, pathlib

RAW = re.compile(r'\.Values\.groupSync\.url\b|(?<![\w.])\.url\b')
ALLOWED_DEFINES = ('group-sync-operator-helm.ldapUrlOrEmpty',)

def actions(text):
    """(line_no, action_body) for every {{ ... }} in the file — comments outside them are ignored."""
    for i, line in enumerate(text.splitlines(), 1):
        # a YAML comment line is not a template action even if it mentions .Values
        stripped = line.lstrip()
        for m in re.finditer(r'\{\{(.*?)\}\}', line):
            body = m.group(1)
            if stripped.startswith('#') and '{{' not in stripped.split('#', 1)[0]:
                continue
            if body.lstrip().startswith('/*'):
                continue
            yield i, body

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
