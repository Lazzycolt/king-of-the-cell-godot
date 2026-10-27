class_name Partida
extends Node2D
## Reglas de la partida. Solo el HOST las calcula; los clientes reciben el resultado
## por el MultiplayerSynchronizer y lo dibujan.

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

@export_group("Objetos")
## Segundos entre que aparece un objeto y el siguiente.
@export_range(1, 60, 1, "suffix:s") var intervalo_objetos := 12.0
## Cuántos objetos puede haber a la vez en la arena.
@export_range(1, 5, 1) var max_objetos := 1
## Segundos que dura el escudo (nadie te puede golpear, pero vos sí podés pegar).
@export_range(1, 20, 0.5, "suffix:s") var duracion_escudo := 5.0
## Segundos que tenés para usar el topetazo después de agarrarlo. Se gasta con el primer golpe.
@export_range(1, 30, 0.5, "suffix:s") var duracion_topetazo := 8.0
## Con topetazo, el golpeado sale a (salto máximo del atacante × esto).[br]2 = el doble de rápido que tu mejor salto.
@export_range(1.0, 4.0, 0.1) var fuerza_topetazo := 2.2
## Segundos que el golpeado se desliza como bola de billar (poca fricción, mucho rebote). Está aturdido mientras tanto.
@export_range(0.5, 5.0, 0.1, "suffix:s") var tiempo_lanzado := 1.5

@export_group("Referencias")
## Nodo donde están los jugadores (el mismo que usa red.gd).
@export var contenedor_jugadores: Node2D
## MultiplayerSpawner que crea los objetos en todas las PCs.
@export var spawner_objetos: MultiplayerSpawner
## Nodo donde aparecen los objetos. Tiene que ser el "Spawn Path" de spawner_objetos.
@export var contenedor_objetos: Node2D
## Texto donde se muestran los puntos y el tiempo.
@export var etiqueta_hud: Label

# --- Estado sincronizado (lo escribe el host, lo leen todos) ---
var celda_activa := -1           # índice = fila * COLUMNAS + columna; -1 = partida sin empezar
var tiempo_para_cambio := 0.0
var puntos := {}                 # { id_jugador: puntos }

var en_curso := false            # solo se usa en el host
var tiempo_para_objeto := 0.0    # solo se usa en el host
var contador_objetos := 0        # solo se usa en el host (para darle un nombre único a cada objeto)

func _ready() -> void:
	add_to_group("partida")   # así los jugadores la encuentran para reportar golpes
	# Le decimos al spawner CÓMO armar un objeto. Esta función corre en TODAS las PCs.
	spawner_objetos.spawn_function = _crear_objeto

## Lo llama red.gd en el host al crear la partida.
func iniciar() -> void:
	en_curso = true
	tiempo_para_objeto = intervalo_objetos
	_cambiar_celda()


## Vuelve todo a cero. Lo llama red.gd cuando se corta la partida.
func reiniciar() -> void:
	en_curso = false
	celda_activa = -1
	puntos = {}
	for objeto in contenedor_objetos.get_children():
		objeto.queue_free()


func _physics_process(delta: float) -> void:
	if en_curso:
		_actualizar_reglas(delta)   # solo pasa en el host
	queue_redraw()
	_actualizar_hud()               # pasa en todas las PCs


# ---------- REGLAS (solo host) ----------

func _actualizar_reglas(delta: float) -> void:
	tiempo_para_cambio -= delta
	if tiempo_para_cambio <= 0.0:
		_cambiar_celda()
	_actualizar_objetos(delta)

	var adentro := []
	for jugador in contenedor_jugadores.get_children():
		if celda_en_posicion(jugador.position) == celda_activa:
			adentro.append(jugador)
	if solo_suma_si_esta_solo and adentro.size() > 1:
		return
	for jugador in adentro:
		var id: int = jugador.name.to_int()
		puntos[id] = puntos.get(id, 0.0) + puntos_por_segundo * delta

