extends PeerTransport
class_name LoopbackTransport
## Single-player transport: the authoritative engine runs in the same process.
##
## This is deliberately *not* a shortcut around the turn engine. Orders go through the same
## queue, the same validation and the same sequential resolution as a networked game; the
## only difference is that "the network" is a function call.

## Reference to the authoritative resolver node (typed as Node so this file does not
## hard-depend on the resolver's script and can be constructed in isolation by tests).
var resolver: Node = null


func transport_name() -> String:
	return "loopback"


func is_authoritative() -> bool:
	return true


func open(_ip: String, _port: int) -> String:
	if resolver == null:
		return "loopback transport has no resolver bound"
	return ""


## Deliver `order` to the bound resolver. Returns false when there is no resolver, so
## callers (and tests) can detect a dropped order rather than silently losing it.
func submit_order(order: Dictionary) -> bool:
	if resolver == null:
		push_error("LoopbackTransport.submit_order() with no resolver bound")
		return false
	# Deliver through the resolver's public ingress point; tests may bind a stub.
	if not resolver.has_method("receive_order"):
		push_error("LoopbackTransport: resolver has no receive_order() ingress point")
		return false
	resolver.call("receive_order", order)
	return true


func close() -> void:
	resolver = null


func poll() -> void:
	# Nothing to pump: delivery is synchronous.
	pass