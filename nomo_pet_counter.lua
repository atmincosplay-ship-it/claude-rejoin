--========================================================--
--                    NOMO PET COUNTER
--       v3.9 RELEASE DATA COUNTS
--========================================================--
-- Writes per-account state to:
--   nomo_rejoiner/<username>_state.json
--
-- v3.4:
-- - EGG CATALOG: Reads the full egg-name catalog from Grow a Garden registry
--                modules and keeps every egg key in state, including count 0.
-- - STABLE CLOUD DATA: Egg names no longer disappear from Cloudflare when an
--                      account temporarily owns zero of that egg.
-- - SAFE FALLBACK: Observed inventory egg names and Config.ExtraEggNames are
--                  merged into the catalog and never removed during runtime.
--
-- v3.3:
-- - CHANGE: Sends two edge clicks by default: the first after game.Loaded +
--           5 seconds, then one more 10 seconds later.
-- - SAFE: Alternates bottom-right and bottom-left, with no UI scan or watcher.
-- - CONFIG: LoadingClickCount can be set to 1-5; default is 2.
--
-- v3.2:
-- - PERF: Removed repeated PlayerGui/GetDescendants loading-screen scanning.
-- - CHANGE: Replaced prompt detection with a fixed delayed edge click.
--========================================================--

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local CoreGui = game:GetService("CoreGui")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = nil
pcall(function()
    VirtualInputManager = game:GetService("VirtualInputManager")
end)

local DataService = nil
local function getDataService()
    if DataService then
        return DataService
    end

    pcall(function()
        local modules = ReplicatedStorage:WaitForChild("Modules", 20)
        local dataServiceModule = modules and modules:WaitForChild("DataService", 10)
        if dataServiceModule then
            DataService = require(dataServiceModule)
        end
    end)

    return DataService
end

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

--========================================================--
-- Stop old counter loop if this is re-executed
--========================================================--

do
    local oldNew = getgenv().NOMO_PET_COUNTER
    local oldLegacy = getgenv().NOMO_GAG_COUNTER
    for _, old in ipairs({oldNew, oldLegacy}) do
        if type(old) == "table" then
            old.Enabled = false
            old.Stop = true
        end
    end
    task.wait(0.35)
end

getgenv().NOMO_PET_COUNTER = getgenv().NOMO_PET_COUNTER or {}
-- Keep the legacy name as an alias for old one-line loaders/config snippets.
getgenv().NOMO_GAG_COUNTER = getgenv().NOMO_PET_COUNTER

local Config = getgenv().NOMO_PET_COUNTER

Config.Enabled = true
Config.Stop = false
Config.Version = "v3.9-release-data-counts"

Config.WriteFolder = Config.WriteFolder or "nomo_rejoiner"

-- Per-username state file so multiple clones can share one executor workspace
-- folder without overwriting each other's state.json.
-- Sanitize the username to a safe filename (letters/digits/_ only).
local function sanitizeName(s)
    s = tostring(s or "")
    s = string.gsub(s, "[^%w_]", "_")
    if s == "" then s = "unknown" end
    return s
end

local _safeUser = sanitizeName(LocalPlayer.Name)
Config.WriteFile = Config.WriteFile or (Config.WriteFolder .. "/" .. _safeUser .. "_state.json")

-- Scan fast, write light.
Config.ScanEvery = tonumber(Config.ScanEvery or 2) or 2
Config.WriteEvery = tonumber(Config.WriteEvery or 5) or 5

Config.Debug = Config.Debug == true
Config.Verbose = Config.Verbose == true

-- Keep false. This popup text can appear on working Roblox too.
Config.TreatGenericPopupAsDisconnect = Config.TreatGenericPopupAsDisconnect == true

-- Pet name fuzzy matching (age/kg). ON by default. Set false to count only
-- items with a real pet attribute (PetType/PET_UUID/etc) — more accurate if
-- you ever see pet over-counting from weighted fruit or similar.
if Config.FuzzyPetNameMatch == nil then
    Config.FuzzyPetNameMatch = true
end

-- Grow a Garden loading splash helper — zero-scan mode.
-- It waits for Roblox game.Loaded, sends one delayed edge click, then sends one
-- more edge click after a fixed interval. It never searches PlayerGui and never
-- watches the UI continuously.
if Config.AutoSkipLoadingScreen == nil then
    Config.AutoSkipLoadingScreen = true
end
Config.LoadingClickDelay = math.max(0, tonumber(Config.LoadingClickDelay or 5) or 5)
Config.LoadingClickInterval = math.max(1, tonumber(Config.LoadingClickInterval or 10) or 10)
Config.LoadingClickCount = math.clamp(math.floor(tonumber(Config.LoadingClickCount or 2) or 2), 1, 5)
Config.LoadingClickSide = string.lower(tostring(Config.LoadingClickSide or "right"))
if Config.LoadingClickSide ~= "left" then
    Config.LoadingClickSide = "right"
end
if Config.LoadingAlternateSides == nil then
    Config.LoadingAlternateSides = true
end

-- Edge-click ratios. Kept slightly inside the actual edge so Android gesture /
-- navigation zones do not swallow the click.
Config.LoadingRightX = tonumber(Config.LoadingRightX or 0.94) or 0.94
Config.LoadingLeftX = tonumber(Config.LoadingLeftX or 0.06) or 0.06
Config.LoadingBottomY = tonumber(Config.LoadingBottomY or 0.88) or 0.88

-- Stable egg catalog. The full registry is read occasionally, then every
-- discovered egg name is retained for the rest of the session. This means the
-- `eggs` JSON object always includes zero-count entries instead of making an
-- egg disappear when the account owns none.
if Config.IncludeZeroCountEggs == nil then
    Config.IncludeZeroCountEggs = true
end
Config.EggCatalogRefreshSeconds = math.max(60, tonumber(Config.EggCatalogRefreshSeconds or 600) or 600)
Config.EggCatalogRetrySeconds = math.max(5, tonumber(Config.EggCatalogRetrySeconds or 15) or 15)
if type(Config.ExtraEggNames) ~= "table" then
    Config.ExtraEggNames = {}
