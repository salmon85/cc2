extends RefCounted
class_name PeerTransport
## Abstract transport between a client and the authoritative turn engine.
##
## Two implementations exist conceptually:
##   * `LoopbackTransport` — single player; the "server" is an in-process node.
##   * `EnetTransport`     — networked play over ENet (Phase 6).
##
## Keeping the surface this small means the resolver, orders and state serialisation never
## branch on transport, which is what guarantees single player cannot diverge from online.

## Emitted when a full state snapshot arrives (sent to clients, echoed on loopback).
signal state_received(snapshot: Dictionary)

## Emitted when the peer stops being reachable.
signal disconnected(reason: String)


## Human-readable transport name for the status bar / log.
func transport_name() -> String:
	return "abstract"


## True when this transport hosts the authoritative simulation locally.
func is_authoritative() -> bool:
	return false


## Begin listening (server/loopback) or dialing (client). Returns an error string, or ""
## on success.
func open(_ip: String, _port: int) -> String:
	push_error("PeerTransport.open() is abstract")
	return "abstract transport not implemented"


## Send an order dictionary to the authority. Returns false if the order could not be
## delivered, so callers never silently lose an order.
func submit_order(_order: Dictionary) -> bool:
	push_error("PeerTransport.submit_order() is abstract")
	return false


## Close down cleanly. Must be idempotent.
func close() -> void:
	pass


## Poll the transport once per frame. Callbacks may fire synchronously.
func poll() -> void:
	pass