extends RefCounted
class_name SessionLobby
## Slot assignment, ready state, and the match-start decision.
##
## ## What this owns, and why it is not on `TurnSyncServer`
##
## The lobby is the part of a session that exists *before* the game does. Slot
## bookkeeping, ready flags and the start decision all have to work while no galaxy is
## bound and no turn is resolving. Putting them on the turn-sync node would mean the
## first thing that happens at launch is instantiating a node whose entire job is the
## opposite phase, and it would make the rules directly unit-testable -- which matters,
## because these are the rules most likely to deadlock a real match if they are wrong.
##
## `TurnSyncServer` consults a lobby rather than duplicating it, so there is exactly one
## answer to "may this turn resolve" and "may the match start".

## Emitted when a peer takes a slot.
signal slot_taken(peer_id: int, slot: int)

## Emitted when a peer leaves a slot, however it left.
signal slot_vacated(slot: int, reason: String)

## Emitted when a peer marks itself ready (or un-ready).
signal ready_changed(peer_id: int, slot: int, is_ready: bool)

## Emitted once, when every configured slot is filled and ready.
signal match_start_requested()

## Emitted when a peer is told to wait rather than start.
signal match_start_deferred(reason: String)

## Why a slot changed hands.
const REASON_LEFT := "peer disconnected"
const REASON_EVICTED := "peer kicked"
const REASON_REFUSED := "connection refused"

## One participant, connected or not.
class Entry extends RefCounted:
	## Peer id while connected; 0 once vacated.
	var peer_id: int = 0
	## Empire this player holds.
	var slot: int = -1
	var is_ready: bool = false
	## True once this empire has been handed to the AI because its player did not
	## come back. Distinct from "nobody is connected": a rejoining human takes it back.
	var ai_managed: bool = false

	func is_occupied() -> bool:
		return peer_id != 0


## Peer id -> Entry.
var _entries: Dictionary = {}

## Slot id -> seconds of grace remaining before the AI takes that abandoned empire.
##
## Keyed by slot rather than by peer because an abandoned empire outlives the
## connection that left it: the clock must keep running with nobody connected.
var _pending_grace: Dictionary = {}

## Slot -> peer id of the player whose empire is being held for them. Lets a rejoin find
## the entry it must reclaim instead of creating a second one for the same empire.
var _held: Dictionary = {}

## How many human slots this session offers. `--slots`, so at least 1.
var total_slots: int = 2

## Whether the match has been started. Latches, so a late joiner cannot restart it.
var started: bool = false

## How long an abandoned empire waits for its player before the AI takes it.
##
## The grace period exists because a turn must not stall on someone whose connection
## dropped, and because a player who alt-tabbed away should not lose their empire to a
## reconnect taking longer than one turn resolution.
var grace_seconds: float = 30.0


func _init(p_total_slots: int = 2) -> void:
	total_slots = maxi(1, p_total_slots)


## Seat a peer in the lowest free slot, or return -1 when the lobby is full.
func join(peer_id: int) -> int:
	if peer_id == 0:
		return -1
	# An entry that is still *occupied* means this peer is already seated. An unoccupied
	# one is a held empire and is handled by the reclaim path below, so it must not be
	# rejected here -- that entry is precisely how a returning player finds their slot.
	var existing: Entry = _entries.get(peer_id)
	if existing != null and existing.is_occupied():
		return -1

	# A peer that already held an empire takes it back before anything else is
	# considered. ENet assigns a *different* peer id on every reconnect, so "the same
	# player" cannot be matched on identity -- the held slot is the only link available,
	# and reclaiming it is what stops a reconnecting player from being given a rival's
	# colonies.
	var mine := _held_slot_for(peer_id)
	if mine < 0:
		# Same-process reconnect (a test, or a lobby that re-seats a known peer): the
		# peer's own unoccupied entry still names the empire it had.
		var prior: Entry = _entries.get(peer_id)
		if prior != null and prior.slot >= 0 and not prior.is_occupied():
			mine = prior.slot
	if mine >= 0:
		_reclaim_slot(mine, peer_id)
		return mine

	if free_slot_count() <= 0:
		return -1
	var slot := _lowest_free_slot()
	if slot < 0:
		return -1
	var entry := Entry.new()
	entry.peer_id = peer_id
	entry.slot = slot
	_entries[peer_id] = entry
	slot_taken.emit(peer_id, slot)
	return slot


