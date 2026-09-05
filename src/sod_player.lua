--------------------------------------------------------------------------
-- Player-side cheats. Every offset is resolved by property name through UE's
-- reflection data, so nothing here is tied to a build: the community table's
-- hardcoded +0x620 and friends are only used as a cross-check.
--------------------------------------------------------------------------

PLAYER = PLAYER or {}
-- Kept only for messages: the actual test is ESP.isPawnClass, because the
-- pawn's class differs between levels (BP_PL_ActPlayer_C and BP_PL_Player_C
-- have both been observed).
PLAYER.CLASS   = "BP_PL_ActPlayer_C"
PLAYER.TICK_MS = 5            -- the fire gate has to be re-opened promptly

PLAYER.opts = PLAYER.opts or {
  invincible = false,
  stamina    = false,
  grenades   = false,
  autoFire   = false,   -- hold to keep firing, even on burst/semi weapons
  fastFire   = false,
  allyGod    = false,   -- team-mates immune to damage
  allyNoRape = false,   -- team-mates cannot be grabbed at all
  bigDamage  = false,   -- overwhelm the distance falloff curve
  megaMelee  = false,   -- melee reach far beyond arm's length
}

-- BP_WeaponBase_C::MeleeRange ships at 150 (1.5 m). Melee runs the same
-- StartLocMelee -> EndLocMelee trace the gun does, so the number is a plain
-- reach in centimetres and nothing else has to change.
PLAYER.MELEE_RANGE = 30000

-- Damage is BaseDamage scaled by the DistanceDamage curve (a shared
-- CurveFloat asset, so editing it would hit every weapon using it). Raising
-- BaseDamage instead leaves the curve alone and still lands a kill at any
-- range. The stock value is read back from the class default when switching
-- off, rather than being remembered here.
PLAYER.BIG_DAMAGE = 9999

-- BPC_HeroineBattle_C, confirmed against the community table's layout.
PLAYER.ALLY = {
  CantRape   = "CantRapeCharacter",
  IgnoreDmg  = "IgnoreDamage",
  Downed     = "UnbaleToFight",
  HP         = "1stHealth",   MaxHP  = "Max1stHealth",
  HP2        = "2ndHealth",   MaxHP2 = "Max2ndHealth",
  Shield     = "ShieldPoint", MaxShield = "MaxShieldPoint",
}

-- The real trigger gate is on the pawn, not the weapon: NextFire is the
-- "cooldown finished, you may shoot again" permission flag, and FireRate is a
-- straight multiplier. BP_WeaponBase_C::ContinutyFire turned out not to govern
-- burst weapons at all.
PLAYER.FIRE_RATE = 4.0

local function q(a)   local ok, v = pcall(readQword, a);        if ok then return v end end
local function i32(a) local ok, v = pcall(readInteger, a);      if ok then return v end end
local function f(a)   local ok, v = pcall(readFloat, a);        if ok then return v end end

--- Relies on ESP's reflection helpers; load sod_esp.lua first.
PLAYER.HOT_COOLDOWN_MS  = 1500     -- the pawn is a recent object; cheap to look for
PLAYER.FULL_COOLDOWN_MS = 15000    -- whole-array sweep: only a backstop
PLAYER.SCAN_COOLDOWN_MS = PLAYER.HOT_COOLDOWN_MS   -- kept for older callers

