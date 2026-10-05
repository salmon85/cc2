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

**This works now.** Three terminals; terminal 1 is the authority.

```bash
cd /home/salmon/cc2
```

```bash
# Terminal 1 — dedicated server, 2 slots, reproducible galaxy
~/.local/godot/godot --headless --path . --server --port=7777 --slots=2 --seed=42
```

Expected output:

```
[cc2] launch: DEDICATED_SERVER ip=0.0.0.0 port=7777 seed=42 planets=50 factions=2 slots=2 (no warnings)
[cc2] session: DedicatedServer
[cc2] dedicated server ready: 0.0.0.0:7777, 2 slots, seed 42, 50 planets, stardate 1
```

```bash
# Terminal 2 — a real window, playing empire 0
~/.local/godot/godot --path . --client --ip=127.0.0.1 --port=7777

# Terminal 3 — a second window, playing empire 1
~/.local/godot/godot --path . --client --ip=127.0.0.1 --port=7777
```

Each client should print:

```
[cc2] joining 127.0.0.1:7777 -- waiting for the opening state
[cc2] connected; handshake in progress
[cc2] joined as empire 0: seed 42, 50 planets, stardate 1
```

…and the server should log a seat per client:

```
[cc2] peer 1781186228 joined as empire 0
[cc2] peer 368699998 joined as empire 1
```

