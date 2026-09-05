--------------------------------------------------------------------------
-- Seed of the Dead: Sweet Home  --  toggle menu
--
-- INSERT shows/hides this window, END toggles the ESP overlay.
-- Topmost but deliberately NOT click-through: it has to receive clicks.
--------------------------------------------------------------------------

MENU = MENU or {}

--- Virtual-key codes; override before loading to rebind.
MENU.HOTKEY = MENU.HOTKEY or (VK_INSERT or 0x2D)

-- Every timer ever created by this file, so a rebuild can kill all of them.
-- Tracking only MENU.timer is not enough: if that field is ever overwritten
-- the timer becomes unreachable but keeps firing its old chunk forever, and a
-- stale callback touching destroyed controls recurses into a C stack overflow.
_G.__SOD_TIMERS = _G.__SOD_TIMERS or {}

local function killAllTimers()
  for _, t in ipairs(_G.__SOD_TIMERS) do
    pcall(function() t.Enabled = false end)
    pcall(function() t.destroy() end)
  end
  _G.__SOD_TIMERS = {}
end
-- Overridable so the modules do not have to live at one absolute path; the CT
-- sets SOD_ROOT before loading this file.
local ROOT = SOD_ROOT or [[C:\SoDTrainer\]]

function MENU.loadModules()
  dofile(ROOT .. "sod_esp.lua")
  ESP.rebase()
  dofile(ROOT .. "sod_player.lua")
  dofile(ROOT .. "sod_trainer.lua")
  dofile(ROOT .. "sod_aim.lua")
end

local function topmost(form)
  pcall(function() form.FormStyle = 5 end)           -- fsSystemStayOnTop
  local swp = getAddress("user32.SetWindowPos")
  if swp then pcall(executeCodeLocalEx, swp, form.Handle, -1, 0, 0, 0, 0, 0x13) end
end

--- `get` reports live state so the boxes stay honest when something is
--- toggled elsewhere (the END hotkey, say).
MENU.rows = {
  { head = "武器 / Weapons" },
  { label = "无限弹药  Infinite Ammo (ShotCost=0)",
    get = function() return SOD and SOD.running end,
    set = function(on) if on then SOD.start() else SOD.stop() end end },
  { label = "无后坐力  No Recoil",
    get = function() return SOD and SOD.noRecoil end,
    set = function(on) SOD.noRecoil = on end },

  { label = "无扩散  No Spread (弹道变激光)",
    get = function() return AIM and AIM.noSpread end,
    set = function(on) AIM.noSpread = on end },

  { label = "静默自瞄  Silent Aim (准星不动)",
    get = function() return AIM and AIM.enabled end,
    set = function(on) AIM.enabled = on if not on then AIM.disarm() end end },

  { label = "  锁弱点/爆头  Headshot (按骨骼实测)",
    get = function() return AIM and AIM.headshot end,
    set = function(on) AIM.headshot = on AIM.headBone = {} end },
  { label = "  优先解救队友  Rescue priority",
    get = function() return AIM and AIM.rescue end,
    set = function(on) AIM.rescue = on end },
  { label = "  自动开火  Auto shoot (锁定即开枪)",
    get = function() return AIM and AIM.autoShoot end,
    set = function(on) AIM.autoShoot = on if not on then AIM.setTrigger(false) end end },
  { label = "  炮台模式  Turret (360度, 不用转视角)",
    get = function() return AIM and AIM.turret end,
    set = function(on)
      AIM.turret = on
      if on then AIM.wallbang = true end        -- the endpoint still has to reach
    end },
  { label = "  穿墙命中  Wallbang (需静默自瞄)",
    get = function() return AIM and AIM.wallbang end,
    set = function(on)
      AIM.wallbang = on
      if not on and SA and SA.wall then writeQword(SA.wall, 0) end
    end },

  { label = "长按连发  Full-auto (仅单发/三连发)",
    get = function() return PLAYER and PLAYER.opts.autoFire end,
    set = function(on)
      PLAYER.opts.autoFire = on
      AIM.autoFire = on                      -- weapon-side flag too, harmless
    end },

  { label = "高伤害  Big damage (压过距离衰减)",
    get = function() return PLAYER and PLAYER.opts.bigDamage end,
    set = function(on)
      PLAYER.opts.bigDamage = on
      if not on then PLAYER.restoreDamage() end
    end },

  { label = "近战超远距离  Mega melee (300m)",
    get = function() return PLAYER and PLAYER.opts.megaMelee end,
    set = function(on)
      PLAYER.opts.megaMelee = on
      if not on then PLAYER.restoreMelee() end
    end },

  { head = "角色 / Player" },
  { label = "无敌  God Mode",
    get = function() return PLAYER and PLAYER.opts.invincible end,
    set = function(on) PLAYER.opts.invincible = on end },
  { label = "无限体力  Infinite Stamina",
    get = function() return PLAYER and PLAYER.opts.stamina end,
    set = function(on) PLAYER.opts.stamina = on end },
  { label = "拾取助手  Loot assist (按 E 收全图物品，一次一个)",
    get = function() return PLAYER and PLAYER.opts.autoLoot end,
    set = function(on)
      PLAYER.opts.autoLoot = on
      if on then
        -- Items are placed when the level loads, so most of them sit at low
        -- indices, outside the region the scanner sweeps continuously. Ask for
        -- one whole-array pass so the list is complete before we start.
        PLAYER.looted, PLAYER.lootRotated, PLAYER.lootRank = 0, 0, 0
        if ESP then ESP.fullSweep = true end
      end
    end },

  { label = "无限手雷  Infinite Grenades",
    get = function() return PLAYER and PLAYER.opts.grenades end,
    set = function(on) PLAYER.opts.grenades = on end },

  { label = "队友无敌  Ally god mode (满血/免伤/不倒地)",
    get = function() return PLAYER and PLAYER.opts.allyGod end,
    set = function(on) PLAYER.opts.allyGod = on end },
  { label = "队友免疫侵犯  Allies can't be grabbed",
    get = function() return PLAYER and PLAYER.opts.allyNoRape end,
    set = function(on) PLAYER.opts.allyNoRape = on end },

  { head = "透视 / ESP        (END 开关)" },
  { label = "ESP 总开关  Enable overlay",
    get = function() return ESP and ESP.running end,
    set = function(on) if on then ESP.start(false) else ESP.stop() end end },
  { label = "  显示小怪  Trash mobs",
    get = function() return ESP and ESP.show.trash end,
    set = function(on) ESP.show.trash = on end },
  { label = "  显示精英  Elites",
    get = function() return ESP and ESP.show.elite end,
    set = function(on) ESP.show.elite = on end },
  { label = "  显示 Boss",
    get = function() return ESP and ESP.show.boss end,
    set = function(on) ESP.show.boss = on end },
  { label = "  显示武器  Weapon pickups",
    get = function() return ESP and ESP.show.weapon end,
    set = function(on) ESP.show.weapon = on end },
  { label = "  显示队友  Team-mates (含倒地/被抓)",
    get = function() return ESP and ESP.show.ally end,
    set = function(on) ESP.show.ally = on end },
  { label = "  显示物品  Items",
    get = function() return ESP and ESP.show.item end,
    set = function(on) ESP.show.item = on end },
}