function PLAYER.find()
  local cached = PLAYER.actor
  if cached and ESP.validActor(cached) and ESP.isPawnClass(q(cached + 0x10)) then
    return cached
  end
  PLAYER.actor = nil

  -- A miss costs a full walk of the object array -- ~300k entries, several
  -- seconds. There is legitimately no pawn between matches, on loading
  -- screens and while dead, and PLAYER/AIM/SOD all call this every few
  -- milliseconds: without a cooldown three worker threads sit in that walk
  -- back to back and the game stutters until a pawn reappears.
  -- The scan thread already walks the hot region every ~100ms and picks the
  -- pawn out on the way past. Taking its answer replaces a sweep that cost
  -- ~2s here, and the same sweep again in AIM.tick and in SOD.records.
  local fromScanner = ESP.player
  if fromScanner and ESP.validActor(fromScanner)
     and ESP.isPawnClass(q(fromScanner + 0x10)) then
    PLAYER.actor, PLAYER.cls = fromScanner, q(fromScanner + 0x10)
    PLAYER.nextScan, PLAYER.nextFull = nil, nil
    return fromScanner
  end
  -- Never sweep here while the scanner is running. Re-acquisition is its job:
  -- it escalates to a full sweep when it loses the pawn. Sweeping here as a
  -- "fallback" meant three threads each walking the whole array whenever there
  -- is legitimately no pawn -- a menu, a loading screen -- and each walk was
  -- measured at 11 seconds of held lock.
  if ESP.running then return end

  if PLAYER.nextScan and getTickCount() < PLAYER.nextScan then return end

  local objects, num = q(ESP.gobj), i32(ESP.gobj + 0x14)
  if not objects or not num then return end

  local function sweep(from, to)              -- newest first: the live pawn
    for idx = from, to, -1 do
      local c = ESP.chunkAt(objects, idx >> 16)
      local o = c and q(c + (idx & 0xFFFF) * 24)
      if o and o > 0x1000000000
         and ESP.isPawnClass(q(o + 0x10))
         and not ESP.name(i32(o + 0x18)):find("^Default__") then
        return o
      end
    end
  end

  -- The pawn is a recently created object, so the newest slice almost always
  -- has it and costs a fraction of the whole array. Fall back to the full walk
  -- only when that misses.
  -- On the main menu and during loading there is legitimately no pawn, and the
  -- full sweep is the expensive half. Give it its own, much longer cooldown so
  -- idling in a menu does not mean a whole-array walk every 1.5 seconds.
  local hot = ESP.HOT_SPAN or 80000
  local o = sweep(num - 1, math.max(0, num - hot))
  if not o and num - hot > 0
     and (not PLAYER.nextFull or getTickCount() >= PLAYER.nextFull) then
    o = sweep(num - hot - 1, 0)
    PLAYER.nextFull = getTickCount() + PLAYER.FULL_COOLDOWN_MS
  end

  if o then
    PLAYER.actor    = o
    PLAYER.cls      = q(o + 0x10)
    PLAYER.nextScan, PLAYER.nextFull = nil, nil
    return o
  end

  -- Time the cooldown from when the sweep finished, not when it started: the
  -- full walk outlasts the cooldown, so starting the clock early lets the next
  -- call re-scan immediately and the backoff does nothing.
  PLAYER.nextScan = getTickCount() + PLAYER.HOT_COOLDOWN_MS
end

function PLAYER.off(name)
  local a = PLAYER.actor
  if not a then return end
  return ESP.propOffset(q(a + 0x10), name)
end

function PLAYER.read(name, kind)
  local a, o = PLAYER.actor, PLAYER.off(name)
  if not (a and o) then return end
  if kind == "float" then return f(a + o) end
  if kind == "byte" then
    local ok, v = pcall(readBytes, a + o, 1, false)
    if ok then return v end
    return
  end
  return i32(a + o)
end

