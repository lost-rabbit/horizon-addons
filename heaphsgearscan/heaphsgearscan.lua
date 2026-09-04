--[[
* gearscan - dumps every item in every container to a text file, with the
* level, job list and stat line the client itself holds for each piece of
* gear, for cataloguing and gear-set building outside the game.
*
* Usage: /gearscan          dump everything
*        /gearscan inv      dump only the containers that are live anywhere
*                           (inventory, satchel, sack, case, wardrobes, temp)
*        /gearscan help     command list
* Output: <Game>\config\gearscan_dump.txt (overwritten each run)
*
* Note: Safe/Storage/Locker contents are cached by the client - visit
* your Mog House once after login if those show up empty.
*
* Read-only: the addon only reads memory and the resource tables and writes
* one file. It sends no commands, packets or key presses.
*
* Creation assisted by ADA.
--]]

addon.name      = 'heaphsgearscan';
addon.author    = 'Heaph';
addon.version   = '1.2';
addon.desc      = 'Dumps all inventory containers, with level/jobs/stats.';

require('common');
local chat = require('chat');

local containers = T{
    [0]  = 'Inventory',
    [1]  = 'Mog Safe',
    [2]  = 'Storage',
    [3]  = 'Temporary',
    [4]  = 'Mog Locker',
    [5]  = 'Mog Satchel',
    [6]  = 'Mog Sack',
    [7]  = 'Mog Case',
    [8]  = 'Mog Wardrobe',
    [9]  = 'Mog Safe 2',
    [10] = 'Mog Wardrobe 2',
    [11] = 'Mog Wardrobe 3',
    [12] = 'Mog Wardrobe 4',
};

-- "Local" containers are live anywhere; Safe/Storage/Locker only populate
-- after visiting your Mog House (client-side cache).
local localOnly = T{ [0] = true, [3] = true, [5] = true, [6] = true, [7] = true,
                     [8] = true, [10] = true, [11] = true, [12] = true };

-- Job bit positions in the item's Jobs bitmask (bit N = job id N).
local JOBS = T{ 'WAR','MNK','WHM','BLM','RDM','THF','PLD','DRK','BST','BRD',
                'RNG','SAM','NIN','DRG','SMN','BLU','COR','PUP','DNC','SCH' };

