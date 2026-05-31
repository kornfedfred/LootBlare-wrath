# LootBlare ↔ RollFor Sync — Design Document

**Date:** 2026-05-31
**Status:** Approved
**Target:** WotLK 3.3.5a (Interface 30300) — ChromieCraft

---

## Goal

Transform LootBlare from a passive roll-display frame into an active companion for RollFor. When the ML opens a corpse, LootBlare shows all dropped loot in a unified frame. Raiders can pre-mark items with roll intent (SR/MS/OS/TM). When each item's roll starts, LootBlare auto-rolls for them.

## Architecture

### Communication Layer

RollFor broadcasts structured state via AceComm-3.0 on the `"RollForSync"` channel. Messages are serialized (LibSerialize), compressed (LibDeflate), and encoded for the addon channel. LootBlare adds a passive listener on the same channel using the same decode pipeline.

```
RollFor ML → AceComm("RollForSync") → LootBlare RollForSync.lua → LootBlare UI
```

LootBlare **never sends** on this channel — it's read-only. No conflict with RollForReceiver.lua since multiple listeners are allowed on the same AceComm prefix.

### Backward Compatibility

- Chat-based triggering ("Roll for [item]" in PARTY/RAID/RW) still works if RollFor is not installed
- LootBlare's own addon protocol (PREFIX "LB") still works for ML settings sync
- SavedVariables unchanged

---

## New Libraries

Copied from `roll-for-wrath/libs/` (already proven on 3.3.5a):

| Library | Source Path | Purpose |
|---------|------------|---------|
| AceComm-3.0 | `roll-for-wrath/libs/Ace3/AceComm-3.0/` | Addon channel multiplexing |
| LibSerialize | `roll-for-wrath/libs/LibSerialize/` | Table serialization |
| LibDeflate | `roll-for-wrath/libs/LibDeflate/` | Compression + addon channel encoding |

---

## Unified Frame Design

One draggable frame with two zones:

```
┌──────────────────────────────────────────────────┐
│  LootBlare                              [−] [×]  │
├──────────────────────┬───────────────────────────┤
│  DROPPED LOOT        │  ACTIVE ROLL              │
│                      │                           │
│  1. [Epic Sword]     │  ┌─────┐                  │
│     SR: PlayerA      │  │icon │ [Epic Sword]     │
│     ✅ Won: PlayerA  │  └─────┘ Epic · BoP       │
│                      │                           │
│  2. [Blue Ring]      │  ⏱ 12.3s                  │
│     🎯 MS ← intent   │                           │
│                      │  PlayerB (MS) — 95        │
│  3. [Green Trinket]  │  PlayerC (OS) — 42        │
│     ⏳ Pending        │  PlayerD (MS) — 38        │
│                      │                           │
│  4. [Plate Helm]     │  [SR] [MS] [OS] [TM]     │
│     HR (disabled)    │                           │
└──────────────────────┴───────────────────────────┘
```

### Left Panel — Loot Preview

- Populated from RollFor's chat announce ("X dropped N items:" + numbered item lines)
- Each row: small item icon (shift-hover for tooltip+compare), item link, SR/HR annotation
- Click a row → cycle intent: **none → SR → MS → OS → TM → none**
- HR items → intent selector disabled, shows "HR" greyed out
- Status updates via AceComm:
  - `RF_START` → "Rolling" (highlighted)
  - `RF_WIN` → "Won by PlayerName"
  - `RF_FINISH` → resolved
  - `RF_CANCEL` → "Canceled"

### Right Panel — Active Roll

- Large item icon (shift-hover for tooltip+compare)
- Item name, quality-colored border
- Countdown timer from `RF_TICK`
- Sorted roll list (class-colored names, roll value, roll type badge)
- Roll buttons: SR/MS/OS/TM with thresholds from `RF_START` payload
- Shows "Auto-rolled (MS)" confirmation when auto-roll fires

### Lifecycle

1. Frame appears when loot-drop chat announce is detected
2. Left panel fills with items from the numbered chat lines
3. Raider clicks items to set intents (before or during rolls)
4. `RF_START` → right panel activates, auto-roll fires instantly if intent set
5. `RF_ROLL` → right panel updates sorted roll list
6. `RF_TICK` → right panel updates timer
7. `RF_WIN` → left panel marks winner, right panel shows result
8. `RF_FINISH` → right panel clears, ready for next item
9. All items resolved → auto-hide (if enabled) or stay for review

