class_name NetMidiLink
extends Node
## Wi-Fi MIDI relay between Chord Master XR instances on the same network.
##
## Sender (usually the laptop with the keyboards): forwards every MIDI
## channel message to the receivers it knows about, or a typed-in IP.
##
## Receiver (usually the headset): listens on DATA_PORT and feeds incoming
## messages into the Midi autoload exactly like local MIDI.
##
## Discovery is firewall-friendly: the sender broadcasts DISCOVER from its
## outgoing socket once a second; receivers answer HELLO straight back to
## that socket. Windows Firewall lets replies to our own broadcasts in, so
## the laptop never needs an inbound firewall rule or a typed IP.
##
## Settings: net_send, net_receive, net_target ("" = auto-discover).

signal status_changed(text: String)

const P = preload("res://scripts/net/net_midi_protocol.gd")
const HELLO_INTERVAL := 1.0
const PING_INTERVAL := 1.0
const PEER_TIMEOUT := 4.0

var sending := false
var receiving := false
var target := ""                     # explicit receiver IP, or "" for auto

var receivers := {}                  # ip -> {name, last_seen}
var senders := {}                    # ip -> {name, last_seen, last_seq}
var packets_sent := 0
var packets_received := 0

## Called with (channel, message_type, d1, d2) for each received message.
var on_message: Callable

var _rx: PacketPeerUDP               # receiver: DATA_PORT
var _tx: PacketPeerUDP               # sender: outgoing data + discovery replies
var _seq := 0
var _hello_t := 0.0
var _ping_t := 0.0
var _status_t := 0.0
var _last_status := ""
var data_port := P.DATA_PORT
var discovery_port := P.DISCOVERY_PORT
## Where DISCOVER goes ([] = every local subnet's broadcast address).
var discover_addresses: PackedStringArray = []
## Accept our own machine as a receiver (only for tests).
var allow_self := false
var _discover_t := 0.0


func _ready() -> void:
	_tx = PacketPeerUDP.new()
	_tx.set_broadcast_enabled(true)
	_tx.bind(0)


func _exit_tree() -> void:
	set_receiving(false)
	set_sending(false)
	if _tx:
		_tx.close()


func device_name() -> String:
	var n := OS.get_model_name()
	if n == "" or n == "GenericDevice":
		n = OS.get_name()
	return n


## Local IPv4 addresses (shown in Settings so the user can type them in).
static func local_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return out


func set_receiving(on: bool) -> void:
	if on == receiving:
		return
	receiving = on
	if on:
		_rx = PacketPeerUDP.new()
		var err := _rx.bind(data_port)
		if err != OK:
			_rx = null
			receiving = false
			_set_status("Wi-Fi MIDI: couldn't listen on port %d (error %d)" % [data_port, err])
			return
	elif _rx:
		_rx.close()
		_rx = null
		senders.clear()
	_update_status()


func set_sending(on: bool) -> void:
	if on == sending:
		return
	sending = on
	_discover_t = 999.0   # discover right away
	if not on:
		receivers.clear()
	_update_status()


## Broadcast addresses to search: 255.255.255.255 plus each local subnet's
## x.y.z.255 (Windows sends the global broadcast out of one adapter only,
## e.g. a VPN instead of Wi-Fi).
func _broadcast_addresses() -> PackedStringArray:
	if not discover_addresses.is_empty():
		return discover_addresses
	var out := PackedStringArray(["255.255.255.255"])
	for a in local_addresses():
		var parts := a.split(".")
		out.append("%s.%s.%s.255" % [parts[0], parts[1], parts[2]])
	return out


## Forward one raw MIDI channel message (status byte includes channel).
func send_midi(status: int, d1: int, d2: int) -> void:
	if not sending:
		return
	var targets := _target_ips()
	if targets.is_empty():
		return
	_seq = (_seq + 1) & 0xFFFF
	var pkt := P.encode_midi(_seq, status, d1, d2)
	for ip in targets:
		_tx.set_dest_address(ip, data_port)
		_tx.put_packet(pkt)
		packets_sent += 1


