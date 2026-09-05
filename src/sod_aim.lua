--------------------------------------------------------------------------
-- Silent aim
--
-- The weapon blueprint stores the shot's trace endpoint on the gun actor
-- (BP_WeaponGun_C::EndLoc, +0x420) and then traces from StartLoc to EndLoc.
-- Overwriting EndLoc redirects the bullet without touching the camera, so
-- the crosshair never moves -- which is the whole point of "silent".
--
--   +0x3E0 CurrentSpread   +0x414 StartLoc   +0x420 EndLoc   +0x430 TargetActor
--------------------------------------------------------------------------

AIM = AIM or {}
AIM.enabled   = AIM.enabled or false      -- silent-aim endpoint rewriting
AIM.noSpread  = (AIM.noSpread ~= false)
AIM.wallbang  = AIM.wallbang or false
AIM.autoFire  = AIM.autoFire or false     -- force semi-auto weapons to full-auto
AIM.fastFire  = AIM.fastFire or false
-- Wallbang works by putting the whole trace segment across the target's body:
-- start just in front of it, end just behind. Nothing can sit between two
-- points that are both inside the enemy -- not even a door it is leaning on,
-- which still blocked shots at a 50 cm standoff.
AIM.WALL_GAP  = 25            -- cm in front of the aim point
AIM.WALL_OVER = 25            -- cm past it
-- Calibrated at 2560x1440 and scaled by viewport height at use time, so the
-- lock and fire radii cover the same angle on any resolution.
AIM.MAX_PX    = 600           -- crosshair radius, in pixels at 1440p
AIM.STICKY_MS = 400           -- keep the last target across brief dropouts
AIM.MAX_DIST  = 12000         -- 120 m
-- The root is the capsule centre, which is always inside the body. Reaching
-- for the chest with 0.55 of the half-height overshot the head on the shorter
-- enemy types, whose capsule is taller than the model.
AIM.AIM_FRAC  = 0.15
AIM.headshot  = (AIM.headshot ~= false)   -- aim the weak point instead of the torso
AIM.rescue    = (AIM.rescue ~= false)     -- prioritise whatever has grabbed a team-mate
AIM.autoShoot = AIM.autoShoot or false    -- pull the trigger whenever locked
-- Turret mode: the bullet's endpoint is ours to write, so the shot never has
-- to point anywhere near the target. Dropping the screen-space filter turns
-- the whole thing into a 360 degree emplacement -- no need to face anything.
-- Needs wallbang, or the relocated endpoint still has to clear geometry.
AIM.turret    = AIM.turret or false
AIM.SHOOT_MAX_PX = 260                    -- tighter than the lock radius (at 1440p)
AIM.HEAD_DROP = 12                        -- cm below the topmost bone: skull centre
AIM.BONES_OFF = 0x4B0                     -- USkinnedMeshComponent bone transforms
AIM.SKEL_BONES = 0x1B0                    -- USkeletalMesh bone-name table, 12-byte entries
-- Tried in order. "CriticalFX" is what BP_NewEnemy_Base_C names as its weak
-- point, but no skeleton here actually carries that bone or socket; the head
-- bone is what the crit FX and the head audio component really attach to.
-- Only a fallback now: BP_NewEnemy_Base_C::CriticalHitBones lists the real
-- ones per enemy, and they are not uniform -- the Shooter's is "head_x", which
-- is exactly why a hardcoded "head" missed it.
AIM.WEAK_BONES = { "head", "Head", "neck_01", "Bip001 Head" }
AIM.CRIT_BONES_OFF = "CriticalHitBones"
-- Rescue is performed by shooting the *team-mate*, not the monster holding
-- her: the game paints its marker on her chest. Aim for the upper spine.
AIM.RESCUE_BONES = { "spine_03", "spine_02", "spine_01", "Spine2", "Spine1" }
AIM.TICK_MS   = 1

-- The stub bakes StartLoc and EndLoc into assembly, where nothing can be
-- checked at run time. These stay as the expected layout and every weapon
-- class is verified against reflection before the hook is allowed to use it.
local OFF_START, OFF_END = 0x414, 0x420
AIM.OFF_START, AIM.OFF_END = OFF_START, OFF_END

local function q(a)   local ok, v = pcall(readQword, a);   if ok then return v end end
local function i32(a) local ok, v = pcall(readInteger, a); if ok then return v end end
local function f(a)   local ok, v = pcall(readFloat, a);   if ok then return v end end

--- Does this weapon class actually put StartLoc/EndLoc where the stub expects?
--- Verified once per class and remembered against the class identity.
function AIM.gunLayoutOk(gun)
  local cls = gun and q(gun + 0x10)
  if not cls then return false end
  AIM.layoutOk = AIM.layoutOk or {}
  local nid = i32(cls + 0x18)
  local e   = AIM.layoutOk[cls]
  if e and e.nid == nid then return e.ok end
  local sOff = ESP.propOffset(cls, "StartLoc")
  local eOff = ESP.propOffset(cls, "EndLoc")
  local ok   = (sOff == OFF_START and eOff == OFF_END)
  if not ok then
    print(string.format(
      "[SoD] %s: StartLoc/EndLoc at %s/%s, stub expects %X/%X -- silent aim off for this weapon",
      ESP.className(cls), tostring(sOff), tostring(eOff), OFF_START, OFF_END))
  end
  AIM.layoutOk[cls] = { nid = nid, ok = ok }
  return ok
end


--- Weapon_R is a ChildActorComponent; the gun actor hangs off its ChildActor.
--- Map bone names to indices for a skeleton, built once per skeletal mesh.
--- Anything cached against a skeletal mesh has to be revalidated against that
--- asset's own FName id: a mesh unloaded with its level leaves its address for
--- the next allocation, and a bone table copied across two different rigs is
--- silently wrong rather than absent.
local function skelId(skm) return i32(skm + 0x18) end

