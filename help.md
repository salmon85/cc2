# Colonial Conquest II — Manual Test Guide

Flags for launching the dedicated server and the clients, for driving the
multiplayer build by hand. Everything here was read out of `src/core/cli.gd`
and confirmed by running it; where something does not work yet, this file says
so rather than implying it does.

- **Engine**: Godot 4.7.2 at `~/.local/godot/godot`
- **Run everything from the project root** (`cd /home/salmon/cc2`). Every example
  below assumes that.
- Godot needs its own `--path .`; everything after it is passed to the game.

---

## Quick start

**Start with the server.** It works today:

```bash
cd /home/salmon/cc2
~/.local/godot/godot --headless --path . --server --port=7777 --slots=3 --seed=42
```

Expected output:

```
[cc2] launch: DEDICATED_SERVER ip=0.0.0.0 port=7777 seed=42 systems=50 factions=2 slots=3 (no warnings)
[cc2] session: DedicatedServer
[cc2] dedicated server ready: 0.0.0.0:7777, 3 slots, seed 42, 50 systems, stardate 1
```

The intended three-terminal flow, once the client path is wired — **terminals 2
and 3 do not connect yet** (see *Known limitation* before relying on them):

```bash
# Terminal 1 — dedicated server, 3 slots, reproducible galaxy
~/.local/godot/godot --headless --path . --server --port=7777 --slots=3 --seed=42

# Terminal 2
~/.local/godot/godot --headless --path . --client --ip=127.0.0.1 --port=7777 --seed=42

# Terminal 3 — same
~/.local/godot/godot --headless --path . --client --ip=127.0.0.1 --port=7777 --seed=42
```

Add `--verbose` to any of them for ENet-level traffic.

---

## Modes

Exactly one is chosen at launch. `--server` wins over `--client` if both are
given, and says so in a warning.

| Mode | Flag | What it does |
|---|---|---|
| Dedicated server | `--server` | Generates the galaxy, listens with ENet, waits for orders. No window. |
| Network client | `--client` | **Currently starts a local game — does not dial.** See *Known limitation*. |
| Single player | `--single` (aliases `--singleplayer`, `--local`) | Local game with the authority in-process. Default when no flag is given. |
| Setup menu | `--setup` (alias `--menu`) | Prints a line and starts no session. |

Single player is not a separate code path. It is a client bound to an in-process
loopback authority, so offline and networked play run the same turn resolution.

---

## Server flags

| Flag | Default | Notes |
|---|---|---|
| `--server` | — | Required for a dedicated server. |
| `--port=<int>` | `7777` | 1–65535. Server **binds** this. |
| `--slots=<int>` | `2` | 1–8, clamped. Empire slots the server admits. |
| `--seed=<int>` | random | Integer, **or any string** — `aurora-7` is hashed to a reproducible seed. |
| `--systems=<int>` | `50` | 30–100, clamped. Star systems generated. |
| `--factions=<int>` | `2` | 1–8, clamped. AI empires. Not the same as `--slots`. |

A healthy startup prints:

```
[cc2] launch: DEDICATED_SERVER ip=0.0.0.0 port=7777 seed=42 systems=50 factions=2 slots=3 (no warnings)
[cc2] session: DedicatedServer
[cc2] dedicated server ready: 0.0.0.0:7777, 3 slots, seed 42, 50 systems, stardate 1
```

To confirm it is listening:

```bash
ss -ulnp | grep 7777     # Linux
```

The server binds `0.0.0.0`, so it accepts connections from other machines. Pass
`--ip=` only if you need to see it echoed in the log; it does not change the bind.

### `--slots` vs `--factions`

Easy to confuse, and they mean different things:

- `--slots=N` — **human** players this server admits (max 8).
- `--factions=N` — **total** factions in the galaxy, including AI.

`--slots=2 --factions=2` is two humans and no AI. `--slots=2 --factions=4` is two
humans plus two AI factions competing for the same systems.

---

## Client flags

| Flag | Default | Notes |
|---|---|---|
| `--client` | — | Selects network-client mode. |
| `--ip=<host>` | `127.0.0.1` | Server address. A bare `--ip` also selects client mode. |
| `--port=<int>` | `27015` | Server port. Note this default is **not** 7777 — see below. |
| `--seed=<int>` | random | Only used by the local path today. |
| `--systems=` / `--factions=` | | Only used by the local path today. |

**Port defaults differ by mode, deliberately.** A bare `--server` binds 7777
(its default). But a client with no `--port` targets **27015** — the Quake-style
default the original game shipped with — and a server given a non-numeric port
like `--port abc` also falls back to 27015, not 7777. So this pair will *not*
connect:

```bash
# WRONG — server on 7777, client looking on 27015
~/.local/godot/godot --headless --path . --server --seed=42
~/.local/godot/godot --headless --path . --client --ip=127.0.0.1 --seed=42
```

Always pass `--port` explicitly to **both**.

`--ip=host:port` is accepted, but **only the host part is kept** —
`--ip=example.com:9999` resolves to `ip=example.com port=27015`. The port half
is stripped and discarded, it does *not* set `--port`. Use a separate `--port`.

