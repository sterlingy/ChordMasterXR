extends GutTest

const P = preload("res://scripts/net/net_midi_protocol.gd")


func test_encode_decode_midi() -> void:
	var pkt := P.encode_midi(513, 0x92, 60, 100)
	var d := P.decode(pkt)
	assert_eq(d["type"], P.Type.MIDI)
	assert_eq(d["seq"], 513)
	assert_eq(d["status"], 0x92)
	assert_eq(d["d1"], 60)
	assert_eq(d["d2"], 100)


func test_encode_decode_text() -> void:
	var d := P.decode(P.encode_text(P.Type.HELLO, "Galaxy XR"))
	assert_eq(d["type"], P.Type.HELLO)
	assert_eq(d["text"], "Galaxy XR")


func test_rejects_garbage() -> void:
	assert_eq(P.decode(PackedByteArray([1, 2, 3])), {})
	assert_eq(P.decode("XXXX".to_ascii_buffer() + PackedByteArray([1, 0, 1, 0x90, 60, 100])), {})
	# status byte must be a channel message
	var bad := "CMX1".to_ascii_buffer()
	bad.append_array(PackedByteArray([1, 0, 1, 0x40, 60, 100]))
	assert_eq(P.decode(bad), {})


func test_sequence_wraparound() -> void:
	assert_true(P.is_newer(1, -1))
	assert_true(P.is_newer(2, 1))
	assert_false(P.is_newer(1, 2))
	assert_false(P.is_newer(5, 5))
	assert_true(P.is_newer(0, 0xFFFF))
	assert_true(P.is_newer(3, 0xFFF0))


func test_discovery_finds_receiver() -> void:
	var rx := NetMidiLink.new()
	rx.data_port = 47920
	add_child_autofree(rx)
	rx.set_receiving(true)
	var tx := NetMidiLink.new()
	tx.data_port = 47920
	tx.discover_addresses = PackedStringArray(["127.0.0.1"])
	tx.allow_self = true
	add_child_autofree(tx)
	tx.set_sending(true)
	await wait_frames(15)
	assert_true(tx.receivers.has("127.0.0.1"), "receiver discovered via DISCOVER/HELLO: %s" % tx.receivers)
	var got := []
	rx.on_message = func(ch, type, d1, d2): got.append([ch, type, d1, d2])
	tx.send_midi(0x90, 64, 80)
	await wait_frames(10)
	assert_eq(got, [[0, MIDI_MESSAGE_NOTE_ON, 64, 80]])


func test_loopback_relay() -> void:
	var rx := NetMidiLink.new()
	rx.data_port = 47910
	rx.discovery_port = 47911
	var got := []
	rx.on_message = func(ch, type, d1, d2): got.append([ch, type, d1, d2])
	add_child_autofree(rx)
	rx.set_receiving(true)

	var tx := NetMidiLink.new()
	tx.data_port = 47910
	tx.discovery_port = 47912
	tx.target = "127.0.0.1"
	add_child_autofree(tx)
	tx.set_sending(true)

	tx.send_midi(0x90, 60, 100)   # note on ch1
	tx.send_midi(0x80, 60, 0)     # note off ch1
	tx.send_midi(0xB3, 64, 127)   # sustain on ch4
	await wait_frames(10)
	assert_eq(got.size(), 3)
	if got.size() == 3:
		assert_eq(got[0], [0, MIDI_MESSAGE_NOTE_ON, 60, 100])
		assert_eq(got[1], [0, MIDI_MESSAGE_NOTE_OFF, 60, 0])
		assert_eq(got[2], [3, MIDI_MESSAGE_CONTROL_CHANGE, 64, 127])
	assert_true(rx.senders.has("127.0.0.1"))
