--------------------------------------------------------------------------
-- Seed of the Dead: Sweet Home  --  weapon cheats
--
-- Rewritten to work off the player's own weapon array instead of scanning
-- memory for ammo-shaped structs. Zeroing ShotCost means firing never debits
-- the magazine at all, which beats topping the magazine back up on a timer:
-- no flicker, no window where the gun is briefly empty, and no full-process
-- scans. Credit for the idea goes to the community table's field names.
--
--   BP_PL_Player_C::CurrentHaveWeaponInfo  TArray{ ptr, num, max }
--   BP_PL_Player_C::Loc_WeaponInfo         one inline copy of the same record
--   record stride 0x1C8; slot 0 is the default pistol, 1 and 2 the hotbar
--
--   +0x10 WeaponRank  +0x14 CurrentAmmo  +0x18 AllAmmo  +0x1C MaxAmmo
--   +0x20 ShotCost    +0x24 ReloadCost   +0x28 UsedAmmo +0x2C FireofNum
--   +0x17C / +0x194   recoil, weapon-specific (found by diffing two weapons)
--------------------------------------------------------------------------

SOD = SOD or {}
SOD.STRIDE      = 0x1C8
SOD.SHOT_COST   = 0x20
SOD.RELOAD_COST = 0x24
SOD.RECOIL      = { 0x17C, 0x194 }
SOD.TICK_MS     = 250        -- only has to beat weapon switches, not gunfire
SOD.noRecoil    = (SOD.noRecoil ~= false)

local function q(a)   local ok, v = pcall(readQword, a);   if ok then return v end end
local function i32(a) local ok, v = pcall(readInteger, a); if ok then return v end end
local function f(a)   local ok, v = pcall(readFloat, a);   if ok then return v end end

--- Every weapon record the player owns: the array plus the inline copy the
--- game keeps for the weapon actually in hand.
function SOD.records()
  local a = PLAYER and PLAYER.find()
  if not a then return {} end
  local recs = {}
  local arrOff = ESP.propOffset(q(a + 0x10), "CurrentHaveWeaponInfo")
  if arrOff then
    local data = q(a + arrOff)
    local num  = i32(a + arrOff + 8) or 0
    if data and data > 0x10000 and num > 0 and num < 16 then
      for i = 0, num - 1 do recs[#recs + 1] = data + i * SOD.STRIDE end
    end
  end
  local locOff = ESP.propOffset(q(a + 0x10), "Loc_WeaponInfo")
  if locOff then recs[#recs + 1] = a + locOff end
  return recs
end

function SOD.apply()
  local n = 0
  for _, r in ipairs(SOD.records()) do
    n = n + 1
    if i32(r + SOD.SHOT_COST)   ~= 0 then pcall(writeInteger, r + SOD.SHOT_COST, 0) end
    if i32(r + SOD.RELOAD_COST) ~= 0 then pcall(writeInteger, r + SOD.RELOAD_COST, 0) end
    if SOD.noRecoil then
      -- These two are the only offsets in the project not resolved by name:
      -- the record is a blueprint struct, so its members are not reachable
      -- through a UClass property chain. They were found by differencing two
      -- weapons, which says they are weapon-specific floats but not what else
      -- might live there. Only zero something that still looks like a recoil
      -- coefficient -- every sample was between 0 and 1 -- so a field that
      -- turns out to be a count, a length or a multiplier is left alone
      -- instead of being silently destroyed.
      for _, o in ipairs(SOD.RECOIL) do
        local v = f(r + o)
        if v and v == v and v > 0 and v <= 10 then pcall(writeFloat, r + o, 0) end
      end
    end
  end
  SOD.count = n
  return n
end

function SOD.stop()
  SOD.running = false
  if SOD.thread then pcall(function() SOD.thread.terminate() end); SOD.thread = nil end
end

function SOD.start()
  SOD.stop()
  if not (ESP and ESP.gobj) then ESP.rebase() end
  SOD.running = true
  SOD.thread = createThread(function(t)
    while SOD.running and not t.Terminated do
      ESP.guard("weapon", SOD.apply)
      sleep(SOD.TICK_MS)
    end
  end)
  return SOD.apply()
end

--- Kept for the menu's status line.
function SOD.status()
  local recs = SOD.records()
  local bits = {}
  for i, r in ipairs(recs) do
    bits[#bits + 1] = string.format("[%d] %s/%s cost=%s", i - 1,
      tostring(i32(r + 0x14)), tostring(i32(r + 0x1C)), tostring(i32(r + SOD.SHOT_COST)))
  end
  return table.concat(bits, "  ")
end

return "sod_trainer (weapon-array based) loaded"