end

--========================================================--
-- File helpers
--========================================================--

local function hasFileAPI()
    return type(writefile) == "function"
end

local function safeMakeFolder(folder)
    if not hasFileAPI() then
        return false, "writefile not available"
    end

    pcall(function()
        if type(isfolder) == "function" then
            if not isfolder(folder) then
                makefolder(folder)
            end
        elseif type(makefolder) == "function" then
            makefolder(folder)
        end
    end)

    return true
end

local function safeWrite(path, text)
    if not hasFileAPI() then
        return false, "writefile not available"
    end

    -- Atomic write: write to a temp file, then rename over the target so the
    -- harness never reads a half-written (corrupt) file. This prevents the
    -- truncated state.json artifacts and false "missing state" rejoins.
    local tmp = path .. ".tmp"
    local ok, err = pcall(function()
        writefile(tmp, text)
    end)

    if not ok then
        -- Fallback to direct write if temp write failed.
        local ok2, err2 = pcall(function()
            writefile(path, text)
        end)
        if not ok2 then
            return false, tostring(err2 or err)
        end
        return true
    end

    -- Rename temp -> target. Not all executors expose a rename; fall back to
    -- read-temp + write-target + delete-temp if needed.
    local renamed = false
    if type(getgenv().nomo_renamefile) == "function" then
        renamed = pcall(function() getgenv().nomo_renamefile(tmp, path) end)
    end

    if not renamed then
        -- Manual "rename": copy temp content to target, then remove temp.
        local ok3 = pcall(function()
            local data = readfile(tmp)
            writefile(path, data)
        end)
        pcall(function()
            if type(delfile) == "function" then
                delfile(tmp)
            end
        end)
        if not ok3 then
            return false, "atomic write failed"
        end
    end

    return true
end

--========================================================--
-- Basic helpers
--========================================================--

-- Minimum plausible Unix epoch (2020-09-13). Anything below this is treated as
-- a broken/stubbed clock, NOT a real timestamp.
local MIN_VALID_EPOCH = 1600000000

-- Robust Unix-epoch clock. Some Android executors (e.g. Arceus X) stub os.time()
-- so it returns 0, which made state files carry ts=0. The harness then computed
-- age = now - 0 -> its 999999s sentinel, shown as a phantom "277h", and hard
-- kill+open looped forever. We now try several real-epoch sources and only
-- accept a value that is actually a plausible Unix timestamp.
local function unixNow()
    -- 1) os.time() — correct on most executors.
    local ok, t = pcall(os.time)
    if ok and type(t) == "number" and t >= MIN_VALID_EPOCH then
        return math.floor(t)
    end

    -- 2) DateTime.now().UnixTimestamp — real epoch, rarely stubbed.
    local ok2, t2 = pcall(function()
        return DateTime.now().UnixTimestamp
    end)
    if ok2 and type(t2) == "number" and t2 >= MIN_VALID_EPOCH then
        return math.floor(t2)
    end

    -- 3) tick() — deprecated but returns Unix epoch (float) on most executors.
    local ok3, t3 = pcall(tick)
    if ok3 and type(t3) == "number" and t3 >= MIN_VALID_EPOCH then
        return math.floor(t3)
    end

    -- 4) workspace:GetServerTimeNow() — Unix epoch from the server.
    local ok4, t4 = pcall(function()
        return workspace:GetServerTimeNow()
    end)
    if ok4 and type(t4) == "number" and t4 >= MIN_VALID_EPOCH then
        return math.floor(t4)
    end

    return nil -- no trustworthy clock available
end

-- Session anchor: captured once from the best available real clock. If every
-- epoch source is stubbed, we synthesize a moving timestamp from os.clock()
-- (monotonic seconds since start) on top of this anchor so ts still ADVANCES
-- every write. That keeps the harness's freshness/heartbeat check working even
-- on a fully broken clock, instead of freezing at a constant and looking stale.
local _epochAnchor = unixNow()
local _clockAnchor = os.clock()

local function now()
    local realNow = unixNow()
    if realNow then
        -- Keep the anchor fresh so any later fallback stays close to real time.
        _epochAnchor = realNow
        _clockAnchor = os.clock()
        return realNow
    end

    if _epochAnchor then
        -- Advance the last-known-good epoch by monotonic elapsed seconds.
        local elapsed = os.clock() - _clockAnchor
        if elapsed < 0 then elapsed = 0 end
        return math.floor(_epochAnchor + elapsed)
    end

    -- Absolute last resort: no real clock ever seen. Return a large, always
    -- ADVANCING value (still > MIN_VALID_EPOCH) so the harness sees fresh,
    -- monotonically increasing timestamps rather than 0 -> phantom 277h.
    return math.floor(MIN_VALID_EPOCH + os.clock())
end

local function lower(s)
    return string.lower(tostring(s or ""))
end

local function getAttr(inst, names)
    for _, name in ipairs(names) do
        local ok, value = pcall(function()
            return inst:GetAttribute(name)
        end)

        if ok and value ~= nil then
            return value
        end
    end

    return nil
end

local function countTable(t)
    local n = 0
    for _ in pairs(t) do
        n += 1
    end
    return n
end

local function nameHasAny(name, words)
    local n = lower(name)
    for _, w in ipairs(words) do
        if string.find(n, w, 1, true) then
            return true
        end
    end
    return false
end

--========================================================--
-- Pet / egg detection
--========================================================--

local NON_PET_WORDS = {
    "seed",
    "fruit",
    "carrot",
    "tomato",
    "strawberry",
    "blueberry",
    "bamboo",
    "mushroom",
    "daffodil",
    "flower",
    "sprinkler",
    "shovel",
    "trowel",
    "watering",
    "harvest",
    "tool",
}

