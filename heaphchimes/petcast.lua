--[[
* petcast.lua - automaton nuke cadence timer, a MODULE of cdchime.
*
* MEASURED, not guessed. 588 elemental casts by Lobo/X-32 across the
* 2026.08 chatlogs, 475 usable gaps between consecutive casts:
*
*     mode    35s   (105 gaps, plus 57 at 36s, 23 at 34s)
*     median  38s
*     33-40s band holds 55% of every gap
*     floor   18s   (rare, 13 gaps under 33s = 3%)
*
* Buckets by maneuvers-used-during-the-gap looked like more maneuvers meant
* slower casting, but that is backwards causation: a longer gap simply gives
* more time to press maneuvers. Every clean bucket sits at 35-36s median, so
* the cadence is treated as FIXED and the interval is one setting.
*
* Starts on "<pet> starts casting <elemental>" - the moment the puppet
* commits - and counts the interval down. Green when it is due.
*
* Chat-log reading and a countdown you configured; no automation.
--]]

require('common');
local imgui = require('imgui');
local chat  = require('chat');

local M = { };

-- Lua patterns have no alternation, so the elements are a list and the
-- captured spell name is tested against it by prefix ("Fire", "Fire II").
local ELEMS = { 'Aero', 'Water', 'Thunder', 'Stone', 'Fire', 'Blizzard' };
local lastCast = nil;    -- os.clock() of the last observed cast start
local lastName = nil;

local function Cfg()
    local th = _G.cdchimeTheme;
    if (th == nil) or (th.cfg == nil) then return nil; end
    return th.cfg.petcast;
end

local function PetName()
    local p = GetPlayerEntity();
    if (p == nil) or (p.PetTargetIndex == nil) or (p.PetTargetIndex == 0) then return nil; end
    local pet = GetEntity(p.PetTargetIndex);
    if (pet == nil) then return nil; end
    return pet.Name;
end

ashita.events.register('text_in', 'petcast_text_cb', function (e)
    local c = Cfg();
    if (c == nil) or (c.enabled == false) then return; end
    local msg = e.message;
    if (msg == nil) then return; end
    -- Raw chat carries colour/format control bytes; strip them or the
    -- anchored match below silently never fires.
    msg = msg:gsub('[%z\1-\31\127]', '');
    -- "<pet> starts casting <spell>" - match against the live pet name so a
    -- party member's automaton cannot drive our timer.
    local who, spell = msg:match('^%s*(%S+) starts casting (%a+)');
    if (who == nil) or (spell == nil) then return; end
    local elemental = false;
    for _, el in ipairs(ELEMS) do
        if (spell:sub(1, #el) == el) then elemental = true; break; end
    end
    if (not elemental) then return; end
    local pn = PetName();
    if (pn == nil) or (who ~= pn) then return; end
    lastCast = os.clock();
    lastName = spell;
end);

function M.Left()
    local c = Cfg();
    if (c == nil) or (lastCast == nil) then return nil; end
    local left = (c.interval or 35) - (os.clock() - lastCast);
    return left;
end

function M.Draw()
    local th = _G.cdchimeTheme;
    if (th == nil) or (not th.Enabled('cdchime_petcast')) then return; end
    local c = Cfg();
    -- Drop the stale cast stamp when we are not on PUP, or the cadence
    -- timer keeps ticking on another job for a puppet that is not out.
    local pl = AshitaCore:GetMemoryManager():GetPlayer();
    if (pl == nil) or (pl:GetMainJob() ~= 18) then lastCast = nil; return; end
    if (c == nil) or (c.enabled == false) or (lastCast == nil) then return; end

    local interval = c.interval or 35;
    local left = interval - (os.clock() - lastCast);
    local due = (left <= 0);
    if (due) then
        -- Stop drawing once it has been due for a while: the puppet is
        -- clearly not nuking (no MP, no target) and a stuck "READY" is noise.
        if (-left > (c.hide_after or 30)) then return; end
        left = 0;
    end

    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing);
    th.Push('cdchime_petcast');
    if (imgui.Begin('cdchime_petcast', true, flags)) then
        th.PushScale(th.Scale('cdchime_petcast'));
        local label;
        if (due) then
            label = c.ready_text or 'Nuke due';
        else
            label = ('%s  %.0fs'):fmt(c.label or 'Nuke', math.ceil(left));
        end
        local col = due and th.Col('good') or th.Col('text');
        if ((not due) and left <= (c.warn_at or 5)) then col = th.Col('warn'); end

        if (c.show_bar ~= false) then
            local w = math.floor((c.width or 150) * th.Scale('cdchime_petcast'));
            local h = math.floor((c.height or 10) * th.Scale('cdchime_petcast'));
            local x, y = imgui.GetCursorScreenPos();
            local dl = imgui.GetWindowDrawList();
            local frac = due and 1.0 or math.max(0, math.min(1, 1 - (left / interval)));
            local g = th.Col('ground');
            dl:AddRectFilled({ x, y }, { x + w, y + h }, imgui.GetColorU32({ g[1], g[2], g[3], 0.92 }));
            if (frac > 0) then
                dl:AddRectFilled({ x, y }, { x + math.max(2, w * frac), y + h },
                    imgui.GetColorU32({ col[1], col[2], col[3], 0.90 }));
            end
            local b = th.Col('border');
            dl:AddRect({ x, y }, { x + w, y + h }, imgui.GetColorU32(b), 0.0, 0, 1.0);
            imgui.Dummy({ w, h });
        end
        imgui.TextColored(col, label);
        if (c.show_spell ~= false) and (lastName ~= nil) then
            imgui.SameLine();
            imgui.TextColored(th.Col('dim'), ('(%s)'):fmt(lastName));
        end
        th.PopScale();
    end
    imgui.End();
    th.Pop();
end

ashita.events.register('d3d_present', 'petcast_present_cb', function ()
    M.Draw();
end);

ashita.events.register('command', 'petcast_cmd_cb', function (e)
    local args = e.command:args();
    if (#args == 0) or (args[1] ~= '/petcast') then return; end
    e.blocked = true;
    local c = Cfg();
    if (c == nil) then
        print(chat.header('petcast'):append(chat.error('theme settings unavailable')));
        return;
    end
    local sub = args[2] and args[2]:lower() or 'status';
    if (sub == 'interval') and (tonumber(args[3]) ~= nil) then
        c.interval = tonumber(args[3]);
        if (_G.cdchimeTheme ~= nil) then _G.cdchimeTheme.Save(); end
        print(chat.header('petcast'):append(chat.message(('interval set to %ds'):fmt(c.interval))));
    elseif (sub == 'on') or (sub == 'off') then
        c.enabled = (sub == 'on');
        if (_G.cdchimeTheme ~= nil) then _G.cdchimeTheme.Save(); end
        print(chat.header('petcast'):append(chat.message('timer ' .. sub)));
    elseif (sub == 'reset') then
        lastCast = nil; lastName = nil;
        print(chat.header('petcast'):append(chat.message('cleared')));
    else
        local left = M.Left();
        print(chat.header('petcast'):append(chat.message(
            ('interval %ds, %s  (/petcast interval <secs> | on | off | reset)'):fmt(
            c.interval or 35,
            (left == nil) and 'no cast seen yet' or ('%.0fs left'):fmt(math.max(0, left))))));
    end
end);

_G.cdchimePetcast = M;
return M;
