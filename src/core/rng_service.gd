extends Node
## Deterministic random number source for the whole simulation.
##
## Registered as the `RNGService` autoload. The turn resolver is authoritative and must
## produce identical results for every client, so *all* simulation randomness flows through
## a single explicit stream derived from the galaxy seed. Cosmetic/UI randomness uses
## `cosmetic_rng()` instead, which is never read by the resolver.

const COSMETIC_SEED_OFFSET := 0x5EED0

## The authoritative stream. Reseeded at the start of every galaxy.
var _sim: RandomNumberGenerator = RandomNumberGenerator.new()

## Separate stream for UI-only jitter, so cosmetics cannot desync the simulation.
var _cosmetic: RandomNumberGenerator = RandomNumberGenerator.new()

## Seed the authoritative stream. Same seed ⇒ same galaxy, forever.
func seed_stream(seed_value: int) -> void:
	_sim.seed = seed_value
	_sim.state = seed_value
	_cosmetic.seed = seed_value + COSMETIC_SEED_OFFSET
	_cosmetic.state = seed_value + COSMETIC_SEED_OFFSET


## Reseed from a human-readable string so seeds can be typed ("aurora-7").
func seed_stream_from_string(text: String) -> void:
	seed_stream(abs(hash(text)))


## Currently active simulation seed.
func current_seed() -> int:
	return _sim.seed


## Snapshot/restore so a replay can rewind the stream between turns.
func capture_state() -> int:
	return _sim.state


func restore_state(state_value: int) -> void:
	_sim.state = state_value


## Uniform float in [0.0, 1.0) from the authoritative stream.
func randf() -> float:
	return _sim.randf()


## Uniform integer in [from, to] inclusive.
func randi_range(from: int, to: int) -> int:
	return _sim.randi_range(from, to)


## True with the given probability.
func chance(probability: float) -> bool:
	return _sim.randf() < probability


## Pick a uniformly random element. Returns null for an empty array.
func pick(array: Array) -> Variant:
	if array.is_empty():
		return null
	return array[_sim.randi_range(0, array.size() - 1)]


## Pick a key from a dictionary of int weights.
func pick_weighted(weights: Dictionary) -> Variant:
	var total := 0.0
	for key: Variant in weights:
		total += maxf(0.0, float(weights[key]))
	if total <= 0.0:
		return null
	var roll := _sim.randf() * total
	for key: Variant in weights:
		roll -= maxf(0.0, float(weights[key]))
		if roll <= 0.0:
			return key
	return weights.keys().back()


## Fisher-Yates using the authoritative stream. Mutates and returns `array`.
func shuffle(array: Array) -> Array:
	for i in range(array.size() - 1, 0, -1):
		var j := _sim.randi_range(0, i)
		var tmp: Variant = array[i]
		array[i] = array[j]
		array[j] = tmp
	return array


## Approximately normal via sum-of-uniforms (Bates), clamped to +-1.5 sigma.
## Cheaper and more deterministic across engine versions than Box-Muller.
func randf_normal() -> float:
	var total := 0.0
	for _i in 4:
		total += _sim.randf()
	return (total * 0.5) - 1.0


## UI-only stream, never read by the turn resolver.
func cosmetic_rng() -> RandomNumberGenerator:
	return _cosmetic