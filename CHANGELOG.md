# Changelog

## 1.0.0 — 2026-10-18

First public release.

* **One-key party swap (F5).** Swaps the four active travellers with the other four by
  writing the same party array the in-game tavern writes, then refreshing the party.
  Works with any composition the player sets up; the mod always computes
  "eight recruited travellers minus the current active party".
* **Bench EXP share.** Hooks `LibCharacter_C:AddCharacterExp` and mirrors each
  EXP grant onto the benched travellers. De-duplicated so one battle grants one batch
  (the game calls the grant once per active member).
* **Bench JP share.** Same for `LibCharacter_C:AddJobPoint`, writable with a
  `SetCharacterJobPoint` fallback.
* Story-guest slots are left untouched; unrecruited travellers are skipped.
* Plain-text configuration, re-read at runtime.
* Bundled Windows installer (PowerShell + batch) that backs up saves, installs
  UE4SS v3.0.1 if missing, writes the required settings, registers the mod and
  self-checks; and an uninstaller that removes only what it added.

### Known issues at release

* Achievements not verified.
* Party order changes after a swap (reserves fill in ascending character ID).
* Tested on v1.1.0 / build 13399590 only.