## Un jugador avisa "choqué a otro". Corre SOLO en el servidor, que valida y decide.
@rpc("any_peer", "call_local", "reliable")
func reportar_golpe(id_atacante: int, id_victima: int, velocidad: Vector2) -> void:
	if not multiplayer.is_server():
		return
	var atacante := contenedor_jugadores.get_node_or_null(str(id_atacante)) as Jugador
	var victima := contenedor_jugadores.get_node_or_null(str(id_victima)) as Jugador
	if atacante == null or victima == null or atacante == victima:
		return
	# Cada PC solo puede reportar golpes de SU jugador. El host además reporta los de los bots.
	var remitente := multiplayer.get_remote_sender_id()
	if remitente != id_atacante and not (remitente == 1 and atacante.es_bot):
		return

	# --- Validaciones: el servidor no se cree todo lo que le dicen ---
	if atacante.aturdido > 0.0:
		return   # un aturdido no puede pegar
	if victima.inmune > 0.0:
		return   # ya está aturdido o recién salió
	if victima.escudo > 0.0:
		return   # tiene escudo: no se lo puede golpear
	# Usamos posicion_red (el último dato real que llegó), NO position:
	# en el host, la position de un jugador remoto está interpolada y va unos píxeles atrás.
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
	if atacante.topetazo > 0.0:
		# TOPETAZO: sale disparado a full aunque el golpe no haya sido tan fuerte, y queda
		# deslizándose como bola de billar. Aturdido todo ese tiempo, así no puede frenarse saltando.
		var empuje := atacante.fuerza_maxima * fuerza_topetazo
		victima.recibir_golpe.rpc(direccion * empuje, maxf(duracion_aturdido, tiempo_lanzado), duracion_inmunidad, tiempo_lanzado)
		atacante.poner_topetazo.rpc(0.0)   # se gasta
		print("¡TOPETAZO! ", id_atacante, " → ", id_victima)
		return
	victima.recibir_golpe.rpc(direccion * rapidez * fuerza_empuje, duracion_aturdido, duracion_inmunidad, 0.0)
	print("Golpe: ", id_atacante, " → ", id_victima)

func _cambiar_celda() -> void:
	var opciones := []
	for i in Arena.COLUMNAS * Arena.FILAS:
		if celda_activa == -1 or _distancia(i, celda_activa) >= distancia_minima:
			opciones.append(i)
	celda_activa = opciones.pick_random()
	tiempo_para_cambio = duracion_celda


# ---------- OBJETOS (solo host, salvo _crear_objeto) ----------

func _actualizar_objetos(delta: float) -> void:
	# ¿Alguien pasó por encima de un objeto?
	for objeto: Objeto in contenedor_objetos.get_children():
		if objeto.is_queued_for_deletion():
			continue
		for jugador: Jugador in contenedor_jugadores.get_children():
			# posicion_red = el último dato real del jugador (ver comentario en reportar_golpe)
			if jugador.posicion_red.distance_to(objeto.position) < Jugador.RADIO + Objeto.RADIO:
				_aplicar_objeto(objeto.tipo, jugador)
				objeto.queue_free()   # el spawner lo borra también en los clientes
				break

	# ¿Toca que aparezca uno nuevo?
	tiempo_para_objeto -= delta
	if tiempo_para_objeto > 0.0:
		return
	tiempo_para_objeto = intervalo_objetos
	var cantidad := 0
	for objeto in contenedor_objetos.get_children():
		if not objeto.is_queued_for_deletion():
			cantidad += 1
	if cantidad >= max_objetos:
		return
	contador_objetos += 1
	# spawn() llama a _crear_objeto acá y en cada cliente, con los mismos datos
	spawner_objetos.spawn({
		"nombre": "Objeto%d" % contador_objetos,
		"tipo": Objeto.Tipo.values().pick_random(),
		"posicion": _lugar_para_objeto(),
	})


## Elige el centro de una celda que no sea la activa y que no esté pegada a un jugador ni a otro objeto.
func _lugar_para_objeto() -> Vector2:
	var opciones := []
	for i in Arena.COLUMNAS * Arena.FILAS:
		if i == celda_activa:
			continue
		var centro := rect_de_celda(i).get_center()
		var libre := true
		for jugador: Jugador in contenedor_jugadores.get_children():
			if jugador.posicion_red.distance_to(centro) < Arena.TAM_CELDA:
				libre = false
		for objeto: Node2D in contenedor_objetos.get_children():
			if objeto.position.distance_to(centro) < 1.0:
				libre = false
		if libre:
			opciones.append(centro)
	if opciones.is_empty():   # caso raro: todo ocupado, va a cualquier celda
		return rect_de_celda(randi() % (Arena.COLUMNAS * Arena.FILAS)).get_center()
	return opciones.pick_random()


## Aplica el efecto del objeto al jugador que lo agarró.
func _aplicar_objeto(tipo: Objeto.Tipo, jugador: Jugador) -> void:
	match tipo:
		Objeto.Tipo.ESCUDO:
			jugador.recibir_escudo.rpc(duracion_escudo)
		Objeto.Tipo.TOPETAZO:
			jugador.poner_topetazo.rpc(duracion_topetazo)
	print("El jugador ", jugador.name, " agarró: ", Objeto.Tipo.keys()[tipo])


# Corre en TODAS las PCs. Arma el objeto con los datos que mandó el host.
func _crear_objeto(datos: Dictionary) -> Node:
	var objeto := Objeto.new()
	objeto.name = datos["nombre"]
	objeto.tipo = datos["tipo"]
	objeto.position = datos["posicion"]
	return objeto


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
		var jugador := contenedor_jugadores.get_node_or_null(str(id)) as Jugador
		var nombre := jugador.nombre if jugador else "?"
		texto += "%s: %d\n" % [nombre, roundi(puntos[id])]
	etiqueta_hud.text = texto
