# Project Specification: Colonial Conquest II (Modernized Godot Port)

A faithful modernization and expansion of Christian Mumenthaler's classic 1994 Amiga PD strategy game *Colonial Conquest II*. 

The game is a turn-based 4X space exploration, colony simulation, and fleet warfare strategy title featuring single-player (vs AI) and turn-based network multiplayer via an authoritative headless server architecture.

---

## 1. Technical Stack & Execution Model

* **Engine:** Godot 4 (GDScript, strict static typing enabled).
* **Target Platforms:** Linux / Windows desktop clients; Linux headless dedicated server.
* **Architecture:** Deterministic, turn-based authoritative game state.
* **Modes of Operation:**
  * **Dedicated Server:** Launches with `--headless --server`. Maintains the authoritative galaxy state, handles AI turns, validates player orders, and resolves end-of-turn calculations.
  * **Client GUI:** Connects via `--client --ip=<addr> --port=<port>` or local setup menu.
  * **Single Player:** Client spins up an internal local server on `127.0.0.1`—the exact same turn-resolution code runs locally without offline divergence.

---

## 2. Core Gameplay Loop & Mechanics

The game operates on a discrete turn-based cycle (**Stardate / Turns**).

### A. Turn Resolution Cycle (Server Authoritative)
1. **Order Phase:** Players and AI submit queued orders simultaneously (production queues, tax/research slider adjustments, fleet move vectors, colonization flags).
2. **Turn Process Trigger:** Server receives "End Turn" confirmations from all active factions (or a turn timer expires).
3. **Execution Phase (Sequential Calculation):**
   * **Movement:** Fleets travel across sector coordinates based on engine/drive tech. Interceptions/encounters trigger combat.
   * **Combat Resolution:** Space battles calculate weapon rolls, shield absorption, and hull damage; planetary invasions resolve troop landings vs ground defenses.
   * **Colony Simulation:** Population growth, food consumption/starvation, factory production output, mining yield, and tax revenue.
   * **Research Progress:** Tech points aggregate into selected research fields; new tiers unlock ship hulls/components.
   * **Fog of War / Scanner Updates:** Sensor ranges compute visible systems and fleet vectors.
4. **State Broadcast:** Server serializes updated galaxy state and dispatches it via RPC to all connected clients.

---

## 3. Galaxy & Planetary Simulation

### Galaxy Structure
* **Sector Grid / Star Map:** 2D coordinate space containing $N$ star systems (configurable 30 to 100 systems).
* **Star Systems:** Contain 1 to 6 planets/moons, an orbital space zone, and warp lane or freeform hyperdrive travel vectors.

### Planet Attributes
* **Class / Climate:** Terrestrial, Desert, Ice, Volcanic, Gas Giant (uncolonizable without advanced tech), Barren.
* **Habitability Index:** Percentage multiplier affecting max sustainable population and base growth rate.
* **Minerals / Resources:**
  * `Metals`: Used for construction and ship building.
  * `Rare Elements`: Required for advanced tech and high-tier shielding/weapons.
  * `Energy / Fuel`: Maintenance of planetary shields, fleets, and orbital stations.
* **Colony Metrics:**
  * `Population`: Tax base and workforce. Consumes food per turn.
  * `Farms / Agriculture`: Generates food. Shortages cause starvation, unrest, and population decline.
  * `Factories`: Converts minerals into production points (build queue for structures/ships).
  * `Mines`: Extracts planetary mineral reserves into global/local stockpiles.
  * `Defenses`: Planetary shields, surface missile batteries, ground garrisons.
  * `Morale / Loyalty`: Dictated by tax rate and food security; low morale triggers strikes or rebellion.

---

## 4. Research & Technology Tree

Budget allocation model (slider-based per turn from total imperial treasury):
* **Propulsion / Drives:** Increases fleet movement range (parsecs/turn) and hyperjump efficiency.
* **Energy & Shields:** Unlocks defensive planetary shields, ship deflector arrays, and beam weapon output.
* **Weapons & Ballistics:** Missiles, torpedoes, kinetic cannons, and planetary bombardment batteries.
* **Industrial & Biospheric:** Terraforming tools, hydroponics (farming efficiency), automated mining, and robotic factories.

---

## 5. Fleet Construction & Space Combat

### Ship Classes
1. **Scout / Probe:** High speed, lightweight, long scanner range, minimal hull.
2. **Colony Ship:** Sacrifices itself or drops a modular base kit to establish an outpost on unowned habitable planets.
3. **Transport / Freighter:** Moves raw minerals, food, or ground troops between colonies.
4. **Corvette / Frigate:** Light patrol and screening vessel.
5. **Cruiser:** Mainline fleet combatant.
6. **Battleship / Dreadnought:** Capital vessel with heavy armor, heavy batteries, and planetary bombardment capability.

### Combat System
* Turn-based tactical grid or deterministic abstract round resolution (like CC2):
  * Long-range missile volleys $\rightarrow$ Medium-range beam exchanges $\rightarrow$ Point-defense/torpedo interception $\rightarrow$ Dogfighting $\rightarrow$ Retreat check.
  * Planetary invasion: Orbital bombardment strips surface batteries; transports land ground divisions against garrison forces.

---

## 6. User Interface & Presentation

* **Aesthetic Direction:** Clean retro-futuristic sci-fi terminal. High-contrast typography, CRT/phosphor green or cool blue accents, functional 2D tactical maps, and clean statistical graphs.
* **Screens:**
  1. **Galaxy Map:** Sector view, fleet paths, territory influence lines, star color codes.
  2. **System / Planet View:** High-level orbital schematic displaying planet status, structures, sliders (tax, rations, industrial focus), and build queues.
  3. **Imperial Summary:** Macro budget (Treasury, Income, Expenses, Research sliders).
  4. **Fleet Management:** Ship builder, fleet composition, admiral assignment, and routing orders.
  5. **Turn Report / News Dispatch:** Summary log of battles, colonized worlds, finished research, and diplomatic incidents.

---

## 7. Data-Driven Architecture (Godot 4)

* Use plain-text `.tres` Resources for entity definitions:
  * `PlanetTypeData.tres`: Base habitability, sprite variants, default resource distribution.
  * `ShipHullData.tres`: Base cost, slots, weapon capacity, sprite, engine scale.
  * `TechNodeData.tres`: Cost, dependencies, stat modifiers unlocked.
  * `BuildingData.tres`: Construction cost, maintenance, production yield.
* Game state stored as an authoritative dictionary/resource graph on the server (`GalaxyState`), fully serializable to JSON/binary for game saves and network replication.