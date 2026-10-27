extends Node
## Crea la partida (host) o se une a una, y hace aparecer a los jugadores en sus spawns.

const PUERTO := 7777
const MAX_JUGADORES := 2
const ESCENA_JUGADOR := preload("res://Escenas/jugador.tscn")

@export_group("Referencias")
## El MultiplayerSpawner de la arena: crea a los jugadores en todas las PCs.
@export var spawner: MultiplayerSpawner
## Nodo donde se agregan los jugadores. Tiene que ser el mismo que el "Spawn Path" del MultiplayerSpawner.
@export var contenedor_jugadores: Node2D
## Nodo con las reglas de la partida (celda y puntos).
@export var partida: Node2D
## Puntos de aparición en orden: el host aparece en el primero, el invitado en el segundo.
@export var spawns: Array[Marker2D]
## Panel del menú. Se oculta al conectarse.
@export var menu: Control
## Campo donde se escribe la IP del host. Vacío = esta misma PC (127.0.0.1).
@export var campo_ip: LineEdit
@export var boton_crear: Button
@export var boton_unirse: Button

@export_group("Pruebas")
## Al crear la partida se suman bots que juegan solos. Destildalo para jugar con tus amigos.[br]Solo funciona corriendo desde el editor: en un juego exportado nunca aparecen.
@export var bots_de_prueba := false
## Cuántos bots se suman (además de vos).
@export_range(1, 3, 1) var cantidad_bots := 2

const ID_PRIMER_BOT := 1001   # ids inventados para los bots (los de verdad los da la red)


func _ready() -> void:
	# Le decimos al spawner CÓMO armar un jugador. Esta función corre en TODAS las PCs.
	spawner.spawn_function = _crear_jugador
	boton_crear.pressed.connect(crear_partida)
	boton_unirse.pressed.connect(unirse)
	multiplayer.connection_failed.connect(_on_conexion_fallida)
	multiplayer.server_disconnected.connect(_on_host_desconectado)


# ---------- HOST ----------

func crear_partida() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(PUERTO, MAX_JUGADORES - 1)  # cuántos clientes acepta
	if error != OK:
		print("No se pudo crear la partida. Error: ", error)
		return
	multiplayer.multiplayer_peer = peer
	# Solo el host escucha cuando alguien entra o sale
	multiplayer.peer_connected.connect(_agregar_jugador)
	multiplayer.peer_disconnected.connect(_quitar_jugador)
	_agregar_jugador(1)  # el host también juega; su id siempre es 1
	if bots_de_prueba and OS.has_feature("editor"):
		for i in cantidad_bots:
			_agregar_jugador(ID_PRIMER_BOT + i, true)
	partida.iniciar()    # solo el host corre las reglas
	menu.hide()
	print("Partida creada en el puerto ", PUERTO)


# ---------- CLIENTE ----------

func unirse() -> void:
	var ip := campo_ip.text.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(ip, PUERTO)
	if error != OK:
		print("No se pudo iniciar la conexión. Error: ", error)
		return
	multiplayer.multiplayer_peer = peer
	menu.hide()
	print("Conectando a ", ip, "...")


# ---------- JUGADORES (solo corre en el host) ----------

func _agregar_jugador(id: int, es_bot := false) -> void:
	var indice := contenedor_jugadores.get_child_count()
	var posicion := spawns[indice % spawns.size()].global_position
	if indice >= spawns.size():   # más jugadores que spawns: cerca de uno, corrido un poco
		posicion += Vector2(randf_range(-60, 60), randf_range(-60, 60))
	var datos := {"id": id, "posicion": posicion, "indice": indice, "bot": es_bot}
	# spawn() llama a _crear_jugador acá y en cada cliente, con los mismos datos
	spawner.spawn(datos)
	print("Entró el jugador ", id, " (bot)" if es_bot else "")


# Corre en todas las PCs. Devuelve el jugador armado y el spawner lo agrega al contenedor.
func _crear_jugador(datos: Dictionary) -> Node:
	var jugador := ESCENA_JUGADOR.instantiate()
	jugador.name = str(datos["id"])  # el nombre = id del dueño (lo usa jugador.gd)
	jugador.position = datos["posicion"]
	jugador.indice = datos["indice"]
	jugador.es_bot = datos["bot"]
	return jugador


func _quitar_jugador(id: int) -> void:
	var jugador := contenedor_jugadores.get_node_or_null(str(id))
	if jugador:
		jugador.queue_free()
	print("Salió el jugador ", id)


# ---------- ERRORES ----------

func _on_conexion_fallida() -> void:
	print("No se pudo conectar.")
	multiplayer.multiplayer_peer = null
	menu.show()


func _on_host_desconectado() -> void:
	print("El host cerró la partida.")
	multiplayer.multiplayer_peer = null
	for jugador in contenedor_jugadores.get_children():
		jugador.queue_free()
	partida.reiniciar()
	menu.show()