local function looksLikeEgg(inst)
    local name = inst.Name or ""
    local n = lower(name)

    if string.find(n, "egg", 1, true) then
        return true
    end

    local eggAttr = getAttr(inst, {
        "EggName",
        "EggType",
        "egg_name",
        "egg_type",
        "IsEgg",
        "is_egg"
    })

    if eggAttr ~= nil then
        if type(eggAttr) == "boolean" then
            return eggAttr
        end
        return tostring(eggAttr) ~= ""
    end

    return false
end

local function getEggName(inst)
    local attr = getAttr(inst, {
        "EggName",
        "EggType",
        "egg_name",
        "egg_type"
    })

    if attr ~= nil and tostring(attr) ~= "" then
        return tostring(attr)
    end

    local name = tostring(inst.Name or "Unknown Egg")
    name = string.gsub(name, "%s*%[x%d+%]%s*", "")
    name = string.gsub(name, "%s*%b[]%s*", "")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")

    if name == "" then
        name = "Unknown Egg"
    end

    return name
end

local function looksLikePet(inst)
    if not inst then
        return false
    end

    local class = inst.ClassName
    if class ~= "Tool" and class ~= "Configuration" and class ~= "Folder" then
        return false
    end

    if looksLikeEgg(inst) then
        return false
    end

    local name = tostring(inst.Name or "")
    if nameHasAny(name, NON_PET_WORDS) then
        return false
    end

    local petAttr = getAttr(inst, {
        "PetType",
        "PetName",
        "Pet",
        "pet_type",
        "pet_name",
        "pet",
        "IsPet",
        "is_pet",
        "PET_UUID",
        "PetUUID",
        "pet_uuid",
        "UUID",
        "uuid",
        "Id",
        "id"
    })

    if petAttr ~= nil then
        if type(petAttr) == "boolean" then
            return petAttr
        end
        if tostring(petAttr) ~= "" then
            return true
        end
    end

    -- Fuzzy name fallback (age/kg). This is the least reliable signal — a
    -- weighted fruit ("2.5 KG") could match. Kept ON by default for backward
    -- compatibility, but set Config.FuzzyPetNameMatch = false to require a real
    -- pet attribute instead (more accurate if you see over-counting).
    if Config.FuzzyPetNameMatch ~= false then
        local n = lower(name)
        -- Require the age/kg token AND a pet-ish bracket pattern like [Age N]
        -- or [N.N KG], which pets use, to reduce false matches on plain items.
        local hasAge = string.find(n, "age", 1, true) ~= nil
        local hasKg = string.find(n, "kg", 1, true) ~= nil
        local looksBracketed = string.find(n, "%[") ~= nil
        if (hasAge or hasKg) and looksBracketed and not nameHasAny(n, NON_PET_WORDS) then
            return true
        end
    end

    return false
end

local function getContainers()
    local containers = {}

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        table.insert(containers, backpack)
    end

    if LocalPlayer.Character then
        table.insert(containers, LocalPlayer.Character)
    end

    table.insert(containers, LocalPlayer)

    return containers
end

local function getUniqueId(inst)
    local id = getAttr(inst, {
        "PET_UUID",
        "PetUUID",
        "pet_uuid",
        "UUID",
        "uuid",
        "Id",
        "id"
    })

    if id ~= nil and tostring(id) ~= "" then
        return tostring(id)
    end

    return inst:GetFullName()
end

--========================================================--
-- Stable Grow a Garden egg catalog
--========================================================--

local EGG_CATALOG = {}
local EGG_CATALOG_LAST_SCAN = 0
local EGG_CATALOG_SOURCE = "none"
local EGG_CATALOG_SCAN_LIMIT = 20000

local EGG_NAME_FIELDS = {
    name = true,
    displayname = true,
    itemname = true,
    eggname = true,
    egg_name = true,
    peteggname = true,
    title = true,
}

local function normalizeEggCatalogName(value)
    if type(value) ~= "string" then
        return nil
    end

    local name = value
    name = string.gsub(name, "%s*%[x%d+%]%s*", "")
    name = string.gsub(name, "%s*%b[]%s*", "")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    name = string.gsub(name, "%s+", " ")

    if #name < 5 or #name > 80 then
        return nil
    end

    -- Real GAG egg item names end in "Egg". Requiring that suffix avoids
    -- collecting registry field names such as EggData, EggIcon or EggChance.
    if not string.match(lower(name), " egg$") then
        return nil
    end

    return name
end

local function addEggCatalogName(value)
    local name = normalizeEggCatalogName(value)
    if not name then
        return false
    end

    if EGG_CATALOG[name] then
        return false
    end

    EGG_CATALOG[name] = true
    return true
end

local function extractEggNamesFromTable(value, depth, visited, budget)
    if type(value) ~= "table" or depth > 5 or budget.count >= EGG_CATALOG_SCAN_LIMIT then
        return
    end
    if visited[value] then
        return
    end
    visited[value] = true

    for key, item in pairs(value) do
        budget.count += 1
        if budget.count >= EGG_CATALOG_SCAN_LIMIT then
            break
        end

        if type(key) == "string" then
            addEggCatalogName(key)
        end

        if type(item) == "string" then
            local keyName = type(key) == "string" and lower(key) or ""
            if EGG_NAME_FIELDS[keyName] or string.match(lower(item), " egg$") then
                addEggCatalogName(item)
            end
        elseif type(item) == "table" then
            extractEggNamesFromTable(item, depth + 1, visited, budget)
        end
    end
end

local function inspectEggRegistryInstance(inst, sourceNames)
    if not inst then
        return
    end

    table.insert(sourceNames, inst:GetFullName())

    if inst:IsA("ModuleScript") then
        local ok, data = pcall(require, inst)
        if ok and type(data) == "table" then
            extractEggNamesFromTable(data, 0, {}, {count = 0})
        end
        return
    end

    -- Some game versions expose each egg as a child instead of a module table.
    local ok, children = pcall(function()
        return inst:GetChildren()
    end)
    if ok then
        for _, child in ipairs(children) do
            addEggCatalogName(child.Name)
            if child:IsA("ModuleScript") then
                local okModule, data = pcall(require, child)
                if okModule and type(data) == "table" then
                    extractEggNamesFromTable(data, 0, {}, {count = 0})
                end
            end
        end
    end
