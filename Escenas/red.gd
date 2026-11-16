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
## Texto del menú con el nombre de Steam del jugador.
@export var etiqueta_usuario: Label

## Largo máximo del nombre que se muestra (los de Steam pueden ser muy largos).
const LARGO_MAXIMO_NOMBRE := 16
## Tamaño máximo de los datos de conexión: algo más grande no es nuestro (alguien manda basura).
const MAXIMO_BYTES_DATOS := 1024

# Motivos de rechazo. El cliente los muestra tal cual en el menú (clase 14, "las reglas de entrada").
const MOTIVO_DATOS := "No se pudieron leer tus datos de conexión."
const MOTIVO_VERSION := "Tu versión del juego (%s) no es la misma que la del host (%s). Actualizá el juego."
const MOTIVO_EXPULSADO := "El host te expulsó de la partida."
const MOTIVO_DUPLICADO := "Ya hay alguien conectado con tu cuenta. Si se te cortó, esperá unos segundos y probá de nuevo."
const MOTIVO_EMPEZADA := "La partida ya empezó. Esperá a que termine."
const MOTIVO_LLENA := "La sala está llena."

## Avisa cosas para mostrar a todos ("X entró", "X se fue", "X fue expulsado"). Lo usa la interfaz.
signal aviso(texto: String)

@export_group("Pruebas")
## Activado: este juego manda una versión falsa al conectarse. Sirve para ver el rechazo por versión
## sin armar otro build (como 'probarVersionVieja' de la clase 14).
@export var probar_version_vieja := false

## Versión del juego: Proyecto → Configuración del Proyecto → Application → Config → Version.
## Si un compañero tiene un build con otra versión, el host no lo deja entrar.
var version_juego: String = ProjectSettings.get_setting("application/config/version", "0")

## Código de la sala actual (vacío si no hay). Lo muestra el indicador de conexión.
var codigo_sala := ""
var _soy_host := false
var _id_sala := 0   # id de la sala de Steam (un número largo que da Steam)

## Identifica a la PERSONA (no a la conexión): con Steam es su SteamID, que no cambia aunque
## se reconecte. Con ENet no hay cuenta, así que es un número al azar por cada vez que se abre el juego.
var _mi_id_persona := ""

# --- Solo en el host ---
var _sesion := {}        # { id_peer: { "id_persona", "nombre", "version" } } los que pasaron la puerta
var _expulsados := {}    # { id_persona: true } no vuelven a entrar a esta sala
var _expulsando := {}    # { id_peer: true } para no avisar "se fue" de alguien que acabamos de echar
var _rechazados := {}    # { id_peer: true } rechazados en la puerta (para no confundirlos con un timeout)
## Los que se fueron a mitad de partida y pueden volver con sus puntos (clase 14, paso 8).
## La clave es la PERSONA, no la conexión: al volver le toca otro id de peer.
var _desconectados := {} # { id_persona: id_peer_viejo }


func _ready() -> void:
	# Le decimos al spawner CÓMO armar un jugador. Esta función corre en TODAS las PCs.
	spawner.spawn_function = _crear_jugador
	partida.estado_cambiado.connect(_on_estado_cambiado)
	boton_crear.pressed.connect(crear_partida)
	boton_unirse.pressed.connect(unirse)
	multiplayer.peer_connected.connect(_on_peer_conectado)
	multiplayer.peer_disconnected.connect(_on_peer_desconectado)
	multiplayer.connection_failed.connect(_on_conexion_fallida)
	multiplayer.server_disconnected.connect(_on_host_desconectado)
	# La puerta de entrada (≈ aprobación de conexión de NGO): mientras esto esté puesto,
	# nadie "entra" (peer_connected) hasta que el host lo aprueba con complete_auth().
	multiplayer.auth_callback = _on_datos_de_autenticacion
	multiplayer.peer_authenticating.connect(_on_autenticando)
	multiplayer.peer_authentication_failed.connect(_on_autenticacion_fallida)
	_mi_id_persona = "enet-%d" % randi()
	if usar_steam:
		_iniciar_steam()
	else:
		campo_codigo.placeholder_text = "IP (vacío = esta PC)"
		etiqueta_usuario.text = "Modo ENet (sin Steam)"
		_estado("Creá una partida o escribí una IP.")


