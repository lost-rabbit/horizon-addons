# -*- coding: utf-8 -*-
"""Execute shared_sneak.lua for real across job states and check what the
, and . keys send. The profile harness stubs LoadFile to nil, so this file
was never exercised there."""
import os, sys, importlib.util
import lupa.luajit21 as lj

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
SP = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('rp', os.path.join(SP, 'run_profile.py'))
rp = importlib.util.module_from_spec(spec); spec.loader.exec_module(rp)
src = open(os.path.join(rp.DIR, 'shared_sneak.lua'), encoding='utf-8').read()

# main, level, sync, sub, sublvl, learned spell ids, expected sneak, expected invis
CASES = [
    ('RDM 18, no spells yet',       'RDM', 18, 0,  'PUP', 9,  [],         '/item "Silent Oil" <me>', '/item "Prism Powder" <me>'),
    ('RDM 22, Sneak learned',       'RDM', 22, 0,  'PUP', 11, [137],      '/ma "Sneak" <me>',        '/item "Prism Powder" <me>'),
    ('RDM 30, both learned',        'RDM', 30, 0,  'PUP', 15, [137, 136], '/ma "Sneak" <me>',        '/ma "Invisible" <me>'),
    ('RDM 30 synced to 18',         'RDM', 30, 18, 'PUP', 9,  [137, 136], '/item "Silent Oil" <me>', '/item "Prism Powder" <me>'),
    ('RDM 22, not bought',          'RDM', 22, 0,  'PUP', 11, [],         '/item "Silent Oil" <me>', '/item "Prism Powder" <me>'),
    ('WAR 75 / RDM 37',             'WAR', 75, 0,  'RDM', 37, [137, 136], '/ma "Sneak" <me>',        '/ma "Invisible" <me>'),
    ('RNG 75 / SAM (unchanged)',    'RNG', 75, 0,  'SAM', 37, [137, 136], '/item "Silent Oil" <me>', '/item "Prism Powder" <me>'),
    ('PUP 75 / WAR (unchanged)',    'PUP', 75, 0,  'WAR', 37, [],         '/item "Silent Oil" <me>', '/item "Prism Powder" <me>'),
]

bad = 0
for label, mj, lvl, sync, sub, sublvl, learned, want_s, want_i in CASES:
    L = lj.LuaRuntime()
    g = L.globals()
    g.INSTALL = ''
    g.CMDS = L.table()
    g.MAINJOB, g.LVL, g.SYNC, g.SUB, g.SUBLVL, g.STATUS = mj, lvl, sync, sub, sublvl, 'Idle'
    g.SKILL, g.PET = 0, None
    k = L.table()
    for sid in learned:
        k[sid] = True
    g.KNOWN = k
    L.execute(rp.STUBS)
    M = L.execute(src)
    M.Sneak(); M.Invis()
    got = [g.CMDS[i] for i in range(1, len(g.CMDS) + 1)]
    ok = got == [want_s, want_i]
    bad += not ok
    print(('  ok  ' if ok else ' FAIL '), f'{label:<26} , -> {got[0]:<26} . -> {got[1]}')
print('\nall pass' if not bad else f'\n{bad} FAILED')
