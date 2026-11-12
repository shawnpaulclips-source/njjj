--[[
    Ultimate Unlock-All for Fashion Game (Place 118756480494489)
    ─────────────────────────────────────────────────────────────
    What it does:
      • Unlocks every top, bodice, dress, skirt, corset, detail, detail pack,
        brush, pattern, runway FX, boutique item, frosty item, drop item, and
        VIP-exclusive across the entire UI — editor, shops, salon, camera studio.
      • Sets VIP, every gamepass (Salon, 2x Theme Vote, 2x Diamonds, Extra Roll
        Spot), Frosty Pass with max XP, and StarterOwned.
      • Patches every client-side ownership check so no lock icon, paywall, or
        "buy" overlay appears — items are selectable and usable in the editor.
      • Persists through server attribute rewrites (re-applies on every change).

    What it CANNOT do (server-authoritative):
      • Other players' nametags read VIP and Stars from the Player object,
        which the server owns. Client SetAttribute on Player does NOT replicate
        to other clients in Roblox — only the server can set those.
      • The mannequin wear system (what other players see you wearing) reads
        WornB/WornV/WornN/WornFitted from server-set workspace model attributes,
        then fetches the actual design ops via Remotes.Mannequin:InvokeServer("ops").
        The client never writes these. Your worn outfit is what the server stored.
      • Design submission (SubmitOps) sends paint ops to the server. Whether the
        server validates brush/pattern/detail ownership on those ops is unknown
        from the client dump alone. If it does, ops using paid items will be
        rejected server-side even though the editor let you use them.

    TL;DR: Your screen shows everything unlocked. You can design with any item.
    Whether the server accepts or strips paid items from your submitted design
    requires live testing. Other players see your nametag and worn outfit as
    the server dictates.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClientModules = ReplicatedStorage:WaitForChild("ClientModules")

local Store = require(Shared:WaitForChild("Store"))
local DressShapes = require(Shared:WaitForChild("DressShapes"))
local Config = require(Shared:WaitForChild("Config"))
local Shops = require(ClientModules:WaitForChild("Shops"))

local Mannequin do
    local ok, m = pcall(require, Shared:WaitForChild("Mannequin", 3))
    Mannequin = ok and m or nil
end
local Details do
    local ok, d = pcall(require, Shared:WaitForChild("Details", 3))
    Details = ok and d or nil
end
local FrostyPass do
    local ok, f = pcall(require, Shared:WaitForChild("FrostyPass", 3))
    FrostyPass = ok and f or nil
end
local HairLibrary do
    local ok, h = pcall(require, Shared:WaitForChild("HairLibrary", 3))
    HairLibrary = ok and h or nil
end
local Patterns do
    local ok, p = pcall(require, Shared:WaitForChild("Patterns", 3))
    Patterns = ok and p or nil
end
local Brushes do
    local ok, b = pcall(require, Shared:WaitForChild("Brushes", 3))
    Brushes = ok and b or nil
end

-------------------------------------------------------------------------------
-- 1) BUILD THE COMPLETE OWNED-ITEMS LIST
-------------------------------------------------------------------------------
local keys, seen = {}, {}
local function add(k)
    if k and not seen[k] then
        seen[k] = true
        keys[#keys + 1] = k
    end
end

-- Every bodice / dress shape
for name in pairs(DressShapes.BODICES or {}) do add("top:" .. tostring(name)) end

-- Named top lists
for _, list in ipairs({
    Store.FREE_TOPS, Store.VIP_TOPS, Store.FROSTY_TOPS, Store.TEST_TOPS,
    Store.FREE_DRESSES, Store.NOV_SKIRTS_FREE, Store.NOV_SKIRTS_SHOP
}) do
    if list then for _, t in ipairs(list) do add("top:" .. t) end end
end

-- Boutique items (tops, details, etc.)
for _, b in ipairs(Store.BOUTIQUE or {}) do
    add(b.kind .. ":" .. tostring(b.id))
end

-- Detail packs + their individual details
for _, p in ipairs(Store.DETAIL_PACKS or {}) do
    add("pack:" .. p.key)
    for _, d in ipairs(p.details or {}) do add("detail:" .. d) end
    for _, d in ipairs(p.vipBonus or {}) do add("detail:" .. d) end
end

-- Runway effects
for _, fx in ipairs(Store.RUNWAY_FX or {}) do add("fx:" .. fx.key) end

-- Featured set
if Store.FEATURED_SET then
    if Store.FEATURED_SET.top then add("top:" .. Store.FEATURED_SET.top) end
    if Store.FEATURED_SET.pack then add("pack:" .. Store.FEATURED_SET.pack) end
    if Store.FEATURED_SET.fx then add("fx:" .. Store.FEATURED_SET.fx) end
end

-- Paid items (brushes, patterns, details)
for _, tbl in ipairs({ Store.PAID, Store.DROP_ONLY, Store.FROSTY_ITEMS }) do
    if tbl then
        for kind, list in pairs(tbl) do
            for _, id in ipairs(list) do add(kind .. ":" .. tostring(id)) end
        end
    end
end

-- Drop contents
for _, drop in ipairs(Store.DROPS or {}) do
    for _, k in ipairs(drop.items or {}) do add(k) end
end

-- Gothic details
for _, d in ipairs(Store.GOTHIC_DETAILS or {}) do add("detail:" .. d) end

-- Hardcoded grants
for _, grant in pairs(Store.GRANTS or {}) do
    for _, k in ipairs(grant) do add(k) end
end

-- Full-access user items (grab any extra keys)
for _, desc in pairs(Store.FULL_ACCESS or {}) do
    -- These users get everything; we already have everything above
end

-- Brushes module — add every brush by name/id
if Brushes then
    for _, b in ipairs(Brushes) do
        if b.id then add("brush:" .. tostring(b.id)) end
        if b.name then add("brush:" .. tostring(b.name)) end
    end
    if type(Brushes) == "table" then
        for k, v in pairs(Brushes) do
            if type(v) == "table" and v.id then
                add("brush:" .. tostring(v.id))
            end
        end
    end
end

-- Patterns module — add every pattern
if Patterns and Patterns.LIST then
    for _, p in ipairs(Patterns.LIST) do
        if p.name then add("pattern:" .. tostring(p.name)) end
        if p.id then add("pattern:" .. tostring(p.id)) end
    end
end

local OWNED = table.concat(keys, ",")

-------------------------------------------------------------------------------
-- 2) FROSTY PASS — max XP, VIP flag, all claimed
-------------------------------------------------------------------------------
local function frostyState()
    local ok, cur = pcall(HttpService.JSONDecode, HttpService, LocalPlayer:GetAttribute("FrostyPass") or "")
    cur = (ok and type(cur) == "table") and cur or {}
    cur.vip = true
    cur.xp = math.max(tonumber(cur.xp) or 0, 1e7)
    -- Mark every frosty tier as claimed
    cur.c = cur.c or ""
    local claimed = {}
    for i in string.gmatch(cur.c, "[^,]+") do claimed[i] = true end
    for i = 1, 50 do claimed[tostring(i)] = true end
    local parts = {}
    for k in pairs(claimed) do parts[#parts + 1] = k end
    cur.c = table.concat(parts, ",")
    return HttpService:JSONEncode(cur)
end

-------------------------------------------------------------------------------
-- 3) APPLY ALL ATTRIBUTES
-------------------------------------------------------------------------------
local applying = false
local function apply()
    if applying then return end
    applying = true

    -- Core ownership
    LocalPlayer:SetAttribute("Owned", OWNED)
    LocalPlayer:SetAttribute("VIP", true)
    LocalPlayer:SetAttribute("StarterOwned", true)

    -- Every gamepass
    for _, pass in ipairs(Store.PASSES) do
        LocalPlayer:SetAttribute(Store.attr(pass.key), true)
    end

    -- Frosty pass
    LocalPlayer:SetAttribute("FrostyPass", frostyState())

    -- High stars for rank display (local only, does not replicate)
    LocalPlayer:SetAttribute("Stars", 19000)

    -- Mannequin mode (salon access)
    LocalPlayer:SetAttribute("MannequinMode", true)

    -- Diamonds (cosmetic, for UI display)
    if not LocalPlayer:GetAttribute("Diamonds") or LocalPlayer:GetAttribute("Diamonds") < 99999 then
        LocalPlayer:SetAttribute("Diamonds", 99999)
    end

    -- Rerolls
    LocalPlayer:SetAttribute("Rerolls", 999)

    -- Theme tokens
    LocalPlayer:SetAttribute("ThemeTokens", 99)

    -- Extra wardrobe / lookbook slots
    LocalPlayer:SetAttribute("LookbookExtra", 500)

    applying = false
end

-------------------------------------------------------------------------------
-- 4) WATCH FOR SERVER REWRITES — re-apply on every attribute change
-------------------------------------------------------------------------------
local watched = {
    "Owned", "VIP", "StarterOwned", "FrostyPass", "Stars",
    "MannequinMode", "Diamonds", "Rerolls", "ThemeTokens", "LookbookExtra"
}
for _, pass in ipairs(Store.PASSES) do
    watched[#watched + 1] = Store.attr(pass.key)
end

for _, name in ipairs(watched) do
    pcall(function()
        LocalPlayer:GetAttributeChangedSignal(name):Connect(function()
            task.defer(apply)
        end)
    end)
end

-------------------------------------------------------------------------------
-- 5) PATCH CLIENT-SIDE OWNERSHIP FUNCTIONS
--    These are the gates the UI checks. Returning true removes all lock icons,
--    enables selection, and lets the editor accept the item.
-------------------------------------------------------------------------------
local function yes() return true end
local function no() return false end