end

local function discoverEggCatalog(force)
    local clockNow = os.clock()
    local hasCatalog = next(EGG_CATALOG) ~= nil
    local interval = hasCatalog and Config.EggCatalogRefreshSeconds or Config.EggCatalogRetrySeconds

    if not force and EGG_CATALOG_LAST_SCAN > 0 and clockNow - EGG_CATALOG_LAST_SCAN < interval then
        return
    end
    EGG_CATALOG_LAST_SCAN = clockNow

    -- Manual extras are useful as a safe fallback when a game update renames or
    -- temporarily hides a registry module.
    for _, name in pairs(Config.ExtraEggNames) do
        addEggCatalogName(name)
    end

    local candidates = {}
    local seenInstances = {}

    local function addCandidate(inst)
        if inst and not seenInstances[inst] then
            seenInstances[inst] = true
            table.insert(candidates, inst)
        end
    end

    local dataFolder = ReplicatedStorage:FindFirstChild("Data")
    local petRegistry = dataFolder and dataFolder:FindFirstChild("PetRegistry")
    for _, root in ipairs({petRegistry, dataFolder, ReplicatedStorage}) do
        if root then
            for _, candidateName in ipairs({"PetEggs", "PetEggData", "EggData", "EggRegistry"}) do
                addCandidate(root:FindFirstChild(candidateName))
            end
        end
    end

    -- Targeted recursive fallback. This searches only four exact names and runs
    -- at most once per refresh interval; it does not continuously scan the UI.
    if #candidates == 0 then
        for _, candidateName in ipairs({"PetEggs", "PetEggData", "EggData", "EggRegistry"}) do
            addCandidate(ReplicatedStorage:FindFirstChild(candidateName, true))
        end
    end

    local sourceNames = {}
    for _, inst in ipairs(candidates) do
        pcall(inspectEggRegistryInstance, inst, sourceNames)
    end

    if #sourceNames > 0 then
        EGG_CATALOG_SOURCE = table.concat(sourceNames, "; ")
    elseif next(EGG_CATALOG) ~= nil then
        EGG_CATALOG_SOURCE = "cached/observed"
    else
        EGG_CATALOG_SOURCE = "registry unavailable"
    end
end

local function sortedEggCatalog()
    local names = {}
    for name in pairs(EGG_CATALOG) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

local function getLiveData()
    local service = getDataService()
    if not service then
        return nil
    end

    local ok, data = pcall(function()
        return service:GetData()
    end)

    if ok and type(data) == "table" then
        return data
    end

    if Config.Debug then
        warn("[NOMO PET COUNTER] DataService:GetData failed:", tostring(data))
    end
    return nil
end

local function firstTable(...)
    for _, value in ipairs({...}) do
        if type(value) == "table" then
            return value
        end
    end
    return nil
end

local function countPetsFromData(data)
    local petInv = data and data.PetsData and data.PetsData.PetInventory
    local petData = petInv and firstTable(petInv.Data, petInv.PetData, petInv.Inventory)
    if type(petData) ~= "table" then
        return nil
    end

    local count = 0
    for _, entry in pairs(petData) do
        if entry ~= nil and entry ~= false then
            count += 1
        end
    end
    return count
end

local function cleanInventoryEggName(value)
    local name = normalizeEggCatalogName(value)
    if name then
        return name
    end

    value = tostring(value or "")
    value = string.gsub(value, "%s*%[x%d+%]%s*", "")
    value = string.gsub(value, "%s*%b[]%s*", "")
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    value = string.gsub(value, "%s+", " ")
    if value ~= "" and string.find(lower(value), "egg", 1, true) then
        return value
    end
    return nil
end

local function getStackAmount(value)
    if type(value) == "number" then
        return math.max(0, math.floor(value))
    end
    if type(value) ~= "table" then
        return 1
    end

    local amount = value.Quantity or value.quantity or value.Amount or value.amount
        or value.Count or value.count or value.Stack or value.stack
        or value.Uses or value.uses or value.Value or value.value
    amount = tonumber(amount)
    if amount and amount > 0 then
        return math.floor(amount)
    end
    return 1
end

local function addEggCount(eggs, name, amount)
    name = cleanInventoryEggName(name)
    amount = tonumber(amount) or 0
    if not name or amount <= 0 then
        return false
    end

    addEggCatalogName(name)
    eggs[name] = (eggs[name] or 0) + math.floor(amount)
    return true
end

local function scanEggInventoryTable(container, eggs, depth, visited)
    if type(container) ~= "table" or depth > 4 then
        return 0
    end
    if visited[container] then
        return 0
    end
    visited[container] = true

    local found = 0
    for key, value in pairs(container) do
        local keyName = type(key) == "string" and cleanInventoryEggName(key) or nil
        if keyName then
            if addEggCount(eggs, keyName, getStackAmount(value)) then
                found += 1
            end
        elseif type(value) == "table" then
            local itemName = value.EggName or value.EggType or value.eggName or value.eggType
                or value.ItemName or value.itemName or value.Name or value.name
                or value.Type or value.type or value.PetEggName or value.petEggName
            if addEggCount(eggs, itemName, getStackAmount(value)) then
                found += 1
            else
                found += scanEggInventoryTable(value, eggs, depth + 1, visited)
            end
        end
    end

    return found
end

local function countEggsFromData(data, eggs)
    if type(data) ~= "table" then
        return false
    end

    local petsData = data.PetsData or {}
    local candidates = {
        petsData.PetEggInventory and petsData.PetEggInventory.Data,
        petsData.PetEggInventory,
        petsData.EggInventory and petsData.EggInventory.Data,
        petsData.EggInventory,
        petsData.PetEggs,
        petsData.Eggs,
        data.PetEggInventory and data.PetEggInventory.Data,
        data.PetEggInventory,
        data.EggInventory and data.EggInventory.Data,
        data.EggInventory,
        data.PetEggs,
        data.Eggs,
        data.EggsData,
        data.EggData,
    }

    local found = 0
    local visited = {}
    for _, candidate in ipairs(candidates) do
        found += scanEggInventoryTable(candidate, eggs, 0, visited)
    end

    return found > 0
