--------------------------------------------------------------------------
-- Seed of the Dead: Sweet Home  --  ESP overlay  (UE4.27)
--
-- Everything is resolved through UE's own reflection data rather than guessed
-- offsets, so this survives level loads, weapon swaps and restarts:
--   GUObjectArray  game+0x4BA86E0     FNamePool Blocks[]  game+0x4B6C390
--   UObject  +0x10 Class  +0x18 FName  +0x20 Outer
--   UStruct  +0x40 Super  +0x50 ChildProperties  +0x58 PropertiesSize
--   FField   +0x20 Next   +0x28 Name  |  FProperty +0x3C Size  +0x4C Offset
--
-- Targets are matched by BASE class, not by leaf class name: every enemy
-- derives from BP_NewEnemy_Base_C and every pickup from BP_ItemBase_C, so
-- elites, bosses and item types nobody has seen yet are covered automatically.
--------------------------------------------------------------------------

ESP = ESP or {}

-- Order does not matter: classify() walks the SuperStruct chain upward, so the
-- most derived match wins -- BP_Item_Weapon_C is nearer the leaf than
-- BP_ItemBase_C and therefore claims weapon pickups first.
ESP.BASES = {
  { base = "BP_NewEnemy_Base_C", kind = "enemy"  },
  { base = "BP_Item_Weapon_C",   kind = "weapon" },
  { base = "BP_ItemBase_C",      kind = "item"   },
}

--- Class names are developer shorthand; show something readable instead.
--- "BP_Item_WP09_AP5_C" is just an AP5.
local PRETTY = {
  PresentItemBase = "物品",
  ItemAmmo        = "弹药",
  ItemAmmo_Const  = "弹药箱",
  ItemGrenade     = "手雷",
  Seiryoku        = "精力",
  Weapon          = "武器",
  ItemBase        = "物品",
}
function ESP.pretty(raw)
  local s = raw:gsub("^BP_", ""):gsub("_C$", ""):gsub("^Item_", ""):gsub("^EN_", "")
  if PRETTY[s] then return PRETTY[s] end
  return (s:gsub("^WP%d+_", ""))
end

-- Tiering is driven by MaxHealth rather than the class-name prefix: the trash
-- zombie sits at 20 hp and the tougher variants at 100+, which is a far more
-- honest signal than guessing at the studio's naming scheme. Bosses are picked
-- out by name because they are unmistakable.
ESP.ELITE_HP = 50
ESP.show = ESP.show or
  { trash = false, elite = true, boss = true, item = true, weapon = true, ally = true }
ESP.TIER_COLOUR = {                -- Lazarus TColor is $00BBGGRR
  trash  = 0x8888FF,   -- washed-out red
  elite  = 0x2222FF,   -- strong red
  boss   = 0x00A5FF,   -- orange
  item   = 0xFF66FF,   -- pink  (fallback for unrecognised pickups)
  weapon = 0xFFFF00,   -- cyan
  ally   = 0x00FF00,   -- green
  rescue = 0x0000FF,   -- red: a downed team-mate being assaulted
}

--- Pickups all share one tier but not one purpose, so give each kind its own
--- hue. Keyed by the pretty label, which is stable for a given class.
ESP.ITEM_COLOUR = {
  ["弹药"]   = 0x00FFFF,   -- yellow
  ["弹药箱"] = 0x00FFFF,   -- yellow
  ["手雷"]   = 0x00FF00,   -- green
  ["精力"]   = 0xFF00A5,   -- purple
  ["物品"]   = 0xFF66FF,   -- pink
  checkPoint = 0xFFFFFF,   -- white
}

ESP.MAX_DIST_M   = 200
ESP.ITEM_DIST_M  = 80        -- pickups only matter when they are near
ESP.TICK_MS      = 3         -- ~165 fps; see the driver note further down
-- Measured at ~82k objects/sec, so sweeping all 309k costs 3.8s of thread
-- time -- which is why a freshly spawned enemy took seconds to get a box.
-- Every object we actually track lives in the last ~56k indices (engine
-- packages, classes and CDOs fill the bottom), so sweep only the tail and
-- reach the whole array on a slow cycle to catch anything unusual.
ESP.SCAN_CHUNK   = 800       -- same throughput as 8000/100ms, a tenth of the
ESP.SCAN_TICK_MS = 10        -- wait it imposes on every other loop
ESP.HOT_SPAN     = 80000     -- indices back from the end, swept continuously
ESP.FULL_EVERY   = 45        -- seconds between whole-array sweeps
-- The pawn's class is NOT one fixed name. Two have been seen in this build --
-- BP_PL_ActPlayer_C and BP_PL_Player_C -- and which one is instantiated
-- depends on the level, so matching a literal name silently loses the pawn on
-- any map that uses the other. Match on what the class *has* instead.
--- Virtual-key code for the overlay toggle; override before loading to rebind.
ESP.HOTKEY = ESP.HOTKEY or (VK_END or 0x23)

ESP.PLAYER_PREFIX   = "^BP_PL_"
ESP.PLAYER_REQUIRED = { "CurrentHP", "CurrentHaveWeaponInfo" }
ESP.ALLY_CLASS      = "BPC_HeroineBattle_C"

local function q(a)   local ok, v = pcall(readQword, a);        if ok then return v end end
local function i32(a) local ok, v = pcall(readInteger, a);      if ok then return v end end
local function u16(a) local ok, v = pcall(readSmallInteger, a); if ok then return v end end
local function f(a)   local ok, v = pcall(readFloat, a);        if ok then return v end end

function ESP.rebase()
  local base  = getAddress("SoD2-Win64-Shipping.exe")
  ESP.base    = base
  ESP.gnames  = base + 0x4B6C390
  ESP.gobj    = base + 0x4BA86E0
  ESP.names   = {}
  ESP.classes = {}
  ESP.kinds   = {}
  ESP.propCache = {}
  ESP.chunks  = nil
  return base
end

--- Every address the modules hold -- module base, object array, and all the
--- pointer-keyed caches -- belongs to one specific process, but CE keeps this
--- Lua state when you attach somewhere else. Without this the modules keep
--- writing into addresses from the previous process.
--- Every worker loop used to be `pcall(tick)` with the error discarded, so a
--- feature could stop working with nothing to show for it -- that is how a
--- 6-second scan on every tick stayed hidden. Keep a per-loop tally instead,
--- print the first failure once, and expose the counts to the status line.
ESP.health = ESP.health or {}