## Put a held empire back in its owner's hands and restart the player's participation.
func _reclaim_slot(slot: int, peer_id: int) -> void:
	var previous := int(_held.get(slot, 0))
	if previous != 0 and _entries.has(previous):
		# Drop the stale entry so the empire is not listed twice.
		_entries.erase(previous)
	_held.erase(slot)
	var entry: Entry = _entries.get(peer_id)
	if entry == null:
		entry = Entry.new()
		_entries[peer_id] = entry
	entry.peer_id = peer_id
	entry.slot = slot
	entry.is_ready = false
	entry.ai_managed = false
	cancel_grace(slot)
	slot_taken.emit(peer_id, slot)


## The slot being held for a peer, or -1.
##
## There is no identity link across an ENet reconnect, so this can only answer for a
## caller that already knows the peer id it is re-seating (tests, and a lobby driving
## its own roster).
func _held_slot_for(peer_id: int) -> int:
	var entry: Entry = _entries.get(peer_id)
	if entry != null and entry.slot >= 0 and not entry.is_occupied():
		return entry.slot
	return -1


## Remove a peer. Their slot is held open for `grace_seconds` rather than freed at once.
func leave(peer_id: int) -> int:
	var entry: Entry = _entries.get(peer_id)
	if entry == null:
		return -1
	var slot: int = entry.slot
	# The entry is *retained*, unoccupied, rather than erased. Erasing it would lose the
	# only record that slot 1 belongs to a player who is coming back: `join()` reads these
	# abandoned entries to hand the slot back, and the grace clock would have nothing to
	# tick against. An entry with peer_id 0 is a held empire, not a participant.
	entry.peer_id = 0
	entry.is_ready = false
	_entries[peer_id] = entry
	_held[slot] = peer_id
	begin_grace(slot)
	slot_vacated.emit(slot, REASON_LEFT)
	return slot


## Drop a peer without any grace period. Used when the session is being torn down.
func evict(peer_id: int) -> void:
	var entry: Entry = _entries.get(peer_id)
	if entry == null:
		return
	var slot: int = entry.slot
	_entries.erase(peer_id)
	if slot >= 0:
		slot_vacated.emit(slot, REASON_EVICTED)


## The slot held by a peer, or -1.
func slot_of(peer_id: int) -> int:
	var entry: Entry = _entries.get(peer_id)
	return entry.slot if entry != null else -1


## The peer holding a slot, or 0.
func peer_of(slot: int) -> int:
	for key: int in _entries:
		var entry: Entry = _entries[key]
		if entry.slot == slot:
			return entry.peer_id
	return 0


## Mark a peer ready. Returns false when the peer is not seated.
func set_ready(peer_id: int, is_ready: bool) -> bool:
	var entry: Entry = _entries.get(peer_id)
	if entry == null:
		return false
	if entry.is_ready == is_ready:
		return false
	entry.is_ready = is_ready
	ready_changed.emit(peer_id, entry.slot, is_ready)
	return true


## Whether a peer has marked itself ready.
func is_ready(peer_id: int) -> bool:
	var entry: Entry = _entries.get(peer_id)
	return entry != null and entry.is_ready


## How many connected peers have readied up.
##
## Counts only *occupied* slots: a player who dropped is not "ready", and neither is one
## who has not joined yet. An AI-managed empire never counts -- a match must not report
## itself ready on the strength of a seat nobody is playing.
func ready_count() -> int:
	var n := 0
	for slot: int in occupied_slots():
		var peer := peer_of(slot)
		if peer != 0 and is_ready(peer):
			n += 1
	return n


## Slots currently held by a connected peer, ascending.
func occupied_slots() -> PackedInt32Array:
	var out := PackedInt32Array()
	var seen := PackedInt32Array()
	for key: int in _entries:
		var entry: Entry = _entries[key]
		if entry.slot >= 0 and entry.is_occupied() and not seen.has(entry.slot):
			seen.append(entry.slot)
	seen.sort()
	for s: int in seen:
		out.append(s)
	return out


## How many slots still have no peer.
func free_slot_count() -> int:
	# A slot held for a returning player is not free: offering it would let a stranger
	# take the empire of someone who is one reconnect away.
	return maxi(0, total_slots - claimed_slots().size())


## Every slot with an owner, connected or held -- the slots a match is actually made of.
func claimed_slots() -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in total_slots:
		if _slot_has_entry(i):
			out.append(i)
	return out


func _slot_has_entry(slot: int) -> bool:
	for key: int in _entries:
		var entry: Entry = _entries[key]
		if entry.slot == slot:
			return true
	return false


## Every slot the match was configured with, whether filled or not.
func all_slots() -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in total_slots:
		out.append(i)
	return out


## Whether every configured slot holds a connected, ready peer.
##
## A slot held by nobody does *not* count as ready. That is the whole reason a lobby
## waits rather than starting on first connect: a match that begins while a second
## player is still typing their name would hand them a game already in progress.
func everyone_ready() -> bool:
	var occupied := occupied_slots()
	if occupied.size() < total_slots:
		return false
	for s: int in occupied:
		var peer := peer_of(s)
		if peer == 0 or not is_ready(peer):
			return false
	return true