> **The match does not start yet.** A game waits for every *connected* player
> to be ready — not for every seat `--slots` admits to fill. A `--slots=4` server
> with two people in it shows `Ready 0/2` and starts as soon as both press **READY**;
> the two empty seats are not a reason to wait for people who are never coming. If
> someone drops out mid-game the count shrinks to the players who are still there.
> The server prints `[cc2] match started` when the gate opens. Headless
> clients pass `--ready` instead of pressing anything — see
> [The lobby](#the-lobby).

Note the clients do **not** print a `launch:` line showing `slots`, and they ignore
`--seed`: the galaxy belongs to the server, so a client that seeded its own would be
playing a different universe. Whatever `--seed` the server used is what both clients
get, which is why `seed 42` appears in their output.

Play a turn: once **READY** has been pressed in both windows, stage orders and press
**END TURN**. That client's top bar shows `Awaiting other players...` until every
connected player has submitted; then the server resolves, both windows advance a
stardate together, and the server logs:

```
[cc2] turn 1 resolved, hash 1789442519
```

Add `--verbose` to any of them for ENet-level traffic.

---

## Modes

Exactly one is chosen at launch. `--server` wins over `--client` if both are
given, and says so in a warning.

| Mode | Flag | What it does |
|---|---|---|
| Dedicated server | `--server` | Generates the galaxy, listens with ENet, waits for orders. No window. |
| Network client | `--client` | Dials a server and plays the game it sends. |
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
| `--slots=<int>` | `2` | 1–8, clamped. Empire slots the server admits. Seats are capacity, not a quota: the ready gate counts players who joined. |
| `--seed=<int>` | random | Integer, **or any string** — `aurora-7` is hashed to a reproducible seed. |
| `--systems=<int>` | `50` | 30–100, clamped. **Planets** in the single system. |
| `--map-size=<tier>` | `large` | How big the system is. See [Map size](#map-size-presets). |
| `--factions=<int>` | `2` | 1–8, clamped. Total empires. Raised to `--slots` if not given explicitly. |

A healthy startup prints:

```
[cc2] launch: DEDICATED_SERVER ip=0.0.0.0 port=7777 seed=42 planets=50 size=large factions=2 slots=3 (no warnings)
[cc2] session: DedicatedServer
[cc2] dedicated server ready: 0.0.0.0:7777, 3 slots, seed 42, 50 planets, stardate 1
```

To confirm it is listening:

```bash
ss -ulnp | grep 7777     # Linux
```

The server binds `0.0.0.0`, so it accepts connections from other machines. Pass
`--ip=` only if you need to see it echoed in the log; it does not change the bind.

### The map: one system, many planets

The game is played inside a **single star system**. `--systems=N` is the number of
*planets* orbiting that star (30–100, clamped), not the number of separate star
systems; the flag never changed, but what it counts did. There are no warp lanes —
movement is a straight line between two worlds.

- The **seed** governs the system: the star's class and name, every planet's type,
  position on its orbit ring, and reserves. The same seed always lays out the same
  system.
- The **starting planet** is drawn fresh for each game, from a stream separate from
  the layout. Two games on the same seed are the same system with different
  starting positions — nobody gets handed the same homeworld twice.
- Every empire gets a distinct, colonisable world, so an eight-player game is eight
  empires in one neighbourhood rather than eight private corners of a galaxy.

Fleet speed and sensor reach scale to whatever span `--map-size` selected, so a ship
crosses a `tiny` map in as many turns as it takes to cross an `extreme` one.

### Map size presets

`--map-size=<tier>` picks how much room the single system gets. Each tier is a multiple
of the **original 120-parsec galactic disk**:

| Tier | Scale | Half-extent | Feels like |
|---|---|---|---|
| `tiny` | 1x | 120 pc | The whole system on one screen; a knife fight. |
| `small` | 5x | 600 pc | A tight system. Expansion is a short walk. |
| `medium` | 15x | 1,800 pc | Room to manoeuvre without long hauls. |
| `large` | **30x** | 3,600 pc | **The default.** A proper 4X map. |
| `extreme` | 50x | 6,000 pc | The widest field. Long voyages, slow scouts. |

`large` is the default rather than `extreme` because at 50x a new player's first few
turns are spent watching a ship cross the screen, and the extra span buys nothing the
planet count does not already provide. Pass `extreme` when you want the full field.

```bash
godot --headless --path . --server --map-size=tiny  --slots=2
godot --headless --path . --server --map-size=extreme --slots=8
```

An unknown tier falls back to `large` and says so in the log rather than refusing to
start — a typo should not take a server down, but it should be visible, because a
wrong span produces a game that looks subtly wrong with nothing on screen to explain it.

The map draws a **white bounds frame** around the playable area and a **black** field:
planets sit inside the frame, and everything outside it is out of bounds. Scroll to zoom
in close enough to click a planet; scroll out to fit the whole system.

### `--slots` vs `--factions`

Easy to confuse, and they mean different things:

- `--slots=N` — **human** players this server admits (max 8).
- `--factions=N` — **total** factions in the galaxy, including AI.

`--slots=2 --factions=2` is two humans and no AI. `--slots=2 --factions=4` is two
humans plus two AI factions competing for the same worlds.

**`--slots` implies a faction floor.** An empire *is* a faction, so a slot with no
faction behind it seats a player in a game they cannot play. When you give `--slots`
without giving `--factions` explicitly, the server raises the faction count to match
the slot count (and sizes the map to fit), so `--slots=4` gives four empires and the
third and fourth players each get a real homeworld, colony and starting fleet.

Giving `--factions` explicitly overrides this: `--slots=8 --factions=2` is honoured
as written, and the server reports that it can only seat 2.

---

## Client flags

| flag | meaning |
|---|---|
| `--ip=<addr>` | server address. Defaults to loopback. |
| `--port=<int>` | server port. Defaults to 27015. |
| `--ready`, `--auto-ready` | declare yourself ready on arrival, without a lobby UI. |

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

## What the map shows

The galaxy map draws two different kinds of hidden space, and they are worth
keeping apart:

**Unexplored.** A system outside sensor range is an anonymous hollow marker.
You can see that a star is there; you cannot see its class, name, or who owns
it.

**Explored but not yours.** A system you *can* see but do not own shows no
owner ring unless you have a reason to know who holds it:

- it is **your** system, or
- you have a **fleet parked in it**.

A fleet merely *sailing toward* a system does not reveal its owner. It reveals
the origin now and the destination when it arrives — which is what a real
player would know. Without this rule every opponent's territory would be
outlined across the whole map, giving away deployments and border strength at a
glance, which is most of what scouting exists to withhold.

An unowned system always shows no owner: there is nothing to reveal, and
drawing it neutral is what makes empty space read as empty rather than as
redacted.

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

## The lobby

A multiplayer game does not begin the moment a client connects. It begins when the
server has enough players, and the rules for that live in one place
(`src/net/session_lobby.gd`).

### Who gets which empire

Each connecting peer is handed the lowest free slot. A slot is a faction id, so
`--slots` cannot exceed the factions that exist — asking for more warns and
seats only what it can:

```
WARNING: [cc2] 4 slots requested but only 2 factions exist; seating 2
```

A **full** lobby refuses further peers rather than overlapping slots. Two players
sharing one faction id would file orders into each other's treasury, and the
result would look like a desync rather than the double-booking it is.

### Readying up

The match starts when every slot the lobby was sized for is connected and ready.
Readiness is per-player and retractable: a second press of **READY** takes the
flag back, and the match waits again if it had not started yet.

| | GUI client | headless client |
|---|---|---|
| declare ready | press **READY** in the top bar | `--ready` (or `--auto-ready`) |
| take it back | press it again | — |

The button reads **`Ready 1/2`** and colours itself to match: green while you
still need to press, red once you have. The count is the server's, not a local
guess, so both players see the same number at the same instant — a lobby where
one window says 1/2 and the other says 2/2 just looks broken.

`--ready` exists because a headless client has no button to press. Without it,
`--server --slots=2` plus one headless client is a lobby that waits forever —
correctly, because a second empire was advertised and nobody claimed it.

Once the gate opens, the server announces the match to everyone:

```
[cc2] match started
```

### Losing a player

If *another* player closes their window, nothing happens to yours. The session
is still live: you keep your galaxy, your turn, and your window, and your event
log records the departure. Only losing the *server* ends a client session.

If a client disconnects from the server's point of view, its empire is
**held**, not deleted:

- The empire stops holding the turn open immediately. The resolver can only wait
  for someone who can answer, so a departed player must not be able to stall the
  match. **This is the important part** — a drop never wedges the turn loop.
- The slot stays claimed for 30 seconds, so a player who reconnects gets *their
  own* empire back rather than being handed a stranger's.
- If they do not return, the empire passes to the AI. Its colonies are still on
  the map; it simply stops being a human turn.
- An AI empire never satisfies the *start* gate. A match cannot begin with a
  human-less seat pretending someone pressed ready.

A server with `--slots=1` is the degenerate case: nobody can drop, because there
is nobody to drop on your behalf.

---

## What a client actually does now

`--client` dials the server and plays the game the server sends:

1. `NetworkManager.join_game(ip, port)` creates the ENet client and installs its
   multiplayer branch.
2. `connected_to_server` / `connection_failed` / `server_disconnected` are wired
   to the session. A failure prints the reason and exits non-zero.
3. The client **waits**. It does not create a galaxy, a controller, or a window
   yet.
4. The server seats the peer, picks an empire, and sends an `rpc_welcome`
   carrying the empire id, the full state, and its hash.
5. The client verifies the hash, and only then instantiates the GUI on *that*
   galaxy and *that* empire.

Step 4 is why a client never appears to "load a random galaxy": generating one
locally would produce a different universe from the authority, which is the exact
failure an authoritative server exists to prevent, and it would fail silently.

### Diagnostics for the client path

If a client misbehaves, these are the failure modes already characterised
during Phase 6:

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
~/.local/godot/godot --headless --path . --server --port=7777 --slots=1 --seed=42
```

`--slots=1` because the remote side is a single headless client: advertising two
empires would leave the match waiting for a player that is not coming.

Open `7777/udp` in the firewall. On the client machine:

```bash
~/.local/godot/godot --headless --path . --client --ip=<server-ip> --port=7777 --ready
```

Remember `--port` on both sides, and `--ready`: this is a headless client, so
nothing presses the lobby button for it and the server would otherwise wait for
a second player forever. A client takes no `--seed`; it plays the server's
galaxy whatever seed that was.

---

## Checklist for a manual session

1. Server up, listening line printed, port visible in `ss -ulnp`.
2. Clients launched with an explicit `--port` matching the server.
3. Server logs a join per client: `peer <id> joined as empire <slot>`.
4. Both windows press **READY**; the server prints `match started`. Until this
   happens turn 1 does not exist.
5. Each client prints `joined as empire <n>`, and **no two clients share an empire**.
6. Press **END TURN** in one window: it shows `Awaiting other players...` and the
   stardate does *not* move yet.
7. Press **END TURN** in the other window. Both windows advance together and the
   server logs `turn 1 resolved, hash <n>`.
8. Close a window: the server eventually logs
   `peer <id> left (empire <n> held for 30s)` and the remaining player's next turn
   is no longer held up by the departed empire. **Expect a delay** — ENet only
   concludes a peer is gone when its own timeout expires, so a hard kill takes
   around half a minute to notice. That lag is the transport's, and it is exactly
   why the grace period is 30 seconds: it has to outlast the disconnect itself.
9. Wait out the grace period and the server logs
   `[cc2] empire <n> passed to the AI (player did not return)`.

Two different things wait, and it is worth keeping them apart:

- **Starting** waits for every *configured* slot: `--slots=2` needs two clients
  connected and ready before turn 1 exists at all.
- **Each turn** then waits only for *connected* players. A client that drops
  stops holding the turn open, so its absence never wedges the resolver.

So `--slots=2` with one client is a lobby that waits (correct — a second empire
was advertised and nobody claimed it), while `--slots=2` with two clients where
one disconnects mid-game is a game that keeps running. If you want one player
against one server, launch it with `--slots=1`.

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
| `--ready`, `--auto-ready` | — | client |
| `--seed=<int\|str>` | any | both |
| `--systems=<int>` | 30–100 | server, local |
| `--factions=<int>` | 1–8 | server, local |
| `--headless` | — | all |
| `--log-turns` | — | all |
| `--verbose` | — | all (Godot built-in) |