end

local function countPetsAndEggsFromTools(eggs)
    local petsSeen = {}

    for _, container in ipairs(getContainers()) do
        local children = {}

        pcall(function()
            children = container:GetChildren()
        end)

        for _, inst in ipairs(children) do
            if looksLikePet(inst) then
                petsSeen[getUniqueId(inst)] = true
            elseif looksLikeEgg(inst) then
                local eggName = getEggName(inst)
                addEggCatalogName(eggName)
                eggs[eggName] = (eggs[eggName] or 0) + 1
            end
        end
    end

    return countTable(petsSeen)
end

local function countPetsAndEggs()
    discoverEggCatalog(false)

    local eggs = {}
    if Config.IncludeZeroCountEggs then
        for name in pairs(EGG_CATALOG) do
            eggs[name] = 0
        end
    end

    local data = getLiveData()
    local petCount = countPetsFromData(data)
    local dataEggsOk = countEggsFromData(data, eggs)

    if petCount == nil or not dataEggsOk then
        local toolPetCount = countPetsAndEggsFromTools(eggs)
        if petCount == nil then
            petCount = toolPetCount
        end
    end

    local eggTotal = 0
    for _, amount in pairs(eggs) do
        eggTotal += tonumber(amount) or 0
    end

    return tonumber(petCount) or 0, eggTotal, eggs
end

--========================================================--
-- Grow a Garden loading splash fixed multi-edge clicks
--========================================================--

local LOADING_SKIP = {
    detected = false, -- intentionally unknown: v3.3 does not scan PlayerGui
    active = false,
    skipped = false,  -- true means at least one configured click was sent
    attempts = 0,
    last_action = "",
    last_ts = 0,
}

local function edgeScreenClick(side)
    if not VirtualInputManager then
        return false, "VirtualInputManager unavailable"
    end

    local camera = workspace.CurrentCamera
    if not camera then
        return false, "camera unavailable"
    end

    local size = camera.ViewportSize
    if not size or size.X <= 0 or size.Y <= 0 then
        return false, "viewport unavailable"
    end

    local xRatio = side == "left" and Config.LoadingLeftX or Config.LoadingRightX
    local x = math.floor(size.X * math.clamp(xRatio, 0.02, 0.98))
    local y = math.floor(size.Y * math.clamp(Config.LoadingBottomY, 0.70, 0.96))

    local ok, err = pcall(function()
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.06)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)

    if not ok then
        return false, tostring(err)
    end

    return true, string.format("bottom-%s (%d,%d)", side, x, y)
end

local function recordLoadingAction(action)
    LOADING_SKIP.last_action = tostring(action or "")
    LOADING_SKIP.last_ts = now()
    if Config.Debug then
        print("[NOMO PET COUNTER] loading click:", LOADING_SKIP.last_action)
    end
end

local function oppositeSide(side)
    return side == "left" and "right" or "left"
end

local function runLoadingEdgeClicks()
    if not Config.AutoSkipLoadingScreen then
        return
    end

    LOADING_SKIP.active = true

    -- Event wait only; this does not scan any UI tree.
    if not game:IsLoaded() then
        local loadedOk = pcall(function()
            game.Loaded:Wait()
        end)
        if not loadedOk then
            recordLoadingAction("game.Loaded wait failed")
        end
    end

    task.wait(Config.LoadingClickDelay)

    local side = Config.LoadingClickSide
    local sentAny = false

    for attempt = 1, Config.LoadingClickCount do
        if not Config.Enabled or Config.Stop then
            recordLoadingAction(
                string.format("loading clicks cancelled after %d/%d", LOADING_SKIP.attempts, Config.LoadingClickCount)
            )
            break
        end

        LOADING_SKIP.attempts = attempt
        local ok, action = edgeScreenClick(side)
        sentAny = sentAny or ok
        LOADING_SKIP.skipped = sentAny

        recordLoadingAction(
            string.format("loading click %d/%d: %s%s",
                attempt,
                Config.LoadingClickCount,
                tostring(action or "unknown"),
                ok and "" or " [failed]")
        )

        if attempt < Config.LoadingClickCount then
            if Config.LoadingAlternateSides then
                side = oppositeSide(side)
            end
            task.wait(Config.LoadingClickInterval)
        end
    end

    LOADING_SKIP.active = false
end

--========================================================--
-- Disconnect popup detection
--========================================================--

local function scanTextObjects(root, output, limit)
    limit = limit or 120

    if not root or #output >= limit then
        return
    end

    local descendants = {}
    local ok = pcall(function()
        descendants = root:GetDescendants()
    end)

    if not ok then
        return
    end

    for _, obj in ipairs(descendants) do
        if #output >= limit then
            break
        end

        local class = obj.ClassName
        if class == "TextLabel" or class == "TextButton" or class == "TextBox" then
            local okText, text = pcall(function()
                return obj.Text
            end)

            if okText and text and text ~= "" then
                table.insert(output, tostring(text))
            end
        end
    end
end

local function extractCode(msg)
    msg = tostring(msg or "")
    local code = string.match(msg, "[Ee]rror%s*[Cc]ode:%s*(%d+)")
        or string.match(msg, "[Ee]rror%s*[Cc]ode%s*(%d+)")
        or string.match(msg, "Code%s*(%d+)")
    return code and tostring(code) or ""
end

