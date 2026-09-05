#!/usr/bin/env python3
"""Catch use-before-declaration of Lua locals in the trainer modules.

Lua locals are only visible after their declaration; a call placed above one
resolves to the global of the same name, which is nil. That loads without
complaint and only throws when the line actually runs -- which is how a weapon
layout check placed above `local function q` silently killed silent aim and
auto-fire until someone played far enough to hit it.

    python3 tools/check_scope.py src
"""
import re, sys, glob, os

HELPERS = r'(q|i32|f|u16|skelId|writeVec|setLayered|setTopmost|killAllTimers|topmost)'


def check(path):
    lines = open(path, encoding='utf-8').read().split('\n')
    decl = {}
    for i, line in enumerate(lines):
        m = re.match(r'\s*local function ' + HELPERS + r'\s*\(', line)
        if m and m.group(1) not in decl:
            decl[m.group(1)] = i
    problems = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith('--'):
            continue
        for name, at in decl.items():
            if i < at and re.search(r'(?<![\w.:])' + re.escape(name) + r'\s*\(', line):
                problems.append((i + 1, name, at + 1, line.strip()))
    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else 'src'
    bad = 0
    for path in sorted(glob.glob(os.path.join(root, 'sod_*.lua'))):
        problems = check(path)
        print(f"{path}: {'OK' if not problems else str(len(problems)) + ' problem(s)'}")
        for line_no, name, decl_at, text in problems:
            bad += 1
            print(f"  line {line_no}: calls `{name}`, declared at line {decl_at}")
            print(f"      {text[:100]}")
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
