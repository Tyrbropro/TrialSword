# TrialSword: LiveOps Patching System

A scalable cross-server system to patch item stats (like Sword base damage) on the fly, designed to handle 20K+ CCU and 5000+ concurrent servers.

## Architecture

- **DataStore:** The single source of truth. Uses `UpdateAsync` (CAS) for safe versioning. Only the admin-originating server writes; followers never write on apply.
- **MessagingService:** Primary cross-server fan-out after a successful admin CAS (≤ ~2 min under normal conditions).
- **Polling (rare backup):** Slow, jittered DataStore reconcile (minutes, not ~50s). Skips GetAsync if MS applied a patch recently. Protects **per-key** Get throughput on `Current` (~100 RPS limit): e.g. 5000 servers / 240–300s ≈ 17–21 Get RPS amortized vs ~100 RPS at 50s.
- **No MemoryStore:** Intentionally skipped to avoid budget limits and API failure points at high server counts.

## File Structure

- `src/Server/LiveOps/` — Core system (Types, Config, Store, Messenger, Service).
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