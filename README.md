# TrialSword: LiveOps Patching System

A scalable cross-server system to patch item stats (like Sword base damage) on the fly, designed to handle 20K+ CCU and 5000+ concurrent servers.

## Architecture

- **DataStore (`Current`):** Durable truth. Admin CAS `UpdateAsync` only; followers never write on apply.
- **MemoryStore (one map/key):** Latest `LiveOpsDocument` snapshot for fast shared reads. Boot and MS handlers prefer this so mass restarts do not hammer DataStore per-key (~100 Get RPS).
- **MessagingService:** Tiny version signal only (`SchemaVersion` + `Version`, ≪ 1KiB) — never the full patch. Handlers load the document from MemoryStore (one DS Get fallback on miss).
- **No fleet-wide DataStore poll.** Subscribe retries with exponential backoff if MS subscribe fails. Propagation ≤ ~2 min under normal conditions (typically seconds via MS + MemoryStore).

## File Structure

- `src/Server/LiveOps/` — Types, Config, Store (DS), Cache (MemoryStore), Messenger (tiny MS), Service.
- `src/Server/ItemService.luau` — Applies the live patch over base stats (`override or base`).
- `src/Server/Admin.luau` — Handles admin auth, rate limiting, and pushing updates.
- `src/Server/main.server.luau` — Entry point, exposes `LiveOpsBridge` for Studio testing.

## How to Test

1. Sync the project via `rojo serve`.
2. In Studio, go to **Game Settings → Security** and enable **Studio Access to API Services**.
3. Press **Play**. You should see `[LiveOps] applied vN` in the Output.

### Triggering a patch in Studio (Command Bar)

Do **not** `require` the LiveOpsService directly from the command bar (it will create a fresh, separate module state). Use the bridge exposed by `main`:

```lua
local bridge = game:GetService("ServerScriptService").main.LiveOpsBridge

-- Check current state
print("Version:", bridge.GetLocalVersion:Invoke())
print("Damage:", bridge.GetEffectiveSwordDamage:Invoke())

-- Push a live patch (Ensure your UserId is added to Admin Config)
print("Patching...", bridge.RequestPatch:Invoke(YOUR_USER_ID, 250))