-- Shops module — the central ownership API
Shops.ownsTop = yes
Shops.ownsPack = yes
Shops.ownsFx = yes
Shops.ownsItem = yes
Shops.isTaster = no  -- Hide "taster/trial" badges — you own it outright

-- Store module helpers
Store.isPaid = function() return false end           -- Nothing is "paid" anymore
Store.isDropOnly = function() return false end        -- Nothing is drop-only gated
Store.isFreeTop = yes                                 -- Everything is free
Store.isVipTop = function() return false end          -- Don't gate on VIP check
Store.isTaster = no                                   -- No taster items
Store.hasSalon = yes                                  -- Salon always available
Store.isTester = yes                                  -- Tester access for all features
Store.dressesOpen = yes                               -- All dresses available
Store.boutiqueOpen = yes                              -- Boutique always open

-- Frosty pass — always preview, always available
Store.frostyPreview = yes
if Store.isFrostyItem then
    Store.isFrostyItem = function() return false end  -- Not gated as frosty-only
end
if Store.isFrostyTop then
    Store.isFrostyTop = function() return false end
end

-- Config flags — enable all features
Config.DRESSES_LIVE = true
Config.FROSTY_PASS_LIVE = true
Config.STUDIO_UNLOCK_PACKS = true
if Config.FRINGE_LIVE ~= nil then Config.FRINGE_LIVE = true end
if Config.DRAPE_LIVE ~= nil then Config.DRAPE_LIVE = true end
if Config.EDITOR_V2_LIVE ~= nil then Config.EDITOR_V2_LIVE = true end
if Config.GLOSS_LIVE ~= nil then Config.GLOSS_LIVE = true end

-- Mannequin — enable salon for this player
if Mannequin then
    Mannequin.ENABLED = true
    Mannequin.isTester = yes
    Mannequin.isOn = yes
end

-- Detail limits — VIP limits for everyone
if Details and Details.MAX_VIP then
    Details.MAX_FREE = Details.MAX_VIP
end

-------------------------------------------------------------------------------
-- 6) INITIAL APPLY
-------------------------------------------------------------------------------
apply()

-- Summary
local passCount = #Store.PASSES
local itemCount = #keys
print(string.format("[unlock-all] %d items, %d passes, VIP, Salon, Frosty Pass, all features enabled", itemCount, passCount))
print("[unlock-all] NOTE: Other players see what the server grants. Your editor is fully unlocked.")
