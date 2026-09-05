# Internals

Everything here was measured against the build named in the README. Where a number was
derived rather than observed, it says so.

## 1. Reflection is the whole design

The game ships UE4's reflection data, so every field this trainer touches is resolved by
**property name** at run time. Three module-relative addresses are the only exceptions,
and `ESP.selfCheck()` verifies all three before anything starts.

```
GUObjectArray        game+0x4BA86E0   FChunkedFixedUObjectArray
FNamePool Blocks[]   game+0x4B6C390
LineTraceSingle      game+0x2ACC530   the real implementation, not the exec thunk
```

`GUObjectArray` was found by scanning for the `MaxElements` / `MaxChunks` constant pair
(`MaxChunks == MaxElements / 65536`). Note `MaxElements` is `0x210000` here, not the more
common `0x200000`.

`FNamePool` resisted four different approaches and fell to one invariant: **FName index 0
is always `None`**. Scan module-resident arrays of heap pointers, read what `Blocks[0]`
points at, and check the first entry decodes to `None`.

`LineTraceSingle`: `UFunction::Func` (+0xD8) gives the exec thunk. Disassemble it to the
end; the second-to-last non-helper `call` is the implementation.

### Structure layouts, as measured

```
UObject    +0x08 Flags   +0x0C InternalIndex   +0x10 Class   +0x18 FName   +0x20 Outer
UStruct    +0x40 Super   +0x48 Children (UFunction chain)
           +0x50 ChildProperties (FField chain)   +0x58 PropertiesSize
FField     +0x08 FFieldClass   +0x20 Next   +0x28 Name
FProperty  +0x38 ArrayDim  +0x3C ElementSize  +0x4C Offset_Internal
FBoolProperty tail at +0x78: FieldSize, ByteOffset, ByteMask, FieldMask

FUObjectItem  24-byte stride:  +0x00 Object   +0x08 Flags
  PendingKill = 0x20000000    Unreachable = 0x10000000

FNameEntry  uint16 header then ASCII, 2-byte aligned
  len = header >> 6      bIsWide = header & 1
```

`UStruct` sits `0x10` further along than the stock UE4.27 layout — worth knowing before
comparing against a public SDK dump.

### Types, not guesses

`FProperty+0x08` points at the `FFieldClass`, whose `+0x00` FName is `IntProperty`,
`FloatProperty`, `BoolProperty` and so on. `ESP.readProp` / `ESP.writeProp` use that to
pick the access width, which matters more than it sounds: writing `9999` with
`writeInteger` into a `FloatProperty` stores a bit pattern that reads back as ~1.4e-41, so
a "big damage" option would have quietly set damage to zero.

For bools, `ByteMask` decides between a whole-byte write and read-modify-write. Several of
this game's bools are native bitfields sharing a byte with their neighbours.

## 2. Game structures

### Player pawn

**The pawn's class name is not fixed.** `BP_PL_ActPlayer_C` and `BP_PL_Player_C` have both
been observed, the former deriving from the latter, and which one is instantiated depends
on the level. Matching a literal name loses the pawn on half the maps — and silent aim,
infinite ammo and auto-fire all hang off `PLAYER.find()`, so they die together and look
like three separate bugs.

`ESP.isPawnClass` matches on capability instead: class name prefixed `BP_PL_`, plus the
presence of `CurrentHP` and `CurrentHaveWeaponInfo`. `Default__` CDOs are filtered out.

`APawn::Controller` resolves but is **nil** in this game, so the usual "which pawn does the
PlayerController possess" test does not work.

### Weapon ammo records

Reached from the pawn through `CurrentHaveWeaponInfo` (a `TArray`) and `Loc_WeaponInfo`.
Stride `0x1C8`:

```
+0x10 WeaponRank   +0x14 CurrentAmmo   +0x18 AllAmmo   +0x1C MaxAmmo
+0x20 ShotCost     +0x24 ReloadCost    +0x28 UsedAmmo  +0x2C FireofNum
+0x17C / +0x194    recoil coefficients (weapon-specific)
```

Infinite ammo pins `ShotCost` to 0 rather than refilling the magazine: a full magazine
still triggers the reload animation, a zero-cost shot does not.

The two recoil offsets are the only ones in the project not resolved by name — the record
is a blueprint struct, so its members are not reachable through a `UClass` property chain
(see §6 for the way to fix that). They are range-checked before being zeroed so that a
field which turns out to be something else is left alone.

