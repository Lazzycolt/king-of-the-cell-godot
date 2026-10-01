extends Label
## Muestra el estado de la conexión: si sos host o cliente, cuántos hay conectados y el ping.

## Cada cuántos segundos se actualiza el texto.
@export_range(0.1, 2.0, 0.1, "suffix:s") var intervalo := 0.5

var _espera := 0.0


func _process(delta: float) -> void:
	_espera -= delta
	if _espera > 0.0:
		return
	_espera = intervalo
	text = _armar_texto()


func _armar_texto() -> String:
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer == null:
		return "Sin conexión"
	match peer.get_connection_status():
		MultiplayerPeer.CONNECTION_CONNECTING:
			return "Conectando..."
		MultiplayerPeer.CONNECTION_DISCONNECTED:
			return "Desconectado"

	if multiplayer.is_server():
		var invitados := multiplayer.get_peers()
		if invitados.is_empty():
			return "HOST · esperando jugadores..."
		var texto := "HOST · %d invitado(s)" % invitados.size()
		for id in invitados:
			texto += "\nping invitado: %d ms" % _ping(peer, id)
		return texto
	return "CLIENTE · ping %d ms" % _ping(peer, 1)


# Tiempo de ida y vuelta de un mensaje hasta ese peer (lo mide ENet solo).
func _ping(peer: ENetMultiplayerPeer, id: int) -> int:
	var conexion := peer.get_peer(id)
	if conexion == null:
		return -1
	return int(conexion.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
