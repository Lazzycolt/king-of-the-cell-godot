extends Label
## Muestra el estado de la conexión con GD-Sync: código de sala, si sos host o cliente,
## cuántos jugadores hay y el ping con el otro jugador.

## Cada cuántos segundos se actualiza el texto.
@export_range(0.5, 5.0, 0.5, "suffix:s") var intervalo := 1.0
## Cada cuántos segundos se mide el ping (cada medición manda 10 mensajes chiquitos).
@export_range(1.0, 10.0, 0.5, "suffix:s") var intervalo_ping := 2.0

var _espera := 0.0
var _espera_ping := 0.0
var _ping_ms := -1
var _midiendo := false


func _process(delta: float) -> void:
	_espera -= delta
	_espera_ping -= delta
	if _espera_ping <= 0.0:
		_espera_ping = intervalo_ping
		_medir_ping()
	if _espera <= 0.0:
		_espera = intervalo
		text = _armar_texto()


func _armar_texto() -> String:
	if not GDSync.is_active():
		return "Sin conexión con GD-Sync"
	var sala := GDSync.lobby_get_name()
	if sala == "":
		return "Conectado a GD-Sync"
	var rol := "HOST" if GDSync.is_host() else "CLIENTE"
	var texto := "Sala %s · %s · %d jugador(es)" % [sala, rol, GDSync.lobby_get_player_count()]
	if _ping_ms >= 0:
		texto += "\nping: %d ms" % _ping_ms
	return texto


# Mide el ping con el otro jugador. get_client_ping tarda un rato en responder
# (manda varios mensajes y espera la vuelta), por eso se usa "await".
func _medir_ping() -> void:
	if _midiendo or not GDSync.is_active() or GDSync.lobby_get_name() == "":
		return
	var yo := GDSync.get_client_id()
	for id in GDSync.lobby_get_all_clients():
		if id == yo:
			continue
		_midiendo = true
		var segundos: float = await GDSync.get_client_ping(id)
		_midiendo = false
		_ping_ms = roundi(segundos * 1000.0) if segundos >= 0.0 else -1
		return
	_ping_ms = -1