function PLAYER.tick()
  local a = PLAYER.find()
  if not a then return end
  local o = PLAYER.opts

  if o.invincible then
    -- Width and bit layout come from reflection: bInvincible may be a native
    -- bitfield sharing its byte with other flags, and writing the whole byte
    -- would clear them.
    if ESP.readProp(a, PLAYER.cls, "bInvincible") ~= true then
      ESP.writeProp(a, PLAYER.cls, "bInvincible", true)
    end
  end

  if o.stamina then
    local off = PLAYER.off("CurrentStamina")
    if off then
      local cur = ESP.readProp(a, PLAYER.cls, "CurrentStamina")
      -- The scale is unknown (this build tops out at 5, not 100), so learn the
      -- ceiling from the highest value seen rather than writing a guess the
      -- game would just clamp back.
      if type(cur) == "number" and cur == cur then
        PLAYER.staminaMax = math.max(PLAYER.staminaMax or 0, cur)
        if PLAYER.staminaMax > 0 and cur < PLAYER.staminaMax then
          ESP.writeProp(a, PLAYER.cls, "CurrentStamina", PLAYER.staminaMax)
        end
      end
    end
  end

  -- Only hold the gate open while the trigger is actually held. Pinning it
  -- unconditionally meant one click started a burst that never stopped,
  -- because the blueprint kept seeing permission to fire again.
  -- Hold opens the gate, release slams it shut. Merely *not* writing on
  -- release was not enough: a full-auto weapon keeps NextFire at 1 by itself,
  -- so one click turned into fire that never stopped.
  -- Only help weapons that need it. A weapon whose ContinutyFire is already
  -- set handles held fire on its own, and forcing the gate on those is exactly
  -- what produced the runaway.
  if o.autoFire and AIM and AIM.gun then
    local gun = AIM.gun()
    local alreadyAuto = false
    if gun then
      local cf = ESP.propOffset(q(gun + 0x10), "ContinutyFire")
      if cf then
        local ok, v = pcall(readBytes, gun + cf, 1, false)
        alreadyAuto = ok and v == 1
      end
    end
    if not alreadyAuto then
      local want = isKeyPressed(VK_LBUTTON or 0x01) and 1 or 0
      local cur  = ESP.readProp(a, PLAYER.cls, "NextFire")
      if cur ~= nil and cur ~= want and cur ~= (want == 1) then
        ESP.writeProp(a, PLAYER.cls, "NextFire", want)
      end
    end
  end

  -- Rate of fire is deliberately left alone. ContinutyTime, weapon-actor time
  -- dilation and clearing PlayingFire were all measured to change nothing, and
  -- the last of those fought the blueprint's own state machine badly enough to
  -- leave full-auto weapons firing forever after a few quick clicks.

  -- Team-mates. Stopping the grab before it happens beats rescuing afterwards,
  -- and it is the same component the ESP already reads their state from.
  if (o.allyGod or o.allyNoRape) and ESP and ESP.allies then
    for _, al in ipairs(ESP.allies) do
      local c = al.comp
      if c then
        local cls = q(c + 0x10)
        -- The caller no longer says how wide each field is; reflection does.
        local function put(key, val)
          local name = PLAYER.ALLY[key]
          local cur  = ESP.readProp(c, cls, name)
          if cur == nil then return end
          local want = val
          if type(cur) == "boolean" then want = (val ~= 0 and val ~= false) end
          if cur ~= want then ESP.writeProp(c, cls, name, want) end
        end
        if o.allyNoRape then put("CantRape", 1) end
        if o.allyGod then
          put("IgnoreDmg", 1)
          put("Downed", 0)
          for _, pair in ipairs({ { "HP", "MaxHP" }, { "HP2", "MaxHP2" },
                                 { "Shield", "MaxShield" } }) do
            local max = ESP.readProp(c, cls, PLAYER.ALLY[pair[2]])
            if type(max) == "number" and max > 0 then put(pair[1], max) end
          end
        end
      end
    end
  end

  if o.bigDamage and AIM and AIM.gun then
    local gun = AIM.gun()
    if gun then
      -- writeInteger into a FloatProperty stores 0x270F, which reads back as
      -- ~1.4e-41: the option would have quietly set damage to zero instead.
      local wcls = q(gun + 0x10)
      local cur  = ESP.readProp(gun, wcls, "BaseDamage")
      if type(cur) == "number" and math.abs(cur - PLAYER.BIG_DAMAGE) > 0.5 then
        ESP.writeProp(gun, wcls, "BaseDamage", PLAYER.BIG_DAMAGE)
      end
    end
  end

  if o.megaMelee and AIM and AIM.gun then
    local gun = AIM.gun()
    if gun then
      local wcls = q(gun + 0x10)
      local cur  = ESP.readProp(gun, wcls, "MeleeRange")
      if type(cur) == "number" and math.abs(cur - PLAYER.MELEE_RANGE) > 1 then
        ESP.writeProp(gun, wcls, "MeleeRange", PLAYER.MELEE_RANGE)
      end
    end
  end

  PLAYER.lootCount()
  PLAYER.lootTick()

  if o.grenades then
    local max = ESP.readProp(a, PLAYER.cls, "MaxGrenadeAmmo")
    if type(max) == "number" and max > 0
       and ESP.readProp(a, PLAYER.cls, "GrenadeAmmo") ~= max then
      ESP.writeProp(a, PLAYER.cls, "GrenadeAmmo", max)
    end
  end
