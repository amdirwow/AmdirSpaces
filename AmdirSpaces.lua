-- AmdirSpaces v1.7.1 — WoW WotLK 3.3.5a / Lua 5.1
-- Only the visual arrangement is changed. Blizzard's real bag slots stay untouched.

BINDING_HEADER_AMDIRSPACES_HEADER = "AmdirSpaces"
BINDING_NAME_AMDIRSPACES_TOGGLE = "Відкрити / закрити простори"

local ADDON = ... or "AmdirSpaces"
local db
local ui
local activeID
local showEquipment = false
local showAllItems = false
local nativeShades = {}
local applyBagBindings
local applyLayout
local cursorSrc -- where the item on the WoW cursor was picked up from
local pendingRefresh = false
local nextRefresh = 0
local pendingRuleRoute = false
local ownBagCall = false -- true while AmdirSpaces itself opens/closes Blizzard bags
local pendingHide = false -- a toggle-close deferred to the next frame (see hookBagFunctions)
local nextRuleRoute = 0
local ruleRetryUntil = 0
local ruleBagCounts = {}
local ruleDialog
local refreshNativeBags
local hideShades
local spacesFocus
local nativeBagFocused = false
local shadingPulse = 0
local SLOT_X = 42 -- 37px item + 5px horizontal gap in ContainerFrame.lua.
local SLOT_Y = 41 -- 37px item + 4px vertical gap in ContainerFrame.lua.
local ICON = 37
local MAX_SPACE_SLOTS = 36

