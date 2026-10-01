extends Node
## Conecta con GD-Sync, crea una sala o se une a una con un código,
## y hace aparecer a los jugadores en sus spawns.
## Versión GD-Sync: reemplaza a ENet (IP + puerto) por los servidores relay de GD-Sync.

const ESCENA_JUGADOR := preload("res://Escenas/jugador.tscn")
const MAX_JUGADORES := 2
const LETRAS := "ABCDEFGHJKLMNPQRSTUVWXYZ"   # sin I ni O para no confundir con 1 y 0

@export_group("Conexión")
## Activado: modo LOCAL de GD-Sync. Funciona entre ventanas de la misma PC o en la misma red (LAN),
## sin claves de API y sin gastar datos del plan. Desactivalo para jugar por internet.
@export var modo_local := false
## Cantidad de letras del código de sala que se genera al crear una partida.
@export_range(4, 8, 1) var largo_codigo := 5

@export_group("Referencias")
## Nodo donde se agregan los jugadores.
@export var contenedor_jugadores: Node2D
## Nodo con las reglas de la partida (celda y puntos).
@export var partida: Node2D
## Puntos de aparición en orden: el host aparece en el primero, el invitado en el segundo.
@export var spawns: Array[Marker2D]
## Panel del menú. Se oculta al entrar a una sala.
@export var menu: Control
## Campo donde se escribe el código de la sala para unirse.
@export var campo_codigo: LineEdit
@export var boton_crear: Button
@export var boton_unirse: Button
## Texto del menú donde se muestra qué está pasando (conectando, errores...).
@export var etiqueta_estado: Label

var _soy_creador := false
var _en_sala := false
var _host_conocido := -1   # id del host cuando entramos; si cambia, el host se fue


func _ready() -> void:
	boton_crear.pressed.connect(crear_partida)
	boton_unirse.pressed.connect(unirse)
	_habilitar_botones(false)

	# Señales de GD-Sync (equivalen a las de "multiplayer" en la versión ENet)
	GDSync.connected.connect(_on_conectado)
	GDSync.connection_failed.connect(_on_conexion_fallida)
	GDSync.disconnected.connect(_on_desconectado)
	GDSync.lobby_created.connect(_on_sala_creada)
	GDSync.lobby_creation_failed.connect(_on_sala_no_creada)
	GDSync.lobby_joined.connect(_on_sala_unida)
	GDSync.lobby_join_failed.connect(_on_sala_no_unida)
	GDSync.client_joined.connect(_on_cliente_entro)
	GDSync.client_left.connect(_on_cliente_salio)
	GDSync.host_changed.connect(_on_host_cambio)

	# Paso 1: conectarse a GD-Sync apenas arranca el juego
	_estado("Conectando con GD-Sync...")
	if modo_local:
		GDSync.start_local_multiplayer()
	else:
		GDSync.start_multiplayer()


# ---------- CONEXIÓN CON GD-SYNC ----------

func _on_conectado() -> void:
	_estado("Conectado. Creá una partida o escribí un código para unirte.")
	_habilitar_botones(true)


func _on_conexion_fallida(error: int) -> void:
	match error:
		ENUMS.CONNECTION_FAILED.INVALID_PUBLIC_KEY:
			_estado("Error: las claves de API no son válidas (Proyecto → Herramientas → GD-Sync).")
		ENUMS.CONNECTION_FAILED.TIMEOUT:
			_estado("Error: no se pudo llegar a los servidores de GD-Sync (¿hay internet?).")
		_:
			_estado("Error al conectar con GD-Sync (código %d)." % error)


func _on_desconectado() -> void:
	_terminar_partida("Se perdió la conexión con GD-Sync.")
	_habilitar_botones(false)


# ---------- CREAR SALA (el que crea es el host) ----------

func crear_partida() -> void:
	_soy_creador = true
	var codigo := _generar_codigo()
	_estado("Creando la sala %s..." % codigo)
	_habilitar_botones(false)
	# Sala privada (no aparece en listas) y con lugar para MAX_JUGADORES
	GDSync.lobby_create(codigo, "", false, MAX_JUGADORES)


func _on_sala_creada(codigo: String) -> void:
	# Crear la sala no te mete adentro: hay que unirse
	GDSync.lobby_join(codigo)