end

--- Put weapon fields back to whatever the class default says. Reading the CDO
--- beats bookkeeping: reloading the script would lose any record we kept.
function PLAYER.restoreWeaponField(field)
  if not (ESP and ESP.gobj) then return end
  local objects, num = q(ESP.gobj), i32(ESP.gobj + 0x14)
  if not objects or not num then return end
  local cdo = {}
  for idx = 0, num - 1 do
    local o = objAt(objects, idx)
    if o and o > 0x1000000000 and ESP.name(i32(o + 0x18)):find("^Default__") then
      cdo[q(o + 0x10)] = o
    end
  end
  for idx = 0, num - 1 do
    local o = objAt(objects, idx)
    if o and o > 0x1000000000 and not ESP.name(i32(o + 0x18)):find("^Default__") then
      local cls = q(o + 0x10)
      local off = cdo[cls] and ESP.propOffset(cls, field)
      if off then
        if field == "MeleeRange" then
          local want = f(cdo[cls] + off)
          if want and f(o + off) ~= want then pcall(writeFloat, o + off, want) end
        else
          local want = i32(cdo[cls] + off)
          if want and i32(o + off) ~= want then pcall(writeInteger, o + off, want) end
        end
      end
    end
  end
end

function PLAYER.restoreDamage() PLAYER.restoreWeaponField("BaseDamage") end
function PLAYER.restoreMelee()  PLAYER.restoreWeaponField("MeleeRange")  end

--------------------------------------------------------------------------
-- Loot assist
--
-- Pickups here are interaction-based, not overlap-based: the game traces for
-- something usable, parks it in BP_PL_Player_C::TraceHitActor_Near, and E acts
-- on whatever is in that field. Measured 2026-09-05: putting an item pointer
-- there and pressing E collected it from 24 metres away, so the handler does
-- no distance check of its own.
--
-- So this does not press anything. It simply offers the next item as the
-- thing E would act on, and the player presses E -- one item per press,
-- anywhere on the map. The game's own trace rewrites the field every frame,
-- hence the continuous pin.
--
-- It yields to the game: when the trace has already found something real (a
-- door, a shutter, a downed team-mate) that takes priority and nothing is
-- written, so normal interaction still works.
--------------------------------------------------------------------------
--- Exactly which classes to offer. Deliberately a class list rather than the
--- broader "kind == item": ammo, grenades and stamina pickups are common and
--- the player did not ask for them, and weapon pickups would swap the gun in
--- hand. Add names here to widen it.
PLAYER.LOOT_CLASSES   = { ["BP_PresentItemBase_C"] = true }   -- the pink spheres
PLAYER.LOOT_ROTATE_MS = 3000             -- move the offer along if it is not taken

local function isLootable(obj)
  if not ESP.validActor(obj) then return false end
  return PLAYER.LOOT_CLASSES[ESP.className(q(obj + 0x10))] == true
end