local function isRealDisconnectText(msg)
    local l = lower(msg)

    -- High-confidence Roblox connection/kick phrases only. Standalone words
    -- like "Rejoin" are common executor buttons and must never trigger.
    if string.find(l, "disconnected from the experience", 1, true)
        or string.find(l, "the server has shut down", 1, true)
        or string.find(l, "connection failed", 1, true)
        or string.find(l, "failed to connect", 1, true)
        or string.find(l, "no response from server", 1, true)
        or string.find(l, "you have been kicked", 1, true)
        or string.find(l, "kicked by this experience", 1, true)
        or string.find(l, "unexpectedly disconnected", 1, true)
        or string.find(l, "lost connection", 1, true)
        or string.find(l, "session expired", 1, true)
        or string.find(l, "error code", 1, true) then
        return true
    end

    -- "Disconnected" alone is accepted only with real popup companions.
    if string.find(l, "disconnected", 1, true)
        and (string.find(l, "leave", 1, true)
            or string.find(l, "reconnect", 1, true)
            or string.find(l, "server has shut down", 1, true)
            or string.find(l, "error code", 1, true)) then
        return true
    end

    return false
end

-- GuiService can expose the real Roblox error text on some executors.
local NOMO_REAL_DISCONNECT = {
    active = false,
    text = "",
    code = "",
    reason = "",
    ts = 0,
    mono = 0,
}

local function markRealDisconnect(msg, reason)
    msg = tostring(msg or "")
    if msg == "" then
        return
    end

    if not isRealDisconnectText(msg) then
        return
    end

    NOMO_REAL_DISCONNECT.active = true
    NOMO_REAL_DISCONNECT.text = msg
    NOMO_REAL_DISCONNECT.code = extractCode(msg)
    NOMO_REAL_DISCONNECT.reason = reason or "gui_service"
    NOMO_REAL_DISCONNECT.ts = now()
    NOMO_REAL_DISCONNECT.mono = os.clock()
end

pcall(function()
    if GuiService.ErrorMessageChanged then
        GuiService.ErrorMessageChanged:Connect(function(msg)
            markRealDisconnect(msg, "gui_service_error_message")
        end)
    end
end)

task.spawn(function()
    while Config.Enabled and not Config.Stop do
        pcall(function()
            local msg = ""

            if type(GuiService.GetErrorMessage) == "function" then
                msg = GuiService:GetErrorMessage()
            elseif GuiService.ErrorMessage ~= nil then
                msg = GuiService.ErrorMessage
            end

            if msg and tostring(msg) ~= "" and isRealDisconnectText(msg) then
                markRealDisconnect(msg, "gui_service_error_poll")
            elseif NOMO_REAL_DISCONNECT.active
                and (os.clock() - tonumber(NOMO_REAL_DISCONNECT.mono or 0)) > 3 then
                -- The current GuiService error disappeared. Expire the old
                -- observation; visible RobloxPromptGui text is checked separately.
                NOMO_REAL_DISCONNECT.active = false
                NOMO_REAL_DISCONNECT.text = ""
                NOMO_REAL_DISCONNECT.code = ""
                NOMO_REAL_DISCONNECT.reason = ""
                NOMO_REAL_DISCONNECT.ts = 0
                NOMO_REAL_DISCONNECT.mono = 0
            end
        end)

        task.wait(1)
    end
end)

local function collectVisibleTexts(limit)
    local texts = {}
    limit = limit or 600

    -- GuiService is the cheapest and most authoritative source when available.
    pcall(function()
        local msg = ""
        if type(GuiService.GetErrorMessage) == "function" then
            msg = GuiService:GetErrorMessage()
        elseif GuiService.ErrorMessage ~= nil then
            msg = GuiService.ErrorMessage
        end
        if msg and tostring(msg) ~= "" then
            table.insert(texts, tostring(msg))
        end
    end)

    local roots = {}
    local seen = {}
    local function addRoot(root)
        if root and not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end

    local safeCoreGui = CoreGui
    pcall(function()
        if type(cloneref) == "function" then
            safeCoreGui = cloneref(CoreGui)
        end
    end)

    -- The native Roblox disconnect modal normally lives here. Scan it FIRST;
    -- the previous generic CoreGui-first scan could hit its text limit before
    -- ever reaching ErrorPrompt on UI-heavy clients.
    pcall(function()
        addRoot(safeCoreGui:FindFirstChild("RobloxPromptGui"))
    end)
    pcall(function()
        local rg = safeCoreGui:FindFirstChild("RobloxGui")
        if rg then
            addRoot(rg:FindFirstChild("RobloxPromptGui", true))
            addRoot(rg:FindFirstChild("ErrorPrompt", true))
        end
    end)

    -- Some executors expose protected Roblox UI through gethui().
    pcall(function()
        if type(gethui) == "function" then
            addRoot(gethui())
        end
    end)

    pcall(function()
        addRoot(LocalPlayer:FindFirstChildOfClass("PlayerGui"))
    end)
    addRoot(safeCoreGui)

    for _, root in ipairs(roots) do
        if #texts >= limit then
            break
        end
        pcall(function()
            scanTextObjects(root, texts, limit)
        end)
    end

    return texts
end

local function detectLoginChallenge()
    local texts = collectVisibleTexts(600)
    local joined = table.concat(texts, "\n")
    local l = lower(joined)

    -- High confidence only. Roblox/homepage can contain generic Login, Verify,
    -- Security, Continue, etc. Those words alone must never spend a solver call.
    local strong = {
        "captcha",
        "not a bot",
        "you are not a bot",
        "verify you are human",
        "prove you are human",
        "human verification",
        "real person",
        "start puzzle",
        "solve this puzzle",
        "solve this challenge",
        "complete the challenge",
        "arkose",
        "fun captcha",
    }

    local hits = {}
    for _, phrase in ipairs(strong) do
        if string.find(l, phrase, 1, true) then
            table.insert(hits, phrase)
        end
    end

    if #hits > 0 then
        return true, joined, table.concat(hits, ",")
    end

    return false, "", ""
end