local function say(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff86d7ffAmdirSpaces:|r " .. tostring(message))
end

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function itemID(link)
    if not link then return nil end
    return tonumber(string.match(link, "item:(%-?%d+)"))
end

local function itemKey(link)
    if not link then return nil end
    -- Preserve enchant, gems, random suffix and uniqueID for duplicate gear.
    return string.match(link, "|H(item:[^|]+)|h") or string.match(link, "(item:[^|%s]+)")
end

local function allSlots(space)
    if type(space.slots) ~= "table" then space.slots = {} end
    return space.slots
end

local function findSpace(id)
    if not db then return nil end
    for _, s in ipairs(db.spaces) do
        if s.id == id then return s end
    end
end

local function getActive()
    if not activeID and db and db.spaces[1] then activeID = db.spaces[1].id end
    return findSpace(activeID)
end

local function source(bag, slot, equipped)
    local link
    if equipped then
        link = GetInventoryItemLink("player", slot)
    else
        link = GetContainerItemLink(bag, slot)
    end
    if not link then return nil end
    local texture, count, quality, _
    if equipped then
        texture = GetInventoryItemTexture("player", slot)
        count = 1
    else
        texture, count, _, quality = GetContainerItemInfo(bag, slot)
    end
    local _, _, q, _, _, typeName, subType, _, equipLoc, cachedIcon = GetItemInfo(link)
    return {
        link = link,
        id = itemID(link),
        key = itemKey(link),
        icon = texture or cachedIcon,
        count = count or 1,
        quality = q or quality,
        typeName = typeName,
        subType = subType,
        equipLoc = equipLoc,
        bag = equipped and nil or bag,
        slot = slot,
        equipped = equipped and true or false,
    }
end

local function scan()
    local state = {bags = {}, physical = {}, equipped = {}, general = {}, generalEquipped = {}, assignments = {}, used = {}, total = 0, free = 0}
    for slot = 1, 19 do
        local it = source(nil, slot, true)
        if it then table.insert(state.equipped, it) end
    end
    for bag = 0, 4 do
        local size = GetContainerNumSlots(bag) or 0
        state.total = state.total + size
        for slot = 1, size do
            local it = source(bag, slot, false)
            state.physical[#state.physical + 1] = {bag = bag, slot = slot, item = it}
            if it then
                table.insert(state.bags, it)
            else
                state.free = state.free + 1
            end
        end
    end
    -- Match reserved cells to real items, most exact first:
    --   1. the bag slot this cell last saw AND the same link (identical stacks,
    --      two copies of one item with different enchants/gems);
    --   2. the same link anywhere (item moved, equipped or unequipped);
    --   3. the bag slot it last saw with the same itemID (item got enchanted);
    --   4. the same itemID anywhere.
    -- Equipped items have priority, so their reserved virtual slots look empty.
    for _, sp in ipairs(db.spaces) do
        state.assignments[sp.id] = {}
    end
    local byLoc = {}
    for _, it in ipairs(state.bags) do byLoc[it.bag .. ":" .. it.slot] = it end
    -- A cell waiting for an item that is still travelling to its bag slot
    -- (split stack, bank) only accepts that slot, never another copy.
    local now = GetTime()
    for _, sp in ipairs(db.spaces) do
        for _, pinned in ipairs(allSlots(sp)) do
            if pinned and pinned.pendingUntil and now >= pinned.pendingUntil then
                pinned.pendingUntil = nil
            end
        end
    end
    local function assign(sp, pos, pinned, it)
        state.used[it] = true
        state.assignments[sp.id][pos] = it
        pinned.pendingUntil = nil
    end
    for pass = 1, 4 do
        local byLocation = pass == 1 or pass == 3
        local exactKey = pass <= 2
        for _, sp in ipairs(db.spaces) do
            for pos, pinned in ipairs(allSlots(sp)) do
                if pinned and not state.assignments[sp.id][pos] then
                    if byLocation then
                        local it = pinned.bag and pinned.slot and byLoc[pinned.bag .. ":" .. pinned.slot]
                        if it and not state.used[it] and it.id == pinned.id and
                            (not exactKey or it.key == pinned.key) then
                            assign(sp, pos, pinned, it)
                            -- Same physical item, new enchant/gems: remember them.
                            if not exactKey then pinned.key, pinned.link = it.key, it.link end
                        end
                    elseif not pinned.pendingUntil then
                        local candidate
                        for _, pool in ipairs({state.equipped, state.bags}) do
                            for _, it in ipairs(pool) do
                                if not state.used[it] and it.id == pinned.id and
                                    (not exactKey or it.key == pinned.key) then
                                    candidate = it
                                    break
                                end
                            end
                            if candidate then break end
                        end
                        if candidate then assign(sp, pos, pinned, candidate) end
                    end
                end
            end
        end
    end
    -- Keep location hints fresh after physical moves.
    for _, sp in ipairs(db.spaces) do
        for pos, it in pairs(state.assignments[sp.id]) do
            local pinned = sp.slots[pos]
            if pinned then pinned.bag, pinned.slot = it.bag, (not it.equipped) and it.slot or nil end
        end
    end
    for _, it in ipairs(state.bags) do
        if not state.used[it] then table.insert(state.general, it) end
    end
    for _, it in ipairs(state.equipped) do
        if not state.used[it] then table.insert(state.generalEquipped, it) end
    end
    return state
end

local auctionClasses
local buildGameRules
local function setupClasses()
    if GetAuctionItemClasses then auctionClasses = {GetAuctionItemClasses()} end
    buildGameRules()
end

local function isGear(it)
    return it.equipLoc and it.equipLoc ~= "" and it.equipLoc ~= "INVTYPE_BAG" and
        it.equipLoc ~= "INVTYPE_QUIVER" and it.equipLoc ~= "INVTYPE_AMMO"
end

local PROFESSION_TYPES = {
    ["Trade Goods"] = true, ["Хозяйственные товары"] = true, ["Господарські товари"] = true,
    ["Recipe"] = true, ["Рецепт"] = true, ["Рецепты"] = true, ["Рецепти"] = true,
    ["Gem"] = true, ["Gems"] = true, ["Самоцветы"] = true, ["Самоцвіти"] = true,
    ["Reagent"] = true, ["Реагент"] = true, ["Реагенты"] = true, ["Реагенти"] = true,
}
local function materials(it)
    local kind = it.typeName
    if not kind then return false end
    -- WotLK auction classes: trade goods, recipes, gems. The API supplies
    -- localized names; reagent is a separate item class with no auction tab.
    if PROFESSION_TYPES[kind] or (auctionClasses and
        (kind == auctionClasses[6] or kind == auctionClasses[9] or kind == auctionClasses[10])) then
        return true
    end
    local reagentType = GetItemInfo and select(6, GetItemInfo(17020))
    return reagentType ~= nil and kind == reagentType
end

local RULES = {
    {id = "grey",    name = "Сірий шмот", match = function(it) return isGear(it) and it.quality == 0 end},
    {id = "green",   name = "Зелений шмот", match = function(it) return isGear(it) and it.quality == 2 end},
    {id = "blue",    name = "Синій шмот", match = function(it) return isGear(it) and it.quality == 3 end},
    {id = "purple",  name = "Епічний шмот", match = function(it) return isGear(it) and it.quality == 4 end},
    {id = "junk",    name = "Сміття", match = function(it) return it.quality == 0 and not isGear(it) end},
    {id = "trade",   name = "Усе для професій", match = materials},
}

local function migrateRuleFilters()
    local version = tonumber(db.ruleFiltersVersion) or 0
    local replacements = {
        gear = {"game:class:1", "game:class:2"},
        food = {"game:class:4:sub:1"},
        consum = {"game:class:4"},
        reagent = {"game:reagent"},
        quest = {"game:class:12"},
    }
    for _, sp in ipairs(db.spaces) do
        for oldID, newIDs in pairs(replacements) do
            if sp.rules[oldID] then
                for _, newID in ipairs(newIDs) do sp.rules[newID] = true end
            end
            sp.rules[oldID] = nil
        end
        -- The old grey filter matched ALL poor items. Keep that selection by
        -- splitting it into grey equipment and non-equipment junk once.
        if version < 1 and sp.rules.grey then sp.rules.junk = true end
    end
    db.ruleFiltersVersion = math.max(version, 1)
end

-- Persist API indices, not localized labels, so changing client language does
-- not change the selected rules. GetItemInfo supplies matching localized types.
buildGameRules = function()
    while RULES[#RULES] and RULES[#RULES].game do table.remove(RULES) end
    for index, name in ipairs(auctionClasses or {}) do
        local className = name
        local classID = "game:class:" .. index
        local children = GetAuctionItemSubClasses and {GetAuctionItemSubClasses(index)} or {}
        RULES[#RULES + 1] = {
            id = classID, name = className, game = true, hasChildren = #children > 0,
            match = function(it) return it.typeName == className end,
        }
        for subIndex, subName in ipairs(children) do
            local subclassName = subName
            RULES[#RULES + 1] = {
                id = classID .. ":sub:" .. subIndex, name = subclassName,
                game = true, parent = classID,
                match = function(it) return it.typeName == className and it.subType == subclassName end,
            }
        end
    end
    -- These inventory classes have no separate tab in the WotLK auction API.
    RULES[#RULES + 1] = {
        id = "game:reagent", name = "Реагенти", game = true,
        match = function(it)
            local localized = GetItemInfo and select(6, GetItemInfo(17020))
            return it.typeName and (it.typeName == localized or it.typeName == "Reagent" or
                it.typeName == "Реагент" or it.typeName == "Реагенты" or it.typeName == "Реагенти")
        end,
    }
    RULES[#RULES + 1] = {
        id = "game:key", name = "Ключі", game = true,
        match = function(it)
            local localized = GetItemInfo and select(6, GetItemInfo(7146))
            return it.typeName and (it.typeName == localized or it.typeName == "Key" or
                it.typeName == "Keys" or it.typeName == "Ключ" or it.typeName == "Ключи" or it.typeName == "Ключі")
        end,
    }
end

local function repaint()
    if ui and ui:IsShown() then ui:Update()
    elseif refreshNativeBags and db then refreshNativeBags(scan()) end
end

-- A cell is free when nothing is reserved there, or when the reserved item
-- is no longer in the bags / on the character (used up, learned, sold, banked).
-- Such a cell is shown empty; if the item comes back before the cell is
-- reused, it reappears in place.
local function cellFree(sp, i, state)
    local slots = allSlots(sp)
    if not slots[i] then return true end
    if slots[i].pendingUntil and GetTime() < slots[i].pendingUntil then return false end
    return state and not (state.assignments[sp.id] or {})[i]
end

local function nextSpaceSlot(sp, state)
    for i = 1, MAX_SPACE_SLOTS do
        if cellFree(sp, i, state) then return i end
    end
end

local function appendSlot(sp, it, quiet, state)
    local slots = allSlots(sp)
    state = state or scan()
    local pos = nextSpaceSlot(sp, state)
    if not pos then
        if not quiet then say("У просторі вже 36 предметів — це максимум.") end
        return nil
    end
    for i = #slots + 1, pos - 1 do slots[i] = false end
    slots[pos] = {id = it.id, key = it.key, link = it.link, icon = it.icon,
        bag = (not it.equipped) and it.bag or nil, slot = (not it.equipped) and it.slot or nil}
    state.assignments[sp.id] = state.assignments[sp.id] or {}
    state.assignments[sp.id][pos] = it
    return pos
end

local function findAssignedSource(state, it)
    if not it then return end
    for _, sp in ipairs(db.spaces) do
        for pos, src in pairs(state.assignments[sp.id] or {}) do
            if src and src.id == it.id and src.equipped == it.equipped and
                src.slot == it.slot and (src.equipped or src.bag == it.bag) then
                return sp, pos
            end
        end
    end
end

local function unpinAt(sp, pos)

    if not sp or not sp.slots or not sp.slots[pos] then return end
    sp.slots[pos] = false  -- preserve the hole; real item stays where it is
    repaint()
end

-- Put an item into an exact virtual cell. Works like a bag swap:
--   * item from another virtual cell  -> the two cells exchange contents;
--   * item from "General"             -> whatever was in the cell returns to General.
local function pinAt(sp, pos, it, pending)

    if not sp or not it or not it.id then return false end
    if not pos or pos < 1 or pos > MAX_SPACE_SLOTS then return false end
    local state = scan()
    local oldSpace, oldPos = findAssignedSource(state, it)
    if oldSpace == sp and oldPos == pos then return true end
    local slots = allSlots(sp)
    for i = #slots + 1, pos - 1 do slots[i] = false end
    local replaced = slots[pos]
    -- A reservation whose item is gone is discarded, never swapped around.
    if replaced and cellFree(sp, pos, state) then replaced = false end
    if oldSpace then oldSpace.slots[oldPos] = replaced or false end
    slots[pos] = {id = it.id, key = it.key, link = it.link, icon = it.icon,
        bag = (not it.equipped) and it.bag or nil, slot = (not it.equipped) and it.slot or nil,
        pendingUntil = pending and (GetTime() + 3) or nil}
    return true
end

local function addToActive(it)

    local sp = getActive()
    if not sp then say("Спочатку створи простір."); return end
    local state = scan()
    local oldSpace, oldPos = findAssignedSource(state, it)
    if oldSpace and oldSpace.id == sp.id then return end
    if not nextSpaceSlot(sp, state) then
        say("У просторі вже 36 предметів — це максимум.")
        return
    end
    if oldSpace then
        oldSpace.slots[oldPos] = false
        state.assignments[oldSpace.id][oldPos] = nil
    end
    appendSlot(sp, it, false, state)
end

local function applyRules(state, accept)
    local moved = 0
    for _, it in ipairs(state.general) do
        if not accept or accept(it) then
            local target
            for _, sp in ipairs(db.spaces) do
                for _, rule in ipairs(RULES) do
                    if sp.rules[rule.id] and rule.match(it) and nextSpaceSlot(sp, state) then
                        target = sp
                        break
                    end
                end
                if target then break end
            end
            if target and appendSlot(target, it, true, state) then
                state.used[it] = true
                moved = moved + 1
            end
        end
    end
    return moved
end

-- Remember what is already in the bags without routing anything: rules only
-- apply to items that arrive later (login / reload must not undo manual moves).
local function primeRuleCounts()
    local counts = {}
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots(bag) or 0) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, count = GetContainerItemInfo(bag, slot)
                local key = itemKey(link) or tostring(itemID(link))
                counts[key] = (counts[key] or 0) + (count or 1)
            end
        end
    end
    ruleBagCounts = counts
end

local function routeIncomingItems()
    local state = scan()
    local counts, uncached = {}, {}
    for _, it in ipairs(state.bags) do
        local key = it.key or tostring(it.id)
        counts[key] = (counts[key] or 0) + (it.count or 1)
        if not it.typeName then uncached[key] = true end
    end
    -- Compare total quantities, not physical slots: moving an existing stack
    -- or splitting it must not undo the player's manual space placement.
    applyRules(state, function(it)
        local key = it.key or tostring(it.id)
        return (counts[key] or 0) > (ruleBagCounts[key] or 0)
    end)
    for key in pairs(uncached) do
        counts[key] = ruleBagCounts[key]
        if GetTime() < ruleRetryUntil then
            pendingRuleRoute = true
            nextRuleRoute = GetTime() + 0.25
        end
    end
    ruleBagCounts = counts
end

local function arrange()
    local moved = applyRules(scan())
    say("Рознесено предметів: " .. moved .. ". Фізичні слоти не змінено.")
end

local buttonSeq = 0
local function quickButton(parent, label, w, h, action)
    buttonSeq = buttonSeq + 1
    local b = CreateFrame("Button", "AmdirSpacesButton" .. buttonSeq, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h)
    b:SetText(label)
    b:SetScript("OnClick", action)
    b:HookScript("OnEnter", function() if spacesFocus then spacesFocus() end end)
    return b
end

local function text(parent, size, color)
    local t = parent:CreateFontString(nil, "OVERLAY", size or "GameFontNormal")
    if color then t:SetTextColor(unpack(color)) end
    return t
end

---------------------------------------------------------------------------
-- Cursor handling. Everything goes through the REAL WoW cursor, exactly like
-- Blizzard bags: press+drag (or click) picks the item up, release (or click)
-- on a cell puts it there. We remember where the cursor item came from by
-- hooking the global pickup functions (our cells, Blizzard bags, paperdoll).
---------------------------------------------------------------------------
local function trackPickup(src)
    if CursorHasItem and CursorHasItem() then cursorSrc = src else cursorSrc = nil end
end

local function cursorItem()
    if not GetCursorInfo then return nil end
    local kind, id, link = GetCursorInfo()
    if kind ~= "item" then return nil end
    id = tonumber(id) or itemID(link)
    if not id then return nil end
    if not link or not itemKey(link) then
        local _, cachedLink = GetItemInfo(id)
        link = cachedLink or "item:" .. tostring(id)
    end
    local _, _, quality, _, _, typeName, subType, _, equipLoc, icon = GetItemInfo(link)
    return {
        id = id, key = itemKey(link), link = link, icon = icon or GetItemIcon(id),
        quality = quality, typeName = typeName, subType = subType, equipLoc = equipLoc,
    }
end

-- Returns: real source item (bag 0-4 or equipped) or nil, and the cursor identity.
local function cursorSource()
    local carried = cursorItem()
    if not carried then return nil end
    local src = cursorSrc
    if src then
        local it
        if src.equip then
            it = source(nil, src.equip, true)
        elseif src.bag and src.bag >= 0 and src.bag <= 4 then
            it = source(src.bag, src.slot, false)
        end
        if it and it.id == carried.id then return it, carried end
    end
    return nil, carried
end

local function releaseCursor()
    if ClearCursor then ClearCursor() end
    cursorSrc = nil
end

-- Ordinary bags first; a profession bag only when it accepts this item
-- (herbs -> herb bag), exactly where the client would allow the drop.
local function firstFreeSlot(carried)
    local itemFamily = 0
    if carried and carried.id and GetItemFamily and carried.equipLoc ~= "INVTYPE_BAG" then
        itemFamily = GetItemFamily(carried.id) or 0
    end
    for pass = 1, 2 do
        for bag = 0, 4 do
            local family = 0
            if bag > 0 and GetContainerNumFreeSlots then
                local _, f = GetContainerNumFreeSlots(bag)
                family = f or 0
            end
            local fits
            if pass == 1 then fits = family == 0
            else fits = family ~= 0 and bit and bit.band(family, itemFamily) ~= 0 end
            if fits then
                for slot = 1, (GetContainerNumSlots(bag) or 0) do
                    if not GetContainerItemLink(bag, slot) then return bag, slot end
                end
            end
        end
    end
end

-- Stacking takes priority over virtual reassignment, for both whole stacks
-- and Shift-split amounts. Let the client enforce stack limits and overflow.
local function mergeCursorStack(carried, location)
    if not location or location.equipped or location.bag == nil or not location.slot then return false end
    local target = source(location.bag, location.slot, false)
    if not target or target.id ~= carried.id then return false end
    local _, _, _, _, _, _, _, maxStack = GetItemInfo(target.link)
    if not maxStack or maxStack <= 1 then return false end
    local origin = cursorSrc
    PickupContainerItem(location.bag, location.slot)
    -- A partially merged stack still comes from its original source, not the
    -- destination passed to PickupContainerItem (which our pickup hook sees).
    if CursorHasItem and CursorHasItem() then cursorSrc = origin
    else cursorSrc = nil end
    repaint()
    return true
end

local function dropOnSpace(sp, pos, cell)
    local it, carried = cursorSource()
    if not carried then return end
    if mergeCursorStack(carried, cell and cell.item) then return end
    if cursorSrc and cursorSrc.split then
        -- Part of a stack (Shift+click), exactly like a bag:
        local target = cell and cell.item
        if target then
            if target.id == carried.id and not target.equipped and target.bag then
                PickupContainerItem(target.bag, target.slot)  -- add to that stack
            else
                releaseCursor()  -- can't swap a partial stack; it goes back
            end
            return
        end
        -- Empty cell: the new stack really goes into a free bag slot and
        -- this cell is reserved for exactly that slot.
        local bag, slot = firstFreeSlot(carried)
        if not bag then say("У сумках немає вільного місця."); return end
        PickupContainerItem(bag, slot)
        cursorSrc = nil
        pinAt(sp, pos, {id = carried.id, key = carried.key, link = carried.link,
            icon = carried.icon, bag = bag, slot = slot}, true)
        repaint()
        return
    end
    if it then
        -- Virtual move only: the real item goes back to its physical slot.
        releaseCursor()
        pinAt(sp, pos, it)
    else
        -- Item from the bank or elsewhere: really put it into a free bag slot.
        local bag, slot = firstFreeSlot(carried)
        if not bag then say("У сумках немає вільного місця."); return end
        PickupContainerItem(bag, slot)
        cursorSrc = nil
        pinAt(sp, pos, {id = carried.id, key = carried.key, link = carried.link,
            icon = carried.icon, bag = bag, slot = slot}, true)
    end
    repaint()
end

-- Drop on "General": an item from a space returns to General; otherwise this
-- is a plain physical bag operation (place / swap / stack) on that slot.
local function dropOnGeneral(phys)
    local it, carried = cursorSource()
    if not carried then return end
    if mergeCursorStack(carried, phys) then return end
    if cursorSrc and cursorSrc.split then
        -- Partial stack: plain bag operation (empty slot, or merge into a stack).
        local bag, slot
        if phys and phys.bag then bag, slot = phys.bag, phys.slot
        else bag, slot = firstFreeSlot(carried) end
        if bag then PickupContainerItem(bag, slot) else releaseCursor() end
        return
    end
    if it then
        local sp, pos = findAssignedSource(scan(), it)
        if sp then

            releaseCursor()
            sp.slots[pos] = false
            repaint()
            return
        end
    end
    if phys and phys.bag and PickupContainerItem then
        PickupContainerItem(phys.bag, phys.slot)
    else
        releaseCursor()
    end
end

local lastDropCell, lastDropTime
local function dropOnCell(b)
    if not b.role or b.role == "search" then return end
    if not (CursorHasItem and CursorHasItem()) then return end
    -- OnClick and OnReceiveDrag may both arrive for one release.
    local now = GetTime()
    if lastDropCell == b and lastDropTime == now then return end
    lastDropCell, lastDropTime = b, now
    if b.role == "space" then
        dropOnSpace(b.space, b.pos, b)
    else
        dropOnGeneral(b.physical)
    end
end

local function pickupCell(b)
    local it = b.item
    if not it then return end
    if it.equipped then
        if PickupInventoryItem then PickupInventoryItem(it.slot) end
    elseif it.bag then
        ContainerFrameItemButton_OnClick(b, "LeftButton")
    end
end

local function jumpToSpace(targetID)
    activeID = targetID
    if hideShades then hideShades() end
    if ui then
        ui.tempSwaps = {}
        ui.search:SetText("")
        ui.search:ClearFocus()
        if applyLayout then applyLayout(true) end
        ui:Update()
    end
end

local function anyModifier()
    return IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown()
end

-- Native chat-link / dressing-room / split-stack, same order as
-- ContainerFrameItemButton_OnModifiedClick.
local function modifiedItemClick(b, it)
    if HandleModifiedItemClick and HandleModifiedItemClick(it.link) then return end
    local split = IsModifiedClick and IsModifiedClick("SPLITSTACK")
    if split == nil then split = IsShiftKeyDown() end
    if split and not it.equipped and it.bag and OpenStackSplitFrame and SplitContainerItem then
        local _, quantity, locked = GetContainerItemInfo(it.bag, it.slot)
        if quantity and quantity > 1 and not locked then
            local srcBag, srcSlot = it.bag, it.slot
            b.SplitStack = function(_, amount) SplitContainerItem(srcBag, srcSlot, amount) end
            OpenStackSplitFrame(quantity, b, "BOTTOMRIGHT", "TOPRIGHT")
        end
    end
end

local slotSeq = 0
local function makeCell(parent)
    slotSeq = slotSeq + 1
    local name = "AmdirSpacesItemSlot" .. slotSeq
    local container = CreateFrame("Frame", nil, parent)
    container:SetAllPoints(parent)
    container:SetID(0)
    local b = CreateFrame("Button", name, container, "ContainerFrameItemButtonTemplate")
    b:SetID(0)
    b:SetSize(ICON, ICON)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    -- Keep the template's OnClick untouched: replacing it taints item use.
    -- Left clicks arrange virtual cells via OnMouseUp; right clicks are native.
    b:RegisterForClicks("RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b.image = _G[name .. "IconTexture"]
    -- Blizzard uses b.count as a number in vendor refund confirmation.
    b.countText = _G[name .. "Count"]
    if not b.image then
        b.image = b:CreateTexture(nil, "BORDER")
        b.image:SetAllPoints(b)
    end
    if not b.countText then
        b.countText = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        b.countText:SetPoint("BOTTOMRIGHT", -4, 2)
    end
    b.questTexture = _G[name .. "IconQuestTexture"]
    b.cooldown = _G[name .. "Cooldown"] or CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cooldown:SetAllPoints(b)
    b.cooldown:Hide()
    b.savedR, b.savedG, b.savedB = 1, 1, 1
    b:SetScript("OnEnter", function(self)
        if spacesFocus then spacesFocus() end
        local it = self.item
        local entry = self.entry
        if it and not it.equipped and ContainerFrameItemButton_OnEnter then
            -- Same tooltip as a Blizzard bag: compare, repair cost, sell cursor.
            ContainerFrameItemButton_OnEnter(self)
        elseif it then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetInventoryItem("player", it.slot)
        elseif entry and entry.link then
            -- Reserved item that is no longer in the bags (search results).
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(entry.link)
        else
            return
        end
        if self.role == "search" then
            local target = self.searchTargetID == 0 and "Загальні" or
                (findSpace(self.searchTargetID) and findSpace(self.searchTargetID).name or "")
            GameTooltip:AddLine("У просторі: " .. target, 0.95, 0.75, 0.3)
            GameTooltip:AddLine("ЛКМ: перейти до простору", 0.6, 0.8, 1)
        elseif self.role == "space" then
            if self.temporary then GameTooltip:AddLine("Тимчасово: щойно знята річ", 0.92, 0.75, 0.4) end
            GameTooltip:AddLine("Shift + клік: розділити стак", 0.6, 0.8, 1)
            GameTooltip:AddLine("Alt + ПКМ: прибрати із простору", 0.6, 0.8, 1)
        elseif self.role == "bottom" and it then
            GameTooltip:AddLine("ЛКМ: додати до вибраного простору", 0.6, 0.8, 1)
            GameTooltip:AddLine("Перетягни у потрібну клітинку зверху", 0.6, 0.8, 1)
        end
        GameTooltip:Show()
    end)
    b.UpdateTooltip = b:GetScript("OnEnter")
    b:SetScript("OnLeave", function() GameTooltip:Hide(); if ResetCursor then ResetCursor() end end)
    b:SetScript("OnMouseDown", function(self, button)
        local it = self.item
        local altAction = button == "RightButton" and IsAltKeyDown() and
            not IsShiftKeyDown() and not IsControlKeyDown()
        local kind = GetCursorInfo and GetCursorInfo()
        self.nativeLeftClick = it and not it.equipped and
            ((SpellCanTargetItem and SpellCanTargetItem()) or
             kind == "merchant" or kind == "money" or kind == "guildbankmoney")
        if altAction or (it and it.equipped) or not it then
            self:RegisterForClicks()
        elseif self.nativeLeftClick then
            self:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        else
            self:RegisterForClicks("RightButtonUp")
        end
    end)
    b:SetScript("OnMouseUp", function(self, button)
        if ui and ui:IsShown() and nativeBagFocused then
            nativeBagFocused = false
            if refreshNativeBags then refreshNativeBags() end
        end
        local it = self.item
        if button == "RightButton" then
            -- Equipped items are only a preview of where they go after unequip.
            if IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown() and
                self.role == "space" then
                unpinAt(self.space, self.pos)
            end
            -- Ordinary bag right clicks are handled only by the template.
            return
        end
        if button ~= "LeftButton" or self.nativeLeftClick then return end
        if CursorHasItem and CursorHasItem() then
            dropOnCell(self)
            return
        end
        if self.role == "search" then
            jumpToSpace(self.searchTargetID)
            return
        end
        if it and anyModifier() then
            modifiedItemClick(self, it)
            return
        end
        if self.role == "bottom" and it and getActive() then
            addToActive(it)
            repaint()
            return
        end
        pickupCell(self)
    end)
    b:SetScript("OnDragStart", function(self)
        if CursorHasItem and CursorHasItem() then return end
        pickupCell(self)
    end)
    b:SetScript("OnReceiveDrag", function(self)
        dropOnCell(self)
    end)
    return b
end

local function updateCellCooldown(b)
    if not b then return end
    local it = b.item
    b.cooldown:Hide()
    if it and not it.equipped and it.bag and it.slot and GetContainerItemCooldown and CooldownFrame_SetTimer then
        local start, duration, enable = GetContainerItemCooldown(it.bag, it.slot)
        if start and duration and duration > 0 then
            CooldownFrame_SetTimer(b.cooldown, start, duration, enable)
            b.cooldown:Show()
            if enable == 0 then b.image:SetVertexColor(0.4, 0.4, 0.4)
            elseif not b.locked then b.image:SetVertexColor(b.savedR or 1, b.savedG or 1, b.savedB or 1) end
        elseif not b.locked then
            b.image:SetVertexColor(b.savedR or 1, b.savedG or 1, b.savedB or 1)
        end
    elseif it and it.equipped and GetInventoryItemCooldown and CooldownFrame_SetTimer then
        local start, duration, enable = GetInventoryItemCooldown("player", it.slot)
        if start and duration and duration > 0 then
            CooldownFrame_SetTimer(b.cooldown, start, duration, enable)
            b.cooldown:Show()
        end
    end
end

local EMPTY_CELL = {}
-- info: {role = "space"|"general"|"bottom"|"search"|nil, it, sp, pos, entry, target, temp, phys}
local function setCell(b, info)
    info = info or EMPTY_CELL
    local it, entry = info.it, info.entry
    b.role = info.role
    b.space = info.sp
    b.pos = info.pos
    b.item = it
    b.entry = entry
    b.physical = info.phys
    b.searchTargetID = info.target
    b.temporary = info.temp
    local icon = it and it.icon
    if SetItemButtonTexture then SetItemButtonTexture(b, icon)
    else b.image:SetTexture(icon) end
    if SetItemButtonCount then SetItemButtonCount(b, it and it.count or 0)
    else b.countText:SetText(it and it.count and it.count > 1 and it.count or "") end
    local alpha, r, g, bl = 1, 1, 1, 1
    if it then
        if it.equipped and info.role == "space" then
            alpha, r, g, bl = 0.43, 0.8, 0.8, 0.8
        end
    end
    b.savedR, b.savedG, b.savedB = r, g, bl
    local locked = false
    if it and not it.equipped and it.bag and it.slot and GetContainerItemInfo then
        local _, _, l = GetContainerItemInfo(it.bag, it.slot)
        locked = l and true or false
    elseif it and it.equipped and IsInventoryItemLocked then
        locked = IsInventoryItemLocked(it.slot) and true or false
    end
    b.locked = locked
    -- Native "item is on the cursor" look: desaturated icon in the source slot.
    if SetItemButtonDesaturated then SetItemButtonDesaturated(b, locked, 0.5, 0.5, 0.5) end
    b.image:SetAlpha(alpha)
    if not locked then b.image:SetVertexColor(r, g, bl) end
    updateCellCooldown(b)
    -- Native bag handlers read bag ID from the parent and slot ID from the button.
    local loc = (it and not it.equipped) and it or info.phys
    b:GetParent():SetID(loc and loc.bag or 0)
    b:SetID(loc and loc.slot or 0)
    b.hasItem = it and true or nil
    b.count = it and it.count or 0
    b.readable = nil
    if loc and loc.bag and loc.slot then
        local _, _, _, _, readable = GetContainerItemInfo(loc.bag, loc.slot)
        b.readable = readable
    end
    -- Native quest marker: "!" starts a quest, border = quest item.
    local quest = b.questTexture
    if quest then
        local isQuest, questID, isActive
        if it and not it.equipped and it.bag and GetContainerItemQuestInfo then
            isQuest, questID, isActive = GetContainerItemQuestInfo(it.bag, it.slot)
        end
        if questID and not isActive then
            quest:SetTexture(TEXTURE_ITEM_QUEST_BANG or "Interface\\ContainerFrame\\UI-Icon-QuestBang")
            quest:Show()
        elseif questID or isQuest then
            quest:SetTexture(TEXTURE_ITEM_QUEST_BORDER or "Interface\\ContainerFrame\\UI-Icon-QuestBorder")
            quest:Show()
        else
            quest:Hide()
        end
    end
end

-- In the compact window there are no Blizzard scrollbar arrows outside the bag.
local function createScroll(parent, name, x, y, width, height)
    local sc = CreateFrame("ScrollFrame", name, parent)
    sc:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    sc:SetSize(width, height)
    local child = CreateFrame("Frame", nil, sc)
    child:SetSize(width, height)
    sc:SetScrollChild(child)
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(10)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(SLOT_Y)
    bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(bar)
    track:SetTexture(0.08, 0.08, 0.08, 0.6)
    bar:SetPoint("TOPRIGHT", sc, "TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", sc, "BOTTOMRIGHT", 0, 0)
    bar:SetScript("OnValueChanged", function(_, v) sc:SetVerticalScroll(v) end)
    bar:Hide()
    sc:EnableMouseWheel(true)
    local function scrollWheel(self, delta)
        local minV, maxV = bar:GetMinMaxValues()
        if maxV > minV then
            local value = math.max(minV, math.min(maxV, sc:GetVerticalScroll() - delta * SLOT_Y))
            bar:SetValue(value)
            sc:SetVerticalScroll(value)
        end
    end
    sc:SetScript("OnMouseWheel", scrollWheel)
    child:EnableMouseWheel(true)
    child:SetScript("OnMouseWheel", scrollWheel)
    return {scroll = sc, child = child, bar = bar, cells = {}, cols = 1, scrollWheel = scrollWheel}
end

-- Columns and fully visible rows for a grid with its current size.
local function gridMetrics(o)
    local cols = o.fixedCols or math.max(1, math.floor((o.scroll:GetWidth() - 6) / SLOT_X))
    local rows = math.max(1, math.floor((o.scroll:GetHeight() + 4) / SLOT_Y))
    return cols, rows
end

local function drawGrid(o, length, itemAt)
    length = math.max(0, length)
    local viewWidth = o.scroll:GetWidth()
    local viewHeight = o.scroll:GetHeight()
    local cols = gridMetrics(o)
    local contentHeight = math.ceil(length / cols) * SLOT_Y + 4
    local needsScroll = contentHeight > viewHeight + 1
    if needsScroll and not o.overlayScroll and not o.fixedCols then
        cols = math.max(1, math.floor((viewWidth - 16) / SLOT_X))
        contentHeight = math.ceil(length / cols) * SLOT_Y + 4
    end
    o.length = length
    o.cols = cols
    o.child:SetWidth(math.max(1, viewWidth - (needsScroll and not o.overlayScroll and 12 or 2)))
    o.child:SetHeight(math.max(viewHeight, contentHeight))
    for i = 1, length do
        local b = o.cells[i]
        if not b then
            b = makeCell(o.child)
            b:EnableMouseWheel(true)
            b:SetScript("OnMouseWheel", o.scrollWheel)
            o.cells[i] = b
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", o.child, "TOPLEFT", ((i - 1) % cols) * SLOT_X + 2,
            -math.floor((i - 1) / cols) * SLOT_Y - 2)
        setCell(b, itemAt and itemAt(i))
        b:Show()
    end
    for i = length + 1, #o.cells do
        o.cells[i]:Hide()
        o.cells[i].role = nil
        o.cells[i].item = nil
    end
    o.scroll:UpdateScrollChildRect()
    if needsScroll then
        local limit = math.max(0, contentHeight - viewHeight)
        o.bar:SetMinMaxValues(0, limit)
        local value = math.min(o.scroll:GetVerticalScroll(), limit)
        o.bar:SetValue(value)
        o.scroll:SetVerticalScroll(value)
        if o.hideBar then o.bar:Hide() else o.bar:Show() end
    else
        o.bar:SetMinMaxValues(0, 0)
        o.bar:SetValue(0)
        o.scroll:SetVerticalScroll(0)
        o.bar:Hide()
    end
end

-- Lua 5.1 string.lower only handles ASCII reliably. WoW item links may be
-- Cyrillic; fold Russian/Ukrainian UTF-8 capitals without external libraries.
local CYRILLIC_UPPER = {
    ["А"] = "а", ["Б"] = "б", ["В"] = "в", ["Г"] = "г", ["Ґ"] = "ґ",
    ["Д"] = "д", ["Е"] = "е", ["Є"] = "є", ["Ё"] = "ё", ["Ж"] = "ж",
    ["З"] = "з", ["И"] = "и", ["І"] = "і", ["Ї"] = "ї", ["Й"] = "й",
    ["К"] = "к", ["Л"] = "л", ["М"] = "м", ["Н"] = "н", ["О"] = "о",
    ["П"] = "п", ["Р"] = "р", ["С"] = "с", ["Т"] = "т", ["У"] = "у",
    ["Ф"] = "ф", ["Х"] = "х", ["Ц"] = "ц", ["Ч"] = "ч", ["Ш"] = "ш",
    ["Щ"] = "щ", ["Ъ"] = "ъ", ["Ы"] = "ы", ["Ь"] = "ь", ["Э"] = "э",
    ["Ю"] = "ю", ["Я"] = "я",
}
local function foldName(name)
    name = string.lower(name or "")
    for upper, lower in pairs(CYRILLIC_UPPER) do
        name = string.gsub(name, upper, lower)
    end
    return name
end

local function cleanName(link, id)
    if link then
        local name = string.match(link, "%[(.-)%]")
        if name then return foldName(name) end
    end
    if id then
        local name = GetItemInfo(id)
        if name then return foldName(name) end
    end
    return ""
end

local function searchAll(state, query)
    local results = {}
    if query == "" then return results end
    for _, sp in ipairs(db.spaces) do
        for i = 1, #allSlots(sp) do
            local entry = sp.slots[i]
            if entry then
                local it = state.assignments[sp.id][i]
                if string.find(cleanName((it and it.link) or entry.link, entry.id), query, 1, true) then
                    results[#results + 1] = {it = it, entry = entry, targetID = sp.id}
                end
            end
        end
    end
    for _, it in ipairs(state.general) do
        if string.find(cleanName(it.link, it.id), query, 1, true) then
            results[#results + 1] = {it = it, targetID = 0}
        end
    end
    for _, it in ipairs(state.generalEquipped) do
        if string.find(cleanName(it.link, it.id), query, 1, true) then
            results[#results + 1] = {it = it, targetID = 0}
        end
    end
    return results
end

-- Grayscale masks live on our own UIParent children, never as textures on
-- Blizzard's protected inventory buttons. No secure Blizzard frame is changed.
hideShades = function()
    for _, mask in pairs(nativeShades) do mask:Hide() end
end

refreshNativeBags = function(state)
    if not db then return end
    -- The native bag is normal when it has focus. Returning to the addon
    -- restores the masks without changing the checkbox's saved state.
    if db.replaceBags or nativeBagFocused or not ui or not ui:IsShown() then
        hideShades()
        return
    end
    -- Mark desired overlays instead of hiding and showing every 0.45s.
    -- Repeated toggling caused visible flashing on some bag layouts.
    for _, mask in pairs(nativeShades) do mask.wanted = false end
    state = state or scan()
    local dimmed = {}
    -- Dimming belongs to the currently selected space. Previously every
    -- space that had ever enabled the option stayed gray after switching.
    local activeSpace = getActive()
    if activeSpace and activeSpace.dimInBags then
        for _, it in pairs(state.assignments[activeSpace.id] or {}) do
            if it and not it.equipped then
                dimmed[it.bag .. ":" .. it.slot] = true
            end
        end
    end
    for n = 1, (NUM_CONTAINER_FRAMES or 13) do
        local frame = _G["ContainerFrame" .. n]
        if frame and frame:IsShown() then
            local bag = frame:GetID()
            if bag and bag >= 0 and bag <= 4 then
                local prefix = frame:GetName()
                for i = 1, (frame.size or 36) do
                    local button = _G[prefix .. "Item" .. i]
                    if button and button:IsShown() and dimmed[bag .. ":" .. button:GetID()] then
                        local mask = nativeShades[button]
                        if not mask then
                            mask = CreateFrame("Frame", nil, UIParent)
                            mask:EnableMouse(false)
                            mask.texture = mask:CreateTexture(nil, "ARTWORK")
                            mask.texture:SetAllPoints()
                            mask.texture:SetTexture(0.1, 0.1, 0.1, 0.67)
                            nativeShades[button] = mask
                        end
                        mask:ClearAllPoints()
                        mask:SetPoint("TOPLEFT", button, "TOPLEFT", 3, -3)
                        mask:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -3, 3)
                        mask:SetFrameStrata(button:GetFrameStrata())
                        mask:SetFrameLevel(button:GetFrameLevel() + 2)
                        mask.wanted = true
                        if not mask:IsShown() then mask:Show() end
                    end
                end
            end
        end
    end
    for _, mask in pairs(nativeShades) do
        if not mask.wanted then mask:Hide() end
    end
end

local function nativeFocus()
    nativeBagFocused = true
    hideShades()
end

spacesFocus = function()
    if nativeBagFocused then
        nativeBagFocused = false
        if refreshNativeBags then refreshNativeBags() end
    end
end

local nativeFramesHooked = {}
local function hookNativeBags()
    for n = 1, (NUM_CONTAINER_FRAMES or 13) do
        local frame = _G["ContainerFrame" .. n]
        if frame and not nativeFramesHooked[frame] then
            nativeFramesHooked[frame] = true
            frame:HookScript("OnMouseDown", nativeFocus)
        end
        if frame then
            for i = 1, (frame.size or 36) do
                local button = _G[frame:GetName() .. "Item" .. i]
                if button and not nativeFramesHooked[button] then
                    nativeFramesHooked[button] = true
                    button:HookScript("OnMouseDown", nativeFocus)
                end
            end
        end
    end
end

local function newSpace(name)
    name = trim(name)
    if name == "" then say("Введи назву простору."); return end
    if string.len(name) > 64 then say("Назва надто довга."); return end
    for _, s in ipairs(db.spaces) do
        if s.name == name then say("Такий простір уже існує."); return end
    end
    local sp = {id = db.nextID, name = name, slots = {}, rules = {}, dimInBags = true}
    db.nextID = db.nextID + 1
    table.insert(db.spaces, sp)
    activeID = sp.id
    if ui then
        ui.newName:SetText("")
        if applyLayout then applyLayout() end
        ui:Update()
    end
end

local function moveSpace(direction)
    local sp = getActive()
    if not sp then return end
    for i, s in ipairs(db.spaces) do
        if s == sp then
            local j = i + direction
            if j > 0 and j <= #db.spaces then
                db.spaces[i], db.spaces[j] = db.spaces[j], db.spaces[i]
            end
            break
        end
    end
    ui:Update()
end

StaticPopupDialogs["AMDIRSPACES_DELETE"] = {
    text = "Видалити простір «%s»? Предмети залишаться у реальних сумках.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, targetID)
        for i, sp in ipairs(db.spaces) do
            if sp.id == targetID then table.remove(db.spaces, i); break end
        end
        activeID = db.spaces[1] and db.spaces[1].id
        if ui then ui:Update() end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    preferredIndex = 3,
}

StaticPopupDialogs["AMDIRSPACES_RENAME"] = {
    text = "Нова назва простору «%s»:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 40,
    OnShow = function(self)
        local sp = findSpace(self.data)
        if self.editBox then
            self.editBox:SetText(sp and sp.name or "")
            self.editBox:HighlightText()
            self.editBox:SetFocus()
        end
    end,
    OnAccept = function(self, targetID)
        local sp = findSpace(targetID)
        if not sp then return end
        local name = trim(self.editBox:GetText())
        if name == "" or string.len(name) > 64 then say("Введи коректну назву."); return end
        for _, other in ipairs(db.spaces) do
            if other ~= sp and other.name == name then say("Така назва вже є."); return end
        end
        sp.name = name
        if ui then ui:Update() end
    end,
    EditBoxOnEnterPressed = function(self)
        local popup = self:GetParent()
        local button = _G[popup:GetName() .. "Button1"]
        if button then button:Click() end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    preferredIndex = 3,
}

local function showRules()
    local sp = getActive()
    if not sp then return end
    if not ruleDialog then
        local f = CreateFrame("Frame", "AmdirSpacesRules", UIParent)
        local height = math.max(360, math.min(620, UIParent:GetHeight() - 60))
        f:SetSize(460, height)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetClampedToScreen(true)
        f:SetBackdrop({bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 26,
            insets = {left = 8, right = 8, top = 8, bottom = 8}})
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f.title = text(f, "GameFontNormalLarge")
        f.title:SetPoint("TOP", 0, -24)
        local hint = text(f, "GameFontHighlightSmall")
        hint:SetPoint("TOP", 0, -50)
        hint:SetText("Нові предмети розподіляються автоматично")
        local priority = text(f, "GameFontDisableSmall")
        priority:SetPoint("TOP", 0, -69)
        priority:SetText("Збіг з будь-яким правилом. Пріоритет — за порядком просторів.")
        f.list = createScroll(f, "AmdirSpacesRulesScroll", 20, -94, 420, height - 156)
        f.checks, f.expanded = {}, {}
        f.quickHeading = text(f.list.child, "GameFontNormal")
        f.quickHeading:SetText("Додаткові фільтри")
        f.gameHeading = text(f.list.child, "GameFontNormal")
        f.gameHeading:SetText("Ігрові категорії")
        function f:LayoutRules()
            local y, gameStarted = 6, false
            self.quickHeading:SetPoint("TOPLEFT", 9, -y)
            y = y + 26
            for i, rule in ipairs(RULES) do
                if rule.game and not gameStarted then
                    gameStarted = true
                    y = y + 10
                    self.gameHeading:SetPoint("TOPLEFT", 9, -y)
                    y = y + 26
                end
                local cb = self.checks[i]
                if not rule.parent or self.expanded[rule.parent] then
                    cb:ClearAllPoints()
                    cb:SetPoint("TOPLEFT", self.list.child, "TOPLEFT", rule.parent and 42 or 20, -y)
                    cb:Show()
                    if cb.expand then
                        cb.expand:SetText(self.expanded[rule.id] and "-" or "+")
                        cb.expand:Show()
                    end
                    y = y + 26
                else
                    cb:Hide()
                end
            end
            self.list.child:SetHeight(math.max(self.list.scroll:GetHeight(), y + 8))
            self.list.scroll:UpdateScrollChildRect()
            local limit = math.max(0, y + 8 - self.list.scroll:GetHeight())
            local value = math.min(self.list.scroll:GetVerticalScroll(), limit)
            self.list.bar:SetMinMaxValues(0, limit)
            self.list.bar:SetValue(value)
            self.list.scroll:SetVerticalScroll(value)
            if limit > 0 then self.list.bar:Show() else self.list.bar:Hide() end
        end
        for i, rule in ipairs(RULES) do
            local ruleID = rule.id
            local cb = CreateFrame("CheckButton", "AmdirSpacesRuleCheck" .. i, f.list.child, "UICheckButtonTemplate")
            cb:SetSize(24, 24)
            cb.label = text(cb, rule.parent and "GameFontHighlightSmall" or "GameFontHighlight")
            cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
            cb.label:SetWidth(rule.parent and 320 or 342)
            cb.label:SetJustifyH("LEFT")
            cb.label:SetText(rule.name)
            cb:EnableMouseWheel(true)
            cb:SetScript("OnMouseWheel", f.list.scrollWheel)
            cb:SetScript("OnClick", function(self)
                local current = findSpace(f.targetID)
                if current then
                    current.rules[ruleID] = self:GetChecked() and true or nil
                    if current.rules[ruleID] then
                        applyRules(scan())
                        repaint()
                    end
                end
            end)
            if rule.hasChildren then
                cb.expand = quickButton(cb, "+", 18, 18, function()
                    f.expanded[ruleID] = not f.expanded[ruleID]
                    f:LayoutRules()
                end)
                cb.expand:SetPoint("RIGHT", cb, "LEFT", -2, 0)
                cb.expand:EnableMouseWheel(true)
                cb.expand:SetScript("OnMouseWheel", f.list.scrollWheel)
            end
            f.checks[i] = cb
        end
        local close = quickButton(f, "Готово", 110, 25, function() f:Hide(); if ui then ui:Update() end end)
        close:SetPoint("BOTTOM", 0, 20)
        f:Hide()
        ruleDialog = f
    end
    ruleDialog.targetID = sp.id
    ruleDialog.title:SetText("Правила: " .. sp.name)
    for i, rule in ipairs(RULES) do
        ruleDialog.checks[i]:SetChecked(sp.rules[rule.id] and true or false)
        -- Reveal saved subclass choices on opening a space's rule list.
        if rule.parent and sp.rules[rule.id] then ruleDialog.expanded[rule.parent] = true end
    end
    ruleDialog:LayoutRules()
    ruleDialog:Show()
end

local function setupUI()
    local f = CreateFrame("Frame", "AmdirSpacesFrame", UIParent)
    f:SetSize(778, 550)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 24,
        insets = {left = 7, right = 7, top = 7, bottom = 7}})
    -- Stock variable-height bag artwork. Blizzard splits UI-Bag-Components
    -- into a 94px header, up to two row sections and a 10px bottom edge.
    f.bagArtwork = {}
    local function bagTexture()
        local texture = f:CreateTexture(nil, "BACKGROUND")
        texture:SetWidth(256)
        texture:SetTexture("Interface\\ContainerFrame\\UI-Bag-Components")
        texture:Hide()
        f.bagArtwork[#f.bagArtwork + 1] = texture
        return texture
    end
    f.bagTop = bagTexture()
    f.bagTop:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    f.bagTop:SetTexCoord(0, 1, 0.00390625, 0.18359375)
    f.bagMiddle1 = bagTexture()
    f.bagMiddle2 = bagTexture()
    f.bagMiddle1:SetWidth(192)
    f.bagMiddle2:SetWidth(192)

    -- Preserve the backpack's native money strip below the variable bag body.
    f.moneyBackground = f:CreateTexture(nil, "BACKGROUND")
    f.moneyBackground:SetSize(192, 48)
    f.moneyBackground:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    f.moneyBackground:SetTexture("Interface\\ContainerFrame\\UI-BackpackBackground")
    f.moneyBackground:SetTexCoord(0.25, 1, 0.8125, 1)
    f.moneyBackground:Hide()
    f.bagArtwork[#f.bagArtwork + 1] = f.moneyBackground
    f:Hide()
    table.insert(UISpecialFrames, "AmdirSpacesFrame")
    f:SetScript("OnEnter", function() if spacesFocus then spacesFocus() end end)

    f.title = text(f, "GameFontNormalLarge")
    f.title:SetText("AmdirSpaces")
    f.counter = text(f, "GameFontHighlightSmall")
    local close = CreateFrame("Button", "AmdirSpacesCloseButton", f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, -1)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Original backpack portrait, independent of equipped bags and client
    -- patches replacing UI-BackpackBackground. The sprite is the 48px header
    -- crop at source x=64, y=0; match bagTop's 92px source / 94px display scale.
    f.bagIcon = f:CreateTexture("AmdirSpacesBagPortrait", "BACKGROUND", nil, -1)
    local headerScaleY = 94 / 92
    f.bagIcon:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Textures\\BackpackPortrait")
    f.bagIcon:SetTexCoord(0, 48 / 64, 0, 48 / 64)
    f.bagIcon:SetSize(48, 48 * headerScaleY)
    f.bagIcon:SetPoint("TOPLEFT", 0, 2 * headerScaleY)

    f.money = CreateFrame("Frame", "AmdirSpacesMoneyFrame", f, "SmallMoneyFrameTemplate")
    f.money:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -22, 40)
    f.money:Hide()

    -- Main pane and sidebar use native Blizzard colors and buttons.
    f.separator = f:CreateTexture(nil, "ARTWORK")
    f.separator:SetTexture(0.45, 0.34, 0.18, 0.40)
    f.separator:SetWidth(1)
    f.categoryLabel = text(f, "GameFontNormal")
    f.categoryLabel:SetText("Простори")

    f.spaceScroll = CreateFrame("ScrollFrame", "AmdirSpacesCategoriesScroll", f, "UIPanelScrollFrameTemplate")
    f.spaceScroll.scrollBarHideable = true
    f.spaceChild = CreateFrame("Frame", nil, f.spaceScroll)
    f.spaceChild:SetSize(145, 100)
    f.spaceScroll:SetScrollChild(f.spaceChild)
    f.spaceButtons = {}
    f.generalButton = quickButton(f, "Загальні", 142, 27, function()
        activeID = 0
        if hideShades then hideShades() end
        f.tempSwaps = {}
        applyLayout(true)
        f:Update()
    end)

    f.replaceBagsCheck = CreateFrame("CheckButton", "AmdirSpacesReplaceBags", f, "UICheckButtonTemplate")
    f.replaceBagsCheck:SetSize(21, 21)
    f.replaceBagsLabel = text(f, "GameFontHighlightSmall")
    f.replaceBagsLabel:SetPoint("LEFT", f.replaceBagsCheck, "RIGHT", 2, 0)
    f.replaceBagsLabel:SetText("Замість сумок (B / Shift+B)")
    f.replaceBagsCheck:SetScript("OnClick", function(self)
        if InCombatLockdown and InCombatLockdown() then
            self:SetChecked(db.replaceBags)
            say("Налаштування доступні після бою.")
            return
        end
        db.replaceBags = self:GetChecked() and true or false
        if applyBagBindings then applyBagBindings() end
        if db.replaceBags and CloseAllBags then
            ownBagCall = true
            CloseAllBags()
            ownBagCall = false
        end
        f:Update()
    end)

    f.hideBottomCheck = CreateFrame("CheckButton", "AmdirSpacesHideBottom", f, "UICheckButtonTemplate")
    f.hideBottomCheck:SetSize(21, 21)
    f.hideBottomLabel = text(f, "GameFontHighlightSmall")
    f.hideBottomLabel:SetPoint("LEFT", f.hideBottomCheck, "RIGHT", 2, 0)
    f.hideBottomLabel:SetText("Без нижнього блоку")
    f.hideBottomCheck:SetScript("OnClick", function(self)
        db.hideBottom = self:GetChecked() and true or false
        showEquipment = false
        -- Shrink immediately when hiding the lower section; restoring it
        -- brings back the previously used extended height.
        if db.hideBottom then
            db.fullHeight = db.windowHeight or f:GetHeight()
            f:SetHeight(math.min(f:GetHeight(), 420))
        elseif db.fullHeight then
            f:SetHeight(math.max(f:GetHeight(), db.fullHeight))
        end
        applyLayout(true)
        f:Update()
    end)

    f.compactCheck = CreateFrame("CheckButton", "AmdirSpacesCompactCheck", f, "UICheckButtonTemplate")
    f.compactCheck:SetSize(21, 21)
    f.compactLabel = text(f, "GameFontHighlightSmall")
    f.compactLabel:SetPoint("LEFT", f.compactCheck, "RIGHT", 2, 0)
    f.compactLabel:SetText("Компактний розмір")
    f.compactCheck:SetScript("OnClick", function(self)
        db.compactMode = self:GetChecked() and true or false
        applyLayout(false)
        f:Update()
    end)

    f.newName = CreateFrame("EditBox", "AmdirSpacesNameEntry", f, "InputBoxTemplate")
    f.newName:SetSize(116, 23)
    f.newName:SetAutoFocus(false)
    f.newName:SetMaxLetters(40)
    f.newName:SetScript("OnEnterPressed", function(self) newSpace(self:GetText()); self:ClearFocus() end)
    f.newName:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.plus = quickButton(f, "+", 30, 23, function() newSpace(f.newName:GetText()) end)
    f.plus:SetPoint("LEFT", f.newName, "RIGHT", 5, 0)
    f.createLabel = text(f, "GameFontHighlightSmall")
    f.createLabel:SetText("Новий простір:")

    f.spaceTitle = text(f, "GameFontNormalLarge")
    f.spaceTitle:SetWidth(145)
    f.spaceTitle:SetJustifyH("LEFT")
    f.delete = quickButton(f, "Видалити", 80, 24, function()
        local sp = getActive()
        if sp then StaticPopup_Show("AMDIRSPACES_DELETE", sp.name, nil, sp.id) end
    end)
    f.delete:SetPoint("TOPRIGHT", -23, -58)
    f.down = quickButton(f, "v", 26, 24, function() moveSpace(1) end)
    f.down:SetPoint("RIGHT", f.delete, "LEFT", -3, 0)
    f.up = quickButton(f, "^", 26, 24, function() moveSpace(-1) end)
    f.up:SetPoint("RIGHT", f.down, "LEFT", -3, 0)
    f.rename = quickButton(f, "Назва", 62, 24, function()
        local sp = getActive()
        if sp then StaticPopup_Show("AMDIRSPACES_RENAME", sp.name, nil, sp.id) end
    end)
    f.rename:SetPoint("RIGHT", f.up, "LEFT", -4, 0)
    f.rules = quickButton(f, "Правила", 78, 24, showRules)
    f.rules:SetPoint("RIGHT", f.rename, "LEFT", -4, 0)

    f.shadeCheck = CreateFrame("CheckButton", "AmdirSpacesShadeCheck", f, "UICheckButtonTemplate")
    f.shadeCheck:SetSize(21, 21)
    f.shadeCheck:SetScript("OnClick", function(self)
        local sp = getActive()
        if sp then sp.dimInBags = self:GetChecked() and true or false end
        spacesFocus()
        repaint()
    end)
    f.shadeLabel = text(f, "GameFontHighlightSmall")
    f.shadeLabel:SetPoint("LEFT", f.shadeCheck, "RIGHT", 2, 0)
    f.shadeLabel:SetText("Сірим у звичайних сумках")

    f.search = CreateFrame("EditBox", "AmdirSpacesSearchEntry", f, "InputBoxTemplate")
    f.search:SetSize(166, 23)
    f.search:SetAutoFocus(false)
    f.search:SetMaxLetters(64)
    f.search:SetScript("OnTextChanged", function(self, userInput)
        if userInput and f:IsShown() and not db.compactMode then f:Update() end
    end)
    f.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.search:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); f:Update() end)
    f.searchHint = text(f, "GameFontDisableSmall")
    f.searchHint:SetText("Пошук за назвою")
    f.searchHint:SetPoint("LEFT", f.search, "LEFT", 7, 0)
    f.search:SetScript("OnEditFocusGained", function() f.searchHint:Hide() end)
    f.search:SetScript("OnEditFocusLost", function()
        if not db.compactMode and f.search:GetText() == "" then f.searchHint:Show()
        else f.searchHint:Hide() end
    end)

    f.top = createScroll(f, "AmdirSpacesTopScroll", 210, -133, 530, 200)
    f.divider = f:CreateTexture(nil, "ARTWORK")
    f.divider:SetTexture(0.45, 0.34, 0.18, 0.5)
    f.divider:SetHeight(1)
    f.bottomTitle = text(f, "GameFontNormal")
    f.bottomCount = text(f, "GameFontHighlightSmall")
    f.bottomCount:SetPoint("LEFT", f.bottomTitle, "RIGHT", 9, 0)
    f.allItemsButton = quickButton(f, "Всі сумки", 107, 24, function()
        showAllItems = not showAllItems
        f:Update()
    end)
    f.equipmentButton = quickButton(f, "Показати вдягнене", 151, 24, function()
        showEquipment = not showEquipment
        f:Update()
    end)
    f.allItemsButton:SetPoint("RIGHT", f.equipmentButton, "LEFT", -5, 0)
    f.bottom = createScroll(f, "AmdirSpacesBottomScroll", 210, -350, 530, 120)
    -- Empty area of the lower block also accepts drops: the item returns to General.
    local generalZone = {role = "general"}
    f.bottom.child:EnableMouse(true)
    f.bottom.child:SetScript("OnReceiveDrag", function() dropOnCell(generalZone) end)
    f.bottom.child:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then dropOnCell(generalZone) end
    end)


    f.help = text(f, "GameFontHighlightSmall")
    f.help:SetJustifyH("LEFT")
    f.help:SetText("Перетягни предмет у клітинку  |  ПКМ: використати  |  Shift+клік: розділити  |  Alt+ПКМ: прибрати")
    f.arrange = quickButton(f, "Рознести", 105, 26, function()
        arrange()
        f:Update()
    end)
    f.arrange:SetPoint("BOTTOMRIGHT", -26, 17)

    -- Compact mode: just a dropdown, slot grid, a restore button and close.
    f.miniMenu = CreateFrame("Frame", "AmdirSpacesMiniDropdown", f, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(f.miniMenu, function(self, level)
        if level ~= 1 then return end
        local function option(name, spaceID)
            local info = UIDropDownMenu_CreateInfo()
            info.text = name
            info.checked = (activeID == spaceID)
            info.func = function()
                activeID = spaceID
                if hideShades then hideShades() end
                f.tempSwaps = {}
                applyLayout(false)
                f:Update()
            end
            UIDropDownMenu_AddButton(info, level)
        end
        option("Загальні", 0)
        for _, sp in ipairs(db.spaces) do option(sp.name, sp.id) end
    end)
    -- UIDropDownMenuTemplate is taller than the native 18px bag title strip.
    -- Keep it only as the menu owner and use a borderless title button.
    f.miniSelect = CreateFrame("Button", "AmdirSpacesMiniSelect", f)
    f.miniSelect:SetSize(70, 16)
    f.miniSelect:SetPoint("TOPLEFT", f, "TOPLEFT", 47, -8)
    f.miniSelect.label = text(f.miniSelect, "GameFontHighlightSmall")
    f.miniSelect.label:SetPoint("LEFT", 2, 0)
    f.miniSelect.label:SetPoint("RIGHT", -13, 0)
    f.miniSelect.label:SetJustifyH("CENTER")
    f.miniSelect.arrow = text(f.miniSelect, "GameFontNormalSmall")
    f.miniSelect.arrow:SetPoint("RIGHT", -2, 0)
    f.miniSelect.arrow:SetText("v")
    f.miniSelect:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    f.miniSelect:RegisterForDrag("LeftButton")
    f.miniSelect:SetScript("OnDragStart", function() f:StartMoving() end)
    f.miniSelect:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f.miniSelect:SetScript("OnClick", function(self)
        if ToggleDropDownMenu then ToggleDropDownMenu(1, nil, f.miniMenu, self, 0, 0) end
    end)
    f.miniExpand = CreateFrame("Button", "AmdirSpacesExpandButton", f)
    f.miniExpand:SetSize(32, 32)
    f.miniExpand:SetNormalTexture("Interface\\Buttons\\UI-Panel-BiggerButton-Up")
    f.miniExpand:SetPushedTexture("Interface\\Buttons\\UI-Panel-BiggerButton-Down")
    f.miniExpand:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    f.miniExpand:SetScript("OnClick", function()
        db.compactMode = false
        applyLayout(false)
        f:Update()
    end)
    f.miniExpand:SetPoint("RIGHT", close, "LEFT", 10, 0)
    f.miniExpand:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Розгорнути налаштування", 1, 0.85, 0.4)
        GameTooltip:Show()
    end)
    f.miniExpand:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.resize = CreateFrame("Button", "AmdirSpacesResizeGrip", f)
    f.resize:SetSize(19, 19)
    f.resize:SetPoint("BOTTOMRIGHT", 0, 0)
    f.resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    f.resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    f.resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    -- In compact mode the grip is invisible over the bag corner until hovered.
    local function gripArt(visible)
        local a = visible and 1 or 0
        f.resize:GetNormalTexture():SetAlpha(a)
        f.resize:GetPushedTexture():SetAlpha(a)
    end
    f.resize:SetScript("OnEnter", function() if db and db.compactMode then gripArt(true) end end)
    f.resize:SetScript("OnLeave", function() if db and db.compactMode then gripArt(false) end end)
    local resizing = false
    local changingSize = false
    local resizeCursorY, resizeStartHeight

    local function compactRows(height)
        local rows = 4 + math.floor(((height or 256) - 256) / SLOT_Y + 0.5)
        return math.max(4, math.min(9, rows))
    end

    local function compactHeight(height)
        return 256 + (compactRows(height) - 4) * SLOT_Y
    end

    local function layoutBagArtwork(rows)
        f.bagTop:SetHeight(94)
        f.bagTop:Show()
        local previous = f.bagTop
        local remaining = rows - 1
        for _, middle in ipairs({f.bagMiddle1, f.bagMiddle2}) do
            middle:ClearAllPoints()
            if remaining > 0 then
                local usesFullSection = remaining > 6
                local sectionRows = math.min(6, remaining)
                local height = usesFullSection and 246 or sectionRows * SLOT_Y - 9
                middle:SetHeight(height)
                middle:SetTexCoord(0.25, 1, 0.353515625, 0.353515625 + height / 512)
                middle:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, 0)
                middle:Show()
                previous = middle
                remaining = remaining - sectionRows
            else
                middle:Hide()
            end
        end
        -- The backpack's own bottom (slot padding + money groove) continues the
        -- body directly, like the stock backpack; no second border cap.
        f.moneyBackground:ClearAllPoints()
        f.moneyBackground:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, 0)
        f.moneyBackground:Show()
    end

    local function finishResize()
        if not resizing then return end
        resizing = false
        if not db.compactMode then f:StopMovingOrSizing() end
        if db.compactMode then
            changingSize = true
            f:SetSize(192, compactHeight(f:GetHeight()))
            changingSize = false
            db.compactWidth, db.compactHeight = 192, f:GetHeight()
        else
            db.windowWidth, db.windowHeight = f:GetWidth(), f:GetHeight()
        end
        applyLayout(true)
        f:Update()
    end
    f.resize:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            -- StartSizing with a CENTER anchor causes the classic instant jump
            -- on 3.3.5. Freeze the TOPLEFT in UIParent coordinates first.
            local left, top = f:GetLeft(), f:GetTop()
            if left and top then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
            end
            resizing = true
            if db.compactMode then
                local _, y = GetCursorPosition()
                resizeCursorY = y / UIParent:GetEffectiveScale()
                resizeStartHeight = f:GetHeight()
            else
                f:StartSizing("BOTTOMRIGHT")
            end
        end
    end)
    f.resize:SetScript("OnMouseUp", finishResize)
    -- 3.3.5 can lose OnMouseUp after the cursor leaves the grip. Without this
    -- guard StartSizing stays active and the window keeps expanding.
    f.resize:SetScript("OnUpdate", function()
        if not resizing then return end
        if not IsMouseButtonDown("LeftButton") then
            finishResize()
        elseif db.compactMode then
            local _, y = GetCursorPosition()
            local height = compactHeight(resizeStartHeight + resizeCursorY - y / UIParent:GetEffectiveScale())
            if height ~= f:GetHeight() then
                changingSize = true
                f:SetSize(192, height)
                changingSize = false
                db.compactHeight = height
                applyLayout(true)
                f:Update()
            end
        end
    end)

    local function display(focusSet, isVisible)
        for _, panel in ipairs(focusSet) do
            if isVisible then panel:Show() else panel:Hide() end
        end
    end

    local extended = {
        f.title, f.counter, f.separator, f.categoryLabel, f.spaceScroll,
        f.generalButton, f.replaceBagsCheck, f.replaceBagsLabel,
        f.hideBottomCheck, f.hideBottomLabel, f.compactCheck, f.compactLabel,
        f.newName, f.plus, f.createLabel, f.spaceTitle, f.delete, f.down,
        f.up, f.rename, f.rules, f.shadeCheck, f.shadeLabel,
        f.search, f.searchHint, f.help, f.arrange,
    }
    local bottomPanels = {
        f.divider, f.bottomTitle, f.bottomCount,
        f.equipmentButton, f.allItemsButton, f.bottom.scroll, f.bottom.bar,
    }
    applyLayout = function(keepSize)
        if not db then return end
        -- Compact view uses the stock four-column variable-height bag skin.
        if f.styledCompact ~= db.compactMode then
            f.styledCompact = db.compactMode
            if db.compactMode then
                f:SetBackdrop(nil)
            else
                for _, texture in ipairs(f.bagArtwork) do texture:Hide() end
                f:SetBackdrop({bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 24,
                    insets = {left = 7, right = 7, top = 7, bottom = 7}})
            end
        end
        changingSize = true
        if db.compactMode then
            f:SetMinResize(192, 256)
            if f.SetMaxResize then f:SetMaxResize(192, 256 + 5 * SLOT_Y) end
            if resizing then f:SetWidth(192)
            else f:SetSize(192, compactHeight(db.compactHeight or f:GetHeight())) end
        else
            if f.SetMaxResize then
                f:SetMaxResize(math.max(680, UIParent:GetWidth() - 24),
                    math.max(388, UIParent:GetHeight() - 24))
            end
            f:SetMinResize(680, 388)
            if not keepSize then f:SetSize(db.windowWidth or 778, db.windowHeight or 550) end
        end
        changingSize = false

        local w, h = f:GetWidth(), f:GetHeight()
        if db.compactMode then
            local rows = compactRows(h)
            layoutBagArtwork(rows)
            display(extended, false)
            display(bottomPanels, false)
            f.miniMenu:Hide()
            f.miniSelect:Show()
            f.miniExpand:Show()
            f.bagIcon:Show()
            f.money:Show()
            f.resize:Show()
            f.resize:ClearAllPoints()
            -- The money artwork ends 18px above its texture bounds. Account
            -- for the grabber's own transparent padding to align its visible tip.
            f.resize:SetSize(14, 14)
            f.resize:SetPoint("BOTTOMRIGHT", f.moneyBackground, "BOTTOMRIGHT", -3, 18)
            gripArt(resizing)
            f.top.scroll:Show()
            f.top.overlayScroll = true
            f.top.fixedCols = 4
            f.top.hideBar = true
            f.top.bar:SetWidth(4)
            f.top.bar:ClearAllPoints()
            f.top.bar:SetPoint("TOPLEFT", f.top.scroll, "TOPRIGHT", 2, 0)
            f.top.bar:SetPoint("BOTTOMLEFT", f.top.scroll, "BOTTOMRIGHT", 2, 0)
            f.top.scroll:ClearAllPoints()
            f.top.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -46)
            f.top.scroll:SetSize(168, rows * SLOT_Y + 4)
        else
            display(extended, true)
            f.miniMenu:Hide()
            f.miniSelect:Hide()
            f.miniExpand:Hide()
            f.bagIcon:Hide()
            f.money:Hide()
            f.resize:Show()
            f.resize:ClearAllPoints()
            f.resize:SetSize(19, 19)
            f.resize:SetPoint("BOTTOMRIGHT", 0, 0)
            gripArt(true)
            f.top.scroll:Show()
            f.top.overlayScroll = false
            f.top.fixedCols = nil
            f.top.hideBar = false
            f.top.bar:SetWidth(10)
            f.top.bar:ClearAllPoints()
            f.top.bar:SetPoint("TOPRIGHT", f.top.scroll, "TOPRIGHT", 0, 0)
            f.top.bar:SetPoint("BOTTOMRIGHT", f.top.scroll, "BOTTOMRIGHT", 0, 0)
            f.title:ClearAllPoints()
            f.title:SetPoint("TOPLEFT", 21, -17)
            f.counter:ClearAllPoints()
            f.counter:SetPoint("TOPRIGHT", -56, -21)
            f.separator:ClearAllPoints()
            f.separator:SetPoint("TOPLEFT", 191, -48)
            f.separator:SetHeight(h - 65)
            f.categoryLabel:ClearAllPoints()
            f.categoryLabel:SetPoint("TOPLEFT", 21, -56)
            f.generalButton:ClearAllPoints()
            f.generalButton:SetPoint("TOPLEFT", 20, -79)
            f.spaceScroll:ClearAllPoints()
            f.spaceScroll:SetPoint("TOPLEFT", 20, -112)
            f.spaceScroll:SetSize(165, math.max(72, h - 302))
            f.replaceBagsCheck:ClearAllPoints()
            f.replaceBagsCheck:SetPoint("BOTTOMLEFT", 15, 135)
            f.hideBottomCheck:ClearAllPoints()
            f.hideBottomCheck:SetPoint("BOTTOMLEFT", 15, 110)
            f.compactCheck:ClearAllPoints()
            f.compactCheck:SetPoint("BOTTOMLEFT", 15, 85)
            f.newName:ClearAllPoints()
            f.newName:SetPoint("BOTTOMLEFT", 22, 38)
            f.createLabel:ClearAllPoints()
            f.createLabel:SetPoint("BOTTOMLEFT", f.newName, "TOPLEFT", 0, 2)
            f.spaceTitle:ClearAllPoints()
            f.spaceTitle:SetPoint("TOPLEFT", 210, -60)
            f.shadeCheck:ClearAllPoints()
            f.shadeCheck:SetPoint("TOPLEFT", 208, -92)
            f.search:ClearAllPoints()
            f.search:SetPoint("TOPRIGHT", -28, -92)
            f.help:ClearAllPoints()
            f.help:SetPoint("BOTTOMLEFT", 211, 23)
            f.help:SetWidth(math.max(150, w - 365))
            local contentWidth = w - 240
            local hideBottom = db.hideBottom or activeID == 0
            local topHeight = hideBottom and (h - 195) or (h - 349)
            f.top.scroll:ClearAllPoints()
            f.top.scroll:SetPoint("TOPLEFT", 210, -131)
            f.top.scroll:SetSize(contentWidth, math.max(94, topHeight))
            display(bottomPanels, not hideBottom)
            if not hideBottom then
                local lowerY = 139 + topHeight
                f.divider:ClearAllPoints()
                f.divider:SetPoint("TOPLEFT", 210, -lowerY)
                f.divider:SetWidth(contentWidth)
                f.bottomTitle:ClearAllPoints()
                f.bottomTitle:SetPoint("TOPLEFT", 211, -(lowerY + 12))
                f.equipmentButton:ClearAllPoints()
                f.equipmentButton:SetPoint("TOPRIGHT", -29, -(lowerY + 6))
                f.bottom.scroll:ClearAllPoints()
                f.bottom.scroll:SetPoint("TOPLEFT", 210, -(lowerY + 43))
                f.bottom.scroll:SetSize(contentWidth, math.max(60, h - lowerY - 92))
            end
        end
    end

    -- Entering any interactive control brings dimming back after a click
    -- on Blizzard's original inventory window.
    for _, control in ipairs({f.replaceBagsCheck, f.hideBottomCheck,
        f.compactCheck, f.shadeCheck, f.newName, f.search,
        f.spaceScroll, f.top.scroll, f.bottom.scroll, f.miniMenu, f.miniSelect}) do
        control:HookScript("OnEnter", function() spacesFocus() end)
    end

    f:SetScript("OnSizeChanged", function(self, w, h)
        if changingSize or not db then return end
        if db.compactMode then
            db.compactWidth, db.compactHeight = w, h
        else
            db.windowWidth, db.windowHeight = w, h
        end
        applyLayout(true)
        pendingRefresh = true
        nextRefresh = GetTime() + 0.04
    end)

    function f:Update(force)
        if not force and not self:IsShown() then return end
        local state = scan()
        local sp = getActive()
        -- Detect a gear swap without changing SavedVariables. When a reserved
        -- gear item is equipped, show the just-unequipped gear in its cell as
        -- a TEMPORARY, usable stand-in while the same space remains selected.
        -- The pinned item keeps its original spot in the database.
        self.tempSwaps = self.tempSwaps or {}
        if self.lastActiveSpace ~= activeID then
            self.tempSwaps = {}
            self.lastActiveSpace = activeID
        end
        local wornNow = {}
        for _, it in ipairs(state.equipped) do wornNow[it.slot] = it end
        if sp and self.previousEquipped then
            for equipSlot, former in pairs(self.previousEquipped) do
                local equipped = wornNow[equipSlot]
                if former and equipped and
                    (former.id ~= equipped.id or former.key ~= equipped.key) then
                    for pos, candidate in pairs(state.assignments[sp.id] or {}) do
                        if candidate == equipped and candidate.equipped then
                            -- Keep the physical location fresh after equipment swaps.
                            self.tempSwaps[pos] = {oldID = former.id, oldKey = former.key,
                                newKey = equipped.key, newID = equipped.id}
                            break
                        end
                    end
                end
            end
        end
        self.previousEquipped = wornNow
        self.counter:SetText(state.total .. " слотів  |  " .. state.free .. " вільно")
        if MoneyFrame_Update and GetMoney then
            MoneyFrame_Update(self.money:GetName(), GetMoney())
        end
        self.hideBottomCheck:SetChecked(db.hideBottom and true or false)
        self.replaceBagsCheck:SetChecked(db.replaceBags and true or false)
        self.compactCheck:SetChecked(db.compactMode and true or false)
        self.spaceTitle:SetText(sp and sp.name or (activeID == 0 and "Загальні" or "Створи простір"))
        self.shadeCheck:SetChecked(sp and sp.dimInBags or false)
        if sp then
            self.shadeCheck:Enable()
            self.shadeLabel:SetTextColor(1, 1, 1)
            for _, b in ipairs({self.delete, self.up, self.down, self.rules, self.rename}) do b:Enable() end
        else
            self.shadeCheck:Disable()
            self.shadeLabel:SetTextColor(0.45, 0.45, 0.45)
            for _, b in ipairs({self.delete, self.up, self.down, self.rules, self.rename}) do b:Disable() end
        end
        local categoryHeight = math.max(72, self.spaceScroll:GetHeight())
        self.spaceChild:SetHeight(math.max(categoryHeight, #db.spaces * 32 + 2))
        self.spaceScroll:UpdateScrollChildRect()
        self.generalButton:GetFontString():SetTextColor(1, activeID == 0 and 0.85 or 1, activeID == 0 and 0.35 or 1)
        for i, s in ipairs(db.spaces) do
            local b = self.spaceButtons[i]
            if not b then
                b = quickButton(self.spaceChild, "", 141, 29, function(self)
                    activeID = self.spaceID
                    if hideShades then hideShades() end
                    f.tempSwaps = {}
                    applyLayout(true)
                    f:Update()
                end)
                self.spaceButtons[i] = b
            end
            b.spaceID = s.id
            b:SetText(s.name)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 1, -((i - 1) * 32 + 2))
            b:Show()
            b:GetFontString():SetTextColor(1, (s.id == activeID) and 0.85 or 1, (s.id == activeID) and 0.35 or 1)
        end
        for i = #db.spaces + 1, #self.spaceButtons do self.spaceButtons[i]:Hide() end
        UIDropDownMenu_SetText(self.miniMenu, sp and sp.name or "Загальні")
        self.miniSelect.label:SetText(sp and sp.name or "Загальні")

        local searchQuery = ""
        if not db.compactMode then searchQuery = foldName(trim(self.search:GetText())) end
        if not db.compactMode and searchQuery == "" and not self.search:HasFocus() then self.searchHint:Show()
        else self.searchHint:Hide() end
        -- Always create real cells for every visible slot so each one has the
        -- native hover and accepts drops, exactly like a Blizzard bag.
        local spaceCols, visibleRows = gridMetrics(self.top)
        local capacity = spaceCols * visibleRows
        if searchQuery ~= "" then
            local results = searchAll(state, searchQuery)
            self.spaceTitle:SetText("Знайдено: " .. #results)
            drawGrid(self.top, #results, function(i)
                local r = results[i]
                return {role = "search", it = r.it, entry = r.entry, target = r.targetID}
            end)
        elseif sp then
            local slots = allSlots(sp)
            -- Saved cells keep their exact index; one spare row is always shown.
            local used = 0
            for i = 1, math.min(#slots, MAX_SPACE_SLOTS) do
                if slots[i] then used = i end
            end
            local count = math.ceil((used + 1) / spaceCols) * spaceCols
            count = math.min(MAX_SPACE_SLOTS, math.max(capacity, count))
            drawGrid(self.top, count, function(i)
                local pinned = state.assignments[sp.id][i]
                local proxy, temporary
                local swap = self.tempSwaps[i]
                if swap and pinned and pinned.equipped and pinned.id == swap.newID then
                    -- Only a stand-in for gear that has no cell of its own;
                    -- otherwise it would be shown twice.
                    for _, bagItem in ipairs(state.general) do
                        if bagItem.id == swap.oldID and
                            (bagItem.key == swap.oldKey or not swap.oldKey) then
                            proxy, temporary = bagItem, true
                            break
                        end
                    end
                end
                -- Inventory and bag updates can arrive in separate events.
                -- Keep the pending swap until the former item appears in a bag;
                -- discard it only when the pinned gear is no longer equipped.
                if swap and (not pinned or not pinned.equipped or pinned.id ~= swap.newID) then
                    self.tempSwaps[i] = nil
                end
                return {role = "space", it = proxy or pinned, sp = sp, pos = i,
                    entry = slots[i] or nil, temp = temporary}
            end)
        elseif activeID == 0 then
            -- General: unassigned items packed together (bag order), then the
            -- real free slots. Items placed into spaces leave no holes here.
            local list = {}
            for _, p in ipairs(state.physical) do
                if p.item and not state.used[p.item] then list[#list + 1] = p end
            end
            for _, p in ipairs(state.physical) do
                if not p.item then list[#list + 1] = p end
            end
            local count = math.max(capacity, math.ceil(#list / spaceCols) * spaceCols)
            drawGrid(self.top, count, function(i)
                local p = list[i]
                return {role = "general", it = p and p.item, phys = p}
            end)
        else
            drawGrid(self.top, capacity, nil)
        end
        local sources
        if showEquipment then
            sources = showAllItems and state.equipped or state.generalEquipped
        else
            sources = showAllItems and state.bags or state.general
        end
        self.bottomTitle:SetText(showEquipment and "На персонажі" or (showAllItems and "Усі сумки" or "Загальні"))
        self.bottomCount:SetText("(" .. #sources .. ")")
        self.allItemsButton:SetText(showAllItems and "Нерознесені" or "Всі сумки")
        self.equipmentButton:SetText(showEquipment and "Показати загальні" or "Показати вдягнене")
        if not (db.hideBottom or db.compactMode or activeID == 0) then
            drawGrid(self.bottom, #sources, function(i)
                local it = sources[i]
                return {role = "bottom", it = it, phys = (it and not it.equipped) and it or nil}
            end)
        end
        refreshNativeBags(state)
    end

    function f:RefreshCooldowns()
        for _, grid in ipairs({self.top, self.bottom}) do
            for _, cell in ipairs(grid.cells) do
                if cell:IsShown() then updateCellCooldown(cell) end
            end
        end
    end

    f:SetScript("OnShow", function(self)
        nativeBagFocused = false
        self:Update()
    end)
    f:SetScript("OnHide", function(self)
        finishResize()
        self.tempSwaps = {}
        -- Gear swaps made while closed are not "just unequipped" any more.
        self.previousEquipped = nil
        if ruleDialog then ruleDialog:Hide() end
        hideShades()
    end)
    ui = f
    applyLayout(false)
end

-- In replacement mode, keys assigned by the player to ordinary bag commands
-- temporarily click our button. No account key bindings are overwritten.
local bindingOwner = CreateFrame("Frame", "AmdirSpacesBindingOwner", UIParent)
local bindingButton = CreateFrame("Button", "AmdirSpacesBagToggleButton", UIParent)
bindingButton:SetScript("OnClick", function(_, command)
    AmdirSpaces_Toggle(command == "OPENALLBAGS")
end)
applyBagBindings = function()
    if InCombatLockdown and InCombatLockdown() then return end
    if ClearOverrideBindings then ClearOverrideBindings(bindingOwner) end
    if not db or not SetOverrideBindingClick then return end
    local commands = {"AMDIRSPACES_TOGGLE"}
    if db.replaceBags then
        for _, command in ipairs({"TOGGLEBACKPACK", "OPENALLBAGS", "TOGGLEBAG1", "TOGGLEBAG2", "TOGGLEBAG3", "TOGGLEBAG4"}) do
            commands[#commands + 1] = command
        end
    end
    local assigned = {}
    for _, command in ipairs(commands) do
        local key1, key2 = GetBindingKey(command)
        if key1 and not assigned[key1] then
            SetOverrideBindingClick(bindingOwner, true, key1, "AmdirSpacesBagToggleButton", command)
            assigned[key1] = true
        end
        if key2 and not assigned[key2] then
            SetOverrideBindingClick(bindingOwner, true, key2, "AmdirSpacesBagToggleButton", command)
            assigned[key2] = true
        end
    end
end

local function closeInventoryBags()
    -- Keep bank bags intact when replacing only the player's inventory.
    for bag = 0, (NUM_BAG_SLOTS or 4) do CloseBag(bag) end
end

function AmdirSpaces_Toggle(allBags)
    if not ui then return end
    local atBank = db and db.replaceBags and BankFrame and BankFrame:IsShown()
    local close = ui:IsShown() and not pendingHide
    pendingHide = false
    if allBags == true and atBank and close then
        -- Like ToggleAllBags: first open any missing bank bags; close only
        -- when the inventory and every equipped bank bag are already open.
        for bag = (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7) do
            if GetContainerNumSlots(bag) > 0 and not IsBagOpen(bag) then
                close = false
                break
            end
        end
    end
    ownBagCall = true
    if close then
        ui:Hide()
        if db and db.replaceBags and CloseAllBags then CloseAllBags() end
    else
        if db and db.replaceBags then closeInventoryBags() end
        if allBags == true and atBank then
            for bag = (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7) do
                OpenBag(bag)
            end
        end
        ui:Show()
    end
    ownBagCall = false
end

-- Replacement mode for every other way the game opens/closes the inventory
-- (backpack button, bag slot buttons, mailbox, AH, trade, guild bank, vendor,
-- bank, other addons). Post-hooks only: Blizzard code is never replaced.
local function replacing()
    return db and db.replaceBags and ui and not ownBagCall
end

local function inventoryBagOpen()
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        if IsBagOpen(bag) then return true end
    end
end

-- Blizzard "open" calls (vendor, mailbox, AH: OpenAllBags(true),
-- OpenBackpack, OpenBag) internally toggle every bag one by one, so the
-- number of ToggleBackpack/ToggleBag calls decides whether we end up shown.
-- A hide requested by a toggle is therefore deferred to the next frame and
-- cancelled when the surrounding call turns out to be an "open" request.
local function hookBagFunctions()
    if not hooksecurefunc then return end
    local function toggled()
        if not replacing() then return end
        local wasShown = ui:IsShown() and not pendingHide
        ownBagCall = true
        closeInventoryBags()
        if wasShown then
            pendingHide = true
        else
            pendingHide = false
            ui:Show()
        end
        ownBagCall = false
    end
    local function opened()
        if not replacing() then return end
        pendingHide = false
        ownBagCall = true
        closeInventoryBags()
        ui:Show()
        ownBagCall = false
    end
    if OpenAllBags then
        hooksecurefunc("OpenAllBags", function(forceOpen)
            if forceOpen then opened() end
        end)
    end
    if OpenBackpack then hooksecurefunc("OpenBackpack", opened) end
    if OpenBag then
        hooksecurefunc("OpenBag", function(bag)
            if bag and bag >= 0 and bag <= (NUM_BAG_SLOTS or 4) then opened() end
        end)
    end
    if ToggleBackpack then hooksecurefunc("ToggleBackpack", toggled) end
    if ToggleBag then
        hooksecurefunc("ToggleBag", function(bag)
            if bag and bag >= 1 and bag <= (NUM_BAG_SLOTS or 4) then toggled() end
        end)
    end
    local function closed()
        if replacing() then
            pendingHide = false
            ui:Hide()
        end
    end
    if CloseAllBags then hooksecurefunc("CloseAllBags", closed) end
    if CloseBackpack then hooksecurefunc("CloseBackpack", closed) end
end

SLASH_AMDIRSPACES1 = "/as"
SlashCmdList["AMDIRSPACES"] = AmdirSpaces_Toggle

local dispatcher = CreateFrame("Frame")
dispatcher:RegisterEvent("ADDON_LOADED")
dispatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
dispatcher:RegisterEvent("BAG_UPDATE")
dispatcher:RegisterEvent("BAG_UPDATE_COOLDOWN")
dispatcher:RegisterEvent("SPELL_UPDATE_COOLDOWN")
dispatcher:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
dispatcher:RegisterEvent("ITEM_LOCK_CHANGED")
dispatcher:RegisterEvent("UNIT_INVENTORY_CHANGED")
dispatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
dispatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
dispatcher:RegisterEvent("UPDATE_BINDINGS")
dispatcher:RegisterEvent("PLAYER_MONEY")
dispatcher:RegisterEvent("MERCHANT_SHOW")
dispatcher:RegisterEvent("MERCHANT_CLOSED")
dispatcher:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        if type(AmdirSpacesDB) ~= "table" then
            AmdirSpacesDB = type(SimpleSpacesDB) == "table" and SimpleSpacesDB or {}
        end
        db = AmdirSpacesDB
        SimpleSpacesDB = nil -- imported legacy SavedVariables, if supplied
        if type(db.spaces) ~= "table" then db.spaces = {} end
        if type(db.nextID) ~= "number" then db.nextID = 1 end
        db.toys = nil -- removed feature
        db.replaceBags = db.replaceBags and true or false
        db.hideBottom = db.hideBottom and true or false
        db.compactMode = db.compactMode and true or false
        if type(db.windowWidth) ~= "number" then db.windowWidth = 778 end
        if type(db.windowHeight) ~= "number" then db.windowHeight = db.hideBottom and 420 or 550 end
        db.windowWidth = math.max(680, math.min(1450, db.windowWidth))
        db.windowHeight = math.max(388, math.min(980, db.windowHeight))
        local previousUIVersion = tonumber(db.uiVersion) or 0
        if previousUIVersion < 4 then
            -- Start the new row-snapped UI at four visible rows.
            db.compactWidth, db.compactHeight = 192, 256
            db.uiVersion = 4
        end
        db.compactWidth = 192
        local compactRows = 4 + math.floor(((db.compactHeight or 256) - 256) / 41 + 0.5)
        compactRows = math.max(4, math.min(9, compactRows))
        db.compactHeight = 256 + (compactRows - 4) * 41
        for _, sp in ipairs(db.spaces) do
            sp.slots = type(sp.slots) == "table" and sp.slots or {}
            for _, pinned in pairs(sp.slots) do
                if type(pinned) == "table" then pinned.pendingUntil = nil end
            end
            local individualRules = {}
            if type(sp.rules) == "table" then
                for id, enabled in pairs(sp.rules) do
                    if enabled then individualRules[id] = true end
                end
            end
            sp.rules = individualRules
            -- Older versions defaulted this per-space setting to false,
            -- leaving newly selected spaces unexpectedly unshaded.
            if previousUIVersion < 5 then sp.dimInBags = true
            else sp.dimInBags = sp.dimInBags and true or false end
            if sp.id >= db.nextID then db.nextID = sp.id + 1 end
        end
        db.uiVersion = 5
        setupClasses()
        migrateRuleFilters()
        primeRuleCounts()
        setupUI()
        hookNativeBags()
        hookBagFunctions()
        applyBagBindings()
        if hooksecurefunc and ContainerFrame_Update then
            hooksecurefunc("ContainerFrame_Update", function()
                if db then refreshNativeBags(scan()) end
            end)
        end
        -- Remember where the cursor item was taken from (our cells, Blizzard
        -- bags, character sheet), so a drop knows what is being moved.
        if hooksecurefunc then
            if PickupContainerItem then
                hooksecurefunc("PickupContainerItem", function(bag, slot) trackPickup({bag = bag, slot = slot}) end)
            end
            if SplitContainerItem then
                hooksecurefunc("SplitContainerItem", function(bag, slot) trackPickup({bag = bag, slot = slot, split = true}) end)
            end
            if PickupInventoryItem then
                hooksecurefunc("PickupInventoryItem", function(slot) trackPickup({equip = slot}) end)
            end
        end
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_REGEN_DISABLED" then
        pendingRefresh = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        if ui and applyLayout then applyLayout(true) end
        pendingRefresh = true
        nextRefresh = GetTime() + 0.05
        if applyBagBindings then applyBagBindings() end
    elseif event == "UPDATE_BINDINGS" then
        if applyBagBindings then applyBagBindings() end
    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_CLOSED" then
        if ui and ui:IsShown() then ui:Update() end
    elseif event == "PLAYER_MONEY" then
        if ui and ui.money and MoneyFrame_Update and GetMoney then
            MoneyFrame_Update(ui.money:GetName(), GetMoney())
        end
    elseif ui and (event == "BAG_UPDATE_COOLDOWN" or
        event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_COOLDOWN") then
        -- Cooldown events are visual-only. Updating synchronously matches the
        -- native bags and removes the previous 120 ms GCD delay.
        if ui:IsShown() and ui.RefreshCooldowns then ui:RefreshCooldowns() end
    elseif ui and event == "ITEM_LOCK_CHANGED" then
        -- Fast refresh: the source slot greys out as soon as the item is picked up.
        pendingRefresh = true
        nextRefresh = GetTime() + 0.02
    elseif ui and event == "PLAYER_ENTERING_WORLD" and not self.primed then
        self.primed = true
        pendingRuleRoute = false
        primeRuleCounts()
        pendingRefresh = true
        nextRefresh = GetTime() + 0.12
    elseif ui and (event == "BAG_UPDATE" or
        event == "PLAYER_ENTERING_WORLD" or
        (event == "UNIT_INVENTORY_CHANGED" and arg1 == "player")) then
        pendingRuleRoute = true
        nextRuleRoute = GetTime() + 0.12
        ruleRetryUntil = GetTime() + 3
        pendingRefresh = true
        nextRefresh = GetTime() + 0.12
    end
end)
dispatcher:SetScript("OnUpdate", function(self, elapsed)
    if pendingHide then
        pendingHide = false
        if ui then ui:Hide() end
    end
    -- Whatever opened a Blizzard inventory bag, show AmdirSpaces instead.
    -- Bank bags (5-11) stay as they are.
    if replacing() and inventoryBagOpen() then
        ownBagCall = true
        closeInventoryBags()
        ui:Show()
        ownBagCall = false
    end
    if cursorSrc and not (CursorHasItem and CursorHasItem()) then cursorSrc = nil end
    -- Blizzard frequently recreates bag buttons/visibility without firing
    -- BAG_UPDATE. Recheck while our window is open so returning from a native
    -- bag consistently restores its gray overlays.
    shadingPulse = shadingPulse + (elapsed or 0)
    if shadingPulse >= 0.45 then
        shadingPulse = 0
        if ui and ui:IsShown() then
            hookNativeBags()
            if not nativeBagFocused and not (InCombatLockdown and InCombatLockdown()) then
                refreshNativeBags(scan())
            end
        end
    end
    if pendingRuleRoute and self.primed and GetTime() >= nextRuleRoute and
        not (CursorHasItem and CursorHasItem()) then
        pendingRuleRoute = false
        routeIncomingItems()
        pendingRefresh = true
        nextRefresh = GetTime()
    end
    if pendingRefresh and GetTime() >= nextRefresh then
        pendingRefresh = false
        if ui and ui:IsShown() then ui:Update()
        elseif refreshNativeBags then refreshNativeBags() end
    end
end)