--- All lootable actors, nearest first.
local function lootableByDistance(px, py, pz)
  local list = {}
  for _, e in ipairs(ESP.actors or {}) do
    if isLootable(e.obj) then
      local x, y, z = ESP.location(e.obj)
      if x then
        list[#list + 1] = { obj = e.obj, d = (x - px)^2 + (y - py)^2 + (z - pz)^2 }
      end
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  return list
end

PLAYER.LOOT_COUNT_MS = 250

--- Remaining / total for the overlay corner. Counted on a timer, not per
--- frame: walking the tracked list and validating every actor is far too much
--- to do at draw rate.
function PLAYER.lootCount()
  local now = getTickCount()
  if PLAYER.lootCountAt and now - PLAYER.lootCountAt < PLAYER.LOOT_COUNT_MS then return end
  PLAYER.lootCountAt = now
  local n = 0
  for _, e in ipairs(ESP.actors or {}) do
    if isLootable(e.obj) then n = n + 1 end
  end
  PLAYER.lootLeft = n
  -- The total is per match. Reset it when the pawn changes -- that is a new
  -- level -- and otherwise keep the high-water mark, because these items sit
  -- below the hot region and only arrive in the list as full sweeps find them,
  -- so the count ramps up before it starts coming down.
  if PLAYER.lootBaseFor ~= PLAYER.actor then
    PLAYER.lootBaseFor, PLAYER.lootTotal = PLAYER.actor, n
  elseif n > (PLAYER.lootTotal or 0) then
    PLAYER.lootTotal = n
  end
end

function PLAYER.lootTick()
  if not PLAYER.opts.autoLoot then
    PLAYER.lootTarget = nil
    return
  end
  local a = PLAYER.actor
  if not a then return end
  local off = PLAYER.off("TraceHitActor_Near")
  if not off then return end

  local now = getTickCount()
  local t   = PLAYER.lootTarget

  if t and not ESP.validActor(t) then                 -- the player collected it
    PLAYER.looted = (PLAYER.looted or 0) + 1
    PLAYER.lootRank = 0                               -- back to the nearest one
    t = nil
  elseif t and now - (PLAYER.lootSince or now) > PLAYER.LOOT_ROTATE_MS then
    -- Not taken within a few seconds. That usually just means the player has
    -- not pressed E yet, so nothing is excluded permanently: the offer moves
    -- along and this one comes round again. An earlier version parked it for
    -- good, which quietly ate through the map while the player was walking.
    PLAYER.lootRank = (PLAYER.lootRank or 0) + 1
    PLAYER.lootRotated = (PLAYER.lootRotated or 0) + 1
    t = nil
  end

  if not t then
    -- Only re-pick when we need to: this walks every tracked item and reads a
    -- position for each, which is far too much to do on every tick.
    local px, py, pz = ESP.location(a)
    if not px then return end
    local list = lootableByDistance(px, py, pz)
    if #list == 0 then PLAYER.lootTarget = nil return end
    local rank = (PLAYER.lootRank or 0) % #list
    PLAYER.lootRank = rank
    t = list[rank + 1].obj
    PLAYER.lootDist = math.sqrt(list[rank + 1].d)
    PLAYER.lootTarget, PLAYER.lootSince = t, now
  end

  -- Let anything the game itself found win: doors, shutters, a team-mate to
  -- pick up. Only fill the field when the trace left it empty.
  local cur = readQword(a + off)
  if cur and cur > 0x1000000000 and cur ~= t then return end
  pcall(writeQword, a + off, t)
end

function PLAYER.lootReport()
  local left = 0
  for _, e in ipairs(ESP.actors or {}) do
    if isLootable(e.obj) then left = left + 1 end
  end
  return string.format("collected=%d  rotations=%d  items on the map=%d  offering=%s",
    PLAYER.looted or 0, PLAYER.lootRotated or 0, left,
    PLAYER.lootTarget and string.format("#%d, %.0f m away",
      (PLAYER.lootRank or 0) + 1, (PLAYER.lootDist or 0) / 100) or "nothing")
end

function PLAYER.stop()
  PLAYER.running = false
  if PLAYER.thread then pcall(function() PLAYER.thread.terminate() end); PLAYER.thread = nil end
end

function PLAYER.start()
  PLAYER.stop()
  if not (ESP and ESP.gobj) then ESP.rebase() end
  PLAYER.running = true
  -- worker thread: these are plain memory reads, no GUI involvement
  PLAYER.thread = createThread(function(t)
    while PLAYER.running and not t.Terminated do
      ESP.guard("player", PLAYER.tick)
      sleep(PLAYER.TICK_MS)
    end
  end)
  return PLAYER.find()
end

return "sod_player loaded"