# ---------- STEAM ----------

func _iniciar_steam() -> void:
	# true = GodotSteam procesa solo los avisos de Steam (si no, habría que llamar Steam.run_callbacks() cada frame)
	var resultado: Dictionary = Steam.steamInitEx(APP_ID_PRUEBA, true)
	if resultado["status"] != Steam.STEAM_API_INIT_RESULT_OK:
		etiqueta_usuario.text = "Steam no disponible"
		_estado("No se pudo iniciar Steam: %s\n¿Está Steam abierto y con la sesión iniciada?" % resultado["verbal"])
		_habilitar_botones(false)
		return
	Steam.lobby_created.connect(_on_sala_creada)
	Steam.lobby_joined.connect(_on_sala_unida)
	Steam.lobby_match_list.connect(_on_lista_de_salas)
	_mi_id_persona = str(Steam.getSteamID())
	etiqueta_usuario.text = "Jugando como %s" % _mi_nombre()
	_estado("Creá una partida o escribí un código para unirte.")


## Nuestro nombre de Steam (vacío en modo ENet: ahí se usa el nombre del color).
func _mi_nombre() -> String:
	if not usar_steam:
		return ""
	return _limpiar_nombre(Steam.getPersonaName())


static func _limpiar_nombre(nombre: String) -> String:
	nombre = nombre.strip_edges()
	if nombre.length() > LARGO_MAXIMO_NOMBRE:
		nombre = nombre.left(LARGO_MAXIMO_NOMBRE - 1) + "…"
	return nombre


# ---------- LA PUERTA DE ENTRADA (autenticación) ----------
# Igual que la aprobación de conexión de la clase 14, pero con la forma de Godot:
#
#   CLIENTE                                    HOST
#   se conecta ───────────────────────────────►
#   peer_authenticating(1)                     peer_authenticating(id)
#   send_auth(1, {versión, id, nombre}) ──────► _on_datos_de_autenticacion(id, datos)
#                                                 revisa las reglas, en orden
#   _on_datos_de_autenticacion(1, respuesta) ◄── send_auth(id, {ok: true}) + complete_auth(id)
#     ok → complete_auth(1) → entra                  o  {ok: false, motivo} + lo desconecta
#     no → vuelve al menú mostrando el motivo
#
# Los datos viajan UNA vez y antes de que el jugador exista: así el host decide con todo en la mano
# y nunca hay un frame con el jugador sin nombre.

# Los dos lados: arranca la autenticación con alguien.
func _on_autenticando(id: int) -> void:
	if _soy_host:
		return   # el host espera a que el cliente mande sus datos
	if id != 1:
		return   # el cliente solo se autentica con el host
	var datos := {
		"version": "0.0-prueba" if probar_version_vieja else version_juego,
		"id_persona": _mi_id_persona,
		"nombre": _mi_nombre(),
	}
	multiplayer.send_auth(1, JSON.stringify(datos).to_utf8_buffer())


# Los dos lados: llegaron datos de autenticación.
func _on_datos_de_autenticacion(id: int, bytes: PackedByteArray) -> void:
	if _soy_host:
		_revisar_pedido(id, bytes)
	else:
		_leer_respuesta(bytes)