## Begin the match if the lobby is full and ready. Idempotent.
##
## Returns true only on the transition into the started state, so a caller polling this
## every frame cannot broadcast two match starts.
func try_start() -> bool:
	if started:
		return false
	if not everyone_ready():
		match_start_deferred.emit(_deferral_reason())
		return false
	started = true
	match_start_requested.emit()
	return true


## The slots the server should hold the *turn* open for.
##
## Only slots with a connected player. An abandoned or AI-held empire must not stall the
## turn: the resolver can only wait for someone who can actually answer, and a player who
## has disconnected is never going to submit this turn.
func turn_slots() -> PackedInt32Array:
	return occupied_slots()


## Advance every grace period. Returns the slots whose grace expired this frame.
##
## A grace period belongs to a *slot*, not a connection: it starts when a peer leaves and
## runs whether or not anyone is still connected. Only an occupied entry can have a
## running grace period (a peer that is still here does not need one), so the scan is
## over live entries and the abandoned ones are tracked by `pending_grace` instead.
func tick(delta: float) -> PackedInt32Array:
	var expired := PackedInt32Array()
	for slot: int in _pending_grace.keys():
		var left: float = float(_pending_grace[slot]) - delta
		if left <= 0.0:
			_pending_grace.erase(slot)
			expired.append(slot)
		else:
			_pending_grace[slot] = left
	return expired


## Start the grace clock for an abandoned slot.
func begin_grace(slot: int) -> void:
	if slot < 0 or grace_seconds <= 0.0:
		return
	_pending_grace[slot] = grace_seconds


## Seconds left on a slot's grace period, or 0 when none is running.
func grace_left(slot: int) -> float:
	return float(_pending_grace.get(slot, 0.0))


## Cancel a grace period, because its player came back.
func cancel_grace(slot: int) -> void:
	_pending_grace.erase(slot)


## Hand a slot to the AI because its player did not return.
##
## The empire stays in the game -- its colonies are still on the map -- it simply stops
## holding up the turn loop. This is what keeps a dropped client from stalling the match.
func mark_ai_managed(slot: int) -> bool:
	for key: int in _entries:
		var entry: Entry = _entries[key]
		if entry.slot == slot:
			entry.ai_managed = true
			cancel_grace(slot)
			return true
	return false


## Whether an empire is currently run by the AI.
func is_ai_managed(slot: int) -> bool:
	for key: int in _entries:
		var entry: Entry = _entries[key]
		if entry.slot == slot:
			return entry.ai_managed
	return false


## Give a reconnecting peer their old empire back, if the AI has not taken it.
##
## Returns the slot reclaimed, or -1 when there was nothing to reclaim. Called after the
## grace period expires, and again on a normal rejoin.
func reclaim_for(peer_id: int) -> int:
	for key: int in _entries:
		var entry: Entry = _entries[key]
		if entry.is_occupied():
			continue
		if grace_left(entry.slot) > 0.0 or not entry.ai_managed:
			# Still within its grace period, or never abandoned: the slot is simply
			# waiting for whoever owned it, and must not be handed to a different peer.
			continue
		entry.peer_id = peer_id
		entry.ai_managed = false
		cancel_grace(entry.slot)
		_entries[peer_id] = entry
		slot_taken.emit(peer_id, entry.slot)
		return entry.slot
	return -1


## Forget every abandoned entry whose grace has fully expired. Server teardown only.
func clear() -> void:
	_entries.clear()
	_pending_grace.clear()
	_held.clear()
	started = false


func _lowest_free_slot() -> int:
	for candidate in total_slots:
		if peer_of(candidate) == 0 and not _slot_has_entry(candidate):
			return candidate
	return -1


## An abandoned slot still inside its grace period, if one exists.
func _reclaimable_slot() -> int:
	var held := PackedInt32Array()
	for key: int in _entries:
		var entry: Entry = _entries[key]
		if entry.slot >= 0 and not entry.is_occupied():
			held.append(entry.slot)
	held.sort()
	for s: int in held:
		if not is_ai_managed(s):
			return s
	return held[0] if not held.is_empty() else -1


func _deferral_reason() -> String:
	var occupied := occupied_slots()
	if occupied.size() < total_slots:
		return "waiting for %d more player(s)" % (total_slots - occupied.size())
	for s: int in occupied:
		var peer := peer_of(s)
		if peer == 0 or not is_ready(peer):
			return "waiting for player(s) to ready up"
	return ""