### Weapon actor

Reached via `Weapon_R` → `ChildActor`.

```
+0x3E0 CurrentSpread   +0x414 StartLoc   +0x420 EndLoc   +0x430 TargetActor
```

`AIM.gunLayoutOk` confirms `StartLoc`/`EndLoc` really are at `0x414`/`0x420` for each
weapon class before letting the hook use it, because the stub has those baked into
assembly and cannot check anything itself.

### Mesh bounds: not what the name says

`CachedWorldSpaceBounds` holds **mesh-local** coordinates with the origin at the model's
feet, despite its name. Measured across enemies standing at world z 197, 217 and 265,
`Origin.z` stayed between 86 and 115 — it does not track the actor at all.

```
world = actorZ + Mesh component RelativeLocation.Z + local
```

Cross-check: an actor at z=198 with relZ=-104 gives a model bottom of 101, and its capsule
(half-height 96) puts its feet at 102.

Treating them as world coordinates broke three unrelated-looking things at once: ESP boxes
drawn at the wrong height, an aim clamp (`zTop - actorZ`) that mixed two coordinate spaces
and put the lock below the model's feet, and auto-fire misjudging its screen-space radius
because the aim point was hundreds of units off in z.

**Lesson: a field name is not evidence. Move the actor and see whether the value moves.**

## 3. Silent aim

The blueprint writes `StartLoc` and `EndLoc` onto the weapon actor and immediately calls
`LineTraceSingle`. Overwriting `EndLoc` from Lua loses that race — the gap is microseconds.
So the trace call itself is hooked and the *parameter* is rewritten.

`FVector` is 12 bytes, so MSVC passes it by pointer: **RDX = &Start, R8 = &End**.

The hard part is telling the bullet apart from the ~35,000 traces a second that AI
perception and interaction checks fire. The shot is the only one whose Start **and** End
both equal the weapon's own `StartLoc`/`EndLoc`. Matching on Start alone gave about twenty
false redirects per shot.

```asm
sod_sa_mem:
  push rax
  push rbx
  cmp qword ptr [sod_sa_on],0     ; gate FIRST -- see below
  je  skip
  mov rax,[sod_sa_gun]
  test rax,rax
  je  skip
  mov rbx,[rdx]
  cmp rbx,[rax+414]               ; Start == gun->StartLoc ?
  jne skip
  mov rbx,[r8]
  cmp rbx,[rax+420]               ; End == gun->EndLoc ?
  jne skip
  inc qword ptr [sod_sa_seen]
  ... rewrite [r8], optionally [rdx] for wallbang ...
```

Three rules that are not optional:

1. **The gate comes before any dereference.** With `cmp [sod_sa_on],0` after the pointer
   load, a "disabled" hook still read `[rax+0x414]` on every trace, using a pointer Lua had
   stopped refreshing. That is an access violation waiting for the next weapon swap.
2. **Disarming is the default action, not a branch.** Every early return in the aim tick —
   no weapon, aim off, no camera — happens at exactly the moments a weapon is being
   destroyed. `AIM.disarm()` runs before all of them: gate to 0 first, then the pointer.
   Arming goes in the opposite order.
3. **The stub does not preserve RFLAGS.** That is only safe because it sits at a function
   entry, where no flags are live across the stolen bytes.

### Installing and removing

- The prologue is known (`40 53 55 56 57`) and treated as the single source of truth. An
  `E9` at the patch site is *not* evidence the stub behind it is ours; a foreign hook is
  refused, untouched.
- `readmem()` copies the stolen bytes into the stub, so re-injecting over a live hook makes
  it copy the jump in as the "original" instructions and the stub jumps to itself.
  `installHook` restores first, `uninstallHook` exists for exactly this reason.
- `SA` records the pid and module base. CE keeps its Lua state across process attaches, so
  neither the table nor the registered symbols prove the hook is present *here*.
- **Retired stubs are never freed.** Freeing one immediately is a use-after-free — the game
  enters it tens of thousands of times a second — and `deAlloc` on a stub allocated by a
  *previous* CE session corrupts CE's allocator: observed as `0xC0000374`
  STATUS_HEAP_CORRUPTION in ntdll. The cost of not freeing is 1 KB per install.

## 4. Concurrency