function AIM.boneMap(skm, num)
  AIM.boneMaps = AIM.boneMaps or {}
  local nid = skelId(skm)
  local e = AIM.boneMaps[skm]
  if e and e.nid == nid then return e.map end
  local data, n = q(skm + AIM.SKEL_BONES), i32(skm + AIM.SKEL_BONES + 8)
  if not data or n ~= num then return end
  local m = {}
  for i = 0, n - 1 do m[ESP.name(i32(data + i * 12))] = i end
  AIM.boneMaps[skm] = { nid = nid, map = m }
  return m
end

--- Height of the head above the actor's root, measured from the skeleton
--- rather than assumed from the capsule. The game marks its weak point with a
--- "CriticalFX" socket, and the topmost bone is where that socket sits; going
--- by a fraction of the capsule half-height overshot short models badly.
--- The bone index is found once per actor and then only that bone is read.
--- Offset from an actor's root to the first bone in `wanted` that its
--- skeleton actually has. Returns nil when none of them exist.
function AIM.boneOffset(actor, wanted)
  local cls = q(actor + 0x10)
  local moff = ESP.propOffset(cls, "Mesh")
  local mesh = moff and q(actor + moff)
  if not mesh then return end
  local data = q(mesh + AIM.BONES_OFF)
  local num  = i32(mesh + AIM.BONES_OFF + 8)
  if not data or not num or num < 2 or num > 400 then return end
  local skm = q(mesh + (ESP.propOffset(q(mesh + 0x10), "SkeletalMesh") or 0x480))
  local map = skm and AIM.boneMap(skm, num)
  if not map then return end
  for _, nm in ipairs(wanted) do
    local i = map[nm]
    if i and i < num then
      local z = f(data + i * 48 + 24)
      if z and z == z then
        local relZ = select(4, ESP.meshBounds(actor)) or -ESP.halfHeight(actor)
        return relZ + z      -- bone positions stay in mesh space
      end
    end
  end
end

