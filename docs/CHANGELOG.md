# Changelog

Dates are when the work was done, not release dates — there have been no releases yet.

## Unreleased

### Added

- **Loot assist.** Offers the next pickup to the game's own **E** action, anywhere on the
  map, one per press. Yields to doors, shutters and downed team-mates. The overlay corner
  shows how many are left out of the match total.
- **Build self-check.** `ESP.selfCheck()` verifies module size, PE timestamp, the
  `GUObjectArray` layout, the FName pool and the hook prologue before anything starts, and
  refuses to run on a build the offsets were not measured against.
- **Reflection-typed property access.** `ESP.prop` / `readProp` / `writeProp` pick the
  access width from the property's own `FFieldClass`, and respect `FBoolProperty`'s
  `ByteMask` so a native bitfield is not written a whole byte at a time.
- **Health reporting.** `ESP.guard` counts successes and failures per loop and prints an
  error when its text changes; the menu status line shows which loops are unhappy.
  `ESP.timing()` reports per-loop lock-hold time.
- `AIM.uninstallHook`, and a teardown path that actually runs: the table's `[DISABLE]`
  now releases the hotkeys and removes the hook instead of only stopping the loops.
- `tools/check_scope.py`, `.luacheckrc` and CI.

### Fixed

- **Mesh bounds were treated as world coordinates.** `CachedWorldSpaceBounds` is
  mesh-local with the origin at the model's feet. This one mistake produced three
  unrelated-looking symptoms: ESP boxes at the wrong height, the aim point landing below an
  enemy's feet (or two metres above its head, depending on the sign of the actor's world
  z), and auto-fire skipping shots because it judges its radius from the aim point's screen
  projection.
- **The pawn's class name is not fixed.** `BP_PL_ActPlayer_C` and `BP_PL_Player_C` are both
  used depending on the level; the hardcoded name meant no pawn on half the maps, which
  killed silent aim, infinite ammo and auto-fire simultaneously. Matched on capability now.
- **The hook's gate ran after its first dereference.** A disarmed hook still read through a
  pointer nothing was refreshing, on every trace. The `sod_sa_on` test is now the first
  instruction in the stub.
- **Disarming was a branch, not the default.** The clearing code sat after every early
  return in the aim tick, so it never ran at the moments it was written for — a weapon
  being destroyed. It now runs before them.
- **The hook was not reinstalled after a game restart.** `SA` and the registered symbols
  survive a process change, so the tick simply skipped its work forever while the health
  line stayed green. `SA` now records the pid and base, and `onOpenProcess` reinstalls.
- **Reclaiming an orphaned hook trusted any `E9`.** It would write a foreign stub's bytes
  into game code and free somebody else's memory. The known prologue is now the only thing
  accepted.
- **Retired stubs are no longer freed.** Freeing immediately is a use-after-free; freeing
  one inherited from a previous CE session corrupts CE's allocator (observed:
  `0xC0000374` in ntdll). 1 KB per install is leaked instead.
- **Pointer-keyed caches had no identity check.** A `UClass` or skeletal mesh address gets
  reused after a level unload, so cached property offsets and bone indices could be applied
  to a different class — the most visible symptom being a "weak point" that resolved to a
  foot. Every cache now revalidates against the object's own FName id, and bone indices are
  keyed by skeleton rather than by actor.
- **A pawn miss cost about two seconds, on three threads.** `PLAYER.find`, `AIM.gun` and the
  weapon loop each walked the whole object array. One scanner now publishes the pawn,
  team-mates, the camera and the actor list; the others read.
- **The scanner's warm-up never terminated early** (`cursor` is nil at the end of a round,
  not 0) and triggered a full sweep on top, freezing the UI for seconds when the overlay
  was toggled. 3 s + a full sweep → 1.1 s.
- **`ESP.chunkAt` cached the zero** read from a not-yet-allocated chunk, permanently hiding
  every object that later landed in that range.
- **Auto-fire could stop for good.** There is one mouse button: if the player released it
  while the trainer believed it was holding it, the trigger was never re-asserted and, with
  a target always in view, nothing ever reset that belief.
- **Synthetic clicks fired while the game was in the background**, landing on whatever
  window had focus. Gated on the foreground process, with hysteresis so a momentary blip
  does not drop the trigger.
- **The overlay's transparency invariant was assumed rather than checked.** `pcall` only
  reports that the call was made; `SetWindowLongA` returning 0 and
  `SetLayeredWindowAttributes` returning FALSE both counted as success, and the result is an
  opaque black window covering the screen with no way to click past it. The extended style
  is read back now.
- **A check-then-use race in the overlay** — `AIM.current` tested, then read again after a
  call that yields — crashed the draw loop.
- **`ESP.guard` only ever printed the first error**, and its state survived a reload, so the
  next bug in the same loop was silent.
- **`onOpenProcess` gained another wrapper on every reload.**
- **`writeProp` threw out of its own `pcall`** when handed a boolean for a numeric property,
  taking the rest of the player tick with it.
- **`timeBeginPeriod` had no matching `timeEndPeriod`.**
- Menu: the sync timer read control properties, which pumps messages, which re-entered the
  timer — deep enough to be a C stack overflow, and the resulting dialog reappeared twice a
  second. It compares against its own last written value now and holds a global timer
  registry so a reload cannot orphan one.

### Changed

- Registered symbols are prefixed `sod_sa_` so they cannot collide with another table.
- `SOD_ROOT` makes the module path configurable; nothing is hardcoded to one folder.
- Hotkeys are `MENU.HOTKEY` / `ESP.HOTKEY`.
- Crosshair radii are calibrated at 1440p and scaled by viewport height.
- Removed: the abandoned rate-of-fire experiment and its restore path, an unused spread
  offset, an unused timer field.
