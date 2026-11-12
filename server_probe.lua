--[[
    Server Behaviour Prober + Learning Dumper  (Place 118756480494489)
    ──────────────────────────────────────────────────────────────────
    Server scripts are NOT on the client and cannot be dumped. What this
    does instead is map what the server ENFORCES vs TRUSTS, so you know
    whether a paid look can be made visible to other players.

    Method (the only honest one):
      1. Hook every RemoteEvent/RemoteFunction under ReplicatedStorage.Remotes.
      2. Passively capture REAL payloads while you play normally — those are
         ground-truth schemas, the hardest thing to guess.
      3. Active replay: take a captured-valid payload, change ONLY an item id
         to a paid one, re-fire it, then read back the server-visible state
         (WornB/WornN/WornV + Mannequin "ops"). If the paid content survives
         and is served back through the path other clients read, others will
         see it. If it's stripped/rejected, that's ownership enforcement.

    LEARNING: everything observed is merged into a persistent knowledge base
    on disk (hf_probe/knowledge.json). Every run — success OR failure — loads
    the prior knowledge, adds what it learned (schemas, id fields, reply
    shapes, rejection reasons, timings), and writes it back. A failed probe
    still advances the next run: you keep the schema, the reply, and the
    reason it bounced. Nothing learned is ever lost, even on a mid-run error.

    Safety: the active replay NEVER fires purchase/currency remotes
    (Store prompt/diamonds/gift/subscription). Only free design/outfit/style
    remotes are replayed. Read-only enumeration runs on load; the paid-swap
    replay runs on a keybind so you control timing.
]]

--==[ 0. ENVIRONMENT / EXECUTOR FEATURE DETECTION ]============================
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

-- Guarded executor API: every function is optional. We degrade, never crash.
local EXEC = {
    hookmeta   = rawget(getfenv(), "hookmetamethod") or hookmetamethod,
    getnamecall= rawget(getfenv(), "getnamecallmethod") or getnamecallmethod,
    newcc      = rawget(getfenv(), "newcclosure") or function(f) return f end,
    checkcaller= rawget(getfenv(), "checkcaller") or function() return false end,
    writefile  = rawget(getfenv(), "writefile") or writefile,
    readfile   = rawget(getfenv(), "readfile") or readfile,
    isfile     = rawget(getfenv(), "isfile") or isfile,
    appendfile = rawget(getfenv(), "appendfile") or appendfile,
    makefolder = rawget(getfenv(), "makefolder") or makefolder,
    isfolder   = rawget(getfenv(), "isfolder") or isfolder,
    listfiles  = rawget(getfenv(), "listfiles") or listfiles,
    delfile    = rawget(getfenv(), "delfile") or delfile,
    -- zip APIs differ per executor; try them all later
    zip        = rawget(getfenv(), "zip"),
    writezip   = rawget(getfenv(), "writezip"),
    compress   = rawget(getfenv(), "compressfiles") or rawget(getfenv(), "zipfiles"),
}

local CAN_FS = EXEC.writefile and EXEC.makefolder and true or false
local DIR = "hf_probe"

local function fsSafe(fn, ...)
    if not fn then return false end
    local ok, res = pcall(fn, ...)
    return ok, res
end

if CAN_FS then
    if EXEC.isfolder and not select(2, fsSafe(EXEC.isfolder, DIR)) then
        fsSafe(EXEC.makefolder, DIR)
    else
        fsSafe(EXEC.makefolder, DIR)
    end
end

--==[ 1. SAFE SERIALIZER ]=====================================================
-- Converts arbitrary Luau values (tables, Instances, Roblox datatypes, cyclic
-- refs) into plain tables that JSONEncode can handle. Capped depth + width.
local MAX_DEPTH, MAX_KEYS, MAX_STR = 8, 200, 4000