## HOST: decide si el que llega puede entrar. Las reglas van en el orden de la clase 14:
## a un expulsado le decimos que está expulsado, no que la sala está llena.
func _revisar_pedido(id: int, bytes: PackedByteArray) -> void:
	var datos := _leer_json(bytes)
	var motivo := ""
	if datos.is_empty() or str(datos.get("id_persona", "")) == "":
		motivo = MOTIVO_DATOS
	elif str(datos.get("version", "")) != version_juego:
		motivo = MOTIVO_VERSION % [str(datos.get("version", "?")), version_juego]
	elif _expulsados.has(str(datos["id_persona"])):
		motivo = MOTIVO_EXPULSADO
	elif _esta_conectada(str(datos["id_persona"])):
		motivo = MOTIVO_DUPLICADO
	elif partida.estado != Partida.Estado.LOBBY and not _puede_volver(str(datos["id_persona"])):
		motivo = MOTIVO_EMPEZADA   # con la partida empezada solo entra el que se había ido
	elif _primer_lugar_libre() == -1:
		motivo = MOTIVO_LLENA   # la sala de Steam ya limita a 4; esto cubre ENet y casos raros

	if motivo != "":
		print("Rechazado el jugador ", id, ": ", motivo)
		_rechazados[id] = true
		multiplayer.send_auth(id, JSON.stringify({"ok": false, "motivo": motivo}).to_utf8_buffer())
		# Le damos un momento para que le llegue el motivo. Normalmente se va solo al leerlo;
		# si sigue ahí (un cliente modificado, por ejemplo), lo cortamos nosotros.
		get_tree().create_timer(0.5).timeout.connect(func() -> void:
			if _soy_host and id in multiplayer.get_authenticating_peers():
				multiplayer.multiplayer_peer.disconnect_peer(id))
		return

	# Aprobado: guardamos sus datos (limpios: el host no confía en lo que manda el cliente)
	_sesion[id] = {
		"id_persona": str(datos["id_persona"]),
		"nombre": _limpiar_nombre(str(datos.get("nombre", ""))),
		"version": str(datos["version"]),
	}
	multiplayer.send_auth(id, JSON.stringify({"ok": true}).to_utf8_buffer())
	multiplayer.complete_auth(id)   # cuando el cliente también lo complete, llega peer_connected


## CLIENTE: la respuesta del host.
func _leer_respuesta(bytes: PackedByteArray) -> void:
	var respuesta := _leer_json(bytes)
	if respuesta.get("ok", false):
		multiplayer.complete_auth(1)
		return
	# Diferido: no conviene cerrar la conexión en medio de procesar un mensaje de la red
	_volver_al_menu.call_deferred(str(respuesta.get("motivo", MOTIVO_DATOS)))


# Los dos lados: no se completó a tiempo (auth_timeout, 3 s por defecto).
func _on_autenticacion_fallida(id: int) -> void:
	if _soy_host:
		if not _rechazados.erase(id):   # a los rechazados ya los despedimos: no es un timeout
			print("El jugador ", id, " no completó la entrada a tiempo")
		return
	# El host no contestó: lo más probable es que tenga un build viejo (sin esta puerta)
	_volver_al_menu("El host no respondió al pedido de entrada. ¿Tienen la misma versión del juego?")