--- Diagnostic ring buffer. Only records when the locked target changes, and
--- keeps enough context to tell apart the ways this can go wrong: a zeroed
--- pose, a stale bounds box, or a genuinely odd bone.
AIM.LOG_MAX = 40
function AIM.note(actor, offset)
  AIM.log = AIM.log or {}
  local cls = q(actor + 0x10)
  local mesh = q(actor + (ESP.propOffset(cls, "Mesh") or 0))
  local data = mesh and q(mesh + AIM.BONES_OFF)
  local num  = mesh and i32(mesh + AIM.BONES_OFF + 8)
  local skm  = mesh and q(mesh + (ESP.propOffset(q(mesh + 0x10), "SkeletalMesh") or 0x480))
  local e    = skm and AIM.headBone and AIM.headBone[skm]
  local idx  = e and e.idx
  local boneZ = (data and idx and idx < (num or 0)) and f(data + idx * 48 + 24) or nil
  local probe = 0
  if data and num and num > 4 then
    for _, p in ipairs({ 1, math.floor(num/4), math.floor(num/2) }) do
      local pz = f(data + p * 48 + 24)
      if pz and pz == pz and math.abs(pz) > probe then probe = math.abs(pz) end
    end
  end
  local _, _, az = ESP.location(actor)
  local zBot, zTop, _, relZ = ESP.meshBounds(actor, az)
  local critNames = {}
  local coff = ESP.propOffset(cls, AIM.CRIT_BONES_OFF)
  if coff then
    local d2, n2 = q(actor + coff), i32(actor + coff + 8)
    if d2 and n2 and n2 > 0 and n2 < 40 then
      for i = 0, n2 - 1 do critNames[#critNames+1] = ESP.name(i32(d2 + i * 8)) end
    end
  end
  local hh = ESP.halfHeight(actor)
  local rec = string.format(
    "%s | off=%+.0f hh=%.0f relZ=%s bone#%s z=%s probe=%.0f%s | bounds=%s | crit=[%s]",
    ESP.className(cls), offset or 0/0, hh,
    relZ and string.format("%.0f", relZ) or "?", tostring(idx),
    boneZ and string.format("%.0f", boneZ) or "?", probe,
    probe <= 25 and " POSE-STALE" or "",
    zBot and string.format("%.0f..%.0f", zBot, zTop) or "stale",
    table.concat(critNames, ","))
  -- suspicious: the aim ended up at or below the feet
  if offset and offset < -hh * 0.5 then rec = "!! " .. rec end
  table.insert(AIM.log, 1, rec)
  while #AIM.log > AIM.LOG_MAX do table.remove(AIM.log) end
end

function AIM.headOffset(actor)
  local cls = q(actor + 0x10)
  local moff = ESP.propOffset(cls, "Mesh")
  local mesh = moff and q(actor + moff)
  if not mesh then return end
  local data = q(mesh + AIM.BONES_OFF)
  local num  = i32(mesh + AIM.BONES_OFF + 8)
  if not data or not num or num < 2 or num > 400 then return end

  -- Keyed by skeleton, not by actor. The bone index describes the rig, and
  -- actor addresses get recycled: a dead enemy's slot handed its index to the
  -- next enemy allocated there, so a humanoid head index could land on a toe
  -- of a different skeleton -- which is exactly what "the weak point is at its
  -- feet" looked like.
  local skm = q(mesh + (ESP.propOffset(q(mesh + 0x10), "SkeletalMesh") or 0x480))
  if not skm or skm < 0x1000000000 then return end
  local snid = skelId(skm)
  AIM.headBone = AIM.headBone or {}
  local entry = AIM.headBone[skm]
  if entry and entry.nid ~= snid then entry = nil end
  local idx = entry and entry.idx
  local byPose = false
  if not idx then
    -- Prefer the named weak-point bone; only fall back to "whatever is highest"
    -- for rigs that have none, where that guess put the lock in mid-air above
    -- the non-humanoid elites.
    local map = AIM.boneMap(skm, num)
    if map then
      -- ask the enemy which bones it counts as critical before guessing
      local coff = ESP.propOffset(q(actor + 0x10), AIM.CRIT_BONES_OFF)
      if coff then
        local data2, n2 = q(actor + coff), i32(actor + coff + 8)
        if data2 and n2 and n2 > 0 and n2 < 60 then
          for i = 0, n2 - 1 do
            local nm = ESP.name(i32(data2 + i * 8))
            if map[nm] then idx = map[nm]; break end
          end
        end
      end
      if not idx then
        for _, nm in ipairs(AIM.WEAK_BONES) do
          if map[nm] then idx = map[nm]; break end
        end
      end
    end
    if not idx then
      -- No named head: on a quadruped like the Creaper the highest bone is a
      -- raised limb, which put the lock in mid-air. Use the centre of the mesh
      -- instead -- always inside the body, whatever the shape.
      local _, _, az = ESP.location(actor)
      local zBot, zTop = ESP.meshBounds(actor, az)
      if zBot and az then return (zBot + zTop) / 2 - az end
      local best, bestZ = nil, -1e9
      for i = 0, num - 1 do
        local z = f(data + i * 48 + 24)
        if z and z == z and math.abs(z) < 1e4 and z > bestZ then bestZ, best = z, i end
      end
      idx = best
      byPose = true          -- guessed from the current pose, not from a name
    end
    if not idx then return end
    AIM.headBone[skm] = { nid = snid, idx = idx, byPose = byPose }
  end
  if idx >= num then AIM.headBone[skm] = nil; return end
  local z = f(data + idx * 48 + 24)
  if not z or z ~= z then return end

  -- UE skips animation updates for meshes that are off-screen or far away, and
  -- their component-space transforms sit at zero. Reading the head bone then
  -- yields ~0, which put the lock at the enemy's feet. Detect the flat pose by
  -- sampling a few bones: a live skeleton always has something well above the
  -- root. When it is flat, fall back to a proportion of the capsule.
  local live = false
  for _, probe in ipairs({ 1, math.floor(num / 4), math.floor(num / 2) }) do
    if probe > 0 and probe < num then
      local pz = f(data + probe * 48 + 24)
      if pz and pz == pz and math.abs(pz) > 25 then live = true break end
    end
  end
  if not live then
    -- Only a pose-derived index needs re-resolving. Clearing a name-derived
    -- one meant every off-screen enemy of a species wiped the entry its
    -- on-screen kin had just rebuilt, several times per tick.
    if entry and entry.byPose then AIM.headBone[skm] = nil end
    return ESP.halfHeight(actor) * 0.6
  end
  -- The topmost bone is the head on humanoids, but on the non-humanoid elites
  -- it is a rig bone floating above the model, which parked the lock in empty
  -- space. Clamp against the mesh bounds -- which are world space, so convert.
  local _, _, _, relZ = ESP.meshBounds(actor)
  relZ = relZ or -ESP.halfHeight(actor)
  local _, _, az = ESP.location(actor)
  local zBot, zTop = ESP.meshBounds(actor, az)
  local offset = relZ + z
  if zBot and az then
    local topOff, midOff = zTop - az, (zBot + zTop) / 2 - az
    if offset > topOff then offset = topOff end
    if offset < midOff then offset = midOff end
  end
  return offset - AIM.HEAD_DROP
end

function AIM.gun()
  local a = PLAYER and PLAYER.find()
  if not a then return end
  local cls = q(a + 0x10)
  for _, slot in ipairs({ "Weapon_R", "Weapon_L" }) do
    local off = ESP.propOffset(cls, slot)
    local comp = off and q(a + off)
    if comp then
      local coff = ESP.propOffset(q(comp + 0x10), "ChildActor")
      local child = coff and q(comp + coff)
      -- Verify it is still a live UObject. The hook dereferences this pointer
      -- from assembly with no way to probe it, so a weapon destroyed on a
      -- swap or a level change turns into an access violation inside the
      -- game's own trace call.
      if child and child > 0x1000000000 and ESP.validActor(child) then return child end
    end
  end
end

--- Pick whatever is nearest the crosshair *on screen*. The previous version
--- compared 3D angles, which falls apart up close: at one metre, aiming at the
--- head while the aim point sits at chest height is already tens of degrees,
--- so a distant enemy could win over the one you are touching. Screen-space
--- distance is what "the enemy my crosshair is on" actually means.
---
--- It also revalidates the actor: without that the aim happily locks onto a
--- corpse or a despawned spawner that still carries its last position.
function AIM.target(v, w, h)
  local best, bestPx
  local cx, cy = w / 2, h / 2

  -- Turret: nearest enemy in three dimensions, view direction irrelevant.
  if AIM.turret then
    local bestD
    for _, e in ipairs(ESP.actors or {}) do
      if e.def.kind == "enemy" and ESP.validActor(e.obj) and ESP.alive(e.obj) then
        local x, y, z = ESP.location(e.obj)
        if x then
          local hh = ESP.halfHeight(e.obj)
          local dz = AIM.headshot and AIM.headOffset(e.obj) or nil
          local az = z + (dz or hh * AIM.AIM_FRAC)
          local len = math.sqrt((x-v.x)^2 + (y-v.y)^2 + (az-v.z)^2)
          if len > 1 and len < AIM.MAX_DIST and (not bestD or len < bestD) then
            bestD = len
            best = { x = x, y = y, z = az, px = 0, d = len, obj = e.obj, turret = true }
          end
        end
      end
    end
    if best then return best end
  end

  -- A grabbed team-mate outranks anything near the crosshair. The shot has to
  -- land on *her* -- that is how this game frees her, and it is where the game
  -- paints its own red marker -- so aim at her chest, not at the monster.
  if AIM.rescue then
    for _, al in ipairs(ESP.allies or {}) do
      if al.raped and ESP.validActor(al.obj) then
        local x, y, z = ESP.location(al.obj)
        if x then
          local dz = AIM.boneOffset(al.obj, AIM.RESCUE_BONES)
          if not dz then
            local zBot, zTop = ESP.meshBounds(al.obj, z)
            dz = zBot and ((zBot + zTop) / 2 - z) or 0
          end
          local az = z + dz
          local len = math.sqrt((x-v.x)^2 + (y-v.y)^2 + (az-v.z)^2)
          if len < AIM.MAX_DIST then
            return { x = x, y = y, z = az, px = 0, d = len, obj = al.obj, rescue = true }
          end
        end
      end
    end
  end
  for _, e in ipairs(ESP.actors or {}) do
    if e.def.kind == "enemy" and ESP.validActor(e.obj) and ESP.alive(e.obj) then
      local x, y, z = ESP.location(e.obj)
      if x then
        local hh = ESP.halfHeight(e.obj)
        local lift = AIM.headshot and AIM.headOffset(e.obj) or nil
        local ax, ay, az = x, y, z + (lift or hh * AIM.AIM_FRAC)
        local dx, dy, dz = ax - v.x, ay - v.y, az - v.z
        local len = math.sqrt(dx*dx + dy*dy + dz*dz)
        if len > 1 and len < AIM.MAX_DIST then
          local sx, sy = ESP.w2s(v, ax, ay, az, w, h)
          if sx then
            local px = math.sqrt((sx - cx)^2 + (sy - cy)^2)
            if px <= AIM.MAX_PX * (AIM.pxScale or 1) and (not bestPx or px < bestPx) then
              bestPx = px
              best = { x = ax, y = ay, z = az, px = px, d = len, obj = e.obj }
            end
          end
        end
      end
    end
  end
  return best
end

--- Disarming has to be the default action rather than a branch. Every early
--- return in the tick -- no weapon, aim switched off, no camera -- happens at
--- exactly the moments a weapon is being destroyed: level change, death,
--- weapon swap. Leaving sod_sa_gun pointing into freed memory is what the stub
--- then dereferences on every trace.
--- Order matters in both directions: close the gate before dropping the
--- pointer, publish the pointer before opening the gate.
function AIM.disarm()
  if not SA then return end
  AIM.current = nil
  -- Three WriteProcessMemory calls per millisecond forever is a lot to pay for
  -- writing zero over zero. `armed` is cleared by installHook, uninstallHook
  -- and resetForProcess, so anything that could have changed the slots behind
  -- our back forces the next disarm to write for real.
  if AIM.armed == false then return end
  pcall(writeQword, SA.on, 0)
  pcall(writeQword, SA.gun, 0)
  if SA.wall then pcall(writeQword, SA.wall, 0) end
  AIM.armed = false
end

--- One WriteProcessMemory instead of three. The stub reads this vector as
--- 8 bytes plus 4, so a target change landing between separate writes handed
--- it a new x with a stale y. A 12-byte write is still not atomic, but the
--- window shrinks from three round trips to one.
local function writeVec(addr, x, y, z)
  local ok, packed = pcall(string.pack, "<fff", x, y, z)
  if not ok then return false end
  return pcall(writeBytes, addr, { string.byte(packed, 1, 12) })
end

--- True when at least one thing that needs the weapon pointer is switched on.
local function anythingWantsTheGun()
  if AIM.enabled or AIM.noSpread then return true end
  local o = PLAYER and PLAYER.opts
  return o ~= nil and (o.bigDamage or o.megaMelee or o.autoFire) or false
end

function AIM.tick()
  -- No-spread is independent of the aim rewrite and is the part that actually
  -- works: the blueprint reads CurrentSpread when it builds the cone, and it
  -- is not recomputed inside the same microsecond window as EndLoc.
  -- With everything off, AIM.gun() still walked the whole chain -- pawn
  -- lookup, three property resolutions, a validity check -- every millisecond.
  if not anythingWantsTheGun() then
    AIM.gunPtr = nil
    AIM.disarm()
    return
  end
  local gun = AIM.gun()
  AIM.gunPtr = gun
  if not (AIM.enabled and gun) then AIM.disarm() end
  if gun and AIM.noSpread then
    -- Resolve by name rather than writing 0x3E0 into whatever class this is:
    -- AIM.gun() returns any ChildActor in the weapon slot, and on a class with
    -- a different layout that constant lands on an unrelated field.
    local soff = ESP.propOffset(q(gun + 0x10), "CurrentSpread")
    if soff and (f(gun + soff) or 0) ~= 0 then pcall(writeFloat, gun + soff, 0) end
  end
  -- Rate of fire is deliberately left alone. ContinutyTime, weapon-actor time
  -- dilation, the player's FireRate and clearing PlayingFire were each measured
  -- to change nothing, and the last of those fought the blueprint's own state
  -- machine badly enough to leave full-auto weapons firing forever. The cadence
  -- appears to come from the fire montage. See docs/INTERNALS.md.
  --
  -- ContinutyFire is read but never written: the player module uses it to tell
  -- a genuinely full-auto weapon from one whose trigger gate needs holding.

  if not AIM.enabled or not gun then return end
  local pcm = ESP.pcm; if not pcm then AIM.disarm() return end
  local v = ESP.view(pcm); if not v then AIM.disarm() return end
  -- Reading a control property from a worker thread is what sent the menu
  -- timer into a C stack overflow; ESP records the size once when it creates
  -- the overlay. The fallback is the screen, not a hardcoded 2560x1440.
  local w = ESP.w or (getScreenWidth  and getScreenWidth())  or 2560
  local h = ESP.h or (getScreenHeight and getScreenHeight()) or 1440
  AIM.pxScale = h / 1440
  local t = AIM.target(v, w, h)

  -- 18% of shots used to go unredirected because target selection had a
  -- momentary gap -- the actor list being swapped, the camera pointer briefly
  -- unset, a weapon switch. Hold the previous target across those.
  local now = os.clock() * 1000
  if t then
    if t.obj ~= AIM.lastObj then
      local az = select(3, ESP.location(t.obj)) or t.z
      pcall(AIM.note, t.obj, t.z - az)
    end
    AIM.lastTarget, AIM.lastSeen, AIM.lastObj = t, now, t.obj
  elseif AIM.lastTarget and AIM.lastObj
         and now - (AIM.lastSeen or 0) < AIM.STICKY_MS
         and ESP.validActor(AIM.lastObj) and ESP.alive(AIM.lastObj) then
    local x, y, z = ESP.location(AIM.lastObj)
    if x then
      local hh = ESP.halfHeight(AIM.lastObj)
      local dz = AIM.headshot and AIM.headOffset(AIM.lastObj) or nil
      t = { x = x, y = y, z = z + (dz or hh * AIM.AIM_FRAC), px = AIM.lastTarget.px,
            d = AIM.lastTarget.d, obj = AIM.lastObj, sticky = true }
    end
  end
  AIM.current = t
  pcall(AIM.autoTrigger, t)

  -- Writing EndLoc from here loses the race: the blueprint computes it and
  -- traces within the same microsecond. Instead feed the injected hook, which
  -- rewrites the End parameter inside the trace call itself.
  if SA then
    -- gun is non-nil and was validated by AIM.gun() above; the guard that used
    -- to stand here re-tested the same thing after the early returns had
    -- already skipped it, so it never ran. What does need checking is that the
    -- stub's baked-in offsets fit this weapon class.
    if not AIM.gunLayoutOk(gun) then AIM.disarm() return end
    pcall(writeQword, SA.gun, gun)
    AIM.armed = true
    if t then
      writeVec(SA.aim, t.x, t.y, t.z)
      -- Wallbang: start the trace just short of the target instead of at the
      -- muzzle, so whatever is in between is simply not on the segment.
      if AIM.wallbang and SA.wall then
        local dx, dy, dz = t.x - v.x, t.y - v.y, t.z - v.z
        local len = math.sqrt(dx*dx + dy*dy + dz*dz)
        if len > AIM.WALL_GAP then
          local ux, uy, uz = dx/len, dy/len, dz/len
          writeVec(SA.start, t.x - ux * AIM.WALL_GAP,
                             t.y - uy * AIM.WALL_GAP,
                             t.z - uz * AIM.WALL_GAP)
          -- push the endpoint past the target so the segment straddles the body
          writeVec(SA.aim, t.x + ux * AIM.WALL_OVER,
                           t.y + uy * AIM.WALL_OVER,
                           t.z + uz * AIM.WALL_OVER)
          pcall(writeQword, SA.wall, 1)
        else
          pcall(writeQword, SA.wall, 0)
        end
      elseif SA.wall then
        pcall(writeQword, SA.wall, 0)
      end
      pcall(writeQword, SA.on, 1)
    else
      pcall(writeQword, SA.on, 0)
      if SA.wall then pcall(writeQword, SA.wall, 0) end
    end
  end
  AIM.writes = (AIM.writes or 0) + 1
end

--- Synthesise the trigger rather than poking the blueprint's fire flags:
--- writing NextFire/PlayingFire directly fought the state machine and left
--- weapons firing forever. A real button event goes through the same path the
--- player's own click does.
local MOUSE_LEFTDOWN, MOUSE_LEFTUP = 0x0002, 0x0004
--- mouse_event goes to whatever window has focus, not to the game. With the
--- game in the background auto-fire clicks land on CE or on this trainer's own
--- menu -- which is deliberately not click-through -- and toggle whatever sits
--- under the cursor.
function AIM.gameInFocus()
  local ok, pid = pcall(getForegroundProcess)
  if ok and pid and pid == getOpenedProcessID() then
    AIM.focusMiss = 0
    return true
  end
  -- One stray reading -- a window animating, a tool briefly activating -- used
  -- to drop the trigger outright, which showed up as auto-fire skipping shots.
  -- Only give the trigger up after several consecutive misses; at a 1 ms tick
  -- that is still a handful of milliseconds.
  AIM.focusMiss = (AIM.focusMiss or 0) + 1
  AIM.fgPids = AIM.fgPids or {}
  AIM.fgPids[tostring(pid)] = (AIM.fgPids[tostring(pid)] or 0) + 1
  return AIM.focusMiss < 5
end

AIM.REASSERT_MS = 100

function AIM.setTrigger(down)
  if down and not AIM.gameInFocus() then down = false end
  if AIM.triggerHeld == down then
    if not down then return end
    -- What we believe and what the OS reports can drift apart: the player
    -- physically releases a button we synthesised a press for, or the game
    -- swallows an event. There is one button, so their release cancels our
    -- press -- and with a target still in view `want` never goes false, so the
    -- old early return meant auto-fire stopped for good. Re-assert instead,
    -- rate-limited so a genuinely-held button cannot turn into a click storm.
    if isKeyPressed(VK_LBUTTON or 0x01) then return end
    if getTickCount() - (AIM.lastPress or 0) < AIM.REASSERT_MS then return end
    AIM.reasserts = (AIM.reasserts or 0) + 1
  end
  local fn = getAddress("user32.mouse_event")
  if not fn then return end
  pcall(executeCodeLocalEx, fn, down and MOUSE_LEFTDOWN or MOUSE_LEFTUP, 0, 0, 0, 0)
  AIM.triggerHeld = down
  AIM.lastPress = getTickCount()
end

function AIM.autoTrigger(t)
  if not AIM.autoShoot then
    if AIM.triggerHeld then AIM.setTrigger(false) end
    return
  end
  -- Counters, so "it sometimes does not fire" can be answered with numbers
  -- instead of guesses: no target, out of the shoot radius, or the game not in
  -- front are three different problems.
  local st = AIM.shootStats
  if not st then st = { ticks = 0, target = 0, wanted = 0, blurred = 0, held = 0 }
    AIM.shootStats = st end
  st.ticks = st.ticks + 1
  if t then st.target = st.target + 1 end

  -- Never fight the player's own click: if they are already holding the
  -- button, leave the trigger alone entirely.
  if isKeyPressed(VK_LBUTTON or 0x01) and not AIM.triggerHeld then
    st.held = st.held + 1
    return
  end
  local want = t ~= nil and (t.rescue or t.turret
                             or (t.px or 1e9) <= AIM.SHOOT_MAX_PX * (AIM.pxScale or 1))
  if want then
    st.wanted = st.wanted + 1
    if not AIM.gameInFocus() then st.blurred = st.blurred + 1 end
    st.maxMiss = math.max(st.maxMiss or 0, AIM.focusMiss or 0)
  end
  AIM.setTrigger(want and true or false)
end

--- Why auto-fire did or did not pull the trigger, over the last stretch.
function AIM.shootReport()
  local st = AIM.shootStats
  if not st then return "auto-fire has not run" end
  return string.format(
    "ticks=%d  hadTarget=%d (%.0f%%)  wantedToFire=%d  blockedByFocus=%d  " ..
    "longestMiss=%d  playerHolding=%d  reasserted=%s\n" ..
    "  foreground pids seen while not the game: %s  (game pid %s)",
    st.ticks, st.target, st.ticks > 0 and st.target / st.ticks * 100 or 0,
    st.wanted, st.blurred, st.maxMiss or 0, st.held, tostring(AIM.reasserts or 0),
    (function()
       local out = {}
       for p, n in pairs(AIM.fgPids or {}) do out[#out + 1] = p .. "x" .. n end
       table.sort(out)
       return #out > 0 and table.concat(out, " ") or "none"
     end)(), tostring(getOpenedProcessID()))
end


--------------------------------------------------------------------------
-- The trace hook
--
-- UKismetSystemLibrary::LineTraceSingle's real implementation is at
-- game+0x2ACC530 (the UFunction's Func pointer gives the exec thunk; the
-- second-to-last non-helper call inside it is the implementation). FVector is
-- 12 bytes so MSVC passes it by pointer: RDX = &Start, R8 = &End.
--
-- The hard part is telling the bullet apart from the ~35k traces a second the
-- AI and interaction checks fire. The shot is the only one whose Start AND End
-- both equal the gun's own StartLoc/EndLoc, which the blueprint has just
-- written, so compare against those.
--------------------------------------------------------------------------
-- The stub does not preserve RFLAGS. That is safe only because it is placed
-- at a function entry, where no flags are live across the patched bytes; move
-- the hook anywhere else and it needs pushfq/popfq.
--
-- The sod_sa_on gate is the first thing the stub does. It used to sit after the
-- StartLoc/EndLoc comparison, which meant every disarmed hook still ran
-- `mov rax,[sod_sa_gun]` and read [rax+0x414] on all ~35k traces per second --
-- with a pointer Lua had stopped refreshing. Consequence of moving it:
-- sod_sa_seen now only counts while armed.
AIM.HOOK_OFF = 0x2ACC530

--- The build is frozen, so the bytes we steal are known exactly. Treating them
--- as the single source of truth is what lets us tell our own hook apart from
--- somebody else's: "there is an E9 here" is not evidence that the stub behind
--- it is ours, and writing a foreign stub's bytes back into game code (then
--- freeing its memory) is a good way to break another tool.
AIM.HOOK_ORIG = { 0x40, 0x53, 0x55, 0x56, 0x57 }   -- push rbx; push rbp; push rsi; push rdi

AIM.SYMS = { "sod_sa_mem", "sod_sa_gun", "sod_sa_aim", "sod_sa_start", "sod_sa_on",
             "sod_sa_wall", "sod_sa_hits", "sod_sa_seen" }

-- Names used before the sod_ prefix was added. Unregistered too, so upgrading
-- in place does not leave a set of stale global symbols behind.
AIM.LEGACY_SYMS = { "sa_mem", "sa_gun", "sa_aim", "sa_start", "sa_on",
                    "sa_wall", "sa_hits", "sa_seen" }

local function bytesEqual(a, b, n)
  if not a or not b then return false end
  n = n or #b
  if #a < n or #b < n then return false end
  for i = 1, n do if a[i] ~= b[i] then return false end end
  return true
end

--- Retired stubs are never freed, on purpose.
---
--- Two reasons. Freeing one the instant the patch site is restored is a
--- use-after-free: the game enters the stub ~35k times a second, so a thread
--- can already be inside it. And deAlloc on a stub that a *previous* CE
--- session allocated corrupts CE's own allocator bookkeeping -- that is
--- exactly how CE died here, 0xC0000374 STATUS_HEAP_CORRUPTION in ntdll,
--- right after a reload freed a stub inherited from the CE instance before it.
---
--- The cost of not freeing is 1 KB of the game's address space per install.
--- The list is kept only so the count is visible.
local function retireStub(addr)
  if not addr then return end
  _G.__SOD_STALE_STUBS = _G.__SOD_STALE_STUBS or {}
  _G.__SOD_STALE_STUBS[#_G.__SOD_STALE_STUBS + 1] = addr
end

local function flushStaleStubs()
  local n = #(_G.__SOD_STALE_STUBS or {})
  if n > 0 then
    print(string.format("[SoD] %d retired stub(s) left allocated on purpose (1 KB each)", n))
  end
  _G.__SOD_STALE_STUBS = {}
end

function AIM.installHook()
  -- SA and the registered symbols outlive the target process, so neither one
  -- says the hook is present *here*. Tie it to the process it was written into
  -- and confirm the jump is still at the patch site; otherwise every tick
  -- writes sod_sa_gun into whatever now lives at that address in the new process.
  if SA and SA.pid == getOpenedProcessID() and SA.base == (ESP and ESP.base)
     and SA.addr and (readBytes(SA.addr, 1, false) or 0) == 0xE9 then
    return true
  end
  SA = nil
  flushStaleStubs()
  -- a half-registered symbol from a failed attempt blocks the next one
  for _, sym in ipairs(AIM.SYMS) do pcall(unregisterSymbol, sym) end
  for _, sym in ipairs(AIM.LEGACY_SYMS) do pcall(unregisterSymbol, sym) end
  if not (ESP and ESP.base) then ESP.rebase() end
  local addr = ESP.base + AIM.HOOK_OFF

  -- Never let readmem() capture a jump that is already at the patch site: it
  -- would be copied into the new stub as the "original" instructions, so every
  -- call would execute a rel32 computed for a different address. Recover the
  -- real prologue from the existing stub and put it back first.
  if (readBytes(addr, 1, false) or 0) == 0xE9 then
    local rel  = readInteger(addr + 1)
    local prev = addr + 5 + (rel > 0x7FFFFFFF and rel - 0x100000000 or rel)
    local rec  = AIM.recoverOrig(prev)
    -- Only reclaim a stub that gives back exactly the prologue we know. Any
    -- other jump here belongs to someone else and must be left alone.
    if not bytesEqual(rec, AIM.HOOK_ORIG) then
      return false, "patch site is hooked by something else -- refusing to touch it"
    end
    writeBytes(addr, rec)
    if not bytesEqual(readBytes(addr, #AIM.HOOK_ORIG, true), AIM.HOOK_ORIG) then
      return false, "could not restore the prologue over the foreign jump"
    end
    retireStub(prev)
    print(string.format("[SoD] reclaimed an orphaned hook of ours; stub %X retired", prev))
  end

  local size = 0
  while size < 5 do
    local s2 = getInstructionSize(addr + size)
    if not s2 or s2 == 0 then return false, "bad prologue" end
    size = size + s2
  end
  local script = string.format([[
alloc(sod_sa_mem,1024,%X)
label(sod_sa_ret)
label(sod_sa_gun)
label(sod_sa_aim)
label(sod_sa_start)
label(sod_sa_on)
label(sod_sa_wall)
label(sod_sa_hits)
label(sod_sa_seen)
label(sod_sa_skip)
label(sod_sa_nowall)
registersymbol(sod_sa_mem)
registersymbol(sod_sa_gun)
registersymbol(sod_sa_aim)
registersymbol(sod_sa_start)
registersymbol(sod_sa_on)
registersymbol(sod_sa_wall)
registersymbol(sod_sa_hits)
registersymbol(sod_sa_seen)

sod_sa_mem:
  push rax
  push rbx
  cmp qword ptr [sod_sa_on],0
  je sod_sa_skip
  mov rax,[sod_sa_gun]
  test rax,rax
  je sod_sa_skip
  mov rbx,[rdx]
  cmp rbx,[rax+414]
  jne sod_sa_skip
  mov rbx,[r8]
  cmp rbx,[rax+420]
  jne sod_sa_skip
  inc qword ptr [sod_sa_seen]
  mov rbx,[sod_sa_aim]
  mov [r8],rbx
  mov ebx,[sod_sa_aim+08]
  mov [r8+08],ebx
  cmp qword ptr [sod_sa_wall],0
  je sod_sa_nowall
  mov rbx,[sod_sa_start]
  mov [rdx],rbx
  mov ebx,[sod_sa_start+08]
  mov [rdx+08],ebx
sod_sa_nowall:
  inc qword ptr [sod_sa_hits]
sod_sa_skip:
  pop rbx
  pop rax
  readmem(%X,%d)
  jmp sod_sa_ret

sod_sa_gun:
  dq 0
sod_sa_aim:
  dq 0
  dq 0
sod_sa_start:
  dq 0
  dq 0
sod_sa_on:
  dq 0
sod_sa_wall:
  dq 0
sod_sa_hits:
  dq 0
sod_sa_seen:
  dq 0

%X:
  jmp sod_sa_mem
%s
sod_sa_ret:
]], addr, addr, size, addr, size > 5 and ("  nop " .. (size - 5)) or "")
  -- 32 bytes, not `size`: if CE falls back to a 14-byte absolute jump we have
  -- to be able to put back more than we planned to steal.
  local wide = readBytes(addr, 32, true)
  if not wide then return false, "cannot read the prologue" end
  if not bytesEqual(wide, AIM.HOOK_ORIG) then
    return false, string.format(
      "prologue is %02X %02X %02X %02X %02X, expected %02X %02X %02X %02X %02X" ..
      " -- unsupported build",
      wide[1], wide[2], wide[3], wide[4], wide[5],
      AIM.HOOK_ORIG[1], AIM.HOOK_ORIG[2], AIM.HOOK_ORIG[3], AIM.HOOK_ORIG[4], AIM.HOOK_ORIG[5])
  end
  local orig = {}
  for i = 1, size do orig[i] = wide[i] end

  local ok, err = autoAssemble(script)
  if not ok then return false, tostring(err) end

  -- A 5-byte relative jump only reaches +-2GB. CE silently falls back to a
  -- 14-byte absolute jump when the allocation lands further away, which
  -- clobbers more than the bytes we stole. That used to leave the site
  -- half-overwritten with no way back, so undo it here while we still can.
  if (readBytes(addr, 1, false) or 0) ~= 0xE9 then
    local back = {}
    for i = 1, 14 do back[i] = wide[i] end
    pcall(writeBytes, addr, back)
    -- getAddress returns 0 for an unknown symbol rather than failing, so a
    -- plain nil test would hand deAlloc a zero.
    local okm, mem = pcall(getAddress, "sod_sa_mem")
    if okm and mem and mem ~= 0 then retireStub(mem) end   -- see retireStub: never freed
    for _, sym in ipairs(AIM.SYMS) do pcall(unregisterSymbol, sym) end
    return false, "stub allocated out of near-jump range; patch site restored"
  end
  local rel  = readInteger(addr + 1)
  local stub = addr + 5 + (rel > 0x7FFFFFFF and rel - 0x100000000 or rel)

  AIM.armed = nil
  SA = { gun = getAddress("sod_sa_gun"), aim = getAddress("sod_sa_aim"),
         start = getAddress("sod_sa_start"), on = getAddress("sod_sa_on"),
         wall = getAddress("sod_sa_wall"), hits = getAddress("sod_sa_hits"),
         seen = getAddress("sod_sa_seen"), addr = addr, size = size,
         orig = orig, mem = stub,
         pid = getOpenedProcessID(), base = ESP and ESP.base }
  return true
end

--- Recover the stolen bytes from a stub built before installHook saved them:
--- readmem() copied them in verbatim, between the register restores (5B 58)
--- and the jump back (E9).
--- `size` may be nil, in which case the stolen length is inferred from where
--- the trailing jump sits. Returns the bytes and the size.
function AIM.recoverOrig(stub, size)
  local b = readBytes(stub, 512, true)
  if not b then return end
  for i = 1, #b - 20 do
    if b[i] == 0x5B and b[i + 1] == 0x58 then
      for n = (size or 5), (size or 16) do
        if b[i + 2 + n] == 0xE9 then
          local orig = {}
          for k = 1, n do orig[k] = b[i + 1 + k] end
          return orig, n
        end
      end
    end
  end
end

--- Without this there is no safe way to change the stub: re-injecting over a
--- live hook makes readmem() copy the jump itself in as the "original"
--- instructions, and the stub then jumps to itself.
function AIM.uninstallHook()
  if not (SA and SA.addr) then return false, "not installed" end
  -- A hook recorded against another process must not be unpatched here; one
  -- from a build that did not record a pid has to prove itself instead, by
  -- still having our jump at the patch site.
  if SA.pid and SA.pid ~= getOpenedProcessID() then
    SA = nil
    return false, "hook belongs to a different process"
  end
  if (readBytes(SA.addr, 1, false) or 0) ~= 0xE9 then
    SA = nil
    return false, "no jump at the patch site -- nothing of ours to remove"
  end
  local size = SA.size or 5
  local stub = SA.mem
  if not stub then
    local rel = readInteger(SA.addr + 1)
    stub = SA.addr + 5 + (rel > 0x7FFFFFFF and rel - 0x100000000 or rel)
  end
  local orig = SA.orig or AIM.recoverOrig(stub, size)
  if not bytesEqual(orig, AIM.HOOK_ORIG) then
    return false, "recorded prologue is not the one we know -- refusing to unpatch"
  end

  pcall(writeQword, SA.on, 0)                      -- gate first, then the data
  pcall(writeQword, SA.gun, 0)
  writeBytes(SA.addr, orig)
  if (readBytes(SA.addr, 1, false) or 0) == 0xE9 then
    return false, "restore did not take"
  end
  retireStub(stub)
  for _, sym in ipairs(AIM.SYMS) do pcall(unregisterSymbol, sym) end
  SA = nil
  AIM.armed = nil
  return true
end

function AIM.stop()
  if AIM.triggerHeld then pcall(AIM.setTrigger, false) end
  AIM.disarm()
  AIM.running = false
  if AIM.thread then pcall(function() AIM.thread.terminate() end); AIM.thread = nil end
end

function AIM.start()
  AIM.stop()
  local ok, err = AIM.installHook()
  if not ok then print("[SoD] silent-aim hook unavailable: " .. tostring(err)) end
  AIM.running = true
  AIM.thread = createThread(function(t)
    while AIM.running and not t.Terminated do
      -- A throwing tick leaves the hook exactly as the last successful one set
      -- it: still armed, still holding a gun pointer nothing is refreshing.
      if not ESP.guard("aim", AIM.tick) then pcall(AIM.disarm) end
      sleep(AIM.TICK_MS)
    end
  end)
  return true
end

function AIM.status()
  local t = AIM.current
  local hits = SA and select(2, pcall(readQword, SA.hits)) or nil
  return string.format("gun=%s target=%s redirected=%s",
    AIM.gunPtr and string.format("%X", AIM.gunPtr) or "-",
    t and string.format("%.0fm @%.0fpx%s%s", t.d/100, t.px,
      t.sticky and " (sticky)" or "",
      t.rescue and " [RESCUE]" or (t.turret and " [TURRET]" or "")) or "none",
    tostring(hits or "-"))
end

return "sod_aim loaded"
