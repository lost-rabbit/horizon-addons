# -*- coding: utf-8 -*-
"""Actually execute a LuAshitaCast profile and call its hooks.

A loadstring check only proves the file parses. The "attempt to call global
'Say'" crash parsed fine and still blew up in OnLoad, because Lua resolves a
local at call time. This stubs enough of Ashita and LuAshitaCast to run the
profile for real and call every hook, which catches that whole class of bug.

Usage: run_profile.py RNG [PUP ...]
"""
import os, sys
import lupa.luajit21 as lj

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
DIR = os.path.join(os.environ['APPDATA'], 'HorizonXI-Launcher', 'HorizonXI', 'Game',
                   'config', 'addons', 'luashitacast', 'Heaph_17007')

STUBS = """
-- Ashita adds these string helpers; without them a profile that uses :fmt()
-- looks broken here when it is fine in game.
string.fmt = string.format
getmetatable('').__index.fmt = string.format

-- the two globals every profile reaches for
local function tbl(t) return t or {} end

gData = {
    GetPlayer = function()
        return { MainJob = MAINJOB, MainJobLevel = LVL, MainJobSync = SYNC, SubJob = SUB,
                 SubJobLevel = SUBLVL, Status = STATUS, HPP = 80, Name = 'Heaph' }
    end,
    GetEquipment = function()
        return { Range = { Name = 'Hellfire +1', Resource = { Delay = 640, Skill = 26 } },
                 Main  = { Name = 'Bee Spatha +1', Resource = { Delay = 227, Skill = 3 } } }
    end,
    GetEnvironment = function() return { Time = 12.0, Area = 'Sauromugue Champaign' } end,
    GetAction        = function() return nil end,
    GetBuffCount     = function() return 0 end,
    GetTargetIndex   = function() return 0 end,
    GetPet           = function() return PET end,
    GetPetAction     = function() return nil end,
    GetTarget        = function() return nil end,
    GetSpellCost     = function() return 0 end,
}
gFunc = {
    EquipSet  = function() end,
    LoadFile  = function() return nil end,
    Equip     = function() end,
    ForceEquip= function() end,
}
gSettings = {}

AshitaCore = {
    GetChatManager = function()
        return { QueueCommand = function(_, _, c) CMDS[#CMDS + 1] = c end }
    end,
    GetMemoryManager = function()
        return {
            GetPlayer = function()
                return {
                    GetMainJob = function() return 11 end,
                    GetSubJob = function() return 2 end,
                    GetMainJobLevel = function() return LVL end,
                    GetSubJobLevel = function() return SUBLVL end,
                    GetCombatSkill = function() return { GetSkill = function() return SKILL end } end,
                    HasSpell       = function(_, id) return KNOWN[id] == true end,
                    HasSpellData   = function() return true end,
                }
            end,
            GetRecast = function()
                return { GetAbilityTimer = function() return 0 end,
                         GetSpellTimer   = function() return 0 end }
            end,
            GetEntity = function()
                return { GetStatus      = function() return 0 end,
                         GetName        = function() return 'Heaph' end,
                         GetHPPercent   = function() return 100 end,
                         GetSpawnFlags  = function() return 0 end }
            end,
            GetTarget = function() return nil end,
            GetParty  = function()
                return { GetMemberIsActive = function() return 0 end,
                         GetMemberName     = function() return '' end,
                         GetMemberServerId = function() return 0 end,
                         GetMemberTargetIndex = function() return 0 end,
                         GetTargetIndex       = function() return 0 end }
            end,
            GetInventory = function()
                return { GetContainerCount = function() return 0 end,
                         GetItem           = function() return nil end,
                         GetItemByName     = function() return nil end,
                         GetContainerItem  = function() return nil end }
            end,
        }
    end,
    GetResourceManager = function()
        return {
            GetString      = function(_, _, id) return 'WAR' end,
            GetAbilityById = function() return nil end,
            GetAbilityByName = function() return nil end,
            GetItemByName    = function() return nil end,
            GetItemById      = function() return nil end,
        }
    end,
    GetInstallPath = function() return INSTALL end,
}
GetPlayerEntity = function() return { Name = 'Heaph', Distance = 100 } end
"""