func _on_sala_no_creada(codigo: String, error: int) -> void:
	_soy_creador = false
	_habilitar_botones(true)
	if error == ENUMS.LOBBY_CREATION_ERROR.LOBBY_ALREADY_EXISTS:
		_estado("Ese código ya existe, probá de nuevo.")
	elif error == ENUMS.LOBBY_CREATION_ERROR.ON_COOLDOWN:
		_estado("Esperá unos segundos antes de crear otra sala.")
	else:
		_estado("No se pudo crear la sala (error %d)." % error)


# ---------- UNIRSE A UNA SALA ----------

func unirse() -> void:
	var codigo := campo_codigo.text.strip_edges().to_upper()
	if codigo == "":
		_estado("Escribí el código de la sala.")
		return
	_soy_creador = false
	_estado("Entrando a la sala %s..." % codigo)
	_habilitar_botones(false)
	GDSync.lobby_join(codigo)


func _on_sala_no_unida(codigo: String, error: int) -> void:
	_habilitar_botones(true)
	match error:
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_DOES_NOT_EXIST:
			_estado("No existe ninguna sala con el código %s." % codigo)
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_IS_FULL:
			_estado("La sala %s está llena." % codigo)
		_:
			_estado("No se pudo entrar a la sala (error %d)." % error)


func _on_sala_unida(codigo: String) -> void:
	_en_sala = true
	menu.hide()
	print("Dentro de la sala ", codigo, " · mi id: ", GDSync.get_client_id())
	if _soy_creador:
		# El host también juega y es quien corre las reglas
		partida.iniciar()
		partida.agregar_jugador(GDSync.get_client_id())


# ---------- JUGADORES ----------
# El host anota quién está en la partida en partida.jugadores (se sincroniza solo).
# Cada PC, incluido el host, crea o borra sus nodos para que coincidan con esa lista.
# Es lo mismo que hacía el MultiplayerSpawner, pero hecho a mano.

func _on_cliente_entro(id: int) -> void:
	# Se emite en todas las PCs, incluso para uno mismo. Solo el host anota jugadores,
	# y el suyo ya lo anotó en _on_sala_unida.
	if _soy_creador and id != GDSync.get_client_id():
		partida.agregar_jugador(id)
		print("Entró el jugador ", id)


func _on_cliente_salio(id: int) -> void:
	if not _soy_creador and id == _host_conocido:
		_terminar_partida("El host cerró la partida.")
		return
	if _soy_creador:
		partida.quitar_jugador(id)
		print("Salió el jugador ", id)


func _sincronizar_jugadores() -> void:
	# Crear los que están en la lista y todavía no existen acá
	for id in partida.jugadores:
		if contenedor_jugadores.get_node_or_null("J%d" % id) == null:
			_crear_jugador(id, partida.jugadores[id])
	# Borrar los que ya no están en la lista
	for jugador in contenedor_jugadores.get_children():
		if jugador is Jugador and not partida.jugadores.has(jugador.id_dueno):
			jugador.queue_free()


func _crear_jugador(id: int, indice: int) -> void:
	var jugador := ESCENA_JUGADOR.instantiate() as Jugador
	jugador.name = "J%d" % id   # mismo nombre en todas las PCs → misma ruta para call_func
	jugador.id_dueno = id
	jugador.indice = indice
	jugador.position = spawns[indice].global_position
	contenedor_jugadores.add_child(jugador)


func _on_host_cambio(_soy_host: bool, nuevo_host: int) -> void:
	# La primera vez es GD-Sync avisando quién es el host de la sala.
	if _host_conocido == -1:
		_host_conocido = nuevo_host
		return
	# Si cambia después, es porque el host se fue y GD-Sync eligió otro.
	# En nuestro juego, si se va el que creó la partida, termina para todos (como en el GDD).
	if _en_sala and nuevo_host != _host_conocido:
		_terminar_partida("El host cerró la partida.")


# ---------- FIN Y UTILIDADES ----------

# Red de seguridad: si la sala desaparece sin avisar (por ejemplo, en modo local
# el host cierra el juego), volvemos al menú igual.
func _process(_delta: float) -> void:
	if _en_sala and (not GDSync.is_active() or GDSync.lobby_get_name() == ""):
		_terminar_partida("Se cerró la sala.")
		return
	_sincronizar_jugadores()


func _terminar_partida(motivo: String) -> void:
	if _en_sala and GDSync.lobby_get_name() != "":
		GDSync.lobby_leave()
	_en_sala = false
	_soy_creador = false
	_host_conocido = -1
	for jugador in contenedor_jugadores.get_children():
		jugador.queue_free()
	partida.reiniciar()
	menu.show()
	_habilitar_botones(GDSync.is_active())
	_estado(motivo)
	print(motivo)


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
