# OT2FCLite — one-key party swap for OCTOPATH TRAVELER II

Swap your whole party with a single key so the other four travellers' **path actions**
(Challenge, Provoke, Guide, Scrutinize, Steal, Purchase, Inquire, Entreat…) become
usable at NPCs — and let benched travellers share **EXP and JP** so they stop sitting
at level 1.

![Before / after](docs/compare-before-after.gif)

> Tested on **v1.1.0 / build 13399590** (Steam). A game update may break it.
> Unofficial fan mod. No game assets, no patched game files, no native engine hooks.

## Why this exists

OCTOPATH TRAVELER II only lets four of the eight travellers act. The other four never
offer their path actions at NPCs, so you have to walk back to a tavern whenever you
want them — and they gain no EXP at all, which leaves them permanently at level 1.

The "only four may act" rule is hard-coded in the game's C++ module and the
field-command data table has no per-character field, so a data-only (pak) mod cannot
change it. This project does the next best thing: it swaps the party data the same way
the in-game tavern does, and lets the game rebuild the field characters itself.

## How it works

* `F5` writes the party array in your save data (same fields the tavern writes), then
  asks the game to refresh the party.
* You press `Y` to open the game's own party screen and close it — that is where the
  game rebuilds the actual field characters. **Do not skip this step.**
* EXP / JP are mirrored onto the benched travellers by hooking the game's own
  blueprint helper that grants EXP (`LibCharacter_C:AddCharacterExp` / `AddJobPoint`).

## Install

The easy way uses the bundled installer (download the release zip, not this repo):

1. Extract `OT2FCLite-1.0.0.zip` anywhere.
2. Double-click `一键安装或卸载.bat` and accept the UAC prompt.
3. Click the second button from the left (green) — Install / Update.

The installer finds the game, backs up your saves, installs UE4SS v3.0.1 if it is
missing, writes the required settings, copies the mod, registers it in `mods.txt` and
self-checks. Files it touches are backed up as `.bak` first.

Manual install: see [INSTALL.txt](INSTALL.txt).

## Use

1. In the field, press `F5`.
2. Press `Y`, then close the party screen.
3. Talk to an NPC — the new members' path actions are there and work natively.

## Configuration

All plain text, in `Mods\OT2FCLite\`, re-read while the game is running:

| File | Default | Meaning |
|---|---|---|
| `swapkey.txt` | `1` | `1` = bind the swap to F5, `0` = do not bind |
| `exphook.txt` | `1` | `1` = share EXP with the bench |
| `expratio.txt` | `100` | EXP share ratio (%) |
| `sharejp.txt` | `1` | `1` = share JP |
| `jpratio.txt` | `100` | JP share ratio (%) |
| `hooktarget.txt` | `none` | **must stay `none`** — other values are development leftovers and crash the game |

## Known limitations

* A **swap**, not eight simultaneous party slots — the game's party screen has four.
* The swap persists if you save afterwards; press `F5` again to swap back.
* Party order changes (reserves fill in ascending character ID), so the leader can change.
* Only recruited travellers take part; unrecruited slots are skipped.
* Story guests are left untouched — only the four traveller slots are swapped.
* Achievements: **not verified**. The mod does not patch the executable but does write
  save values.
* Do not combine with other mods that also modify EXP/JP.

## Credits

* [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) by the UE4SS-RE team (MIT, Copyright (c) 2022
  Narknon) — the scripting layer this mod runs on. Shipped unmodified in the release
  zip; see [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt).
* Not affiliated with Square Enix or Acquire. All game content belongs to its owners.

## 中文说明

## 中文说明

按 `F5` 换队 → 按手柄 `Y` 打开游戏自带队伍界面 → 关闭 → 新队员的天赋技能在 NPC 处可用。
未上场成员共享 EXP / JP。本仓库只含 Lua 脚本与配置，不含任何游戏资源；安装包中的 UE4SS
为 MIT 许可的第三方组件。

📖 **完整中文手册：[docs/中文使用手册.md](docs/中文使用手册.md)** — 安装、使用、配置、常见问题、已知限制、技术说明。

## License

MIT — see [LICENSE](LICENSE). The bundled UE4SS keeps its own MIT license.