function MENU.status()
  local t = {}
  for _, a in ipairs(ESP and ESP.actors or {}) do
    t[a.tier or "?"] = (t[a.tier or "?"] or 0) + 1
  end
  -- Only read HP through a pawn that is still alive: PLAYER.actor can outlive
  -- the pawn by a tick and the read would then be of freed memory.
  local hp = "-"
  if PLAYER and PLAYER.actor and ESP and ESP.validActor(PLAYER.actor) then
    hp = tostring(PLAYER.read("CurrentHP") or "-")
  end
  return string.format("trash %d  elite %d  boss %d  wp %d  item %d | hp %s | %s",
    t.trash or 0, t.elite or 0, t.boss or 0, t.weapon or 0, t.item or 0, hp,
    (ESP and ESP.healthLine) and ESP.healthLine() or "?")
end

function MENU.destroy()
  -- Order matters: kill the timer first so it can never observe a half-torn
  -- down form. Then drop every control reference -- a dangling checkbox sends
  -- CE's __index metamethod into an infinite recursion (C stack overflow).
  MENU.building = true
  killAllTimers()
  MENU.timer = nil
  if MENU.form then pcall(function() MENU.form.destroy() end); MENU.form = nil end
  MENU.cbs = {}
  MENU.shown = {}
  MENU.statusLbl = nil
  MENU.lastLine = nil
  MENU.inTimer = false
end

--- Full unload: the INSERT hotkey survives destroy() so the menu can be
--- rebuilt, but a real teardown has to give it back too.
function MENU.teardown()
  MENU.destroy()
  if MENU.hotkey then pcall(function() MENU.hotkey.destroy() end); MENU.hotkey = nil end
  if ESP and ESP.teardown then ESP.teardown() end
  if AIM then AIM.stop(); if AIM.uninstallHook then pcall(AIM.uninstallHook) end end
  if PLAYER then PLAYER.stop() end
  if SOD then SOD.stop() end
end

function MENU.toggle()
  if not MENU.form then return end
  MENU.form.Visible = not MENU.form.Visible
  if MENU.form.Visible then topmost(MENU.form) end
end