func _target_ips() -> PackedStringArray:
	if target != "":
		return PackedStringArray([target])
	return PackedStringArray(receivers.keys())


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if receiving and _rx:
		while _rx.get_available_packet_count() > 0:
			var pkt := _rx.get_packet()
			var ip := _rx.get_packet_ip()
			var port := _rx.get_packet_port()
			var d := P.decode(pkt)
			if not d.is_empty() and d["type"] == P.Type.DISCOVER:
				# Answer straight back to the asking socket.
				_rx.set_dest_address(ip, port)
				_rx.put_packet(P.encode_text(P.Type.HELLO, device_name()))
			else:
				_on_rx(d, ip, now)
	if sending:
		# Replies to our DISCOVER broadcasts arrive on the outgoing socket.
		while _tx.get_available_packet_count() > 0:
			var pkt := _tx.get_packet()
			var ip := _tx.get_packet_ip()
			var d := P.decode(pkt)
			if not d.is_empty() and d["type"] == P.Type.HELLO and (allow_self or not (ip in local_addresses())):
				receivers[ip] = {"name": d["text"], "last_seen": now}
		_discover_t += delta
		if target == "" and _discover_t >= HELLO_INTERVAL:
			_discover_t = 0.0
			var ask := P.encode_text(P.Type.DISCOVER, device_name())
			for addr in _broadcast_addresses():
				_tx.set_dest_address(addr, data_port)
				_tx.put_packet(ask)
		for ip in receivers.keys():
			if now - receivers[ip]["last_seen"] > PEER_TIMEOUT:
				receivers.erase(ip)
		_ping_t += delta
		if _ping_t >= PING_INTERVAL:
			_ping_t = 0.0
			for ip in _target_ips():
				_tx.set_dest_address(ip, data_port)
				_tx.put_packet(P.encode_text(P.Type.PING, device_name()))
	for ip in senders.keys():
		if now - senders[ip]["last_seen"] > PEER_TIMEOUT:
			senders.erase(ip)
	_status_t += delta
	if _status_t >= 0.5:
		_status_t = 0.0
		_update_status()


func _on_rx(d: Dictionary, ip: String, now: float) -> void:
	if d.is_empty():
		return
	var s: Dictionary = senders.get(ip, {"name": ip, "last_seen": now, "last_seq": -1})
	s["last_seen"] = now
	match int(d["type"]):
		P.Type.PING:
			s["name"] = d["text"]
		P.Type.MIDI:
			# Drop late duplicates/out-of-order packets (UDP may reorder).
			if not P.is_newer(d["seq"], s["last_seq"]):
				senders[ip] = s
				return
			s["last_seq"] = d["seq"]
			packets_received += 1
			if on_message.is_valid():
				var status: int = d["status"]
				on_message.call(status & 0x0F, status >> 4, d["d1"], d["d2"])
	senders[ip] = s


func _update_status() -> void:
	var parts := []
	if receiving:
		if senders.is_empty():
			parts.append("Receiving: waiting for a sender")
		else:
			var names := []
			for ip in senders:
				names.append("%s (%s)" % [senders[ip]["name"], ip])
			parts.append("Receiving from " + ", ".join(names))
	if sending:
		var t := _target_ips()
		if t.is_empty():
			parts.append("Sending: looking for a headset… (run Chord Master XR on it with 'Receive' on; same Wi-Fi network)")
		else:
			var names := []
			for ip in t:
				var n: String = receivers[ip]["name"] if receivers.has(ip) else ip
				names.append("%s (%s)" % [n, ip] if n != ip else ip)
			parts.append("Sending to " + ", ".join(names))
	var text := "  ·  ".join(parts) if not parts.is_empty() else "Wi-Fi MIDI is off"
	_set_status(text)


func _set_status(text: String) -> void:
	if text != _last_status:
		_last_status = text
		status_changed.emit(text)


func status_text() -> String:
	return _last_status
