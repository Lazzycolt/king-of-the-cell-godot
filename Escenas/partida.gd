class_name Partida
extends Node2D
## Reglas de la partida. Solo el HOST las calcula; los clientes reciben el resultado
## por el PropertySynchronizer (GD-Sync) y lo dibujan.

@export_group("Reglas")
## Segundos que la celda se queda en un lugar antes de saltar a otro.
@export_range(5, 120, 1, "suffix:s") var duracion_celda := 30.0
## Puntos que suma por segundo quien está en la celda activa.
@export_range(1, 100, 1, "suffix:pts/s") var puntos_por_segundo := 10.0
## Si está activado, cuando hay 2 o más jugadores en la celda nadie suma (obliga a empujar).
@export var solo_suma_si_esta_solo := true
## Distancia mínima (en celdas) entre la celda vieja y la nueva.
@export_range(1, 4, 1) var distancia_minima := 2

@export_group("Golpes")
## Velocidad mínima del que choca para que cuente como golpe.
@export_range(0, 1000, 10, "suffix:px/s") var velocidad_minima_golpe := 300.0
## Qué parte de la velocidad del que choca se le pasa al golpeado (1 = toda).
@export_range(0.0, 2.0, 0.05) var fuerza_empuje := 1.0
## Segundos que queda aturdido el golpeado (no puede cargar ni saltar).
@export_range(0.1, 3.0, 0.1, "suffix:s") var duracion_aturdido := 1.0
## Segundos de inmunidad después del aturdido, para que no te encadenen golpes.
@export_range(0.0, 3.0, 0.1, "suffix:s") var duracion_inmunidad := 0.5
## Distancia máxima entre los dos para creer el golpe (cubre el retraso de la red).
@export_range(48, 300, 1, "suffix:px") var distancia_maxima_golpe := 90.0

@export_group("Referencias")
## Nodo donde están los jugadores (el mismo que usa red.gd).
@export var contenedor_jugadores: Node2D
## Texto donde se muestran los puntos y el tiempo.
@export var etiqueta_hud: Label

# --- Estado sincronizado (lo escribe el host, lo leen todos) ---
var celda_activa := -1           # índice = fila * COLUMNAS + columna; -1 = partida sin empezar
var tiempo_para_cambio := 0.0
var puntos := {}                 # { id_jugador: puntos }
var jugadores := {}              # { id_jugador: indice }  0 = host (rojo, Spawn1), 1 = invitado (azul, Spawn2)

var en_curso := false            # solo se usa en el host

## Cada cuánto el host reenvía TODO el estado aunque no haya cambiado (por si alguien
## se perdió un mensaje, por ejemplo al entrar a la sala justo en ese momento).
const REENVIO_ESTADO := 1.0
var _reenvio := 0.0

func _ready() -> void:
	add_to_group("partida")   # así los jugadores la encuentran para reportar golpes
	# Permitimos que cualquiera llame reportar_golpe por red (≈ @rpc("any_peer")).
	# Igual adentro se valida todo: el host no se cree lo que le dicen.
	GDSync.expose_func(reportar_golpe)

## Lo llama red.gd en el host al crear la partida.
func iniciar() -> void:
	en_curso = true
	# Solo el host manda el estado de la partida; en las demás PCs queda en NEVER (solo recibe).
	$PropertySynchronizer.broadcast = PropertySynchronizer.BROADCAST_MODE.ALWAYS
	_cambiar_celda()


## Vuelve todo a cero. Lo llama red.gd cuando se corta la partida.
func reiniciar() -> void:
	en_curso = false
	$PropertySynchronizer.broadcast = PropertySynchronizer.BROADCAST_MODE.NEVER
	celda_activa = -1
	puntos = {}
	jugadores = {}


## Solo host: anota un jugador nuevo en la lista. Cada PC lo crea al ver la lista (ver red.gd).
func agregar_jugador(id: int) -> void:
	if jugadores.has(id) or jugadores.size() >= 2:
		return
	var nueva := jugadores.duplicate()   # copia nueva para que el synchronizer note el cambio
	nueva[id] = jugadores.size()
	jugadores = nueva


## Solo host: saca un jugador de la lista (sus puntos quedan en la tabla).
func quitar_jugador(id: int) -> void:
	if not jugadores.has(id):
		return
	var nueva := jugadores.duplicate()
	nueva.erase(id)
	jugadores = nueva


func _physics_process(delta: float) -> void:
	if en_curso:
		_actualizar_reglas(delta)   # solo pasa en el host
		_reenvio -= delta
		if _reenvio <= 0.0:
			_reenvio = REENVIO_ESTADO
			$PropertySynchronizer.synchronize(true, true)
	queue_redraw()
	_actualizar_hud()               # pasa en todas las PCs


# ---------- REGLAS (solo host) ----------

func _actualizar_reglas(delta: float) -> void:
	tiempo_para_cambio -= delta
	if tiempo_para_cambio <= 0.0:
		_cambiar_celda()

	var adentro := []
	for jugador in contenedor_jugadores.get_children():
		# posicion_red = la posición real que llegó (position está suavizada y va atrasada)
		if jugador is Jugador and celda_en_posicion(jugador.posicion_red) == celda_activa:
			adentro.append(jugador)
	if solo_suma_si_esta_solo and adentro.size() > 1:
		return
	for jugador in adentro:
		var id: int = jugador.id_dueno
		puntos[id] = puntos.get(id, 0.0) + puntos_por_segundo * delta