local function collectRobloxPromptTexts(limit)
    local texts = {}
    limit = limit or 250

    -- GuiService current error is authoritative when non-empty.
    pcall(function()
        local msg = ""
        if type(GuiService.GetErrorMessage) == "function" then
            msg = GuiService:GetErrorMessage()
        elseif GuiService.ErrorMessage ~= nil then
            msg = GuiService.ErrorMessage
        end
        if msg and tostring(msg) ~= "" then
            table.insert(texts, tostring(msg))
        end
    end)

    local safeCoreGui = CoreGui
    pcall(function()
        if type(cloneref) == "function" then
            safeCoreGui = cloneref(CoreGui)
        end
    end)

    local roots = {}
    local seen = {}
    local function addRoot(root)
        if root and not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end

    pcall(function()
        addRoot(safeCoreGui:FindFirstChild("RobloxPromptGui"))
    end)
    pcall(function()
        local rg = safeCoreGui:FindFirstChild("RobloxGui")
        if rg then
            addRoot(rg:FindFirstChild("RobloxPromptGui", true))
            addRoot(rg:FindFirstChild("ErrorPrompt", true))
        end
    end)

    for _, root in ipairs(roots) do
        if #texts >= limit then break end
        pcall(function()
            scanTextObjects(root, texts, limit)
        end)
    end

    return texts
end

local function detectDisconnectPopup()
    if NOMO_REAL_DISCONNECT.active
        and (os.clock() - tonumber(NOMO_REAL_DISCONNECT.mono or 0)) <= 3 then
        return true,
            "Roblox Disconnect",
            NOMO_REAL_DISCONNECT.text or "",
            NOMO_REAL_DISCONNECT.code or "",
            NOMO_REAL_DISCONNECT.reason or "gui_service_real_disconnect"
    end

    local texts = collectRobloxPromptTexts(250)
    local joined = table.concat(texts, "\n")
    local l = lower(joined)
    local code = extractCode(joined)

    -- Safe real-message detection.
    if isRealDisconnectText(joined) then
        return true, "Roblox Disconnect", joined, code, "real_disconnect_text"
    end

    -- Ignore generic popup by default. This can false-trigger while Roblox is still fine.
    if string.find(l, "this is a popup", 1, true)
        and (string.find(l, "goodbye", 1, true) or string.find(l, "leave", 1, true)) then

        if Config.TreatGenericPopupAsDisconnect then
            return true, "This is a popup", joined, code, "generic_popup_forced"
        end

        return false, "This is a popup", joined, "", "generic_popup_ignored"
    end

    return false, "", "", "", ""
end

--========================================================--
-- Server info
--========================================================--

local function getServerInfo()
    -- Client-safe: these properties are blocked/noisy on some Android
    -- executors. Returning nil omits the JSON keys, so Python treats server
    -- privacy as unknown rather than falsely assuming public.
    return nil, nil, nil, "unknown"
end

--========================================================--
-- State build/write
--========================================================--

local lastGoodPetCount = 0
local lastGoodEggTotal = 0
local lastGoodEggs = {}

-- Heartbeat: increments every successful state build. Lets the harness tell
-- "script running but game stuck" (seq advancing, pets frozen) from
-- "script never started / crashed" (file missing or seq frozen).
local WRITE_SEQ = 0
local SCRIPT_START = os.time()

local function buildState()
    local petCount, eggTotal, eggs = 0, 0, {}

    local okCount, a, b, c = pcall(function()
        return countPetsAndEggs()
    end)

    if okCount then
        petCount = tonumber(a) or 0
        eggTotal = tonumber(b) or 0
        eggs = type(c) == "table" and c or {}
        lastGoodPetCount = petCount
        lastGoodEggTotal = eggTotal
        lastGoodEggs = eggs
    else
        petCount = lastGoodPetCount
        eggTotal = lastGoodEggTotal
        eggs = lastGoodEggs
        if Config.Debug then
            warn("[NOMO PET COUNTER] countPetsAndEggs error:", tostring(a))
        end
    end

    local privateServerId, privateServerOwnerId, isPrivate, serverType = getServerInfo()

    local disconnected, disconnectTitle, disconnectText, disconnectCode, disconnectReason = false, "", "", "", ""
    local okDetect, d, title, text, code, reason = pcall(function()
        return detectDisconnectPopup()
    end)

    if okDetect then
        disconnected = d == true
        disconnectTitle = title or ""
        disconnectText = text or ""
        disconnectCode = code or ""
        disconnectReason = reason or ""
    else
        disconnectReason = "detect_error"
        if Config.Debug then
            warn("[NOMO PET COUNTER] detectDisconnectPopup error:", tostring(d))
        end
    end

    local loginChallenge, loginChallengeText, loginChallengeReason = false, "", ""
    local okChallenge, cActive, cText, cReason = pcall(function()
        return detectLoginChallenge()
    end)
    if okChallenge then
        loginChallenge = cActive == true
        loginChallengeText = cText or ""
        loginChallengeReason = cReason or ""
    elseif Config.Debug then
        warn("[NOMO PET COUNTER] detectLoginChallenge error:", tostring(cActive))
    end

    WRITE_SEQ = WRITE_SEQ + 1

    return {
        counter_version = Config.Version,

        username = LocalPlayer.Name,
        display_name = LocalPlayer.DisplayName,

        pet_count = petCount,
        egg_total = eggTotal,
        eggs = eggs,
        egg_catalog = sortedEggCatalog(),
        egg_catalog_count = countTable(EGG_CATALOG),
        egg_catalog_source = EGG_CATALOG_SOURCE,
        egg_counts_include_zero = Config.IncludeZeroCountEggs == true,

        ts = now(),
        write_seq = WRITE_SEQ,
        script_uptime = os.time() - SCRIPT_START,
        counter_alive = true,
        place_id = tostring(game.PlaceId or ""),
        job_id = tostring(game.JobId or ""),

        private_server_id = privateServerId,
        private_server_owner_id = privateServerOwnerId,
        is_private_server = isPrivate,
        server_type = serverType,

        loading_screen_detected = LOADING_SKIP.detected,
        loading_screen_active = LOADING_SKIP.active,
        loading_screen_skipped = LOADING_SKIP.skipped,
        loading_screen_skip_attempts = LOADING_SKIP.attempts,
        loading_screen_last_action = LOADING_SKIP.last_action,
        loading_screen_last_action_ts = LOADING_SKIP.last_ts,

        disconnected = disconnected,
        disconnect_observed_ts = disconnected and now() or 0,
        disconnect_title = disconnectTitle,
        disconnect_text = disconnectText,
        disconnect_code = disconnectCode,
        disconnect_reason = disconnectReason,

        login_challenge = loginChallenge,
        login_challenge_text = loginChallengeText,
        login_challenge_reason = loginChallengeReason,
    }