local function ser(v, depth, seen)
    depth = depth or 0
    local t = typeof(v)
    if t == "string" then
        if #v > MAX_STR then return v:sub(1, MAX_STR) .. ("…(+%d)"):format(#v - MAX_STR) end
        return v
    elseif t == "number" or t == "boolean" or t == "nil" then
        return v
    elseif t == "Instance" then
        return { __t = "Instance", class = v.ClassName, path = v:GetFullName() }
    elseif t == "Vector3" then return { __t = "Vector3", v.X, v.Y, v.Z }
    elseif t == "Vector2" then return { __t = "Vector2", v.X, v.Y }
    elseif t == "Color3"  then return { __t = "Color3", v:ToHex() }
    elseif t == "CFrame"  then return { __t = "CFrame", v.Position.X, v.Position.Y, v.Position.Z }
    elseif t == "UDim2"   then return { __t = "UDim2", v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset }
    elseif t == "EnumItem" then return { __t = "Enum", tostring(v) }
    elseif t == "buffer" then
        local ok, s = pcall(buffer.tostring, v)
        return { __t = "buffer", len = (ok and #s or -1) }
    elseif t == "table" then
        if depth >= MAX_DEPTH then return "…(maxdepth)" end
        seen = seen or {}
        if seen[v] then return "…(cycle)" end
        seen[v] = true
        local out, n = {}, 0
        for k, val in pairs(v) do
            n += 1
            if n > MAX_KEYS then out["__truncated"] = true; break end
            local sk = (type(k) == "string" or type(k) == "number") and k or tostring(k)
            out[tostring(sk)] = ser(val, depth + 1, seen)
        end
        seen[v] = nil
        return out
    else
        return { __t = t, s = tostring(v) }
    end
end

local function jenc(tbl)
    local ok, s = pcall(function() return HttpService:JSONEncode(tbl) end)
    return ok and s or ("{\"__encode_error\":true}")
end
local function jdec(str)
    local ok, t = pcall(function() return HttpService:JSONDecode(str) end)
    return ok and t or nil
end

--==[ 2. PERSISTENT KNOWLEDGE BASE ]===========================================
-- Loaded at start, written after EVERY learned fact. This is what makes a
-- failed run still pay off: schemas/replies/reasons survive to the next run.
local KB = {
    meta     = { place = game.PlaceId, job = game.JobId, runs = 0, firstSeen = os.time() },
    remotes  = {},   -- [name] = {class, path, calls, lastArgs, lastReply}
    schemas  = {},   -- [sig]  = {op, fields, idFields, samples={}}
    idCatalog= { all = {}, paid = {}, byKind = {} },
    probes   = {},   -- replay results, each with verdict + reason
    findings = {},   -- derived conclusions for the next version
}

local KB_PATH = DIR .. "/knowledge.json"

local function loadKB()
    if not (CAN_FS and EXEC.isfile) then return end
    local ok, exists = fsSafe(EXEC.isfile, KB_PATH)
    if ok and exists then
        local ok2, raw = fsSafe(EXEC.readfile, KB_PATH)
        if ok2 and raw then
            local prior = jdec(raw)
            if type(prior) == "table" then
                -- merge prior into KB (prior is the accumulated memory)
                for _, key in ipairs({ "remotes", "schemas", "probes", "findings" }) do
                    if type(prior[key]) == "table" then
                        for k, v in pairs(prior[key]) do KB[key][k] = v end
                    end
                end
                if prior.meta then
                    KB.meta.runs = tonumber(prior.meta.runs) or 0
                    KB.meta.firstSeen = prior.meta.firstSeen or KB.meta.firstSeen
                end
            end
        end
    end
end

local _flushQueued = false
local function flushKB()
    if not CAN_FS then return end
    if _flushQueued then return end
    _flushQueued = true
    task.defer(function()
        _flushQueued = false
        fsSafe(EXEC.writefile, KB_PATH, jenc(KB))
    end)
end

-- Learn a single fact and persist immediately-ish (debounced).
local function learn(category, key, value)
    KB[category] = KB[category] or {}
    KB[category][key] = value
    flushKB()
end

--==[ 3. CATALOG: KNOWN IDS + WHICH ARE PAID ]=================================
-- Needed so the replay knows which fields are item ids and which ids are paid
-- (the swap target). Built from the client Store module.
local Store, DressShapes
do
    local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
    local ok1, s = pcall(require, Shared:WaitForChild("Store", 10)); Store = ok1 and s
    local ok2, d = pcall(require, Shared:WaitForChild("DressShapes", 10)); DressShapes = ok2 and d
end

local function regId(kind, id, paid)
    if type(id) ~= "string" and type(id) ~= "number" then return end
    id = tostring(id)
    KB.idCatalog.all[id] = kind
    KB.idCatalog.byKind[kind] = KB.idCatalog.byKind[kind] or {}
    table.insert(KB.idCatalog.byKind[kind], id)
    if paid then KB.idCatalog.paid[id] = kind end
end

if Store then
    for _, t in ipairs(Store.FREE_TOPS or {}) do regId("top", t, false) end
    for _, t in ipairs(Store.VIP_TOPS or {}) do regId("top", t, true) end
    for _, t in ipairs(Store.FROSTY_TOPS or {}) do regId("top", t, true) end
    if DressShapes then for name in pairs(DressShapes.BODICES or {}) do regId("top", name, false) end end
    for kind, list in pairs(Store.PAID or {}) do
        for _, id in ipairs(list) do regId(kind, id, true) end
    end
    for _, p in ipairs(Store.DETAIL_PACKS or {}) do
        for _, d in ipairs(p.details or {}) do regId("detail", d, true) end
    end
    for _, fx in ipairs(Store.RUNWAY_FX or {}) do regId("fx", fx.key, true) end
end

-- Pick a paid id of a given kind to swap in (prefers one; records the choice).
local function paidIdOfKind(kind)
    for id, k in pairs(KB.idCatalog.paid) do
        if k == kind then return id end
    end
    return nil
end

--==[ 4. REMOTE ENUMERATION ]==================================================
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
local function enumerateRemotes()
    if not Remotes then
        learn("findings", "remotesFolder", "MISSING — ReplicatedStorage.Remotes not found")
        return
    end
    for _, r in ipairs(Remotes:GetDescendants()) do
        if r:IsA("RemoteEvent") or r:IsA("RemoteFunction") or r:IsA("UnreliableRemoteEvent") then
            KB.remotes[r.Name] = KB.remotes[r.Name] or {}
            local rec = KB.remotes[r.Name]
            rec.class = r.ClassName
            rec.path = r:GetFullName()
            rec.calls = rec.calls or 0
        end
    end
    flushKB()
end

--==[ 5. TRAFFIC HOOK — capture every call + return, both directions ]=========
-- Signature of a call keyed by remote name + first-arg op string, so schemas
-- are grouped per operation ("set", "outfit", "ops", ...).
local function sigFor(name, args)
    local op = (type(args[1]) == "string") and args[1] or "_"
    return name .. ":" .. op
end

-- Walk a payload and tag which fields hold known catalog ids — this is the map
-- the replay uses to know WHERE to inject a paid id next time.
local function scanIdFields(value, path, out)
    path = path or "$"
    out = out or {}
    local t = type(value)
    if t == "string" or t == "number" then
        local id = tostring(value)
        local kind = KB.idCatalog.all[id]
        if kind then out[path] = { id = id, kind = kind, paid = KB.idCatalog.paid[id] ~= nil } end
    elseif t == "table" then
        for k, v in pairs(value) do
            if type(k) == "string" or type(k) == "number" then
                scanIdFields(v, path .. "." .. tostring(k), out)
            end
        end
    end
    return out
end

local function recordCall(name, args, reply)
    local rec = KB.remotes[name]
    if not rec then
        rec = { class = "?", calls = 0 }
        KB.remotes[name] = rec
    end
    rec.calls = (rec.calls or 0) + 1
    rec.lastArgs = ser(args)
    if reply ~= nil then rec.lastReply = ser(reply) end
    rec.lastSeen = os.time()

    local sig = sigFor(name, args)
    local sch = KB.schemas[sig] or { op = (type(args[1]) == "string" and args[1] or "_"), samples = {}, seenCount = 0 }
    sch.seenCount = (sch.seenCount or 0) + 1
    -- keep the latest valid sample as the schema template
    sch.template = ser(args)
    -- map id-bearing fields across all args
    local idmap = {}
    for i = 1, #args do scanIdFields(args[i], "$[" .. i .. "]", idmap) end
    sch.idFields = idmap
    if #sch.samples < 3 then table.insert(sch.samples, ser(args)) end
    KB.schemas[sig] = sch
    flushKB()

    return sig, sch
end

-- The captured-valid payload store, in-memory, keyed by sig — raw (not
-- serialized) so the replay can re-send a real table.
local CAPTURED = {}

local hookInstalled = false
local function installHook()
    if hookInstalled or not EXEC.hookmeta then return false end
    local mt = getrawmetatable and getrawmetatable(game)
    local oldNamecall
    local ok = pcall(function()
        oldNamecall = EXEC.hookmeta(game, "__namecall", EXEC.newcc(function(self, ...)
            local args = { ... }
            local method = EXEC.getnamecall and EXEC.getnamecall() or ""
            local isRemote = (self and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction") or self:IsA("UnreliableRemoteEvent")))
            local isFire = (method == "FireServer" or method == "InvokeServer")
            if isRemote and isFire and self:IsDescendantOf(Remotes or ReplicatedStorage) then
                local name = self.Name
                -- store a raw copy of the real valid payload for replay
                CAPTURED[sigFor(name, args)] = { remote = self, args = args, method = method }
                if method == "InvokeServer" then
                    local reply = { oldNamecall(self, ...) }
                    pcall(recordCall, name, args, reply[1])
                    return table.unpack(reply)
                else
                    pcall(recordCall, name, args, nil)
                    return oldNamecall(self, ...)
                end
            end
            return oldNamecall(self, ...)
        end))
    end)
    hookInstalled = ok
    learn("findings", "trafficHook", ok and "installed" or "FAILED — executor lacks hookmetamethod/namecall")
    return ok
end

--==[ 6. READ-BACK: what the server actually stored / serves to others ]=======
-- WornB/N/V live on the character model; "ops" is the path every other client
-- reads. If paid content shows up here, other players will render it.
local function readServerVisibleState()
    local state = { worn = {}, opsServed = nil }
    local char = LocalPlayer.Character
    if char then
        for _, a in ipairs({ "WornB", "WornN", "WornV", "WornFitted" }) do
            state.worn[a] = char:GetAttribute(a)
        end
    end
    local mq = Remotes and Remotes:FindFirstChild("Mannequin")
    if mq and mq:IsA("RemoteFunction") then
        local ok, res = pcall(function() return mq:InvokeServer("ops", LocalPlayer.UserId, 1) end)
        if ok then state.opsServed = ser(res) end
    end
    return state
end

--==[ 7. ACTIVE REPLAY WITH PAID SUBSTITUTION ]================================
-- NEVER replay currency/purchase remotes.
local REPLAY_BLOCKLIST = { Store = true, RoundShop = true, GroupGift = true, Daily = true, Gift = true }

-- Deep-clone a captured table and swap the first free-id field for a paid id
-- of the same kind. Returns the mutated args + a description of what changed.
local function mutatePaid(args, idFields)
    local clone
    local function cp(v)
        if type(v) ~= "table" then return v end
        local o = {}
        for k, val in pairs(v) do o[k] = cp(val) end
        return o
    end
    clone = cp(args)

    -- find a field that currently holds a FREE id we can bump to PAID
    for path, info in pairs(idFields) do
        if not info.paid then
            local target = paidIdOfKind(info.kind)
            if target then
                -- path looks like $[i].a.b — walk and set
                local i = tonumber(path:match("%$%[(%d+)%]"))
                local rest = path:gsub("%$%[%d+%]", "")
                local node = clone[i]
                local keys = {}
                for seg in rest:gmatch("[^.]+") do table.insert(keys, seg) end
                if #keys == 0 then
                    clone[i] = target
                else
                    for j = 1, #keys - 1 do
                        node = node and node[keys[j]] or node[tonumber(keys[j])]
                    end
                    if node then
                        local lk = keys[#keys]
                        node[lk] = target; node[tonumber(lk) or lk] = target
                    end
                end
                return clone, { path = path, from = info.id, to = target, kind = info.kind }
            end
        end
    end
    return clone, nil
end

local probeCounter = 0
local function runPaidReplay()
    probeCounter += 1
    local pid = "probe_" .. probeCounter .. "_" .. os.time()
    local result = { id = pid, t = os.time(), attempts = {} }

    local before = readServerVisibleState()
    result.before = before

    local any = false
    for sig, cap in pairs(CAPTURED) do
        local name = cap.remote and cap.remote.Name
        if name and not REPLAY_BLOCKLIST[name] then
            local sch = KB.schemas[sig]
            local idFields = sch and sch.idFields or {}
            if next(idFields) then
                any = true
                local mutated, change = mutatePaid(cap.args, idFields)
                local attempt = { sig = sig, remote = name, method = cap.method, change = change }
                if change then
                    local ok, reply = pcall(function()
                        if cap.method == "InvokeServer" then
                            return cap.remote:InvokeServer(table.unpack(mutated))
                        else
                            cap.remote:FireServer(table.unpack(mutated))
                            return "(fired, no return)"
                        end
                    end)
                    attempt.ok = ok
                    attempt.reply = ser(reply)
                    task.wait(0.35) -- let the server settle + replicate
                    attempt.after = readServerVisibleState()
                    -- verdict: did the paid id survive into server-visible state?
                    local served = jenc(attempt.after)
                    attempt.paidSurvived = change and served:find(tostring(change.to), 1, true) ~= nil
                    attempt.verdict = attempt.paidSurvived and "ACCEPTED(others-will-see)"
                        or (ok and "STRIPPED-OR-REJECTED") or "ERROR"
                else
                    attempt.verdict = "NO-FREE-ID-TO-SWAP"
                end
                table.insert(result.attempts, attempt)
                learn("probes", pid, ser(result)) -- persist after EVERY attempt
            end
        end
    end

    if not any then
        result.note = "No captured payloads with id fields yet. Equip/submit items in-game first, then re-run (press K)."
    end

    -- derive a forward-looking conclusion for the next version
    local conclusion = { t = os.time(), accepted = {}, blocked = {}, needsCapture = {} }
    for _, a in ipairs(result.attempts) do
        if a.verdict:find("ACCEPTED") then table.insert(conclusion.accepted, a.remote .. ":" .. (a.change and a.change.kind or "?"))
        elseif a.verdict:find("STRIPPED") then table.insert(conclusion.blocked, a.remote .. ":" .. (a.change and a.change.kind or "?")) end
    end
    for name in pairs(KB.remotes) do
        if not REPLAY_BLOCKLIST[name] then
            local seen = false
            for sig in pairs(CAPTURED) do if sig:find(name, 1, true) == 1 then seen = true break end end
            if not seen then table.insert(conclusion.needsCapture, name) end
        end
    end
    learn("findings", "lastReplayConclusion", conclusion)
    flushKB()
    return result
end

--==[ 8. DUMP + ZIP ]==========================================================
local function dumpAll()
    if not CAN_FS then
        warn("[probe] No filesystem API — printing KB to console instead.")
        print(jenc(KB))
        return
    end
    fsSafe(EXEC.writefile, DIR .. "/knowledge.json", jenc(KB))
    fsSafe(EXEC.writefile, DIR .. "/remotes.json", jenc(KB.remotes))
    fsSafe(EXEC.writefile, DIR .. "/schemas.json", jenc(KB.schemas))
    fsSafe(EXEC.writefile, DIR .. "/probes.json", jenc(KB.probes))
    fsSafe(EXEC.writefile, DIR .. "/findings.json", jenc(KB.findings))
    fsSafe(EXEC.writefile, DIR .. "/idcatalog.json", jenc(KB.idCatalog))

    -- human-readable report
    local rep = {}
    local function line(s) table.insert(rep, s) end
    line("HF SERVER PROBE — RUN " .. (KB.meta.runs))
    line(("Place %s  Job %s"):format(tostring(game.PlaceId), tostring(game.JobId)))
    line(("Remotes known: %d"):format((function() local n=0 for _ in pairs(KB.remotes) do n+=1 end return n end)()))
    line(("Schemas captured: %d"):format((function() local n=0 for _ in pairs(KB.schemas) do n+=1 end return n end)()))
    line("")
    line("REMOTES:")
    for name, r in pairs(KB.remotes) do
        line(("  %-18s %-16s calls=%s"):format(name, r.class or "?", tostring(r.calls or 0)))
    end
    line("")
    line("CAPTURED SCHEMAS (op + id fields found):")
    for sig, s in pairs(KB.schemas) do
        local idn = 0; for _ in pairs(s.idFields or {}) do idn += 1 end
        line(("  %-28s samples=%s idFields=%d"):format(sig, tostring(s.seenCount or 0), idn))
    end
    line("")
    line("FINDINGS FOR NEXT VERSION:")
    line(jenc(KB.findings))
    fsSafe(EXEC.writefile, DIR .. "/REPORT.txt", table.concat(rep, "\n"))

    -- try to zip. APIs vary; attempt each, fall back to a single bundle file.
    local zipped = false
    local files = { "knowledge.json","remotes.json","schemas.json","probes.json","findings.json","idcatalog.json","REPORT.txt" }
    if EXEC.writezip then
        local paths = {}
        for _, f in ipairs(files) do table.insert(paths, DIR .. "/" .. f) end
        zipped = fsSafe(EXEC.writezip, DIR .. "/hf_probe_dump.zip", paths)
    end
    if not zipped and EXEC.compress then
        zipped = fsSafe(EXEC.compress, DIR .. "/hf_probe_dump.zip", DIR)
    end
    if not zipped and EXEC.zip then
        zipped = fsSafe(EXEC.zip, DIR, DIR .. "/hf_probe_dump.zip")
    end
    if not zipped then
        -- no zip API: produce one consolidated bundle so you still get a single artifact
        fsSafe(EXEC.writefile, DIR .. "/hf_probe_bundle.json", jenc({
            readme = "Executor has no zip API; this single file bundles everything.",
            knowledge = KB,
        }))
        warn("[probe] No zip API on this executor — wrote hf_probe/hf_probe_bundle.json instead.")
    else
        print("[probe] Zipped to hf_probe/hf_probe_dump.zip")
    end
end

--==[ 9. BOOT ]===============================================================
loadKB()
KB.meta.runs = (KB.meta.runs or 0) + 1
enumerateRemotes()
installHook()
flushKB()

-- Read-only enumeration finished on load. Active replay + dump on keybind so
-- you choose when (after you've equipped/submitted items to capture schemas).
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.K then
        print("[probe] Running paid-substitution replay…")
        local res = runPaidReplay()
        print(jenc(ser(res)))
        dumpAll()
    elseif input.KeyCode == Enum.KeyCode.J then
        print("[probe] Dumping knowledge base…")
        dumpAll()
    end
end)

-- Safety net: if the script errors or the session ends, still flush what we
-- learned so a failed run advances the next one.
game:BindToClose and pcall(game.BindToClose, game, function() flushKB(); dumpAll() end)
task.spawn(function()
    while true do task.wait(20); flushKB() end -- periodic autosave of learnings
end)

print(("[probe] ready. run #%d. hook=%s fs=%s"):format(
    KB.meta.runs, tostring(hookInstalled), tostring(CAN_FS)))
print("[probe]  • Play normally to capture real payloads (auto).")
print("[probe]  • Press K to replay captured payloads with a PAID id swapped + dump.")
print("[probe]  • Press J to dump/zip the knowledge base any time.")
print("[probe]  Everything learned persists to hf_probe/knowledge.json — failures included.")
