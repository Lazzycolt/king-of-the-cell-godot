extends Node
## Crea la partida (host) o se une a una, y hace aparecer a los jugadores en sus spawns.
## Dos modos:
##  - Steam: salas de Steam con un código de 5 letras. Funciona por internet sin VPN ni abrir puertos.
##  - ENet: conexión directa por IP. Sirve para probar con 2 ventanas en la misma PC
##    (con Steam no se puede, porque las dos ventanas tendrían la misma cuenta).
## En los dos modos, el resto del juego (MultiplayerSpawner, MultiplayerSynchronizer, @rpc) es el mismo.

const PUERTO := 7777
const MAX_JUGADORES := 4
const ESCENA_JUGADOR := preload("res://Escenas/jugador.tscn")
## App ID de prueba de Valve ("Spacewar"): cualquiera puede usarlo sin pagar Steamworks.
const APP_ID_PRUEBA := 480
## Muchos juegos de prueba usan el 480: marcamos nuestras salas para no encontrar las de otros.
const MARCA_JUEGO := "king_of_the_cell"
const LETRAS := "ABCDEFGHJKLMNPQRSTUVWXYZ"   # sin I ni O para no confundir con 1 y 0

@export_group("Conexión")
## Activado: salas de Steam con código (para jugar por internet).[br]Desactivado: ENet por IP (para probar con 2 ventanas en esta PC).
@export var usar_steam := true
## Cantidad de letras del código de sala.
@export_range(4, 8, 1) var largo_codigo := 5

@export_group("Referencias")
## El MultiplayerSpawner de la arena: crea a los jugadores en todas las PCs.
@export var spawner: MultiplayerSpawner
## Nodo donde se agregan los jugadores. Tiene que ser el mismo que el "Spawn Path" del MultiplayerSpawner.
@export var contenedor_jugadores: Node2D
## Nodo con las reglas de la partida (celda y puntos).
@export var partida: Node2D
## Puntos de aparición en orden (uno por jugador): el host aparece en el primero, el 2º jugador en el segundo, etc.
@export var spawns: Array[Marker2D]
## Panel del menú. Se oculta al conectarse.
@export var menu: Control
## Campo de texto: el código de la sala (Steam) o la IP del host (ENet; vacío = esta PC).
@export var campo_codigo: LineEdit
@export var boton_crear: Button
@export var boton_unirse: Button
## Texto del menú donde se muestra qué está pasando (conectando, errores...).
@export var etiqueta_estado: Label

## Código de la sala actual (vacío si no hay). Lo muestra el indicador de conexión.
var codigo_sala := ""
var _soy_host := false
var _id_sala := 0   # id de la sala de Steam (un número largo que da Steam)


func _ready() -> void:
	# Le decimos al spawner CÓMO armar un jugador. Esta función corre en TODAS las PCs.
	spawner.spawn_function = _crear_jugador
	boton_crear.pressed.connect(crear_partida)
	boton_unirse.pressed.connect(unirse)
	multiplayer.peer_connected.connect(_on_peer_conectado)
	multiplayer.peer_disconnected.connect(_on_peer_desconectado)
	multiplayer.connection_failed.connect(_on_conexion_fallida)
	multiplayer.server_disconnected.connect(_on_host_desconectado)
	if usar_steam:
		_iniciar_steam()
	else:
		campo_codigo.placeholder_text = "IP del host (vacío = esta PC)"
		_estado("Modo ENet (sin Steam): creá una partida o escribí una IP.")


# ---------- STEAM ----------