CE's Lua state is a single instance and every `createThread` thread is serialised through
one critical section, yielding only at `sleep` and `synchronize`. So shared tables cannot
be torn — but **any long tick stalls every other loop and the GUI with it**. The metric
that matters is lock-hold time, not thread safety.

That said, serialisation is not absolute: a check-then-use across a call that yields *can*
be interleaved. A `nil` crash in the overlay came from testing `AIM.current` and then
reading it again with `ESP.view()` in between. Snapshot once.

`ESP.guard(name, fn)` wraps every loop: `xpcall`, an ok/error tally, and the message
printed when it changes. A bare `pcall` hides why a feature stopped working, which is how a
six-second scan on every tick stayed invisible for a whole session.

Measured hold times after tuning, in a match:

| loop | typical / peak |
|---|---|
| aim (1 ms) | 0 / 8 ms |
| player (5 ms) | 1 / 14 ms |
| weapon (250 ms) | 0 / 1 ms |
| scan (10 ms) | 14 / 101 ms |
| draw (3 ms) | 10 / 25 ms |

### One scanner

`ESP.scanStep` walks the object array in chunks and is the only thing that walks it. On the
way past it picks out enemies, items, the camera manager, the player pawn and team-mate
components, and publishes them at the end of each round. Everything else reads those lists.

This is not an optimisation detail. When `PLAYER.find`, `AIM.gun` and the weapon loop each
walked the array themselves, a miss cost about two seconds *per thread*, which is what a
loading screen or a menu looks like to them.

**The hot region is not enough on its own.** The sweep covers the newest ~80,000 indices
continuously and the whole array every 45 seconds. Items and the pawn are created at level
load, so their indices are low and they fall out of the hot window — measured: the map's
items sat at indices 254,336–254,805 with the hot region starting at 263,675. Two
mechanisms cover that: low-index finds from a full sweep are carried forward, and losing
the pawn for two seconds forces an early full sweep.

## 5. Pickups

Pickups are interaction-based, not overlap-based. The game traces for something usable,
stores it in the pawn's `TraceHitActor_Near`, and the **E** action operates on whatever is
in that field — with **no distance check of its own**: writing an item pointer there and
pressing E collected it from 24 metres away.

Loot assist therefore synthesises nothing. It keeps the next pickup pinned in that field,
rewriting it every tick because the game's own trace overwrites it every frame, and yields
whenever the trace has already found something real so doors and downed team-mates still
take priority.

## 6. Measured dead ends

Do not re-attempt these without new evidence.

- **Rate of fire.** `ContinutyTime`, weapon-actor `CustomTimeDilation`, the player's
  `FireRate`, and clearing `PlayingFire` were each measured to change nothing (~7 rounds/s
  either way, counted with the hook's own counter). The last of those also fought the
  blueprint state machine into firing forever. The cadence appears to come from the fire
  montage; hooking `PlayGunfire` / `StopFireMontage` is the untried path.
- **`APawn::GetBaseAimRotation`.** Instrumented: zero calls while firing.
- **Overwriting `BP_WeaponGun_C::EndLoc` from Lua.** Loses the race by microseconds.
  `CurrentSpread` is different — it is not recomputed in the same window, so no-spread
  works by plain polling.
- **Hardware breakpoints on per-frame values.** A breakpoint on the camera pitch crashes
  the game. Low-frequency writes are fine; use passive sampling for anything per-frame.
- **Unknown-initial-value scans** and AOB scans with leading wildcards will wedge CE at
  several GB.

## 7. Still open

- The two recoil offsets are the last unnamed ones. `CurrentHaveWeaponInfo` is an
  `FArrayProperty` whose `+0x78` is `Inner`, an `FStructProperty` whose `+0x78` is the
  `UScriptStruct` — and `ESP.propOffset` works on any `UStruct`. Blueprint struct members
  carry a GUID suffix (`ShotCost_12_0123ABCD…`), so a prefix match is needed.
- `AIM.gun()` dereferences a pointer validated up to a whole lock-hold ago. `RCX` at the
  trace call is the `WorldContextObject` and is necessarily alive; if it turns out to equal
  the weapon, comparing `rcx` instead of dereferencing `sod_sa_gun` removes the window
  entirely.
- `restoreWeaponField` writes class-default values back to every class carrying the
  property name, which is both too broad and not what the value was before the cheat.
