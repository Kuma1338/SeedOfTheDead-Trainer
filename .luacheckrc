-- Cheat Engine runs these files in its own Lua state, where the CE API and the
-- trainer's own modules are globals. Declaring them here is what makes
-- "accessing undefined variable" meaningful: that warning is how a local used
-- above its declaration shows up, which is a failure mode this project has hit.

std = "lua53"
max_line_length = 100

-- The trainer's own modules, deliberately global so they can be reloaded
-- independently from CE's Lua console.
globals = {
  "ESP", "AIM", "PLAYER", "SOD", "MENU", "SA",
  "objAt", "onOpenProcess",
  "SOD_ROOT",
}

read_globals = {
  -- memory
  "readBytes", "writeBytes", "readInteger", "writeInteger", "readQword",
  "writeQword", "readFloat", "writeFloat", "readDouble", "writeDouble",
  "readSmallInteger", "writeSmallInteger", "readString",
  -- process and modules
  "getAddress", "getAddressSafe", "getModuleSize", "getOpenedProcessID",
  "openProcess", "getProcessIDFromProcessName", "getForegroundProcess",
  -- code injection
  "autoAssemble", "allocateMemory", "deAlloc", "registerSymbol",
  "unregisterSymbol", "getInstructionSize", "executeCodeLocalEx",
  -- threading and timing
  "createThread", "createTimer", "synchronize", "sleep", "getTickCount",
  -- ui
  "createForm", "createLabel", "createCheckBox", "createHotkey", "createBitmap",
  "getMainForm", "getFormCount", "getForm", "getScreenWidth", "getScreenHeight",
  "bsNone", "bsSingle", "bsSolid", "bsClear", "poDesigned", "stNever", "fsBold",
  -- input
  "isKeyPressed", "doKeyPress", "keyDown", "keyUp",
  "VK_LBUTTON", "VK_INSERT", "VK_END", "VK_E",
  -- misc
  "syntaxcheck",
}

-- Injected assembly and reflection walking both use short names on purpose.
ignore = {
  "212",  -- unused argument
  "542",  -- empty if branch (used as a labelled no-op in the scan loop)
}
