-- Client-side unlock-all. Local only: what you see in your own editor/shop UI.
-- The server keeps its own ownership list and does not read these values.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClientModules = ReplicatedStorage:WaitForChild("ClientModules")

local Store = require(Shared:WaitForChild("Store"))
local DressShapes = require(Shared:WaitForChild("DressShapes"))
local Shops = require(ClientModules:WaitForChild("Shops"))

local keys, seen = {}, {}
local function add(k)
	if k and not seen[k] then
		seen[k] = true
		table.insert(keys, k)
	end
end

for name in pairs(DressShapes.BODICES or {}) do add("top:" .. tostring(name)) end
for _, list in ipairs({ Store.FREE_TOPS, Store.VIP_TOPS, Store.FROSTY_TOPS, Store.TEST_TOPS,
	Store.NOV_SKIRTS_FREE, Store.NOV_SKIRTS_SHOP }) do
	for _, t in ipairs(list or {}) do add("top:" .. t) end
end
for _, b in ipairs(Store.BOUTIQUE or {}) do add(b.kind .. ":" .. tostring(b.id)) end
for _, p in ipairs(Store.DETAIL_PACKS or {}) do
	add("pack:" .. p.key)
	for _, d in ipairs(p.details or {}) do add("detail:" .. d) end
end
for _, fx in ipairs(Store.RUNWAY_FX or {}) do add("fx:" .. fx.key) end
for _, tbl in ipairs({ Store.PAID, Store.DROP_ONLY, Store.FROSTY_ITEMS }) do
	for kind, list in pairs(tbl or {}) do
		for _, id in ipairs(list) do add(kind .. ":" .. tostring(id)) end
	end
end
for _, drop in ipairs(Store.DROPS or {}) do
	for _, k in ipairs(drop.items or {}) do add(k) end
end
for _, grant in pairs(Store.GRANTS or {}) do
	for _, k in ipairs(grant) do add(k) end
end

local OWNED = table.concat(keys, ",")

local function frostyState()
	local ok, cur = pcall(HttpService.JSONDecode, HttpService, LocalPlayer:GetAttribute("FrostyPass") or "")
	cur = (ok and type(cur) == "table") and cur or {}
	cur.vip = true
	cur.xp = math.max(tonumber(cur.xp) or 0, 1e6)
	return HttpService:JSONEncode(cur)
end

local applying = false
local function apply()
	if applying then return end
	applying = true
	LocalPlayer:SetAttribute("Owned", OWNED)
	LocalPlayer:SetAttribute("VIP", true)
	LocalPlayer:SetAttribute("StarterOwned", true)
	for _, pass in ipairs(Store.PASSES) do
		LocalPlayer:SetAttribute(Store.attr(pass.key), true)
	end
	LocalPlayer:SetAttribute("FrostyPass", frostyState())
	applying = false
end

-- Server replication overwrites these whenever it updates them; put them back.
local watched = { "Owned", "VIP", "StarterOwned", "FrostyPass" }
for _, pass in ipairs(Store.PASSES) do table.insert(watched, Store.attr(pass.key)) end
for _, name in ipairs(watched) do
	LocalPlayer:GetAttributeChangedSignal(name):Connect(function()
		task.defer(apply)
	end)
end

-- Shops' own internal calls go through its local `owned` upvalue (covered by the
-- attribute), external callers go through the table — patch both paths.
local yes = function() return true end
Shops.ownsTop, Shops.ownsPack, Shops.ownsFx, Shops.ownsItem = yes, yes, yes, yes
Shops.isTaster = function() return false end
Store.isFreeTop = function(top) return DressShapes.BODICES[top] ~= nil or table.find(Store.FREE_TOPS, top) ~= nil end
Store.hasSalon = yes
Store.frostyPreview = yes

apply()
print(("[unlock] %d items, %d passes"):format(#keys, #Store.PASSES))
