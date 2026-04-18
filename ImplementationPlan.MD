# NPC Retreat System Bug-Fix Plan (2026-04-16)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Context.** The v1 retreat system shipped and works end-to-end (retreat trigger, skull recovery gate, tile reservation, invulnerability during transit). Three behavior bugs surfaced in play:
- Attackers retreat (or silently disengage) when damaged by Defenders, not just by enemy Attackers.
- Retreated (skulled) NPCs cannot fight back against enemy Attackers.
- The skull overhead icon is oversized (reads as a badge, not a status indicator).

This plan fixes those three bugs with narrowly-scoped changes to two files. No existing retreat-system behavior outside the listed bug areas is touched.

---

## 1. Intended Behavior Rules (authoritative)

1. Attackers **must not** retreat when the damage source is a Defender.
2. Attackers **must not** enter any "offensive mute" state (stop firing at Defenders) purely because Defenders hit them.
3. When an Attacker is hit by an enemy **Attacker** while attacking a Defender, the Attacker **must** stop attacking the Defender while that enemy-Attacker threat is alive and adjacent. Manual Defender targets must resume automatically once the threat is gone.
4. A skulled NPC **must** retain full combat capability outside the actual retreat-transit window. The skull is a **visual status indicator**, not a "cannot fight" flag.
5. The skull icon **must** be sized like a normal overhead status indicator (≈ 24 px, ≈ 2.5 studs above HRP), not a 56 px emoji-filled badge.

These rules apply to Attackers specifically. Defender retreat behavior (10% HP → retreat attempt against any damage source) is **unchanged** unless stated otherwise.

---

## 2. Scope

### In scope
- Role-aware retreat trigger for Attacker targets.
- Removal of the HP-only Attacker offensive mute (`lowHealthAttackPaused`).
- New enemy-Attacker-specific threat channel that works for player-owned NPCs too.
- Attacker target-list filtering while an enemy-Attacker threat is active.
- Removing the skull-based combat pause gate.
- Skull GUI resize and asset swap.

### Out of scope
- Defender retreat logic — unchanged.
- Movement-phase invulnerability — unchanged (still governed by `NPCMovementSystem.isRetreating`).
- Tile selection / territory / scoring — unchanged.
- `AutoRetaliate` semantics for country-owned NPCs' auto-retaliation against Defenders — unchanged.
- Exhaustion counter, player-controlled retreat, health restoration — still future work.

---

## 3. Confirmed Current Behavior Being Changed

| # | Current code | File:line | Why it's wrong under §1 |
|---|---|---|---|
| C1 | Retreat trigger at `fireMultiLaser` fires on any shooter, any damage, when projected HP ≤ 10%. | NPCCombatSystem.luau:280-298 | Violates Rule 1 for Attacker targets hit by Defenders. |
| C2 | `shouldPauseAttackerCombatForHealth` mutes Attackers purely on HP ≤ 10%. | NPCCombatSystem.luau:186-213 | Violates Rule 2 (damage source ignored). |
| C3 | Retreat-success branch sets `lowHealthAttackPaused[targetNpcModel] = true`. | NPCCombatSystem.luau:289-290 | Double-mutes skulled Attackers — contributes to Bug 2. |
| C4 | Combat-loop gate OR-chains `shouldPauseForSkull` (= `hasSkull AND role ≠ "Attacker"`). | NPCCombatSystem.luau:374-375 | Violates Rule 4 for skulled Defenders. |
| C5 | Player-owned Attackers never consume `attackerThreats`; `noteHit` short-circuits unless `AutoRetaliate=true`. | NPCCombatSystem.luau:713, 906-920 | Violates Rules 3 & 4 for player-owned Attackers — they can never register an enemy-Attacker threat. |
| C6 | Skull GUI: `Size = UDim2.fromOffset(56, 56)`, `StudsOffset = (0, 4, 0)`, `TextScaled = true` on a ☠ emoji. | NPCRetreatSystem.luau:50, 51, 81 | Violates Rule 5. |

---

## 4. Design

### 4.1 Damager-role-aware retreat (Rule 1)

`fireMultiLaser` already knows the shooter (`npcModel` parameter). The retreat check at line 287 becomes:

> If the target is an Attacker (`npcRoles[targetNpcModel] == "Attacker"`), only call `attemptRetreat` when the shooter is also an Attacker (`npcRoles[npcModel] == "Attacker"`). Otherwise skip the retreat check and let damage resolve normally.
>
> If the target is a Defender, behavior is unchanged — the existing retreat attempt still fires.

This is a one-conditional change. No new state, no new API.

### 4.2 Replace HP-only offensive mute with threat-driven mute (Rules 2 & 3)

- Delete `shouldPauseAttackerCombatForHealth` and its call site in the combat-loop gate.
- Delete the `lowHealthAttackPaused[targetNpcModel] = true` line in `fireMultiLaser`'s retreat-success branch.
- Delete the `lowHealthAttackPaused` table and every remaining reference (`registerNPC`, `unregisterNPC`, `transferOwnership` if present).

In its place: a **universal enemy-Attacker threat channel** that any Attacker (player-owned or country-owned) can read. This channel does **not** replace `attackerThreats` (which serves the AutoRetaliate auto-retaliation feature). It lives alongside it and is cheaper to consume.
In `noteHit`, populate this channel **before** the legacy `AutoRetaliate` early return so player-owned Attackers still register the threat. The existing `AutoRetaliate` path remains in place for `attackerThreats`.

New state:

```
enemyAttackerThreats: { [AttackerNpcModel] = { [EnemyAttackerModel] = true, ... } }
```

Written to in `noteHit` whenever **shooter is Attacker AND target is Attacker AND they are on opposing, hostile countries**, regardless of `AutoRetaliate`.
Cleared when: the threat NPC dies, becomes non-adjacent, is unregistered, or the target NPC's ownership changes.

### 4.3 Attacker target-list filtering (Rule 3)

Inside the Attacker `getAllTargets` callback (NPCCombatSystem.luau:672), after collecting manual targets and before returning:

1. Walk `enemyAttackerThreats[npcModel]`. Prune dead / non-adjacent / non-hostile entries in the same sweep. Track whether any live, adjacent, hostile enemy Attacker remains — call this `hasEnemyAttackerThreat`.
2. If `hasEnemyAttackerThreat`, **filter the returned target list to exclude Defender-role entries** (keep any Attacker-role manual targets).
3. Always append every live enemy-Attacker threat to the returned list so the Attacker fires back — including for player-owned NPCs. This is the minimum change to the existing line-713 behavior (player-owned Attackers now consume `enemyAttackerThreats`, but still **not** `attackerThreats`, preserving the rule that player-owned Attackers don't auto-retaliate against Defenders).

This means the "stop attacking Defenders" behavior is non-destructive: `manualTargets[npcModel]` is not mutated. When the threat dies or disengages, `hasEnemyAttackerThreat` becomes false on the next combat tick and the Defender targets flow through again.

### 4.4 Skull is cosmetic (Rule 4)

In the combat-loop gate at NPCCombatSystem.luau:374-375, drop `shouldPauseForSkull` from the OR chain. The new gate retains only `moveSystem.isRetreating(npcModel)` — which is **true only during the actual retreat movement**, which is the correct invulnerability window.

Skulled NPCs post-arrival:
- Are visible to enemy target filters (unchanged: those check `isRetreating`, not `hasSkull`).
- Consume their own target/threat lists normally.
- Fire on valid targets normally.
- Still show the skull GUI until HP ≥ 30% (unchanged).

### 4.5 Skull GUI resize (Rule 5)

In `NPCRetreatSystem.createSkullGui`:
- `billboard.Size` → `UDim2.fromOffset(24, 24)`.
- `billboard.StudsOffset` → `Vector3.new(0, 2.5, 0)`.
- Replace the ☠ emoji TextLabel + `TextScaled = true` with an **ImageLabel** referencing the finalized skull asset ID. If a valid asset ID is not ready yet, keep a smaller text-skull fallback temporarily instead of using `rbxassetid://0`.
- Keep the red circular Frame backdrop, scaled to the new 24 px size. `UICorner.CornerRadius = UDim.new(1, 0)` remains (preserves the circle shape). `UIStroke` thickness drops to 1.
- Keep `AlwaysOnTop = true`, `LightInfluence = 0`, `MaxDistance = 250`.

---

## 5. Tasks

### Task 1: Damager-role-aware retreat trigger

- [ ] **Step 1:** In `fireMultiLaser`, read `shooterRole = npcRoles[npcModel]` before the retreat decision.
- [ ] **Step 2:** Wrap the `attemptRetreat(targetNpcModel)` call in a condition: skip when `npcRoles[targetNpcModel] == "Attacker"` **and** `shooterRole ~= "Attacker"`. Defender targets unchanged.
- [ ] **Step 3:** Remove the `lowHealthAttackPaused[targetNpcModel] = true` assignment in the retreat-success branch.
- [ ] **Step 4:** Commit.

### Task 2: Remove HP-only Attacker offensive mute

- [ ] **Step 1:** Delete `shouldPauseAttackerCombatForHealth` (function body) and its declaration.
- [ ] **Step 2:** In the combat-loop gate, remove the `isLowHealthAttackPaused` local, its call site, and its OR in the `if` condition.
- [ ] **Step 3:** Delete the `lowHealthAttackPaused` table and all remaining reads/writes (`registerNPC`, `unregisterNPC`, `transferOwnership` if touched).
- [ ] **Step 4:** Verify no references remain via grep.
- [ ] **Step 5:** Commit.

### Task 3: Universal enemy-Attacker threat channel

- [ ] **Step 1:** Add `local enemyAttackerThreats = {}` at module scope alongside `attackerThreats`.
- [ ] **Step 2:** Add private helpers: `addEnemyAttackerThreat(targetNpc, shooterNpc)`, `removeEnemyAttackerThreat(targetNpc, shooterNpc)`, `clearEnemyAttackerThreats(npc)`. Keyed as a set (`[EnemyNpc] = true`) for O(1) membership tests.
- [ ] **Step 3:** Extend `noteHit`: record the enemy-Attacker threat **before** the legacy `AutoRetaliate` early return, so the new channel is populated even for player-owned Attackers. If `npcRoles[attackerNpc] == "Attacker"` AND `npcRoles[targetNpc] == "Attacker"` AND `DiplomacyManager.canNPCAttack(targetNpc, attackerNpc)`, call `addEnemyAttackerThreat(targetNpc, attackerNpc)`. The existing `AutoRetaliate` branch stays in place for `attackerThreats`.
- [ ] **Step 4:** In `unregisterNPC` and `transferOwnership`, add sweeps that remove `npcModel` from every `enemyAttackerThreats[*]` entry and clear `enemyAttackerThreats[npcModel]`. Mirror the existing sweeps for `manualTargets`, `defenderAttackers`, `attackerThreats`.
- [ ] **Step 5:** Commit.

### Task 4: Attacker target-list filtering & player-owned threat consumption

- [ ] **Step 1:** Inside the Attacker `getAllTargets` callback, after manual-target validation, walk `enemyAttackerThreats[npcModel]`. For each entry, validate: parent exists, humanoid alive, `areNPCsOnAdjacentTiles`, `DiplomacyManager.canNPCAttack` still holds. Remove invalid entries in place.
- [ ] **Step 2:** Track `hasEnemyAttackerThreat` and build a `validEnemyAttackerHumanoids` list during that walk.
- [ ] **Step 3:** If `hasEnemyAttackerThreat`, remove entries from `allValidTargets` where the owning model's `npcRoles[model] == "Defender"`. Keep Attacker-role manual targets.
- [ ] **Step 4:** Append `validEnemyAttackerHumanoids` to `allValidTargets` (de-duplicate against manual Attacker targets). This runs **regardless of `hasActivePlayerOwner(npcModel)`** — it supersedes the line-713 restriction for the enemy-Attacker channel only. `attackerThreats` (auto-retaliation) remains gated by `hasActivePlayerOwner` as before.
- [ ] **Step 5:** Commit.

### Task 5: Skull is cosmetic (remove skull-based combat pause)

- [ ] **Step 1:** In the combat-loop gate (NPCCombatSystem.luau:374-375), delete `shouldPauseForSkull` (and the `retreatSys.hasSkull` call in that gate). Keep `moveSystem.isRetreating(npcModel)` as the only pause in that branch.
- [ ] **Step 2:** Confirm `retreatSys` is still referenced elsewhere in the file; if not, leave the `getRetreatSystem()` lazy-loader in place because `fireMultiLaser` still uses it.
- [ ] **Step 3:** Commit.

### Task 6: Shrink skull icon

- [ ] **Step 1:** In `NPCRetreatSystem.createSkullGui`, change `billboard.Size = UDim2.fromOffset(24, 24)` and `billboard.StudsOffset = Vector3.new(0, 2.5, 0)`.
- [ ] **Step 2:** Replace the `TextLabel` + `☠` emoji with an `ImageLabel` using the finalized skull asset ID. If a valid asset ID is not ready yet, keep the smaller text-skull fallback temporarily instead of using `rbxassetid://0`. Size `UDim2.new(1, 0, 1, 0)`, `BackgroundTransparency = 1`.
- [ ] **Step 3:** Keep the red-circle Frame backdrop with `UICorner(1,0)` and `UIStroke` (thickness 1 at the new size).
- [ ] **Step 4:** Visually verify in Studio at default camera distance against the reference screenshot.
- [ ] **Step 5:** Commit.

### Task 7: Integration verification

- [ ] **A1 — Defender damage does NOT cause Attacker retreat or mute.** Spawn 1 Attacker vs. 2 Defenders on adjacent tiles, no enemy Attackers present. Drive the Attacker's HP below 10% via Defender return fire. Expected: Attacker does **not** retreat, does **not** acquire a skull, continues to fire on its Defender manual targets.
- [ ] **A2 — Enemy Attacker damage causes stop-attacking-Defender behavior.** Attacker-A targeting Defender-D. Spawn enemy Attacker-B adjacent to A. B fires at A via `noteHit`. Expected: on the next combat tick, A's target list excludes D and includes B. When B is killed or moves off-adjacent, A's target list includes D again without re-issuing the manual order.
- [ ] **A3 — Skulled NPC fights back.** Drive Attacker-A below 10% via enemy-Attacker fire, let A retreat and finish transit. Skull appears. Have enemy Attacker-B approach A's new tile. Expected: A fires at B despite carrying the skull.
- [ ] **A4 — Skulled Defender fights back.** Drive Defender-D below 10% via Attacker fire, let D retreat. Skull appears. Enemy Attacker approaches. Expected: D fires at the attacker.
- [ ] **A5 — Player-owned Attacker threat channel.** Repeat A2/A3 with a player-owned Attacker. Expected: same behavior; the player-owned Attacker acquires and discharges the enemy-Attacker threat despite having no `AutoRetaliate` attribute.
- [ ] **A6 — Skull visual.** Confirm the skull icon renders at roughly the size of the reference screenshot, ~2.5 studs above HRP, clearly readable but not dominating the character's silhouette.
- [ ] **A7 — No regressions.** Re-run v1 test scenarios (retreat at 10%, skull at 30% recovery, invulnerability during transit, die-if-trapped). All must still pass.
- [ ] **Commit.**

---

## 6. Rejected Alternatives

| Alternative | Why Rejected |
|---|---|
| Keep `lowHealthAttackPaused` and just gate it on shooter role | Retains a silent-disengage twin of retreat that the player can't see. A single threat-driven rule is simpler and easier to reason about. |
| Clear `manualTargets[attacker]` Defender entries on enemy-Attacker hit | Lossy — player would need to re-issue target orders after every engagement. Filter-based pause is non-destructive and auto-resumes. |
| Add a skull-aware "fire back at Attackers only" exception inside `shouldPauseForSkull` | Creates a three-branch conditional inside a hot gate and still leaves the skull as a partial combat flag. Cleaner to make skull purely cosmetic and trust `isRetreating` for transit invulnerability. |
| Expand `AutoRetaliate=true` to player-owned NPCs | Too broad — player-owned NPCs should **not** auto-retaliate against Defenders. The new `enemyAttackerThreats` channel is narrowly scoped to enemy-Attacker-on-Attacker hits. |
| Start using `NPCMovementSystem.canBeAttacked()` at combat target filters | Wraps `isRetreating` with no added logic. Doesn't distinguish transit vs. skulled-but-idle, which is the actual bug. |
| Move `hasSkull` into `NPCMovementSystem.movementStates` to unify sources of truth | Scope creep. Skull is cosmetic after this fix; having it as a separate module flag is fine and already cleanly owned. |

---

## 7. Scalability Check

- `enemyAttackerThreats[npc]` is bounded by the number of adjacent hostile Attackers — capped at tile fan-out (typically ≤ 6 neighbors × a small number of NPCs per tile). Combat-tick cost is negligible.
- Filtering runs inside the existing `getAllTargets` callback; no new loops, no new per-frame work.
- `noteHit` extension is a constant-time insert.
- Cross-NPC sweeps in `unregisterNPC` / `transferOwnership` are already O(N) over the tables; adding `enemyAttackerThreats` is one more O(N) sweep at the same cost class. No change in asymptotic behavior.
- Skull resize is zero runtime cost.

---

## 8. Failure Simulations

| Scenario | Expected behavior |
|---|---|
| Enemy Attacker dies while threat is active | Next combat tick prunes it via parent/health checks → `hasEnemyAttackerThreat` becomes false → Attacker's Defender targets re-enter the list. |
| Enemy Attacker moves off-adjacency | Same prune path (adjacency test fails). No special case needed. |
| Attacker retreats while under enemy-Attacker fire | Retreat trigger still fires (Rule 1 allows Attacker-on-Attacker retreat). Skull appears. After transit, Rule 4 keeps the Attacker combat-capable, and the threat channel keeps it engaged with the enemy Attacker. |
| Country / ownership change mid-engagement | `transferOwnership` sweeps `enemyAttackerThreats` alongside the existing sweeps. No stale threats. |
| Simultaneous Defender + enemy Attacker damage | Rule 1 only gates retreat on the **current triggering shot**. A lethal shot from a Defender still resolves as normal damage; only a lethal shot from an enemy Attacker attempts retreat. No ordering issue. |
| Skull removes while enemy-Attacker threat still active | Independent lifecycles — skull removal on HP ≥ 30% does not touch `enemyAttackerThreats`. Attacker keeps focusing on the threat until the threat is gone. |
| `AutoRetaliate=true` country-owned Attacker takes Attacker-on-Attacker hit | Both `attackerThreats` **and** `enemyAttackerThreats` populate. Target-list path prefers `enemyAttackerThreats` for the Defender-filtering decision; `attackerThreats` continues to drive auto-retaliation. No conflict. |

---

## 9. Files Touched

| File | Change |
|---|---|
| `src/shared/NPCCombatSystem.luau` | Role-aware retreat gate in `fireMultiLaser`; delete `shouldPauseAttackerCombatForHealth` + `lowHealthAttackPaused`; add `enemyAttackerThreats` table + helpers; extend `noteHit`; update Attacker `getAllTargets`; drop `shouldPauseForSkull` from combat-loop gate; extend sweeps in `unregisterNPC` and `transferOwnership`. |
| `src/shared/NPCRetreatSystem.luau` | Resize skull GUI (56→24 px, offset 4→2.5 studs); swap TextLabel(☠) for ImageLabel. |
| (no others) | `NPCMovementSystem.luau`, `NPCTargetingHandler.server.luau`, `NPCSpawner.luau`, etc. — unchanged. |

---

## 10. Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Damager-role-aware retreat trigger | MODIFY: NPCCombatSystem.luau |
| 2 | Remove HP-only Attacker offensive mute | MODIFY: NPCCombatSystem.luau |
| 3 | Universal enemy-Attacker threat channel | MODIFY: NPCCombatSystem.luau |
| 4 | Attacker target-list filtering & player-owned threat consumption | MODIFY: NPCCombatSystem.luau |
| 5 | Skull is cosmetic (remove skull-based combat pause) | MODIFY: NPCCombatSystem.luau |
| 6 | Shrink skull icon | MODIFY: NPCRetreatSystem.luau |
| 7 | Integration verification | All files |

Total tasks: 7 (each with 3-5 steps). All tasks sequential; Task 7 depends on 1-6.
