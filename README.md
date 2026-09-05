# SoD Trainer

A Cheat Engine trainer for **Seed of the Dead: Sweet Home** — ESP, silent aim, and the
usual weapon and character options, written against the game's own UE4 reflection data
rather than byte signatures.

Single-player only. The game has no anti-cheat and no multiplayer.

## Why this exists

Community tables for this game locate the player by AOB-scanning for an injection point
and then apply fixed offsets. That breaks whenever the compiler moves anything, and it
gives no way to tell a wrong offset from a right one.

This trainer walks UE4's `GUObjectArray` and `FNamePool` and resolves **every field by
property name** through the reflection data the game ships with. A weapon swap, a level
change or a restart needs no rescan, and a field that is not where it is expected is
detected instead of silently corrupting memory. Three module-relative addresses are still
hardcoded (see below) and are verified at start-up.

## Supported build

Offsets were measured against one specific executable and are checked before anything runs:

| | |
|---|---|
| Game | Seed of the Dead: Sweet Home (GOG) |
| Engine | Unreal Engine 4.27, Shipping |
| Module | `SoD2-Win64-Shipping.exe` |
| Module size | `0x5194000` (85,540,864 bytes) |
| PE timestamp | `0x653EA209` (2023-10-29 18:18:49 UTC) |
| Cheat Engine | tested on 7.6 |

On any other build `ESP.selfCheck()` refuses to start and says which check failed. It does
not try to adapt — a wrong base address here means writes land on unrelated data and the
game dies minutes later, far from the cause.

## Install

1. Copy `src/` somewhere, e.g. `C:\SoDTrainer\`.
2. Open `SoD_Trainer.ct` in Cheat Engine and point `SOD_ROOT` at that folder — it is the
   first line of the script, and it needs a trailing separator.
3. Start the game and get into a match, then tick the table entry.
4. Press **Insert** for the menu.

`SOD_ROOT` can also be set in CE's Lua console before enabling the entry, which leaves the
table file untouched.

## Features

Everything is a toggle in the menu; nothing is on until you switch it on.

| Group | Option | Notes |
|---|---|---|
| Weapons | 无限弹药 Infinite ammo | Pins the per-shot cost to 0, so no reload is triggered |
| | 无后坐力 No recoil | |
| | 无扩散 No spread | |
| | 长按连发 Full-auto | Only for weapons that are not already full-auto |
| | 高伤害 Big damage | Overrides the distance falloff curve |
| | 近战超远距离 Mega melee | Melee reach, not area |
| Aim | 静默自瞄 Silent aim | Rewrites the trace endpoint; the crosshair does not move |
| | 锁弱点/爆头 Headshot | Resolves the weak point from the skeleton, per species |
| | 优先解救队友 Rescue priority | Targets a grabbed team-mate — shooting *her* is how the game frees her |
| | 自动开火 Auto shoot | Pulls the trigger when a target is locked |
| | 炮台模式 Turret | Nearest enemy in any direction, no need to turn |
| | 穿墙命中 Wallbang | Moves the trace start past the wall; needs silent aim |
| Player | 无敌 God mode | |
| | 无限体力 Infinite stamina | |
| | 无限手雷 Infinite grenades | |
| | 拾取助手 Loot assist | Offers the next pickup to your **E** key, anywhere on the map |
| Team-mates | 队友无敌 Ally god mode | Full health, no damage, never downed |
| | 队友免疫侵犯 Allies can't be grabbed | Blocks the grab rather than needing a rescue |
| ESP | Overlay with per-tier boxes | Trash / elite / boss / weapons / items / team-mates, each toggleable |

Loot assist does not press anything for you. It keeps the next pickup in the field the
game's **E** action reads, so one press collects it wherever it is; it yields to doors,
shutters and downed team-mates so normal interaction still works.

## Hotkeys

| Key | |
|---|---|
| **Insert** | show / hide the menu |
| **End** | toggle the ESP overlay |

Rebind by setting `MENU.HOTKEY` / `ESP.HOTKEY` (virtual-key codes) before the modules load.

## Layout

```
src/     the trainer: five Lua modules and the Cheat Engine table
docs/    INTERNALS.md — engine layout, hook design, concurrency model
         CHANGELOG.md — what changed and why
tools/   check_scope.py — catches Lua locals used above their declaration
```

## Contributing

`docs/INTERNALS.md` is worth reading first: it records the measured structure layouts, the
approaches that were tried and abandoned, and the traps that cost the most time. Please do
not re-attempt the things listed there as measured dead ends without new evidence.

Run before opening a PR:

```
luacheck src
luac5.3 -p src/*.lua
python3 tools/check_scope.py src
```

## Disclaimer

For single-player use on your own copy. The game ships no anti-cheat and has no
multiplayer, so there is nobody else to affect — but modifying a running process can crash
it, and save files are yours to back up. Use at your own risk.

## License

MIT — see `LICENSE`.