static func _leer_json(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty() or bytes.size() > MAXIMO_BYTES_DATOS:
		return {}
	var datos = JSON.parse_string(bytes.get_string_from_utf8())
	return datos if datos is Dictionary else {}


## ¿Es alguien que se fue a mitad de esta partida y puede volver con sus puntos?
func _puede_volver(id_persona: String) -> bool:
	return partida.estado == Partida.Estado.JUGANDO and _desconectados.has(id_persona)


func _esta_conectada(id_persona: String) -> bool:
	if id_persona == _mi_id_persona:
		return true   # el host también cuenta
	for datos in _sesion.values():
		if datos["id_persona"] == id_persona:
			return true
	return false


# ---------- EXPULSAR (solo host) ----------

## Saca a un jugador de la sala y no lo deja volver mientras dure (clase 14, paso 7).
## Al host no se lo puede expulsar: sin él no hay partida.
func expulsar(id: int) -> void:
	if not _soy_host or id == 1 or not id in multiplayer.get_peers():
		return
	var datos: Dictionary = _sesion.get(id, {})
	if datos.has("id_persona"):
		_expulsados[datos["id_persona"]] = true   # sin esta lista, vuelve a entrar con el mismo código
	_expulsando[id] = true
	_avisar.rpc("%s fue expulsado" % partida.nombre_jugador(id))
	_rechazar(id, MOTIVO_EXPULSADO)


## Lista para el panel del host: los que se pueden expulsar (todos menos el host).
func jugadores_expulsables() -> Array:
	var lista := []
	for id in partida.jugadores:
		if id != 1 and id in multiplayer.get_peers():
			lista.append(id)
	return lista


# ---------- AVISOS PARA TODOS ----------

## El host la llama en TODAS las PCs (clase 13: "los que se quedan tienen que enterarse").
@rpc("authority", "call_local", "reliable")
func _avisar(texto: String) -> void:
	aviso.emit(texto)


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
	partida.abrir_lobby()  # solo el host corre las reglas; arranca esperando en el lobby
	_sesion.clear()
	_expulsados.clear()   # cada sala nueva arranca de cero
	_expulsando.clear()
	_rechazados.clear()
	_desconectados.clear()
	_agregar_jugador(1)    # el host también juega; su id siempre es 1
	partida.nombres[1] = _mi_nombre()
	menu.hide()
	print("Sala creada: ", codigo_sala if usar_steam else "ENet puerto %d" % PUERTO)


## Botón "Iniciar" del lobby (solo lo ve el host).
func iniciar_partida() -> void:
	if _soy_host:
		partida.empezar()


## Botón "Volver al menú" (resultados) o "Salir al menú" (Esc). Sirve para host y clientes.
func salir_al_menu() -> void:
	if not _soy_host and partida.estado == Partida.Estado.JUGANDO:
		_volver_al_menu("Saliste de la partida. Si tocás Unirse con el mismo código, volvés con tus puntos.")
		return
	_volver_al_menu("Volviste al menú.")


func soy_host() -> bool:
	return _soy_host


## ¿Estamos conectados a una sala (como host o como cliente)?
func esta_en_sala() -> bool:
	var peer := multiplayer.multiplayer_peer
	return peer != null and not peer is OfflineMultiplayerPeer \
			and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


# En el host: la sala de Steam se puede buscar hasta que termina la partida. Mientras se juega
# sigue abierta para que pueda volver el que se cortó; a los nuevos los frena la puerta de entrada
# (con el motivo "La partida ya empezó"), que es más claro que un error de Steam.
func _on_estado_cambiado(nuevo: Partida.Estado) -> void:
	if _soy_host and usar_steam and _id_sala != 0:
		Steam.setLobbyJoinable(_id_sala, nuevo != Partida.Estado.FINALIZADO)


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
		_estado("No se pudo entrar a la sala (respuesta %d). ¿Está llena o ya empezó?" % respuesta)
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
	if not _soy_host:
		return
	# Acá solo llegan los que pasaron la puerta (_revisar_pedido). Por las dudas, si la partida
	# empezó en el medio (entre la aprobación y este momento), igual lo echamos.
	if not _sesion.has(id):
		_rechazar(id, MOTIVO_DATOS)
		return
	var persona: String = _sesion[id]["id_persona"]
	if _puede_volver(persona):
		_reincorporar(id, persona)
		return
	if partida.estado != Partida.Estado.LOBBY:
		_rechazar(id, MOTIVO_EMPEZADA)
		return
	_agregar_jugador(id)
	partida.nombres[id] = _sesion[id]["nombre"]   # el nombre llegó con el pedido de entrada
	_avisar.rpc("%s entró a la sala" % partida.nombre_jugador(id))


## Vuelve alguien que se había ido a mitad de partida: aparece en su esquina, con su color y sus puntos.
func _reincorporar(id: int, persona: String) -> void:
	var id_viejo: int = _desconectados[persona]
	_desconectados.erase(persona)
	_agregar_jugador(id, partida.jugadores.get(id_viejo, -1))
	if not partida.jugadores.has(id):
		return   # no había lugar (no debería pasar: los nuevos no entran con la partida empezada)
	partida.nombres[id] = _sesion[id]["nombre"]
	partida.reincorporar(id_viejo, id)
	_avisar.rpc("%s volvió a la partida (%d puntos)" % [partida.nombre_jugador(id), roundi(partida.puntos.get(id, 0.0))])
	print("Volvió el jugador ", id, " (antes ", id_viejo, ")")


func _on_peer_desconectado(id: int) -> void:
	if _soy_host:
		_quitar_jugador(id)


## Le avisa al jugador por qué no puede entrar y lo desconecta.
func _rechazar(id: int, motivo: String) -> void:
	print("Rechazado el jugador ", id, ": ", motivo)
	_avisar_rechazo.rpc_id(id, motivo)
	# Le damos medio segundo para que le llegue el aviso; si no se fue solo, lo desconectamos.
	get_tree().create_timer(0.5).timeout.connect(func() -> void:
		if _soy_host and id in multiplayer.get_peers():
			multiplayer.multiplayer_peer.disconnect_peer(id))


## Corre en el cliente rechazado: vuelve al menú mostrando el motivo.
@rpc("authority", "reliable")
func _avisar_rechazo(motivo: String) -> void:
	# Diferido: no conviene cerrar la conexión en medio de procesar un mensaje de la red
	_volver_al_menu.call_deferred(motivo)


## lugar_preferido: el que tenía antes (al reconectar), si sigue libre. Si no, el primero libre.
func _agregar_jugador(id: int, lugar_preferido := -1) -> void:
	var indice := lugar_preferido if _lugar_libre(lugar_preferido) else _primer_lugar_libre()
	if indice == -1:
		_rechazar(id, MOTIVO_LLENA)
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
		if _lugar_libre(i):
			return i
	return -1


func _lugar_libre(indice: int) -> bool:
	if indice < 0 or indice >= mini(MAX_JUGADORES, spawns.size()):
		return false
	for jugador in contenedor_jugadores.get_children():
		if jugador.indice == indice and not jugador.is_queued_for_deletion():
			return false
	return true


func _quitar_jugador(id: int) -> void:
	var nombre: String = partida.nombre_jugador(id)   # antes de que jugador_salio lo borre de la lista
	var jugador := contenedor_jugadores.get_node_or_null(str(id))
	# Si se va a mitad de partida (y no lo echamos), lo anotamos por PERSONA para que pueda volver
	var puede_volver: bool = jugador != null and partida.estado == Partida.Estado.JUGANDO \
			and not _expulsando.has(id) and _sesion.has(id)
	if puede_volver:
		_desconectados[_sesion[id]["id_persona"]] = id
	if jugador:
		jugador.queue_free()
		partida.jugador_salio(id, puede_volver)   # si queda uno solo, se espera a que vuelva o se termina
		if not _expulsando.has(id):   # al expulsado ya lo anunciamos
			_avisar.rpc("%s se fue de la partida" % nombre)
	_sesion.erase(id)
	_expulsando.erase(id)
	print("Salió el jugador ", id)


# ---------- ERRORES Y FIN ----------

func _on_conexion_fallida() -> void:
	_volver_al_menu("No se pudo conectar con el host.")


func _on_host_desconectado() -> void:
	if not partida.resultado.is_empty():
		# La partida ya terminó y el host volvió al menú: dejamos la pantalla de resultados
		# hasta que este jugador toque "Volver al menú". Solo cortamos la conexión.
		_cerrar_conexion()
		return
	# Desde el cliente no se puede distinguir "el host se fue" de "se cortó la red" (clase 14, paso 6)
	var motivo := "Se perdió la conexión con el host (cerró la partida o se cortó la red)."
	if partida.estado == Partida.Estado.JUGANDO:
		# El código (o la IP) sigue escrito en el campo: con tocar Unirse alcanza
		motivo += "\nSi la partida sigue, tocá Unirse para volver con tus puntos."
	_volver_al_menu(motivo)


## Deja todo como al abrir el juego: sin conexión, sin sala, sin jugadores ni objetos.
## Sirve igual para el host y para los clientes.
func _volver_al_menu(motivo: String) -> void:
	print(motivo)
	_cerrar_conexion()
	codigo_sala = ""
	for jugador in contenedor_jugadores.get_children():
		jugador.queue_free()
	partida.reiniciar()
	menu.show()
	_habilitar_botones(true)
	_estado(motivo)


func _cerrar_conexion() -> void:
	# Primero dejamos de ser host: así, si al cerrar llegan avisos de "se fue X",
	# no se corren las reglas (ni se mandan RPC por una conexión que se está cerrando).
	_soy_host = false
	partida.soy_host = false
	var peer := multiplayer.multiplayer_peer
	if peer != null and not peer is OfflineMultiplayerPeer:
		peer.close()   # avisa a los demás enseguida (si no, se enteran recién por timeout)
	# Sin conexión dejamos un peer "offline" (no null): así get_unique_id() y compañía
	# siguen respondiendo (id 1) en vez de tirar error mientras estamos en el menú.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_salir_de_la_sala()


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
