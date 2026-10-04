extends SceneTree
## Headless verification for Phase 1: the transport abstraction and loopback binding.
##
##   godot --headless --path . -s res://tests/test_transport.gd

const LoopbackTransportScript := preload("res://src/net/loopback_transport.gd")

var _t: TestSupport = null


## Minimal stand-in for the authoritative resolver: records what reaches `receive_order`.
class ResolverStub extends Node:
	var received: Array[Dictionary] = []

	func receive_order(order: Dictionary) -> void:
		received.append(order)


## A Node with no `receive_order()` ingress point, to exercise the mis-binding guard.
class UselessStub extends Node:
	pass


func _initialize() -> void:
	_t = TestSupport.new()

	_test_abstract_contract()
	_test_loopback_routing()
	_test_missing_resolver_is_rejected()
	_test_misbound_resolver_is_rejected()
	_test_loopback_lifecycle()

	var code := _t.finish("test_transport")
	print("---test_transport-exit=%d---" % code)
	quit(code)


func _test_abstract_contract() -> void:
	_t.begin("abstract transport contract")
	var base := PeerTransport.new()
	_t.eq(base.transport_name(), "abstract", "base reports itself as abstract")
	_t.ok(not base.is_authoritative(), "base is not authoritative")
	base.poll()
	_t.ok(true, "base poll is a safe no-op")
	base.close()
	_t.ok(true, "base close is idempotent and does not crash")

	_t.ok(base.open("127.0.0.1", 1).length() > 0, "abstract open() reports a failure string")
	_t.ok(not base.submit_order({"type": 0}), "abstract submit_order() reports failure")


func _test_loopback_routing() -> void:
	_t.begin("loopback order delivery")
	var stub := ResolverStub.new()
	var loop := LoopbackTransportScript.new() as LoopbackTransport
	loop.resolver = stub

	_t.eq(loop.open(CC2CLI.DEFAULT_LOOPBACK, 27015), "", "open() succeeds once a resolver is bound")
	_t.eq(loop.transport_name(), "loopback", "transport identifies as loopback")
	_t.ok(loop.is_authoritative(), "loopback hosts the authority")

	_t.ok(loop.submit_order({"type": 1, "faction": 0, "payload": {"x": 1}}), "order accepted")
	_t.ok(loop.submit_order({"type": 4, "faction": 1, "payload": {}}), "second order accepted")
	_t.eq(stub.received.size(), 2, "orders arrive at the resolver")
	_t.eq(stub.received[0]["type"], 1, "order contents preserved in transit")
	_t.eq(stub.received[1]["faction"], 1, "second order preserved in transit")

	loop.poll()
	_t.ok(true, "poll() on a live loopback is a no-op")
	loop.close()


func _test_missing_resolver_is_rejected() -> void:
	_t.begin("missing resolver is rejected")
	var bare := LoopbackTransportScript.new() as LoopbackTransport
	var err := bare.open(CC2CLI.DEFAULT_LOOPBACK, 27015)
	_t.ok(err.length() > 0, "open() without a resolver returns an error string")
	_t.ok(err.contains("resolver"), "error message names the missing resolver")
	_t.expect_guard("submit_order without a resolver is rejected", func() -> Variant:
		return bare.submit_order({"type": 0})
	)


func _test_misbound_resolver_is_rejected() -> void:
	_t.begin("misbound resolver is rejected")
	var loop := LoopbackTransportScript.new() as LoopbackTransport
	loop.resolver = UselessStub.new()
	_t.expect_guard("submit_order to a resolver with no ingress is rejected", func() -> Variant:
		return loop.submit_order({"type": 0})
	)
	loop.close()


func _test_loopback_lifecycle() -> void:
	_t.begin("loopback lifecycle")
	var loop := LoopbackTransportScript.new() as LoopbackTransport
	var stub := ResolverStub.new()
	loop.resolver = stub

	loop.poll()
	_t.ok(true, "poll() with a resolver does not raise")

	loop.close()
	_t.eq(loop.resolver, null, "close() detaches the resolver")
	loop.close()
	_t.ok(true, "close() is idempotent")

	# After close the transport must reject rather than silently swallow the order.
	_t.expect_guard("submitting after close is rejected, not dropped", func() -> Variant:
		return loop.submit_order({"type": 0})
	)
	_t.eq(stub.received.size(), 0, "the rejected order never reached the resolver")
	stub.free()