func _iniciar_steam() -> void:
	# true = GodotSteam procesa solo los avisos de Steam (si no, habría que llamar Steam.run_callbacks() cada frame)
	var resultado: Dictionary = Steam.steamInitEx(APP_ID_PRUEBA, true)
	if resultado["status"] != Steam.STEAM_API_INIT_RESULT_OK:
		_estado("No se pudo iniciar Steam: %s\n¿Está Steam abierto y con la sesión iniciada?" % resultado["verbal"])
		_habilitar_botones(false)
		return
	Steam.lobby_created.connect(_on_sala_creada)
	Steam.lobby_joined.connect(_on_sala_unida)
	Steam.lobby_match_list.connect(_on_lista_de_salas)
	_estado("Steam listo (%s). Creá una partida o escribí un código." % Steam.getPersonaName())


# ---------- CREAR PARTIDA (host) ----------

func crear_partida() -> void:
	_habilitar_botones(false)
	if not usar_steam:
		_crear_host_enet()
		return
	codigo_sala = _generar_codigo()
	_estado("Creando la sala %s..." % codigo_sala)
	# Pública para que se pueda buscar por código (igual nadie la encuentra sin el código)
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, MAX_JUGADORES)


func _on_sala_creada(resultado: int, id_sala: int) -> void:
	if resultado != Steam.RESULT_OK:
		_estado("Steam no pudo crear la sala (error %d)." % resultado)
		_habilitar_botones(true)
		return
	_id_sala = id_sala
	# Datos de la sala que después se usan para buscarla
	Steam.setLobbyData(id_sala, "juego", MARCA_JUEGO)
	Steam.setLobbyData(id_sala, "codigo", codigo_sala)
	# El que crea la sala hace de servidor (≈ ENetMultiplayerPeer.create_server)
	var peer := SteamMultiplayerPeer.new()
	var error := peer.create_host(0)
	if error != OK:
		_estado("No se pudo crear el host de Steam (error %d)." % error)
		_habilitar_botones(true)
		return
	peer.server_relay = true
	multiplayer.multiplayer_peer = peer
	_empezar_como_host()


func _crear_host_enet() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(PUERTO, MAX_JUGADORES - 1)  # cuántos clientes acepta
	if error != OK:
		_estado("No se pudo crear la partida (error %d)." % error)
		_habilitar_botones(true)
		return
	multiplayer.multiplayer_peer = peer
	_empezar_como_host()


func _empezar_como_host() -> void:
	_soy_host = true
	_agregar_jugador(1)  # el host también juega; su id siempre es 1
	partida.iniciar()    # solo el host corre las reglas
	menu.hide()
	print("Partida creada. Sala: ", codigo_sala if usar_steam else "ENet puerto %d" % PUERTO)


# ---------- UNIRSE (cliente) ----------