function ESP.guard(name, fn, ...)
  local h = ESP.health[name]
  if not h then h = { ok = 0, err = 0, maxMs = 0 }; ESP.health[name] = h end
  h.stopped = nil
  local t0 = os.clock()
  local ok, err = xpcall(fn, function(e)
    return tostring(e) .. "\n" .. debug.traceback("", 2)
  end, ...)
  local ms = (os.clock() - t0) * 1000
  h.lastMs = ms
  if ms > (h.maxMs or 0) then h.maxMs = ms end
  if ok then
    h.ok, h.lastOk = h.ok + 1, os.clock()
  else
    h.err, h.last = h.err + 1, err
    -- Printing only the very first failure means that once one bug is fixed
    -- the next one in the same loop is silent, and ESP.health survives a
    -- dofile. Print whenever the message changes, and re-print a persistent
    -- one every 30s.
    local head = err:match("^[^\n]*")
    if head ~= h.lastPrinted or os.clock() - (h.printedAt or 0) > 30 then
      h.lastPrinted, h.printedAt = head, os.clock()
      print("[SoD] " .. name .. " failed: " .. tostring(err))
    end
  end
  return ok
end

--- Per-loop timing, for judging how long each one holds the shared lock.
function ESP.timing()
  local names = {}
  for n in pairs(ESP.health) do names[#names + 1] = n end
  table.sort(names)
  local out = {}
  for _, n in ipairs(names) do
    local h = ESP.health[n]
    out[#out + 1] = string.format("%s %.1f/%.1fms", n, h.lastMs or 0, h.maxMs or 0)
  end
  return table.concat(out, "  ")
end

--- Compact "which loops are unhappy" line for the menu.
function ESP.healthLine()
  local bad, now = {}, os.clock()
  -- A hook that is not installed is otherwise completely silent: the tick just
  -- skips its `if SA then` block and every counter stays green.
  if AIM and AIM.running and AIM.enabled and not SA then bad[#bad + 1] = "hook!" end
  for name, h in pairs(ESP.health) do
    if h.stopped then                                  -- loop deliberately off
    elseif h.err > 0 then bad[#bad + 1] = string.format("%s!%d", name, h.err)
    -- Every loop shares one lock, so a single long operation elsewhere can
    -- starve one for a second or two without anything being wrong.
    elseif h.lastOk and now - h.lastOk > 10 then bad[#bad + 1] = name .. "?" end
  end
  if #bad == 0 then return "ok" end
  table.sort(bad)
  return table.concat(bad, " ")
end

--- Everything in this project is offsets into one specific executable. On any
--- other build they point at unrelated data, and the failure is not a clean
--- one: writes land wherever those offsets happen to fall and the game dies
--- minutes later, far from the cause. So refuse to run at all unless the
--- module we are attached to is byte-for-byte the build these were measured
--- against.
---
--- Measured on the GOG build, 2026-09-05:
ESP.EXPECT = {
  module      = "SoD2-Win64-Shipping.exe",
  moduleSize  = 0x5194000,          -- 85540864 bytes
  peTimestamp = 0x653EA209,         -- 2023-10-29 18:18:49 UTC
  hookOrig    = { 0x40, 0x53, 0x55, 0x56, 0x57 },
}

function ESP.selfCheck()
  local okBase, base = pcall(getAddress, ESP.EXPECT.module)
  if not okBase or not base then
    return false, "game module not found -- attach to " .. ESP.EXPECT.module .. " first"
  end
  if type(getModuleSize) == "function" then
    local size = getModuleSize(ESP.EXPECT.module)
    if size ~= ESP.EXPECT.moduleSize then
      return false, string.format("module size 0x%X, expected 0x%X -- unsupported build",
                                  size or 0, ESP.EXPECT.moduleSize)
    end
  end
  local lfanew = i32(base + 0x3C)
  local ts = lfanew and i32(base + lfanew + 8)
  if ts ~= ESP.EXPECT.peTimestamp then
    return false, string.format("PE timestamp 0x%X, expected 0x%X -- unsupported build",
                                ts or 0, ESP.EXPECT.peTimestamp)
  end

  -- The offsets themselves, checked against what the structures must look like
  -- rather than trusted because the build matched.
  local gobj = base + 0x4BA86E0
  local maxChunks, numChunks, num = i32(gobj + 0x18), i32(gobj + 0x1C), i32(gobj + 0x14)
  if maxChunks ~= 33 or not numChunks or numChunks < 1 or numChunks > 33
     or not num or num < 1000 or num > numChunks * 65536 then
    return false, "GUObjectArray layout check failed"
  end
  ESP.rebase()
  if ESP.name(0) ~= "None" then return false, "FNamePool check failed (index 0 is not None)" end

  local site = readBytes(base + (AIM and AIM.HOOK_OFF or 0x2ACC530), 5, true)
  if not site then return false, "cannot read the hook site" end
  local ok = (site[1] == 0xE9)                     -- already hooked, by us or otherwise
  if not ok then
    ok = true
    for i = 1, 5 do if site[i] ~= ESP.EXPECT.hookOrig[i] then ok = false end end
  end
  if not ok then return false, "LineTraceSingle prologue does not match -- unsupported build" end
  return true
end

function ESP.resetForProcess()
  -- rebase() throws when attached to anything that is not the game. It used to
  -- be the first statement, so that single failure skipped every line below it
  -- and left SA, the caches and the pawn pointer aimed at the old process.
  local okBase = pcall(ESP.rebase)              -- also clears names/classes/kinds/propCache
  ESP.propNid, ESP.propMeta, ESP.chunks, ESP.pawnKinds = {}, {}, {}, {}
  ESP.actors, ESP.allies, ESP.pcm, ESP.player = {}, {}, nil, nil
  -- Scan cursor state: a stale lastNum makes the next scanStep sweep the whole
  -- lastNum..num range in one go.
  ESP.lastNum, ESP.cursor, ESP.buf, ESP.cold = nil, nil, {}, {}
  ESP.fullSweep, ESP.bufPcm, ESP.bufPlayer, ESP.alliesFound = false, nil, nil, nil
  ESP.playerMissingSince, ESP.lastPawnHunt = nil, nil
  ESP.bufAllies = {}
  -- Only drop SA when this really is a different process. Re-attaching to the
  -- same one and clearing it makes installHook think nothing is installed, and
  -- it then injects over its own jump.
  if SA and SA.pid ~= getOpenedProcessID() then SA = nil end
  if AIM then
    AIM.headBone, AIM.boneMaps, AIM.layoutOk = {}, {}, {}
    AIM.current, AIM.lastObj, AIM.lastTarget, AIM.gunPtr = nil, nil, nil, nil
    AIM.armed = nil
    if AIM.triggerHeld then pcall(AIM.setTrigger, false) end
  end
  if PLAYER then PLAYER.actor, PLAYER.cls, PLAYER.nextScan = nil, nil, nil end
  ESP.procResets = (ESP.procResets or 0) + 1

  -- Reinstall right here. installHook is only called from AIM.start(), so
  -- after a game restart the tick's `if SA then` was simply false forever and
  -- silent aim was gone with nothing to show for it.
  if okBase and AIM and AIM.running and not SA then
    local ok, err = AIM.installHook()
    print("[SoD] hook reinstalled for the new process: "
          .. tostring(ok) .. " " .. tostring(err or ""))
  end
end

-- Wrap once ever. This file is re-run on every MENU.open(), and taking the
-- current onOpenProcess as `prev` each time built a chain that ran the reset
-- once per reload.
if not _G.__SOD_ONOPEN_WRAPPED then
  _G.__SOD_PREV_ONOPEN = onOpenProcess
  _G.__SOD_ONOPEN_WRAPPED = true
  function onOpenProcess(pid)
    local prev = _G.__SOD_PREV_ONOPEN
    if type(prev) == "function" then pcall(prev, pid) end
    if ESP and ESP.resetForProcess then pcall(ESP.resetForProcess) end
  end
end

function ESP.name(id)
  if not id then return "?" end
  local c = ESP.names[id]; if c then return c end
  local bp = q(ESP.gnames + (id >> 16) * 8); if not bp then return "?" end
  local e = bp + (id & 0xFFFF) * 2
  local h = u16(e); if not h then return "?" end
  local len = h >> 6
  if len < 1 or len > 200 then return "?" end
  local ok, s = pcall(readString, e + 2, len, (h & 1) == 1)
  s = (ok and s or "?"):sub(1, len)
  ESP.names[id] = s
  return s
end

--- No per-class cache here on purpose. A blueprint class unloaded with its
--- level leaves its address free for another class, and a cache keyed on that
--- address then reports the old name. The FName id at cls+0x18 is the identity,
--- so read it every time; ESP.names still caches the id -> string decode, which
--- is the expensive half.
function ESP.className(cls)
  if not cls then return "?" end
  local id = i32(cls + 0x18)
  if not id then return "?" end
  return ESP.name(id)
end

--- Walk the SuperStruct chain once per class and remember the verdict.
function ESP.classify(cls)
  if not cls then return nil end
  local nid = i32(cls + 0x18)
  local hit = ESP.kinds[cls]
  -- The scan loop wants this nid too; returning it saves a second read there.
  if hit and hit.nid == nid then return hit.def or nil, nid end
  local s, d = cls, 0
  while s and s > 0x1000000000 and d < 20 do
    local nm = ESP.name(i32(s + 0x18))
    for _, b in ipairs(ESP.BASES) do
      if nm == b.base then
        local label = ESP.pretty(ESP.className(cls))
        local def = { kind = b.kind, label = label,
                      colour = (b.kind == "item") and ESP.ITEM_COLOUR[label] or nil }
        ESP.kinds[cls] = { nid = nid, def = def }
        return def, nid
      end
    end
    s = q(s + 0x40); d = d + 1
  end
  ESP.kinds[cls] = { nid = nid, def = false }
  return nil, nid
end

--- trash / elite / boss / item, decided once when the actor is discovered.
function ESP.tier(obj, def)
  if def.kind == "item" or def.kind == "weapon" then return def.kind end
  if def.label:lower():find("boss") then return "boss" end
  local mh = ESP.propOffset(q(obj + 0x10), "MaxHealth")
  local hp = mh and f(obj + mh)
  if hp and hp >= ESP.ELITE_HP then return "elite" end
  return "trash"
end

--- Chunks are allocated lazily as the object array grows. Caching the zero
--- read back from a slot that is not allocated yet makes every object landing
--- in that range permanently invisible once it is -- and a garbage
--- InternalIndex from a freed object is enough to poison a slot that way.
function ESP.chunkAt(objects, hi)
  ESP.chunks = ESP.chunks or {}
  local c = ESP.chunks[hi]
  if c then return c end
  if hi < 0 or hi >= (i32(ESP.gobj + 0x1C) or 0) then return end
  c = q(objects + hi * 8)
  if not c or c == 0 then return end
  ESP.chunks[hi] = c
  return c
end

function objAt(objects, idx)
  local c = ESP.chunkAt(objects, idx >> 16)
  if c then return q(c + (idx & 0xFFFF) * 24) end
end

--- Offsets are cached per class, and the entry is thrown away when the class
--- at that address is no longer the one we resolved against -- otherwise a
--- recycled UClass address makes us apply one class's offsets to another and
--- writes land on the wrong field. Keying by the class table rather than a
--- formatted string also keeps this off the allocator, which matters on the
--- 1 ms aim tick.
--- Drops every cached offset for a class whose address now holds a different
--- class. Called from the scan loop, which has already read the nid for its own
--- purposes -- doing it here instead of inside propOffset takes one
--- ReadProcessMemory off a path that runs several times per millisecond.
--- Is this the class of a controllable player pawn? Prefix plus the presence
--- of the properties the modules actually use; the verdict is remembered per
--- class and revalidated against the class identity like every other cache.
function ESP.isPawnClass(cls, nid)
  if not cls or cls < 0x1000000000 then return false end
  nid = nid or i32(cls + 0x18)
  ESP.pawnKinds = ESP.pawnKinds or {}
  local hit = ESP.pawnKinds[cls]
  if hit and hit.nid == nid then return hit.ok end
  local ok = false
  if nid and ESP.name(nid):find(ESP.PLAYER_PREFIX) then
    ok = true
    for _, prop in ipairs(ESP.PLAYER_REQUIRED) do
      if not ESP.propOffset(cls, prop) then ok = false; break end
    end
  end
  ESP.pawnKinds[cls] = { nid = nid, ok = ok }
  return ok
end

function ESP.checkClass(cls, nid)
  if not nid then return end
  ESP.propNid = ESP.propNid or {}
  local seen = ESP.propNid[cls]
  if seen == nid then return end
  ESP.propNid[cls] = nid
  if seen ~= nil then                     -- the address was reused
    if ESP.propCache then ESP.propCache[cls] = nil end
    if ESP.propMeta  then ESP.propMeta[cls]  = nil end
  end
end

function ESP.propOffset(cls, want)
  if not cls or cls < 0x1000000000 then return end
  ESP.propCache, ESP.propNid = ESP.propCache or {}, ESP.propNid or {}
  local tbl = ESP.propCache[cls]
  if not tbl then
    tbl = {}
    ESP.propCache[cls] = tbl
    ESP.propNid[cls] = i32(cls + 0x18)    -- only on a miss, not on every call
    if ESP.propMeta then ESP.propMeta[cls] = nil end
  end
  local hit = tbl[want]
  if hit ~= nil then return hit ~= false and hit or nil end
  local s, d = cls, 0
  while s and s > 0x1000000000 and d < 20 do
    local p, n = q(s + 0x50), 0
    while p and p > 0x1000000000 and n < 600 do
      if ESP.name(i32(p + 0x28)) == want then
        local off = i32(p + 0x4C)
        tbl[want] = off or false
        if off then ESP.noteProp(cls, want, p, off) end
        return off
      end
      p = q(p + 0x20); n = n + 1
    end
    if n >= 600 then
      -- Hitting the walk limit is indistinguishable from "no such property"
      -- once it is cached as false, and the feature that needed it just stops
      -- working. Say so rather than failing silently.
      print(string.format("[SoD] propOffset: %s walk hit the 600-property limit looking for %s",
                          ESP.className(cls), tostring(want)))
    end
    s = q(s + 0x40); d = d + 1
  end
  tbl[want] = false
end

--- A destroyed actor (picked-up item, despawned corpse) stays in
--- GUObjectArray until the next GC, still carrying its last known position --
--- which is why its box used to sit there forever. The authoritative check is
--- the PendingKill/Unreachable bits in its FUObjectItem, plus making sure the
--- slot has not already been handed to a different object.
--- FUObjectItem: +0x00 Object, +0x08 Flags (24-byte stride)
local PENDING_KILL, UNREACHABLE = 0x20000000, 0x10000000

--- FBoolProperty tail, measured on this build: FieldSize, ByteOffset,
--- ByteMask, FieldMask. A blueprint bool owns its whole byte (ByteMask 0xFF);
--- a native bitfield owns one bit, and writing the byte would clear whatever
--- else lives there.
ESP.BOOL_FIELD = 0x78

--- What reflection says a property actually is. Recorded lazily as propOffset
--- walks the chain, so nothing extra is read on the hot path.
function ESP.noteProp(cls, name, fld, off)
  ESP.propMeta = ESP.propMeta or {}
  local m = ESP.propMeta[cls]; if not m then m = {}; ESP.propMeta[cls] = m end
  local fc = q(fld + 0x08)
  local e  = { off = off, kind = fc and ESP.name(i32(fc)) or "?", size = i32(fld + 0x3C) }
  if e.kind == "BoolProperty" then
    local b = readBytes(fld + ESP.BOOL_FIELD, 4, true)
    if b then e.byteMask, e.fieldMask = b[3], b[4] end
  end
  m[name] = e
  return e
end

function ESP.prop(cls, name)
  local off = ESP.propOffset(cls, name)          -- fills propMeta as a side effect
  if not off then return end
  local m = ESP.propMeta and ESP.propMeta[cls]
  return m and m[name]
end

--- Write through the type reflection reports rather than the one we assumed.
--- Storing 9999 with writeInteger into a FloatProperty leaves a bit pattern
--- that reads back as ~1.4e-41 -- the opposite of the intended effect, and
--- silent.
function ESP.writeProp(obj, cls, name, value)
  local e = ESP.prop(cls, name)
  if not e then return false, "no property " .. tostring(name) end
  local a, k = obj + e.off, e.kind
  -- math.floor/`+ 0.0` are evaluated as arguments, i.e. outside the pcall, so
  -- a boolean here throws out of writeProp and takes the whole tick with it.
  if type(value) == "boolean" then value = value and 1 or 0 end
  if type(value) ~= "number" then return false, "value is not a number" end
  if k == "FloatProperty" then                 return pcall(writeFloat, a, value + 0.0)
  elseif k == "DoubleProperty" then            return pcall(writeDouble, a, value + 0.0)
  elseif k == "IntProperty" or k == "UInt32Property" then
                                               return pcall(writeInteger, a, math.floor(value))
  elseif k == "Int64Property" or k == "UInt64Property" then
                                               return pcall(writeQword, a, math.floor(value))
  elseif k == "Int16Property" or k == "UInt16Property" then
                                               return pcall(writeSmallInteger, a, math.floor(value))
  elseif k == "ByteProperty" or k == "Int8Property" then
                                               return pcall(writeBytes, a, math.floor(value) & 0xFF)
  elseif k == "BoolProperty" then
    local mask = e.byteMask or 0xFF
    local on   = (value ~= false and value ~= nil and value ~= 0)
    if mask == 0xFF or mask == 0 then return pcall(writeBytes, a, on and 1 or 0) end
    local cur = readBytes(a, 1, false)          -- shares its byte: read-modify-write
    if not cur then return false, "cannot read bitfield byte" end
    return pcall(writeBytes, a, on and (cur | mask) or (cur & ~mask & 0xFF))
  end
  return false, "unsupported property type " .. tostring(k)
end

--- Read a property the same way, so callers stop guessing the width too.
function ESP.readProp(obj, cls, name)
  local e = ESP.prop(cls, name)
  if not e then return end
  local a, k = obj + e.off, e.kind
  if k == "FloatProperty" then return f(a) end
  if k == "DoubleProperty" then local ok, v = pcall(readDouble, a); return ok and v or nil end
  if k == "IntProperty" or k == "UInt32Property" then return i32(a) end
  if k == "Int64Property" or k == "UInt64Property" then return q(a) end
  if k == "Int16Property" or k == "UInt16Property" then return u16(a) end
  if k == "ByteProperty" or k == "Int8Property" then
    local ok, v = pcall(readBytes, a, 1, false); return ok and v or nil
  end
  if k == "BoolProperty" then
    local ok, v = pcall(readBytes, a, 1, false)
    if not ok or not v then return end
    local mask = e.byteMask or 0xFF
    return (mask == 0xFF or mask == 0) and (v ~= 0) or ((v & mask) ~= 0)
  end
end

function ESP.validActor(obj)
  local idx = i32(obj + 0x0C)                 -- UObjectBase::InternalIndex
  if not idx or idx < 0 then return false end
  local objects = q(ESP.gobj)
  if not objects then return false end
  local chunk = ESP.chunkAt(objects, idx >> 16)
  if not chunk then return false end
  local item = chunk + (idx & 0xFFFF) * 24
  if q(item) ~= obj then return false end     -- slot recycled: this is gone
  local flags = i32(item + 8) or 0
  return (flags & (PENDING_KILL | UNREACHABLE)) == 0
end

--- Corpses keep their actor alive, so filter them out or the boxes stay put.
function ESP.alive(actor)
  local cls = q(actor + 0x10)
  local dead = ESP.propOffset(cls, "IsDead")
  if dead then
    local ok, b = pcall(readBytes, actor + dead, 1, false)
    if ok and b and b ~= 0 then return false end
  end
  local hp = ESP.propOffset(cls, "Health")
  if hp then
    local v = f(actor + hp)
    if v and v <= 0 then return false end
    return true, v
  end
  return true
end

function ESP.halfHeight(actor)
  local cls = q(actor + 0x10)
  local capOff = ESP.propOffset(cls, "CapsuleComponent")
  if capOff then
    local cap = q(actor + capOff)
    if cap then
      local hh = ESP.propOffset(q(cap + 0x10), "CapsuleHalfHeight")
      if hh then
        local v = f(cap + hh)
        if v and v > 10 and v < 500 then return v end
      end
    end
  end
  return 60
end

--- The rendered mesh's own bounds. Far better than the capsule, which is a
--- fixed cylinder for every character while these track the actual pose.
---
--- CachedWorldSpaceBounds is exactly what it says -- WORLD space, not
--- component space. Treating it as local and adding the actor position on top
--- double-counted the height, which is why team-mates' boxes floated far above
--- them whenever the ground was uneven. It is also *cached*: on actors that
--- have not refreshed it, the origin is stale, so compare it against the
--- actor's own Z and fall back to the capsule when it has drifted.
--- FBoxSphereBounds: FVector Origin, FVector BoxExtent, float SphereRadius
--- Returns worldBottom, worldTop, radius, meshRelativeZ.
--- Vertical extent of the model, in WORLD space.
---
--- CachedWorldSpaceBounds does not hold world coordinates on this build,
--- whatever the name says. Measured across enemies standing at world z 197,
--- 217 and 265, Origin.z stayed between 86 and 115 every time -- it does not
--- track the actor at all. It is mesh-local, with the mesh origin at the
--- model's feet, so the conversion is actorZ + RelativeLocation.Z + local.
--- Cross-check: an actor at z=198 with relZ=-104 gives a bottom of 101, and
--- its capsule (half-height 96) puts its feet at 102.
---
--- Returning the local numbers as if they were world is what drew ESP boxes
--- at the wrong height and made the aim clamp -- `zTop - actorZ` -- mix two
--- coordinate spaces, which put the lock below the model's feet whenever the
--- actor's world z was large and positive.
function ESP.meshBounds(actor, actorZ)
  local cls = q(actor + 0x10)
  local moff = ESP.propOffset(cls, "Mesh")
  local mesh = moff and q(actor + moff)
  if not mesh then return end
  local boff = ESP.propOffset(q(mesh + 0x10), "CachedWorldSpaceBounds")
  if not boff then return end
  local b = mesh + boff
  local oz, ex, ey, ez = f(b + 8), f(b + 12), f(b + 16), f(b + 20)
  if not (oz and ez) or oz ~= oz or ez ~= ez then return end
  if ez < 5 or ez > 2000 then return end
  local relZ = f(mesh + 0x124) or -ESP.halfHeight(actor)
  if not actorZ then actorZ = select(3, ESP.location(actor)) end
  if not actorZ then return nil, nil, nil, relZ end

  local base = actorZ + relZ
  local zBot, zTop = base + oz - ez, base + oz + ez
  -- A model has to straddle its own capsule. Bounds that have not been
  -- refreshed since the mesh was somewhere else fail this, and so do the
  -- stunted boxes some detached meshes carry.
  local hh = ESP.halfHeight(actor) or 96
  if zTop < actorZ - hh or zBot > actorZ + hh then
    return nil, nil, nil, relZ
  end
  return zBot, zTop, math.max(ex or 0, ey or 0), relZ
end

function ESP.location(actor)
  local root = q(actor + 0x130)                 -- AActor::RootComponent
  if not root then return end
  local x, y, z = f(root + 0x11C), f(root + 0x120), f(root + 0x124)
  if not (x and y and z) or x ~= x then return end
  if math.abs(x) + math.abs(y) < 1 then return end
  return x, y, z
end

function ESP.view(pcm)
  local cx, cy, cz = f(pcm + 0x1AF0), f(pcm + 0x1AF4), f(pcm + 0x1AF8)
  local p, y, r    = f(pcm + 0x1AFC), f(pcm + 0x1B00), f(pcm + 0x1B04)
  local fov        = f(pcm + 0x1B08)
  if not (cx and p and fov and fov > 1) then return end
  local D = math.pi / 180
  local SP, CP = math.sin(p*D), math.cos(p*D)
  local SY, CY = math.sin(y*D), math.cos(y*D)
  local SR, CR = math.sin(r*D), math.cos(r*D)
  return {
    x = cx, y = cy, z = cz, fov = fov,
    fwd = { CP*CY, CP*SY, SP },
    rgt = { SR*SP*CY - CR*SY, SR*SP*SY + CR*CY, -SR*CP },
    up  = { -(CR*SP*CY + SR*SY), CY*SR - CR*SP*SY, CR*CP },
  }
end

function ESP.w2s(v, x, y, z, w, h)
  local dx, dy, dz = x - v.x, y - v.y, z - v.z
  local tz = dx*v.fwd[1] + dy*v.fwd[2] + dz*v.fwd[3]
  if tz < 1 then return end
  local tx = dx*v.rgt[1] + dy*v.rgt[2] + dz*v.rgt[3]
  local ty = dx*v.up[1]  + dy*v.up[2]  + dz*v.up[3]
  local sf = (w / 2) / math.tan(v.fov * math.pi / 360)
  return w/2 + tx*sf/tz, h/2 - ty*sf/tz, tz
end

--------------------------------------------------------------------------
-- Object discovery
--
-- Runs on its own thread so a fast full pass never stalls the render loop.
-- New actors usually get appended to the object array, which the fast path
-- catches within a tick; the full pass exists to pick up recycled slots,
-- which is how a respawned enemy can otherwise go missing.
--------------------------------------------------------------------------

function ESP.scanRange(objects, from, to, into)
  local seen = {}
  for _, a in ipairs(into) do seen[a.obj] = true end
  for idx = from, to - 1 do
    local o = objAt(objects, idx)
    if o and o > 0x1000000000 and not seen[o] then
      local def = ESP.classify(q(o + 0x10))
      if def and not ESP.name(i32(o + 0x18)):find("^Default__") then
        into[#into + 1] = { obj = o, def = def, tier = ESP.tier(o, def) }
      end
    end
  end
end

--- Team-mates carry a BPC_HeroineBattle_C component recording whether they are
--- downed or being assaulted, plus RapeCauser.
---
--- Finding them means a scan, so it is split in two: discovery walks the hot
--- index region and only runs when the cached list is empty or has gone stale,
--- while the per-sweep refresh just re-reads a handful of fields off the
--- components we already have. Rediscovering every sweep cost 2.3 seconds --
--- it walked all 309k objects and was single-handedly responsible for new
--- enemies taking seconds to appear.
function ESP.readAlly(comp)
  local owner = q(comp + 0x20)
  if not owner or owner < 0x1000000000 then return end
  local cn = ESP.className(q(owner + 0x10))
  if not cn:find("^BP_HeroineBase") then return end
  local ok, be = pcall(readBytes, comp + 0x151, 1, false)
  local ok2, ph = pcall(readBytes, comp + 0x150, 1, false)
  local causer = q(comp + 0x148)
  return {
    comp   = comp,
    obj    = owner,
    name   = (cn:gsub("^BP_HeroineBase_ALS_", ""):gsub("_C$", "")),
    hp     = f(comp + 0x11C), maxhp = f(comp + 0xE8),
    raped  = ok and be == 1,
    phase  = ok2 and ph or 0,
    causer = (causer and causer > 0x1000000000) and causer or nil,
  }
end

--- Cheap: only re-reads state off components we already know about.
-- refreshAllies() and scanAllies() are gone: discovery now happens inside
-- scanStep's single pass, and the state read at the end of each round is what
-- refreshAllies used to do. scanAllies walked the whole hot region on its own
-- and was measured at up to a full second of lock time per round.

function ESP.scanStep()
  local objects, num = q(ESP.gobj), i32(ESP.gobj + 0x14)
  if not objects or not num then return end
  ESP.bufAllies = ESP.bufAllies or {}

  if ESP.lastNum and num > ESP.lastNum then
    ESP.scanRange(objects, ESP.lastNum, num, ESP.actors or {})
  end
  ESP.lastNum = num

  local floor = ESP.fullSweep and 0 or math.max(0, num - ESP.HOT_SPAN)
  if ESP.cursor == nil or ESP.cursor < floor or ESP.cursor >= num then
    ESP.cursor = floor
    ESP.bufAllies = {}
    -- carry over anything the last full sweep found below the hot region, so
    -- a low-index target does not blink out between full sweeps
    ESP.buf = {}
    for _, keep in ipairs(ESP.cold or {}) do
      if ESP.validActor(keep.obj) then ESP.buf[#ESP.buf + 1] = keep end
    end
  end
  local last = math.min(ESP.cursor + ESP.SCAN_CHUNK, num)
  for idx = ESP.cursor, last - 1 do
    local o = objAt(objects, idx)
    if o and o > 0x1000000000 then
      local cls = q(o + 0x10)
      local def, nid = ESP.classify(cls)
      ESP.checkClass(cls, nid)
      if def and not ESP.name(i32(o + 0x18)):find("^Default__") then
        ESP.buf[#ESP.buf + 1] = { obj = o, def = def, tier = ESP.tier(o, def) }
      elseif nid then
        local cn = ESP.name(nid)
        if cn == "PlayerCameraManager" then
          -- several of these can exist; take whichever has a live POV
          local x, y, fov = f(o + 0x1AF0), f(o + 0x1AF4), f(o + 0x1B08)
          if x and y and fov and fov > 30 and fov < 170
             and (math.abs(x) + math.abs(y)) > 1 then
            ESP.bufPcm = o
          elseif not ESP.bufPcm then ESP.bufPcm = o end
        elseif cn == ESP.ALLY_CLASS
               and not ESP.name(i32(o + 0x18)):find("^Default__") then
          ESP.bufAllies[#ESP.bufAllies + 1] = o
        elseif cn:find(ESP.PLAYER_PREFIX)
               and not ESP.name(i32(o + 0x18)):find("^Default__")
               and ESP.isPawnClass(cls, nid) then
          -- We are already reading every object's class here. Picking the pawn
          -- out costs a prefix test and saves PLAYER/AIM/SOD from each walking
          -- the array themselves. Later index wins, i.e. the newest pawn.
          ESP.bufPlayer = o
        end
      end
    end
  end
  ESP.cursor = last
  if ESP.cursor >= num then
    -- Allies were picked up on the way past, so this is just a state read of a
    -- handful of components. Discovery used to be its own walk of the whole hot
    -- region and was the single longest thing this thread ever did.
    local out = {}
    for _, comp in ipairs(ESP.bufAllies) do
      local al = ESP.readAlly(comp)
      if al then out[#out + 1] = al end
    end
    ESP.allies, ESP.alliesFound = out, os.clock()
    if ESP.fullSweep then
      -- remember what lives outside the hot region before switching back
      local cold, edge = {}, math.max(0, num - ESP.HOT_SPAN)
      for _, a in ipairs(ESP.buf) do
        local idx = i32(a.obj + 0x0C)
        if idx and idx < edge then cold[#cold + 1] = a end
      end
      ESP.cold = cold
      ESP.lastFull = os.clock()
      ESP.fullSweep = false
    elseif os.clock() - (ESP.lastFull or 0) > ESP.FULL_EVERY then
      ESP.fullSweep = true
    end
    ESP.actors = ESP.buf
    if ESP.bufPcm then ESP.pcm = ESP.bufPcm end
    ESP.player = ESP.bufPlayer            -- nil means "there is no pawn"

    -- The pawn is created when the level loads, so its index is low and it
    -- drops out of the hot region as the game allocates. A hot round then
    -- reports "no pawn" for something that is standing right there, and every
    -- feature that needs it goes dead until the next scheduled full sweep --
    -- up to FULL_EVERY seconds away. Escalate instead.
    if ESP.player then
      ESP.playerMissingSince = nil
    else
      ESP.playerMissingSince = ESP.playerMissingSince or os.clock()
      if os.clock() - ESP.playerMissingSince > 2
         and os.clock() - (ESP.lastPawnHunt or 0) > 10 then
        ESP.lastPawnHunt = os.clock()
        ESP.fullSweep = true
      end
    end
    ESP.cursor, ESP.buf, ESP.bufPcm, ESP.bufPlayer, ESP.bufAllies = nil, {}, nil, nil, {}
  end
end

--------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------

local COLOUR_KEY = 0x000000

--- Lazarus' TransparentColor does nothing here: the black fill stays opaque
--- and swallows the whole screen, which has trapped the user twice. Win32
--- colour-keying is the reliable route, and it must be applied while the
--- window is still hidden -- doing it after show() sometimes does not take.
--- pcall only reports that the call was made. SetWindowLongA returning 0 and
--- SetLayeredWindowAttributes returning FALSE both used to count as success,
--- and the overlay then came up as an opaque black rectangle over the whole
--- screen -- which has trapped the user twice. Read the style back instead:
--- without WS_EX_LAYERED the colour key does nothing.
local function setLayered(handle)
  local sl = getAddress("user32.SetWindowLongA")
  local gl = getAddress("user32.GetWindowLongA")
  local sa = getAddress("user32.SetLayeredWindowAttributes")
  if not (sl and gl and sa) then return false end
  local WS_EX_LAYERED = 0x80000
  -- WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
  if not pcall(executeCodeLocalEx, sl, handle, -20,
               WS_EX_LAYERED | 0x20 | 0x80 | 0x08000000) then return false end
  local okr, style = pcall(executeCodeLocalEx, gl, handle, -20)
  if not okr or not style or (style & WS_EX_LAYERED) == 0 then return false end
  local ok2, res = pcall(executeCodeLocalEx, sa, handle, COLOUR_KEY, 0, 1)  -- LWA_COLORKEY
  return ok2 and res ~= nil and res ~= 0
end

--- CE's Lua leaves fsStayOnTop undefined, so the named constant silently sets
--- FormStyle to nil and the window stays behind a fullscreen game.
local function setTopmost(form)
  pcall(function() form.FormStyle = 5 end)
  local swp = getAddress("user32.SetWindowPos")
  if swp then pcall(executeCodeLocalEx, swp, form.Handle, -1, 0, 0, 0, 0, 0x13) end
end

function ESP.draw()
  local form = ESP.form
  if not form then return end
  local w, h = form.Width, form.Height

  -- Draw the whole frame into an offscreen bitmap and blit it once. Clearing
  -- and redrawing straight on the window canvas made the overlay flicker on
  -- every frame, because DWM composited the half-erased state.
  if not ESP.bmp then
    ESP.bmp = createBitmap(w, h)
    ESP.fullClear = true
  end
  local c = ESP.bmp.Canvas
  c.Brush.Style = bsSolid
  c.Brush.Color = COLOUR_KEY

  ESP.frame = (ESP.frame or 0) + 1
  if ESP.fullClear or ESP.frame % 200 == 0 then
    c.fillRect(0, 0, w, h)
    ESP.fullClear = false
  else
    for _, r in ipairs(ESP.dirty or {}) do c.fillRect(r[1], r[2], r[3], r[4]) end
  end
  local dirty = {}

  local pcm = ESP.pcm
  if pcm then
    local v = ESP.view(pcm)
    if v then
      c.Font.Size = 9
      local shown = 0
      for _, a in ipairs(ESP.actors or {}) do
        local tier = a.tier or "trash"
        local x, y, z
        if ESP.show[tier] and ESP.validActor(a.obj) then
          x, y, z = ESP.location(a.obj)
        end
        local ok, hp = true, nil
        if a.def.kind == "enemy" then ok, hp = ESP.alive(a.obj) end
        if x and ok then
          local dist = math.sqrt((x-v.x)^2 + (y-v.y)^2 + (z-v.z)^2) / 100
          local limit = (a.def.kind == "item") and ESP.ITEM_DIST_M or ESP.MAX_DIST_M
          if dist <= limit then
            local zTop, zBot
            if a.def.kind == "enemy" then
              zBot, zTop = ESP.meshBounds(a.obj, z)
              if not zBot then
                local hh = ESP.halfHeight(a.obj)
                zBot, zTop = z - hh, z + hh
              end
            else
              zBot, zTop = z - 25, z + 25
            end
            local fx, fy = ESP.w2s(v, x, y, zBot, w, h)
            local hx, hy = ESP.w2s(v, x, y, zTop, w, h)
            if fx and hx and fx > -w and fx < 2*w then
              local hpx = math.max(6, fy - hy)
              local wpx = hpx * 0.45
              local x1, y1 = math.floor(fx - wpx/2), math.floor(hy)
              local x2, y2 = math.floor(fx + wpx/2), math.floor(fy)
              -- one hollow rect, not four lines: every canvas op on a layered
              -- window costs a composite, so the call count is what caps fps
              local col = a.def.colour or ESP.TIER_COLOUR[tier] or 0xFFFFFF
              c.Pen.Color = col
              c.Pen.Width = (a.def.kind == "enemy") and 2 or 1
              c.Brush.Style = bsClear
              c.rect(x1, y1, x2, y2)
              c.Font.Color = col
              local text = hp and string.format("%s %.0fm %.0fhp", a.def.label, dist, hp)
                              or string.format("%s %.0fm", a.def.label, dist)
              c.textOut(x1, math.max(0, y1 - 15), text)
              c.Brush.Style = bsSolid
              dirty[#dirty + 1] = { x1 - 4, math.max(0, y1 - 20), x2 + 190, y2 + 4 }
              shown = shown + 1
            end
          end
        end
      end
      ESP.lastShown = shown
      c.Brush.Style = bsClear
      c.Font.Color = 0x00FF00
      c.textOut(8, 8, string.format("ESP  %d/%d", shown, #(ESP.actors or {})))
      -- Items left in this match, in the item colour so it reads as a pickup
      -- counter rather than part of the ESP line above it.
      if PLAYER and PLAYER.lootTotal then
        local prev = c.Font.Color
        c.Font.Color = ESP.ITEM_COLOUR["物品"] or 0xFF66FF
        c.textOut(8, 24, string.format("物品  %d/%d", PLAYER.lootLeft or 0, PLAYER.lootTotal))
        c.Font.Color = prev
      end
      c.Brush.Style = bsSolid
    end
  end
  -- Team-mates: their state is what tells the player who needs rescuing.
  if ESP.show.ally and pcm then
    local v = ESP.view(pcm)
    if v then
      for _, al in ipairs(ESP.allies or {}) do
        if ESP.validActor(al.obj) then
          local x, y, z = ESP.location(al.obj)
          if x then
            local zBot, zTop = ESP.meshBounds(al.obj, z)
            if not zBot then
              local hh = ESP.halfHeight(al.obj)
              zBot, zTop = z - hh, z + hh
            end
            local fx, fy = ESP.w2s(v, x, y, zBot, w, h)
            local hx, hy = ESP.w2s(v, x, y, zTop, w, h)
            if fx and hx then
              local hpx = math.max(6, fy - hy)
              local wpx = hpx * 0.45
              local x1, y1 = math.floor(fx - wpx/2), math.floor(hy)
              local x2, y2 = math.floor(fx + wpx/2), math.floor(fy)
              local col = al.raped and ESP.TIER_COLOUR.rescue or ESP.TIER_COLOUR.ally
              c.Pen.Color = col
              c.Pen.Width = al.raped and 3 or 1
              c.Brush.Style = bsClear
              c.rect(x1, y1, x2, y2)
              c.Font.Color = col
              local dist = math.sqrt((x-v.x)^2 + (y-v.y)^2 + (z-v.z)^2) / 100
              -- phase 2 turned out to mean nothing useful: a team-mate on 5 hp
              -- reported it while still on her feet. Only flag the grab.
              c.textOut(x1, math.max(0, y1 - 15), string.format("%s%s %.0f/%.0f  %.0fm",
                al.raped and "救援! " or "", al.name, al.hp or 0, al.maxhp or 0, dist))
              c.Brush.Style = bsSolid
              dirty[#dirty + 1] = { x1 - 4, math.max(0, y1 - 20), x2 + 220, y2 + 4 }
            end
          end
        end
      end
    end
  end

  -- Draw where silent aim is currently locked, so a shot that does not connect
  -- can be told apart from a shot that never had a target.
  -- Snapshot first. Testing AIM.current and then reading it again leaves a
  -- window for the aim thread to clear it in between -- ESP.view() below is
  -- enough of a yield for that to happen, and it did.
  local t = AIM and AIM.enabled and AIM.current
  if t and ESP.pcm then
    local v = ESP.view(ESP.pcm)
    if v then
      local sx, sy = ESP.w2s(v, t.x, t.y, t.z, w, h)
      if sx and sx > 0 and sx < w and sy > 0 and sy < h then
        local R = 14
        c.Pen.Color = t.sticky and 0x00FFFF or 0x00FF00
        c.Pen.Width = 2
        c.Brush.Style = bsClear
        c.line(sx - R, sy, sx - 4, sy)
        c.line(sx + 4, sy, sx + R, sy)
        c.line(sx, sy - R, sx, sy - 4)
        c.line(sx, sy + 4, sx, sy + R)
        c.Brush.Style = bsSolid
        dirty[#dirty + 1] = { sx - R - 3, sy - R - 3, sx + R + 3, sy + R + 3 }
      end
    end
  end

  dirty[#dirty + 1] = { 0, 0, 300, 44 }   -- the two HUD lines in the corner

  -- One blit per frame: the window canvas is only ever touched here, so DWM
  -- has exactly one composite to do and never sees a partially drawn frame.
  form.Canvas.draw(0, 0, ESP.bmp)
  ESP.dirty = dirty
end

function ESP.stop()
  ESP.running = false
  for _, k in ipairs({ "thread", "scanThread" }) do
    if ESP[k] then pcall(function() ESP[k].terminate() end); ESP[k] = nil end
  end
  -- Unguarded, a throw here skipped the bitmap and timeEndPeriod below it.
  if ESP.form then pcall(function() ESP.form.destroy() end); ESP.form = nil end
  if ESP.bmp then pcall(function() ESP.bmp.destroy() end); ESP.bmp = nil end
  -- These loops are off on purpose; without this the status line reports them
  -- as stalled forever.
  for _, n in ipairs({ "draw", "draw.paint", "scan" }) do
    if ESP.health[n] then ESP.health[n].stopped = true end
  end
  -- timeBeginPeriod raises the system timer resolution process-wide and has to
  -- be handed back; without the matching call CE keeps the machine at 1 ms.
  if ESP.timerRaised then
    local tep = getAddress("winmm.timeEndPeriod")
    if tep then pcall(executeCodeLocalEx, tep, 1) end
    ESP.timerRaised = false
  end
end

--- Full unload, as opposed to stop(): also gives up the END hotkey. Left
--- registered it keeps re-launching the overlay and its two threads long after
--- everything else has been disabled.
function ESP.teardown()
  ESP.stop()
  if ESP.hotkey then pcall(function() ESP.hotkey.destroy() end); ESP.hotkey = nil end
end

--- `small` draws into a 700x500 window instead of covering the screen. Use it
--- to sanity-check transparency: if colour-keying silently fails at fullscreen
--- there is no way to click past the window.
function ESP.start(small)
  ESP.stop()
  ESP.rebase()
  ESP.timerRaised = true
  local tbp = getAddress("winmm.timeBeginPeriod")
  if tbp then pcall(executeCodeLocalEx, tbp, 1) end

  ESP.actors, ESP.pcm, ESP.cursor, ESP.buf, ESP.lastNum = {}, nil, nil, {}, nil
  -- A completed round leaves the cursor nil, not 0, so the old `cursor == 0`
  -- test never fired and all 30 chunks ran on the calling thread. With
  -- lastFull unset the round end then kicked off a whole-array sweep on top,
  -- which is why toggling the overlay froze the UI for seconds. Seed lastFull
  -- so the first full sweep happens later, on the scan thread where it belongs.
  ESP.lastFull = os.clock()
  local budget = os.clock() + 0.8
  for _ = 1, 30 do
    ESP.scanStep()
    if ESP.cursor == nil then break end          -- one round complete
    if os.clock() > budget then break end        -- the scan thread finishes it
  end

  local form = createForm(false)
  form.BorderStyle  = bsNone
  form.Position     = poDesigned
  form.Left, form.Top = small and 100 or 0, small and 100 or 0
  form.Width  = small and 700 or (getScreenWidth  and getScreenWidth()  or 2560)
  form.Height = small and 500 or (getScreenHeight and getScreenHeight() or 1440)
  form.Color        = COLOUR_KEY
  form.ShowInTaskBar = stNever

  -- Force the handle, make the window layered and colour-keyed, and only then
  -- show it. If the colour key cannot be set, do not show anything at all --
  -- an opaque fullscreen window with no way past it is far worse than no ESP.
  -- Record the size for the worker threads: they must not touch the control.
  ESP.w, ESP.h = form.Width, form.Height
  local handle = form.Handle
  local keyed = setLayered(handle)
  if not keyed then
    form.destroy()
    print("[SoD] ESP aborted: colour-key transparency unavailable")
    return 0, nil, false
  end
  form.show()
  setTopmost(form)
  setLayered(handle)
  ESP.form = form
  if ESP.bmp then pcall(function() ESP.bmp.destroy() end) end
  ESP.bmp = createBitmap(form.Width, form.Height)
  ESP.fullClear, ESP.dirty, ESP.frame = true, {}, 0

  ESP.running = true
  -- A TTimer cannot exceed ~60 fps (SetTimer has a 10 ms floor and rides the
  -- 15.6 ms tick), and repaint() forces DWM to recomposite the whole layered
  -- window. Drive from a thread and draw straight onto the canvas instead.
  ESP.thread = createThread(function(t)
    while ESP.running and not t.Terminated do
      ESP.guard("draw", function()
        synchronize(function()
          -- Anything thrown in here surfaces on the main thread as a modal
          -- error box, which is its own cascade: the box pumps messages and
          -- re-enters whatever was running.
          if ESP.form then
            ESP.guard("draw.paint", ESP.draw)
            ESP.topmostTick = (ESP.topmostTick or 0) + 1
            if ESP.topmostTick % 600 == 0 then setTopmost(ESP.form) end
          end
        end)
      end)
      sleep(ESP.TICK_MS)
    end
  end)
  ESP.scanThread = createThread(function(t)
    while ESP.running and not t.Terminated do
      ESP.guard("scan", ESP.scanStep)
      sleep(ESP.SCAN_TICK_MS)
    end
  end)

  if not ESP.hotkey then
    ESP.hotkey = createHotkey(function()
      if ESP.running then ESP.stop() else ESP.start(false) end
    end, ESP.HOTKEY)
  end
  return #(ESP.actors or {}), ESP.pcm, true
end

return "sod_esp loaded"