---

## Flag syntax

Both `--key=value` and `--key value` are accepted:

```bash
--slots=3      # works
--slots 3      # also works
```

Values are validated. Out-of-range numbers are clamped rather than rejected;
non-numeric values fall back to the default:

```
[cc2] warning: slots 99 out of range [1, 8]; clamped to 8
[cc2] warning: port 0 out of range [1, 65535]; clamped to 1
[cc2] warning: port 'abc' is not an integer; using 27015
[cc2] warning: unknown flag ignored: --frobnicate
```

All of these are printed **above** the `launch:` line, one per line. Unknown
flags never stop the game. If a flag seems to do nothing, that warning block is
where it shows up.

Unknown flags never stop the game. If a flag seems to do nothing, the warning
line above `launch:` is where it shows up.

Godot's own flags (`--verbose`, `--path`, `--editor`, `--script`, …) are passed
through and never reported as unknown.

---

## Single player (works today, no networking)

```bash
~/.local/godot/godot --path . --single --seed=42
```

Or drop the window entirely:

```bash
~/.local/godot/godot --headless --path . --single --seed=42
```

This is the path the GUI drives, so it is the easiest way to confirm the galaxy
generator and turn resolver still behave.

---

## Known limitation: `--client` does not dial

**As of the Phase 6 commit, `--client` parses and routes correctly but never
calls `join_game()`.** It generates a galaxy locally and starts a local game
against it. Running it against a live server prints:

```
[cc2] launch: CLIENT ip=127.0.0.1 port=7979 seed=42 ...
[cc2] client attached: seed 42, 50 systems, stardate 1
```

— with no connection attempt, no error, and no `peer joined` line on the server.
The server simply never notices the client. The process then just sits there
until you kill it.

The transport underneath is fine; `join_game()` is exercised by the integration
tests, which run real sockets over loopback. What is missing is the wiring in
`src/app.gd` `_attach_client()` that would call `join_game()` and hand the
resulting snapshot to the client instead of generating a fresh galaxy.

So: **the server side is manually testable today; the client side is not.** To
exercise the real protocol now, run the integration test:

```bash
./tools/verify.sh                       # everything, ~2 min
```

or just the networking suite:

```bash
~/.local/godot/godot --headless --path . -s res://tests/test_enet_sync.gd
# => RESULT test_enet_sync: OK (110 checks passed)
```

That test stands up 1 server + 2 clients on ephemeral loopback ports, submits
orders, resolves a turn, and asserts both peers receive identical state hashes
and advance together — which is exactly the manual flow, automated.

### Diagnostics for the future client path

If you wire `_attach_client()` up and it misbehaves, these are the failure modes
already characterised during Phase 6:

- `The rpc node checksum failed` — the two sides have different `@rpc` method
  sets on the node at that path. Both sides must use `turn_sync_peer.gd`.
- `Failed to get path from RPC: @Node@8` — the endpoint was created unnamed, so
  each side resolved a different path. Build it via
  `NetworkManager.add_sync_endpoint()`, which names it consistently.
- `RPC 'x' on yourself is not allowed by selected mode` — the multiplayer branch
  is rooted on a child node, so the sync endpoint fell through to the tree
  default and thinks it *is* the server. The branch root must be the
  `NetworkManager`.
- `Condition "!is_inside_tree()" is true` — an RPC was attempted on a node that
  has not been added to the tree yet.

---

## Remote host test

To test across machines, on the server:

```bash
~/.local/godot/godot --headless --path . --server --port=7777 --slots=2 --seed=42
```

Open `7777/udp` in the firewall. On the client machine:

```bash
~/.local/godot/godot --headless --path . --client --ip=<server-ip> --port=7777
```

Remember `--port` on both sides. (Modulo the `--client` limitation above.)

---

## Checklist for a manual session

1. Server up, listening line printed, port visible in `ss -ulnp`.
2. Clients launched with an explicit `--port` matching the server.
3. Server logs a join per client: `peer <id> joined as empire <slot>`.
4. On disconnect, the slot is returned: `peer <id> left (empire <slot> dropped)`.
5. `--seed` is identical on server and clients if you expect the same galaxy.

Steps 3 and 4 require the client path to be wired; today the server prints them
only when driven by the integration test.

---

## Reference: all flags

| Flag | Values | Applies to |
|---|---|---|
| `--server` | — | server |
| `--client` | — | client |
| `--single`, `--singleplayer`, `--local` | — | single player |
| `--setup`, `--menu` | — | any |
| `--ip=<host>` | hostname or IP | client (also selects client mode) |
| `--port=<int>` | 1–65535 | both |
| `--slots=<int>` | 1–8 | server |
| `--seed=<int\|str>` | any | both |
| `--systems=<int>` | 30–100 | server, local |
| `--factions=<int>` | 1–8 | server, local |
| `--headless` | — | all |
| `--log-turns` | — | all |
| `--verbose` | — | all (Godot built-in) |