"""Detecte les identifiants utilises mais jamais definis dans un module Lua.

Motive par trois pannes du 2026-08-19 : un helper supprime avec le bloc qui
l'entourait, alors que ses appelants restaient. Lua ne s'en plaint qu'a
l'execution, souvent dans un pcall muet.
"""
import io
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else 'C:/Users/eberger/.config/wezterm/lua/workspaces.lua'
src = io.open(path, encoding='utf-8').read()

code = re.sub(r'--\[\[.*?\]\]', ' ', src, flags=re.S)
code = re.sub(r'--[^\n]*', ' ', code)
code = re.sub(r'"[^"\n]*"', '""', code)
code = re.sub(r"'[^'\n]*'", "''", code)

defined = set()
patterns = [
    r'\blocal\s+function\s+([A-Za-z_]\w*)',
    r'\bfunction\s+([A-Za-z_]\w*)\s*\(',
]
for pat in patterns:
    for m in re.finditer(pat, code):
        defined.add(m.group(1))

for m in re.finditer(r'\blocal\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)', code):
    for name in m.group(1).split(','):
        defined.add(name.strip())
for m in re.finditer(r'\bfor\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*(?:=|in)', code):
    for name in m.group(1).split(','):
        defined.add(name.strip())
for m in re.finditer(r'\bfunction\s*[A-Za-z_.:]*\s*\(([^)]*)\)', code):
    for name in m.group(1).split(','):
        name = name.strip()
        if name:
            defined.add(name)

builtins = set('''
and break do else elseif end false for function goto if in local nil not or repeat
return then true until while self
wezterm os io math string table pcall ipairs pairs type tostring tonumber require
print select error assert next unpack setmetatable getmetatable rawget rawset
domains notifications M
'''.split())

problems = {}
for m in re.finditer(r'(?<![\w.:])([A-Za-z_]\w*)', code):
    name = m.group(1)
    if name in builtins or name in defined:
        continue
    tail = code[m.end():m.end() + 4]
    # cle de table ou affectation : `nom =` (mais pas `nom ==`)
    if re.match(r'\s*=(?!=)', tail):
        continue
    problems.setdefault(name, code[:m.start()].count('\n') + 1)

if problems:
    print('IDENTIFIANTS JAMAIS DEFINIS :')
    for name, line in sorted(problems.items(), key=lambda kv: kv[1]):
        print('  ligne %-6d %s' % (line, name))
    sys.exit(1)

print('aucun identifiant orphelin')
