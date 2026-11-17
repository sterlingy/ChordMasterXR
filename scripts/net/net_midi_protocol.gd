class_name NetMidiProtocol
extends RefCounted
## Wire format for the Wi-Fi MIDI relay (UDP, local network only).
##
## Every packet starts with the 4-byte magic "CMX1" and a type byte:
##   1 MIDI    seq:u16  status:u8 d1:u8 d2:u8   (one channel message)
##   2 HELLO   name:utf8                         (receiver announces itself)
##   3 PING    name:utf8                         (sender keep-alive)
##   4 DISCOVER name:utf8                        (sender asks "any receivers?")

const MAGIC := "CMX1"
const DATA_PORT := 47810        # receivers listen here for MIDI/PING
const DISCOVERY_PORT := 47811   # senders listen here for HELLO broadcasts

enum Type { MIDI = 1, HELLO = 2, PING = 3, DISCOVER = 4 }


static func encode_midi(seq: int, status: int, d1: int, d2: int) -> PackedByteArray:
	var b := MAGIC.to_ascii_buffer()
	b.append(Type.MIDI)
	b.append((seq >> 8) & 0xFF)
	b.append(seq & 0xFF)
	b.append(status & 0xFF)
	b.append(d1 & 0x7F)
	b.append(d2 & 0x7F)
	return b


static func encode_text(type: int, text: String) -> PackedByteArray:
	var b := MAGIC.to_ascii_buffer()
	b.append(type)
	b.append_array(text.left(64).to_utf8_buffer())
	return b


## Returns {} for anything that isn't a valid packet, else
## {type, seq?, status?, d1?, d2?, text?}.
static func decode(p: PackedByteArray) -> Dictionary:
	if p.size() < 5 or p.slice(0, 4).get_string_from_ascii() != MAGIC:
		return {}
	var type := int(p[4])
	match type:
		Type.MIDI:
			if p.size() < 10:
				return {}
			var status := int(p[7])
			if status < 0x80 or status >= 0xF0:
				return {}
			return {"type": type, "seq": (int(p[5]) << 8) | int(p[6]), "status": status, "d1": int(p[8]), "d2": int(p[9])}
		Type.HELLO, Type.PING, Type.DISCOVER:
			return {"type": type, "text": p.slice(5).get_string_from_utf8()}
	return {}


## True if `seq` is newer than `last` (16-bit wraparound).
static func is_newer(seq: int, last: int) -> bool:
	if last < 0:
		return true
	var diff := (seq - last) & 0xFFFF
	return diff != 0 and diff < 0x8000