func unirse() -> void:
	_habilitar_botones(false)
	if not usar_steam:
		_unirse_enet()
		return
	var codigo := campo_codigo.text.strip_edges().to_upper()
	if codigo == "":
		_estado("Escribí el código de la sala.")
		_habilitar_botones(true)
		return
	codigo_sala = codigo
	_estado("Buscando la sala %s..." % codigo)
	# Le pedimos a Steam las salas de nuestro juego que tengan ese código
	Steam.addRequestLobbyListStringFilter("juego", MARCA_JUEGO, Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListStringFilter("codigo", codigo, Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListDistanceFilter(Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE)
	Steam.requestLobbyList()


func _on_lista_de_salas(salas: Array) -> void:
	if salas.is_empty():
		_estado("No encontré ninguna sala con el código %s." % codigo_sala)
		codigo_sala = ""
		_habilitar_botones(true)
		return
	_estado("Entrando a la sala %s..." % codigo_sala)
	Steam.joinLobby(salas[0])


func _on_sala_unida(id_sala: int, _permisos: int, _bloqueada: bool, respuesta: int) -> void:
	# Steam también avisa esto al que creó la sala: ese ya es host, no hace nada más.
	if _soy_host:
		return
	if respuesta != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		_estado("No se pudo entrar a la sala (respuesta %d). ¿Está llena?" % respuesta)
		_habilitar_botones(true)
		return
	_id_sala = id_sala
	# Nos conectamos al dueño de la sala, que es el host (≈ ENetMultiplayerPeer.create_client)
	var peer := SteamMultiplayerPeer.new()
	var error := peer.create_client(Steam.getLobbyOwner(id_sala), 0)
	if error != OK:
		_estado("No se pudo conectar con el host (error %d)." % error)
		_salir_de_la_sala()
		_habilitar_botones(true)
		return
	peer.server_relay = true
	multiplayer.multiplayer_peer = peer
	menu.hide()
	print("Conectando con el host de la sala ", codigo_sala, "...")


func _unirse_enet() -> void:
	var ip := campo_codigo.text.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(ip, PUERTO)
	if error != OK:
		_estado("No se pudo iniciar la conexión (error %d)." % error)
		_habilitar_botones(true)
		return
	multiplayer.multiplayer_peer = peer
	menu.hide()
	print("Conectando a ", ip, "...")


# ---------- JUGADORES (solo corre en el host) ----------

func _on_peer_conectado(id: int) -> void:
	if _soy_host:
		_agregar_jugador(id)


func _on_peer_desconectado(id: int) -> void:
	if _soy_host:
		_quitar_jugador(id)


func _agregar_jugador(id: int) -> void:
	var indice := _primer_lugar_libre()
	if indice == -1:
		print("Partida llena, no entra el jugador ", id)
		return
	partida.jugadores[id] = indice   # para el HUD: nombre y color de cada id
	var datos := {"id": id, "indice": indice, "posicion": spawns[indice].global_position}
	# spawn() llama a _crear_jugador acá y en cada cliente, con los mismos datos
	spawner.spawn(datos)
	print("Entró el jugador ", id)


# Corre en todas las PCs. Devuelve el jugador armado y el spawner lo agrega al contenedor.
func _crear_jugador(datos: Dictionary) -> Node:
	var jugador := ESCENA_JUGADOR.instantiate()
	jugador.name = str(datos["id"])  # el nombre = id del dueño (lo usa jugador.gd)
	jugador.indice = datos["indice"]  # decide su color
	jugador.position = datos["posicion"]
	return jugador


# El primer lugar (0 a 3) que no esté usando ningún jugador conectado.
# Si alguien se va, su lugar (spawn y color) queda libre para el próximo que entre.
func _primer_lugar_libre() -> int:
	for i in mini(MAX_JUGADORES, spawns.size()):
		var ocupado := false
		for jugador in contenedor_jugadores.get_children():
			if jugador.indice == i:
				ocupado = true
		if not ocupado:
			return i
	return -1


func _quitar_jugador(id: int) -> void:
	var jugador := contenedor_jugadores.get_node_or_null(str(id))
	if jugador:
		jugador.queue_free()
	print("Salió el jugador ", id)


# ---------- ERRORES Y FIN ----------

func _on_conexion_fallida() -> void:
	_volver_al_menu("No se pudo conectar con el host.")


func _on_host_desconectado() -> void:
	_volver_al_menu("El host cerró la partida.")


func _volver_al_menu(motivo: String) -> void:
	print(motivo)
	multiplayer.multiplayer_peer = null
	_salir_de_la_sala()
	_soy_host = false
	codigo_sala = ""
	for jugador in contenedor_jugadores.get_children():
		jugador.queue_free()
	partida.reiniciar()
	menu.show()
	_habilitar_botones(true)
	_estado(motivo)


func _salir_de_la_sala() -> void:
	if usar_steam and _id_sala != 0:
		Steam.leaveLobby(_id_sala)
	_id_sala = 0


func _generar_codigo() -> String:
	var codigo := ""
	for i in largo_codigo:
		codigo += LETRAS[randi() % LETRAS.length()]
	return codigo


func _habilitar_botones(activos: bool) -> void:
	boton_crear.disabled = not activos
	boton_unirse.disabled = not activos


func _estado(texto: String) -> void:
	etiqueta_estado.text = texto