## Lo llama un jugador cuando choca a otro. Si soy el host lo proceso directo;
## si no, se lo mando por red (≈ reportar_golpe.rpc_id(1, ...)).
## Usamos call_func (a todos los demás) y no call_func_on(host): en las pruebas,
## call_func_on a veces no llegaba nunca. Los que no son host lo ignoran.
func pedir_golpe(id_victima: int, velocidad: Vector2) -> void:
	if GDSync.is_host():
		_procesar_golpe(GDSync.get_client_id(), id_victima, velocidad)
	else:
		GDSync.call_func(reportar_golpe, id_victima, velocidad)


## Llega por red desde un cliente. Corre SOLO en el host, que valida y decide.
func reportar_golpe(id_victima: int, velocidad: Vector2) -> void:
	if not GDSync.is_host():
		return
	# get_sender_id() = quién mandó este llamado (≈ multiplayer.get_remote_sender_id())
	_procesar_golpe(GDSync.get_sender_id(), id_victima, velocidad)


func _procesar_golpe(id_atacante: int, id_victima: int, velocidad: Vector2) -> void:
	var atacante := _buscar_jugador(id_atacante)
	var victima := _buscar_jugador(id_victima)
	if atacante == null or victima == null or atacante == victima:
		return

	# --- Validaciones: el servidor no se cree todo lo que le dicen ---
	if atacante.aturdido > 0.0:
		return   # un aturdido no puede pegar
	if victima.inmune > 0.0:
		return   # ya está aturdido o recién salió
	if velocidad.length() < velocidad_minima_golpe:
		return   # fue un roce, no un golpe
	# Usamos posicion_red (el último dato real que llegó), NO position:
	# en el host, la position de un jugador remoto está interpolada y va unos píxeles atrás.
	if atacante.posicion_red.distance_to(victima.posicion_red) > distancia_maxima_golpe:
		print("Golpe rechazado: están demasiado lejos (", id_atacante, " → ", id_victima, ")")
		return
	# Nadie puede ir más rápido que el salto máximo (un poco de margen)
	var rapidez := minf(velocidad.length(), atacante.fuerza_maxima * 1.1)

	# --- Golpe válido: se lo aplicamos a la víctima en todas las PCs ---
	var direccion := (victima.posicion_red - atacante.posicion_red).normalized()
	# call_func_all = se ejecuta en todas las PCs, incluida la mía (≈ .rpc() con "call_local")
	GDSync.call_func_all(victima.recibir_golpe, direccion * rapidez * fuerza_empuje, duracion_aturdido, duracion_inmunidad)
	print("Golpe: ", id_atacante, " → ", id_victima)

func _buscar_jugador(id: int) -> Jugador:
	for jugador in contenedor_jugadores.get_children():
		if jugador is Jugador and jugador.id_dueno == id:
			return jugador
	return null


func _cambiar_celda() -> void:
	var opciones := []
	for i in Arena.COLUMNAS * Arena.FILAS:
		if celda_activa == -1 or _distancia(i, celda_activa) >= distancia_minima:
			opciones.append(i)
	celda_activa = opciones.pick_random()
	tiempo_para_cambio = duracion_celda


# ---------- GRILLA ----------

## Devuelve el índice de la celda donde cae una posición, o -1 si está afuera.
static func celda_en_posicion(pos: Vector2) -> int:
	var esquina := Vector2(-Arena.COLUMNAS * Arena.TAM_CELDA / 2, -Arena.FILAS * Arena.TAM_CELDA / 2)
	var col := floori((pos.x - esquina.x) / Arena.TAM_CELDA)
	var fila := floori((pos.y - esquina.y) / Arena.TAM_CELDA)
	if col < 0 or col >= Arena.COLUMNAS or fila < 0 or fila >= Arena.FILAS:
		return -1
	return fila * Arena.COLUMNAS + col


## Devuelve el rectángulo que ocupa una celda.
static func rect_de_celda(indice: int) -> Rect2:
	var esquina := Vector2(-Arena.COLUMNAS * Arena.TAM_CELDA / 2, -Arena.FILAS * Arena.TAM_CELDA / 2)
	var col := indice % Arena.COLUMNAS
	var fila := indice / Arena.COLUMNAS
	return Rect2(esquina + Vector2(col, fila) * Arena.TAM_CELDA, Vector2.ONE * Arena.TAM_CELDA)


# Distancia en celdas contando diagonales como 1 (distancia "de rey" del ajedrez).
func _distancia(a: int, b: int) -> int:
	return maxi(absi(a % Arena.COLUMNAS - b % Arena.COLUMNAS), absi(a / Arena.COLUMNAS - b / Arena.COLUMNAS))


# ---------- DIBUJO Y HUD (todas las PCs) ----------

func _draw() -> void:
	if celda_activa == -1:
		return
	var color := Color(1.0, 0.8, 0.1, 0.55)   # dorado
	# Los últimos 5 segundos parpadea para avisar que se va a mover
	if tiempo_para_cambio < 5.0 and int(tiempo_para_cambio * 4) % 2 == 0:
		color.a = 0.15
	draw_rect(rect_de_celda(celda_activa).grow(-4), color)


func _actualizar_hud() -> void:
	if celda_activa == -1:
		etiqueta_hud.text = ""
		return
	var texto := "Cambio de celda en %d s\n" % ceili(tiempo_para_cambio)
	for id in puntos:
		var nombre := "Rojo" if jugadores.get(id, 1) == 0 else "Azul"
		texto += "%s: %d\n" % [nombre, roundi(puntos[id])]
	etiqueta_hud.text = texto