---

## Auto-Roll

### Behavior

- When `RF_START` arrives with `{ strategy, link, ms, os_roll, seconds }`:
  1. Match `link` against `state.lootPreview` entries
  2. If matching entry has an intent:
     - SR/MS intent → `RandomRoll(1, ms_threshold)`
     - OS intent → `RandomRoll(1, os_threshold)`
     - TM intent → `RandomRoll(1, tm_cap)` (from LootBlare config)
  3. Fire immediately (no delay)
  4. Visual confirmation on left panel: intent badge flashes
  5. Right panel shows "Auto-rolled (MS)" text

### Safety

- No intent = no auto-roll (fully manual, buttons still available)
- Manual /roll still works after auto-roll (WoW allows it; RollFor uses first roll)
- HR items cannot have intent set
- Intents are ephemeral — cleared when loot list resets (no SavedVariables)

---

## Data Model

```lua
-- Per-boss loot session (ephemeral, not saved)
state.lootPreview = {
    [1] = {
        link = "|cff...|h[Epic Sword]|h|r",
        icon = "Interface\\Icons\\...",     -- resolved via GetItemInfo
        quality = 4,                         -- rarity
        sr = "PlayerA",                      -- soft-res annotation or nil
        hr = false,                          -- hard-reserved
        count = 1,                           -- quantity (2x etc)
        status = "pending",                  -- pending | rolling | won | canceled
        winner = nil,                        -- "PlayerA" when won
        intent = nil,                        -- nil | "sr" | "ms" | "os" | "tm"
        autoRolled = false,                  -- true after auto-roll fires
    },
    -- ...
}
```

---

## File Structure

| File | Purpose | Est. Lines |
|------|---------|------------|
| `RollForSync.lua` | AceComm listener, decode, dispatch to state | ~150 |
| `LootPreview.lua` | Left panel UI: item list, intent selector, status | ~200 |
| `LootBlare.lua` | Modified: right panel roll display, auto-roll trigger, unified frame | Modified |
| `Config.lua` | Unchanged (existing settings still apply) | Unchanged |

### TOC additions

```
# Sync Libraries
Libs\AceComm-3.0\AceComm-3.0.xml
Libs\LibSerialize\LibSerialize.lua
Libs\LibDeflate\LibDeflate.lua

# New modules
RollForSync.lua
LootPreview.lua
```

---

## RF_* Message Reference

| Message | Trigger | Payload | LootBlare Action |
|---------|---------|---------|-----------------|
| `RF_ITEM` | ML selects item | `link, count` | Highlight item in preview |
| `RF_START` | Roll begins | `strategy, link, count, seconds, ms, os_roll, rolls` | Activate right panel, auto-roll |
| `RF_ROLL` | Player rolls | `player_name, player_class, roll_type, roll` | Add to sorted roll list |
| `RF_TICK` | Timer tick | `seconds_left` | Update countdown |
| `RF_WIN` | Winner found | `name, class, roll_type, roll, link, item_id, strategy` | Mark winner in preview + right panel |
| `RF_TIE` | Tie detected | `players, roll, roll_type` | Show tie state |
| `RF_TIE_ROLL` | Tie reroll (whisper) | `roll_type, ms, os_roll` | Show reroll buttons if you're a tied player |
| `RF_WAIT` | Waiting for rolls | — | Show waiting state |
| `RF_FINISH` | Roll complete | — | Clear right panel, advance |
| `RF_CANCEL` | Roll canceled | — | Show canceled state |

---

## Implementation Order

1. **Copy libraries** — AceComm-3.0, LibSerialize, LibDeflate from roll-for-wrath
2. **RollForSync.lua** — AceComm listener + decode + message dispatch
3. **LootPreview.lua** — Left panel UI with item list and intent selector
4. **Refactor LootBlare.lua** — Unified frame layout, integrate preview + roll panels
5. **Auto-roll logic** — Wire RF_START → intent check → RandomRoll
6. **Polish** — Status transitions, visual feedback, edge cases
7. **Test in-game** — Verify with RollFor in raid/party
