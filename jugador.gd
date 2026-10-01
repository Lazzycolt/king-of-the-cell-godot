class_name Jugador
extends CharacterBody2D

@export_group("Apariencia")
## Color del jugador que crea la partida.
@export var color_host := Color.RED
## Color del jugador que se une.
@export var color_invitado := Color.DODGER_BLUE

var color := Color.WHITE

@export_group("Salto")
## Velocidad con la que sale si soltás el click enseguida (píxeles por segundo).
@export_range(0, 2000, 10, "suffix:px/s") var fuerza_minima := 250.0
## Velocidad con la que sale con la carga completa.[br]Más alto = llega más lejos.
@export_range(0, 3000, 10, "suffix:px/s") var fuerza_maxima := 1100.0
## Segundos que hay que mantener el click para cargar al 100 %.
@export_range(0.1, 3.0, 0.05, "suffix:s") var tiempo_carga := 1.0

@export_group("Deslizamiento")
## Cuánta velocidad pierde por segundo mientras se desliza.[br]Más alto = frena antes.
@export_range(0, 3000, 10, "suffix:px/s²") var friccion := 900.0
## Qué parte de la velocidad conserva al chocar una pared.[br]0 = se clava, 1 = rebota sin perder nada.
@export_range(0.0, 1.0, 0.05) var rebote := 0.7

@export_group("Red")
## Qué tan rápido las copias de los OTROS jugadores alcanzan la posición que llega por red.[br]Más alto = más pegado al dato real pero más "a saltitos". Más bajo = más suave pero con más retraso.
@export_range(1.0, 40.0, 0.5) var suavizado := 15.0

const RADIO := 24.0
## Cada cuánto el dueño reenvía su posición aunque no haya cambiado
## (los envíos de posición no son "reliable": si justo se pierde el último, esto lo corrige).
const REENVIO_POSICION := 0.5

# --- Datos que pone red.gd antes de agregarlo a la escena (iguales en todas las PCs) ---
var id_dueno := -1     # id de GD-Sync del jugador que lo controla
var indice := 0        # 0 = el host (rojo, Spawn1), 1 = el invitado (azul, Spawn2)
var _reenvio := 0.0

# Posición que viaja por la red (la escribe el dueño, la leen los demás).
# El PropertySynchronizer (GD-Sync) sincroniza ESTA variable, no "position".
var posicion_red := Vector2.ZERO
var cargando := false
var carga := 0.0

# --- Golpes (los cambia el servidor con recibir_golpe; todas las PCs lo saben) ---
var aturdido := 0.0    # segundos que le quedan aturdido
var inmune := 0.0      # segundos que le quedan sin poder recibir golpes


func _ready() -> void:
	color = color_host if indice == 0 else color_invitado
	posicion_red = position
	# Solo el dueño manda su posición; en las otras PCs el synchronizer solo recibe
	# (≈ la "autoridad" del MultiplayerSynchronizer).
	$PropertySynchronizer.broadcast = PropertySynchronizer.BROADCAST_MODE.ALWAYS if es_mio() \
			else PropertySynchronizer.BROADCAST_MODE.NEVER
	# Permitimos que recibir_golpe se llame por red, pero SOLO si lo llama el host (≈ @rpc + chequeo de id 1)
	GDSync.expose_func(recibir_golpe, ENUMS.EXPOSE_PERMISSION.HOST)


## true si este personaje lo controlo yo (≈ is_multiplayer_authority()).
func es_mio() -> bool:
	return id_dueno != -1 and id_dueno == GDSync.get_client_id()


func _physics_process(delta: float) -> void:
	queue_redraw()
	# Los contadores bajan en todas las PCs, así todos lo dibujan igual
	aturdido = maxf(aturdido - delta, 0.0)
	inmune = maxf(inmune - delta, 0.0)
	# Si este personaje no es mío, no leo input ni lo muevo:
	# su posición me llega por red desde la PC del dueño.
	if not es_mio():
		# Interpolación: en vez de saltar directo al último dato que llegó,
		# nos acercamos de a poco. Así se ve fluido aunque los datos lleguen a saltos.
		position = position.lerp(posicion_red, 1.0 - exp(-suavizado * delta))
		return
	_leer_input(delta)
	_mover(delta)
	posicion_red = position   # el dueño publica su posición real (la manda el PropertySynchronizer)
	_reenvio -= delta
	if _reenvio <= 0.0:
		_reenvio = REENVIO_POSICION
		$PropertySynchronizer.synchronize(true)


func _leer_input(delta: float) -> void:
	if aturdido > 0.0:
		cargando = false   # aturdido no puede cargar ni saltar
		return
	if Input.is_action_just_pressed("cargar"):
		cargando = true
		carga = 0.0
	if cargando:
		carga = minf(carga + delta / tiempo_carga, 1.0)
		if Input.is_action_just_released("cargar"):
			_soltar()


func _soltar() -> void:
	cargando = false
	var direccion := (get_global_mouse_position() - global_position).normalized()
	velocity = direccion * lerpf(fuerza_minima, fuerza_maxima, carga)


func _mover(delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, friccion * delta)
	var choque := move_and_collide(velocity * delta)
	if choque == null:
		return
	var otro := choque.get_collider()
	if otro is Jugador:
		# Choqué a otro jugador: le aviso al servidor y él decide si cuenta como golpe
		var partida := get_tree().get_first_node_in_group("partida")
		partida.pedir_golpe(otro.id_dueno, velocity)
		# Le "pasé" mi velocidad: yo casi me freno
		velocity = velocity.bounce(choque.get_normal()) * 0.2
	else:
		# Pared: rebote normal
		velocity = velocity.bounce(choque.get_normal()) * rebote


## El host la llama en TODAS las PCs (GDSync.call_func_all) cuando este jugador recibe un golpe válido.
## Solo el host puede llamarla por red: lo controla expose_func con permiso HOST (ver _ready).
func recibir_golpe(impulso: Vector2, tiempo_aturdido: float, tiempo_inmune: float) -> void:
	aturdido = tiempo_aturdido
	inmune = tiempo_aturdido + tiempo_inmune
	cargando = false
	if es_mio():
		velocity = impulso   # solo el dueño mueve su personaje


func _draw() -> void:
	var c := color
	if aturdido > 0.0:
		c = color.darkened(0.5)
	elif inmune > 0.0 and int(inmune * 10) % 2 == 0:
		c.a = 0.4   # parpadea mientras es inmune
	draw_circle(Vector2.ZERO, RADIO, c)
	if aturdido > 0.0:
		# "Estrellitas" girando arriba de la cabeza
		var giro := Time.get_ticks_msec() / 150.0
		for i in 3:
			var angulo := giro + i * TAU / 3
			draw_circle(Vector2(cos(angulo) * 18, -RADIO - 8 + sin(angulo) * 5), 4, Color.YELLOW)
	if cargando:
		var hacia := (get_global_mouse_position() - global_position).normalized()
		draw_line(Vector2.ZERO, hacia * (RADIO + 20 + 120 * carga), Color.WHITE, 4.0)
