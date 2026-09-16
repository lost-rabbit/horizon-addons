# -*- coding: utf-8 -*-
"""Run heaphchimes' real text_in handler against simulated events and check
that e.blocked is actually set. Syntax checks would not catch a handler that
reads the wrong field and silently matches nothing."""
import os, re, sys
import lupa.luajit21 as lj

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
GAME = os.path.join(os.environ['APPDATA'], 'HorizonXI-Launcher', 'HorizonXI', 'Game')
src = open(os.path.join(GAME, 'addons', 'heaphchimes', 'heaphchimes.lua'), encoding='utf-8').read()

start = src.index('local quietOn = true;')
end = src.index('\n\n', src.index("ashita.events.register('text_in', 'heaph_quiet_cb'"))
block = src[start:end]
for name in ('quietOn', 'quietScale', 'QUIET_PATTERNS', 'quietSeen', 'quietHeld'):
    block = block.replace('local ' + name, name)

L = lj.LuaRuntime()
# a stand-in for ashita.events.register that just keeps the handler
L.execute('ashita = { events = { register = function(_, _, fn) HANDLER = fn end } }')
L.execute(block)
handler = L.globals().HANDLER
assert handler is not None, 'handler was not registered'

mkev = L.eval('function(m) return { message = "RAW-DIFFERENT-TEXT", message_modified = m, blocked = false } end')
CLOCK = L.eval('function(t) os.clock = function() return t end end')


def send(text, at):
    CLOCK(at)
    ev = mkev(text)
    handler(ev)
    return bool(ev.blocked)


print('a burst of the same line, one per second:')
for i in range(6):
    b = send('You must wait longer to perform that action.', 100 + i)
    print(f'  t+{i}s  {"HELD" if b else "shown"}')

print('\nthe same line again after the 30s window:')
print('  t+40s ', 'HELD' if send('You must wait longer to perform that action.', 140) else 'shown')

print('\ndifferent lines must not silence each other:')
for txt, t in (('You cannot see the Magmatic Eruca.', 200),
               ('You cannot see the Nival Raptor.', 201),
               ('You cannot see the Magmatic Eruca.', 202)):
    print(f'  {"HELD " if send(txt, t) else "shown"}  {txt}')

print('\nAshita echo, same command repeated then a different one:')
for txt, t in (('>> /ra <t>', 300), ('>> /ra <t>', 301),
               ('>> /ja "Flee" <me>', 302), ('>> /ra <t>', 303)):
    print(f'  {"HELD " if send(txt, t) else "shown"}  {txt}')

print('\nordinary lines must always pass:')
SAFE = [
    '[2]<Bob> anyone need a tele dem or holla',
    "Heaph's ranged attack strikes true, pummeling the Magmatic Eruca for 155 points of damage!",
    'The Magmatic Eruca takes 886 points of damage.',
    'Tensho licks Heaph.',
    'You synthesized 33 silver bullets.',
    'Your Velocity Shot effect wears off.',
]
bad = 0
for i, t in enumerate(SAFE):
    b = send(t, 400 + i)
    bad += b
    print(f'  {"HELD!!" if b else "passes"}  {t[:58]}')

held = L.globals().quietHeld
print(f'\nheld back this run: {held}')
print('PASS' if not bad and held > 0 else 'FAIL')
