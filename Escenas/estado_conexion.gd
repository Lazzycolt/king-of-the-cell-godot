extends Label
## Muestra el estado de la conexión: sala, si sos host o cliente, cuántos hay conectados y el ping.
## El ping lo medimos nosotros con dos RPC (ida y vuelta), así funciona igual con Steam o con ENet.

## Cada cuántos segundos se actualiza el texto y se mide el ping.
@export_range(0.5, 5.0, 0.5, "suffix:s") var intervalo := 1.0
## El nodo Red (de ahí sale el código de la sala).
@export var red: Node

var _espera := 0.0
var _ping_ms := {}   # { id_peer: milisegundos }


func _process(delta: float) -> void:
	_espera -= delta
	if _espera > 0.0:
		return
	_espera = intervalo
	if _conectado():
		_medir_ping()
	else:
		_ping_ms.clear()
	text = _armar_texto()


func _conectado() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and not peer is OfflineMultiplayerPeer \
			and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _armar_texto() -> String:
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return "Sin conexión"
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		return "Conectando..."
	var texto := ""
	if red and red.codigo_sala != "":
		texto += "Sala %s · " % red.codigo_sala
	if multiplayer.is_server():
		var invitados := multiplayer.get_peers()
		if invitados.is_empty():
			return texto + "HOST · esperando jugadores..."
		texto += "HOST · %d invitado(s)" % invitados.size()
		for id in invitados:
			texto += "\nping invitado: %s" % _texto_ping(id)
		return texto
	return texto + "CLIENTE · ping %s" % _texto_ping(1)


func _texto_ping(id: int) -> String:
	return "%d ms" % _ping_ms[id] if _ping_ms.has(id) else "..."


# ---------- PING ----------
# Mandamos la hora de NUESTRO reloj; el otro la devuelve tal cual; al volver,
# la resta con la hora actual da el tiempo de ida y vuelta (no importa que los relojes difieran).

func _medir_ping() -> void:
	var ahora := Time.get_ticks_msec()
	if multiplayer.is_server():
		for id in multiplayer.get_peers():
			_ping.rpc_id(id, ahora)
	else:
		_ping.rpc_id(1, ahora)


@rpc("any_peer", "unreliable")
func _ping(hora_envio: int) -> void:
	_pong.rpc_id(multiplayer.get_remote_sender_id(), hora_envio)


@rpc("any_peer", "unreliable")
func _pong(hora_envio: int) -> void:
	_ping_ms[multiplayer.get_remote_sender_id()] = Time.get_ticks_msec() - hora_envio