RDM_KNOWN = [1, 2, 23, 33, 43, 48, 52, 56, 58, 59, 108, 159, 169, 154, 100 + 3, 104,
             230, 220, 216]   # a Red Mage 18 with a few scrolls learned
JOBCFG = {
    '_':   {'lvl': 75, 'sub': 'SAM', 'sublvl': 37, 'skill': 269, 'known': [],
            'subs': ('WAR', 'NIN', 'SAM', 'NON'), 'cmds': ('gear', 'recycle', 'loud', 'ws')},
    'RDM': {'lvl': 18, 'sub': 'PUP', 'sublvl': 9, 'skill': 55, 'known': RDM_KNOWN,
            'subs': ('PUP', 'BLM', 'NON', 'PUP'),
            'cmds': ('gear', 'loud', 'ws', 'en', 'nuke', 'el next', 'el next', 'el earth',
                     'el water', 'el bogus', 'gravity', 'blaze', 'resummon', 'resummon!')},
}


def run(job):
    L = lj.LuaRuntime()
    g = L.globals()
    g.INSTALL = os.path.join(os.environ['APPDATA'], 'HorizonXI-Launcher', 'HorizonXI', 'Game') + os.sep
    g.CMDS = L.table()
    cfg = JOBCFG.get(job, JOBCFG['_'])
    g.MAINJOB, g.LVL, g.SYNC, g.SUB, g.SUBLVL, g.STATUS = job, cfg['lvl'], 0, cfg['sub'], cfg['sublvl'], 'Idle'
    g.SKILL = cfg['skill']
    g.PET = None
    known = L.table()
    for sid in cfg['known']:
        known[sid] = True
    g.KNOWN = known
    L.execute(STUBS)

    src = open(os.path.join(DIR, job + '.lua'), encoding='utf-8').read()
    chunk = L.eval('function(s, n) return loadstring(s, n) end')(src, '@' + job + '.lua')
    if chunk is None:
        print(f'{job}: WILL NOT PARSE')
        return False

    ok, profile = L.eval('function(f) local o, r = pcall(f); return o, r end')(chunk)
    if not ok:
        print(f'{job}: load failed -> {profile}')
        return False

    failures = []
    def call(name, *args):
        fn = profile[name]
        if fn is None:
            return
        ok, err = L.eval('function(f, ...) local o, e = pcall(f, ...); return o, tostring(e) end')(fn, *args)
        if not ok:
            failures.append(f'{name}: {err}')

    call('OnLoad')
    for lvl, sync in ((75, 0), (75, 50), (0, 0), (75, 0)):
        g.LVL, g.SYNC = lvl, sync
        call('HandleDefault')
    g.STATUS = 'Engaged'
    call('HandleDefault')
    g.STATUS = 'Resting'
    call('HandleDefault')
    for sub in cfg['subs']:
        g.SUB = sub
        call('HandleDefault')
    g.SUB = cfg['sub']
    for cmd in cfg['cmds']:
        call('HandleCommand', L.table_from(cmd.split()))
    call('HandlePrecast'); call('HandleMidcast'); call('HandleAbility')
    call('HandlePreshot'); call('HandleMidshot'); call('HandleWeaponskill')
    call('OnUnload')

    if failures:
        print(f'{job}: {len(failures)} RUNTIME ERROR(S)')
        for f in failures:
            print('   ', f)
        return False
    print(f'{job}: loads and every hook runs clean')
    return True


if __name__ == '__main__':
    jobs = sys.argv[1:] or ['RNG']
    sys.exit(0 if all([run(j) for j in jobs]) else 1)