function MENU.build()
  MENU.building = true
  MENU.destroy()
  local form = createForm(false)
  form.Caption = "SoD Trainer"
  form.Position = poDesigned
  form.Left, form.Top = 60, 60
  form.BorderStyle = bsSingle
  form.ShowInTaskBar = stNever
  MENU.form = form

  local title = createLabel(form)
  title.Left, title.Top = 12, 8
  title.Caption = "Seed of the Dead   --   INSERT 显示/隐藏"
  title.Font.Style = "fsBold"

  MENU.cbs = {}
  MENU.shown = {}
  MENU.lastLine = nil
  local y = 30
  for i, item in ipairs(MENU.rows) do
    if item.head then
      local l = createLabel(form)
      l.Left, l.Top = 10, y + 4
      l.Caption = item.head
      l.Font.Style = "fsBold"
      y = y + 24
    else
      local cb = createCheckBox(form)
      cb.Left, cb.Top = 14, y
      cb.Width = 320
      cb.Caption = item.label
      local init = item.get() and true or false
      cb.Checked = init
      cb.OnChange = function(sender)
        if MENU.syncing then return end            -- syncing must not re-fire set()
        local want = sender.Checked and true or false
        MENU.shown[i] = want
        local ok, err = pcall(item.set, want)
        if not ok then print("[SoD] " .. tostring(err)) end
      end
      MENU.cbs[i] = cb
      MENU.shown[i] = init
      y = y + 24
    end
  end

  MENU.statusLbl = createLabel(form)
  MENU.statusLbl.Left, MENU.statusLbl.Top = 14, y + 6
  MENU.statusLbl.Caption = ""
  form.Width, form.Height = 360, y + 56

  MENU.timer = createTimer(getMainForm(), false)
  _G.__SOD_TIMERS[#_G.__SOD_TIMERS + 1] = MENU.timer
  MENU.timer.Interval = 500
  MENU.timer.OnTimer = function()
    if MENU.building or not MENU.form then MENU.skipped = (MENU.skipped or 0) + 1 return end
    -- Reading a control property pumps the message queue, which dispatches the
    -- pending WM_TIMER and re-enters this callback. Nested deep enough that is
    -- a C stack overflow, and the error dialog then reappears twice a second.
    if MENU.inTimer then MENU.reentered = (MENU.reentered or 0) + 1 return end
    MENU.inTimer = true
    MENU.ticks = (MENU.ticks or 0) + 1
    local ok, err = xpcall(function()
      MENU.syncing = true
      MENU.step = "enter"
      for i, item in ipairs(MENU.rows) do
        local cb = MENU.cbs[i]
        if cb then
          MENU.step = "get:" .. i .. ":" .. tostring(item.label)
          local want = item.get() and true or false
          -- Compare against what we last wrote instead of reading cb.Checked:
          -- in the steady state this touches no control property at all.
          if MENU.shown[i] ~= want then
            MENU.shown[i] = want
            cb.Checked = want
          end
        end
      end
      MENU.syncing = false
      MENU.step = "status"
      local line = MENU.status()
      MENU.step = "caption"
      if MENU.statusLbl and line ~= MENU.lastLine then
        MENU.lastLine = line
        MENU.statusLbl.Caption = line
      end
    end, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
    MENU.inTimer = false
    if not ok then
      -- Stop after the first failure. Left running it repaints the error
      -- dialog twice a second and there is no way to dismiss it.
      MENU.syncing = false
      MENU.lastError = tostring(err)
      MENU.errCount = (MENU.errCount or 0) + 1
      pcall(function() MENU.timer.Enabled = false end)
      print("[SoD] menu sync stopped: " .. tostring(err))
    end
  end
  MENU.timer.Enabled = true
  MENU.building = false

  -- 1 == caHide. Closing with X must not free the controls; the sync timer
  -- would then be reading destroyed objects. (CE's caHide constant is nil.)
  form.OnClose = function() return 1 end

  -- decoys for orphaned timers left over from an earlier load of this file
  MENU.items = {}
  MENU.boxes = {}
  MENU.statusLabel = { Caption = "" }

  form.show()
  topmost(form)
  if not MENU.hotkey then
    MENU.hotkey = createHotkey(function() MENU.toggle() end, MENU.HOTKEY)
  end
  return form
end

function MENU.open()
  MENU.loadModules()
  -- Nothing starts until we know this is the build every offset was measured
  -- against. On a different one they land on unrelated data and the game dies
  -- some minutes later, nowhere near the cause.
  local ok, why = ESP.selfCheck()
  if not ok then
    error("[SoD] self-check failed: " .. tostring(why), 0)
  end
  PLAYER.start()
  SOD.start()
  AIM.start()
  MENU.build()
  return "menu ready"
end

return "sod_menu loaded"