end

local function writeStateTable(state)
    safeMakeFolder(Config.WriteFolder)

    local okEncode, encoded = pcall(function()
        return HttpService:JSONEncode(state)
    end)

    if not okEncode then
        return false, tostring(encoded)
    end

    local ok, err = safeWrite(Config.WriteFile, encoded)

    if Config.Verbose then
        if ok then
            print("[NOMO PET COUNTER] pets=" .. tostring(state.pet_count)
                .. " eggs=" .. tostring(state.egg_total)
                .. " disconnected=" .. tostring(state.disconnected)
                .. " reason=" .. tostring(state.disconnect_reason))
        else
            warn("[NOMO PET COUNTER] write failed:", err)
        end
    end

    return ok, err
end

local function writeState()
    local state = buildState()
    local ok, err = writeStateTable(state)
    return ok, err, state
end

getgenv().NOMO_COUNTER_STOP = function()
    Config.Enabled = false
    Config.Stop = true
    print("[NOMO PET COUNTER] stop requested")
end

getgenv().NOMO_COUNTER_FORCE_GENERIC_POPUP = function(enabled)
    Config.TreatGenericPopupAsDisconnect = enabled == true
    print("[NOMO PET COUNTER] TreatGenericPopupAsDisconnect =", Config.TreatGenericPopupAsDisconnect)
end

getgenv().NOMO_LOADING_SKIP_STATUS = function()
    local copy = {}
    for key, value in pairs(LOADING_SKIP) do
        copy[key] = value
    end
    print("[NOMO PET COUNTER] loading skip:", HttpService:JSONEncode(copy))
    return copy
end

--========================================================--
-- Main loop
--========================================================--

local lastWrite = 0
local lastDisconnected = nil
local lastLoginChallenge = nil
local lastPetCount = nil
local lastEggTotal = nil
local lastLoadingSignature = nil

local function rejoinServer()
    pcall(writeState)

    task.spawn(function()
        local ok, err = pcall(function()
            if tostring(game.JobId or "") ~= "" then
                TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
            else
                TeleportService:Teleport(game.PlaceId, LocalPlayer)
            end
        end)

        if not ok then
            warn("[NOMO PET COUNTER] rejoin failed:", tostring(err))
        end
    end)
end

getgenv().NOMO_COUNTER_REJOIN = rejoinServer

print("========================================")
print("[NOMO PET COUNTER] " .. tostring(Config.Version) .. "  (for NOMO REJOIN V4.04+)")
print("[NOMO PET COUNTER] account = " .. tostring(LocalPlayer.Name))
print("[NOMO PET COUNTER] writing -> " .. tostring(Config.WriteFile))
print("[NOMO PET COUNTER] ^ the harness must look for this SAME filename.")
print("[NOMO PET COUNTER] loading edge clicks = " .. tostring(Config.AutoSkipLoadingScreen)
    .. ", count=" .. tostring(Config.LoadingClickCount)
    .. ", first-after=" .. tostring(Config.LoadingClickDelay) .. "s"
    .. ", interval=" .. tostring(Config.LoadingClickInterval) .. "s"
    .. ", start-side=" .. tostring(Config.LoadingClickSide))
print("========================================")


-- Send fixed delayed edge clicks independently so state writing never waits for them.
task.spawn(runLoadingEdgeClicks)

-- Write immediately once so age starts refreshing.
pcall(writeState)

task.spawn(function()
    while Config.Enabled and not Config.Stop do
        local loopOk, loopErr = pcall(function()
            local nowTime = now()
            local state = buildState()

            local shouldWrite = false

            -- Write on disconnect state change (fast kick detection).
            if state.disconnected ~= lastDisconnected then
                shouldWrite = true
                lastDisconnected = state.disconnected
            end

            -- Write immediately when a high-confidence CAPTCHA signal changes.
            if state.login_challenge ~= lastLoginChallenge then
                shouldWrite = true
                lastLoginChallenge = state.login_challenge
            end

            -- Write immediately when loading-screen detection/skip status changes.
            local loadingSignature = table.concat({
                tostring(state.loading_screen_detected),
                tostring(state.loading_screen_active),
                tostring(state.loading_screen_skipped),
                tostring(state.loading_screen_skip_attempts),
                tostring(state.loading_screen_last_action),
            }, "|")
            if loadingSignature ~= lastLoadingSignature then
                shouldWrite = true
                lastLoadingSignature = loadingSignature
            end

            -- Write on pet/egg change (fast restock/market reaction).
            if state.pet_count ~= lastPetCount or state.egg_total ~= lastEggTotal then
                shouldWrite = true
                lastPetCount = state.pet_count
                lastEggTotal = state.egg_total
            end

            -- Heartbeat: always write at least every WriteEvery seconds so age
            -- keeps refreshing even when nothing changes.
            if nowTime - lastWrite >= Config.WriteEvery then
                shouldWrite = true
            end

            if shouldWrite then
                lastWrite = nowTime
                writeStateTable(state)
            end
        end)

        if not loopOk then
            warn("[NOMO PET COUNTER] main loop error:", tostring(loopErr))
        end

        task.wait(Config.ScanEvery)
    end

    Config.Enabled = false
    Config.Stop = true
    print("[NOMO PET COUNTER] stopped")
end)