local function JobList(mask)
    if (mask == nil) or (mask == 0) then return 'None'; end
    local out = T{};
    for i, name in ipairs(JOBS) do
        if (bit.band(mask, bit.lshift(1, i)) ~= 0) then out:append(name); end
    end
    if (#out == 0) then return ('mask:%d'):fmt(mask); end
    if (#out >= 18) then return 'All Jobs'; end
    return table.concat(out, '/');
end

-- Element icon bytes as they appear in item descriptions (after 0xEF).
local ELEMENT_ICONS = {
    ['\31'] = 'Fire',  ['\32'] = 'Ice',   ['\33'] = 'Wind',  ['\34'] = 'Earth',
    ['\35'] = 'Lightning', ['\36'] = 'Water', ['\37'] = 'Light', ['\38'] = 'Dark',
};

-- One flat line of the CLIENT's own truth: level, jobs, and (for weapons)
-- damage/delay. This is authoritative - wikis disagree with it regularly.
local function ItemInfo(resource)
    local bits = T{};
    if (resource.Level ~= nil) and (resource.Level > 0) then
        bits:append(('Lv%d'):fmt(resource.Level));
    end
    bits:append(JobList(resource.Jobs));
    if (resource.Damage ~= nil) and (resource.Damage > 0) then
        bits:append(('DMG%d/Dly%d'):fmt(resource.Damage, resource.Delay or 0));
    end
    local info = table.concat(bits, ' ');
    -- Description carries the stat text ("DEF:12 HP+13 AGI+3 ..."), newlines
    -- flattened so each item stays on one line.
    local desc = nil;
    if (resource.Description ~= nil) and (resource.Description[1] ~= nil) then
        desc = tostring(resource.Description[1]):gsub('[\r\n]+', ' '):gsub('%s+', ' ');
        -- The client stores element resistances as a two-byte icon code
        -- (0xEF then 0x1F..0x26, in the usual Fire..Dark order). Spell them
        -- out so the dump is readable; strip any other icon code.
        for code, name in pairs(ELEMENT_ICONS) do
            local esc = code:gsub('%W', '%%%0');   -- some codes are pattern magic
            desc = desc:gsub('\239' .. esc, name);
        end
        desc = desc:gsub('\239.', ''):gsub('%s+', ' ');
        desc = desc:gsub('^%s+', ''):gsub('%s+$', '');
    end
    if (desc ~= nil) and (desc ~= '') then
        return ('%s | %s'):fmt(info, desc);
    end
    return info;
end

local function DumpGear(invOnly)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local res = AshitaCore:GetResourceManager();
    local path = ('%s\\config\\gearscan_dump.txt'):fmt(AshitaCore:GetInstallPath());

    local f = io.open(path, 'w');
    if (f == nil) then
        print(chat.header(addon.name):append(chat.error('Could not open config\\gearscan_dump.txt for writing.')));
        return;
    end

    local total = 0;
    f:write(('gearscan dump - %s\n'):fmt(os.date('%Y-%m-%d %H:%M:%S')));

    -- Currently equipped gear (equip slots 0-15 map into containers)
    f:write('\n== Equipped Right Now ==\n');
    for slot = 0, 15 do
        local eq = inv:GetEquippedItem(slot);
        if (eq ~= nil) and (eq.Index ~= nil) and (eq.Index ~= 0) then
            local cid = bit.rshift(eq.Index, 8);
            local cslot = bit.band(eq.Index, 0xFF);
            local item = inv:GetContainerItem(cid, cslot);
            if (item ~= nil) and (item.Id ~= nil) and (item.Id > 0) then
                local resource = res:GetItemById(item.Id);
                if (resource ~= nil) then
                    local name = (resource.Name and resource.Name[1]) or ('item %d'):fmt(item.Id);
                    f:write(('%-22s  %s\n'):fmt(name, ItemInfo(resource)));
                    total = total + 1;
                end
            end
        end
    end

    -- Numeric loop rather than pairs() so the sections come out in a fixed
    -- order (pairs() puts the [0] key wherever it likes).
    for id = 0, 12 do
        local cname = containers[id];
        local skip = (invOnly == true) and (localOnly[id] ~= true);
        local max = inv:GetContainerCountMax(id);
        if (not skip) and (max ~= nil) and (max > 0) then
            f:write(('\n== %s ==\n'):fmt(cname));
            for slot = 0, max do
                local item = inv:GetContainerItem(id, slot);
                -- Id 65535 is the gil pseudo-item in slot 0, not gear.
                if (item ~= nil) and (item.Id ~= nil) and (item.Id > 0) and (item.Id ~= 65535) then
                    local resource = res:GetItemById(item.Id);
                    if (resource ~= nil) then
                        local name = (resource.Name and resource.Name[1]) or ('item %d'):fmt(item.Id);
                        local count = item.Count or 1;
                        if (count > 1) then
                            name = ('%s x%d'):fmt(name, count);
                        end
                        -- Only gear carries a useful level/job line; skip the
                        -- noise for crystals, food, seals and other clutter.
                        local equippable = (resource.Slots ~= nil) and (resource.Slots > 0);
                        if (equippable) then
                            f:write(('%-22s  %s\n'):fmt(name, ItemInfo(resource)));
                        else
                            f:write(('%s\n'):fmt(name));
                        end
                        total = total + 1;
                    end
                end
            end
        end
    end

    f:close();
    print(chat.header(addon.name):append(chat.message(
        ('Dumped %d items to config\\gearscan_dump.txt'):fmt(total))));
end

--[[
* Prints the addon help information.
*
* @param {boolean} isError - Flag if this function was invoked due to an error.
--]]
local function print_help(isError)
    if (isError) then
        print(chat.header(addon.name):append(chat.error('Invalid command syntax for command: ')):append(chat.success('/gearscan')));
    else
        print(chat.header(addon.name):append(chat.message('Available commands:')));
    end

    local cmds = T{
        { '/gearscan', 'Dumps every container to config\\gearscan_dump.txt (Safe/Storage/Locker need a Mog House visit first).' },
        { '/gearscan inv', 'Dumps only the containers that are live anywhere: inventory, satchel, sack, case, wardrobes, temporary.' },
        { '/gearscan help', 'Displays the addons help information.' },
    };

    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or (args[1] ~= '/heaphsgearscan' and args[1] ~= '/gearscan')) then
        return;
    end
    e.blocked = true;
    local sub = args[2] and args[2]:lower() or '';
    if (sub == '') then
        DumpGear(false);
    elseif (sub == 'inv') then
        DumpGear(true);
    elseif (sub == 'help') then
        print_help(false);
    else
        print_help(true);
    end
end);
