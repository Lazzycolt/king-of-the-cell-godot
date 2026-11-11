class_name Jugador
extends CharacterBody2D

@export_group("Apariencia")
## Color de cada jugador según el orden en que entró: 1º (host), 2º, 3º y 4º.
@export var colores: Array[Color] = [Color.RED, Color.DODGER_BLUE, Color.LIME_GREEN, Color.GOLD]

var color := Color.WHITE
## Lugar del jugador en la partida (0 a 3): decide su color y su spawn. Lo pone red.gd al crearlo.
var indice := 0

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

@export_group("Topetazo")
## Fricción mientras está "lanzado" por un topetazo (como bola de billar).[br]Más bajo = se desliza más lejos.
@export_range(0, 3000, 10, "suffix:px/s²") var friccion_lanzado := 250.0
## Rebote en paredes mientras está lanzado.[br]Cerca de 1 = rebota casi sin perder velocidad.
@export_range(0.0, 1.0, 0.05) var rebote_lanzado := 0.95

@export_group("Red")
## Qué tan rápido las copias de los OTROS jugadores alcanzan la posición que llega por red.[br]Más alto = más pegado al dato real pero más "a saltitos". Más bajo = más suave pero con más retraso.
@export_range(1.0, 40.0, 0.5) var suavizado := 15.0

const RADIO := 24.0

# Posición que viaja por la red (la escribe el dueño, la leen los demás).
# El MultiplayerSynchronizer sincroniza ESTA variable, no "position".
var posicion_red := Vector2.ZERO
var cargando := false
var carga := 0.0

# --- Golpes (los cambia el servidor con recibir_golpe; todas las PCs lo saben) ---
var aturdido := 0.0    # segundos que le quedan aturdido
var inmune := 0.0      # segundos que le quedan sin poder recibir golpes
var escudo := 0.0      # segundos que le quedan con escudo (objeto): nadie lo puede golpear
var topetazo := 0.0    # segundos que le quedan para usar el topetazo (objeto): su próximo golpe es brutal
var lanzado := 0.0     # segundos que le quedan deslizándose como bola de billar (recibió un topetazo)


func _enter_tree() -> void:
	# El nombre del nodo es el id del jugador dueño (lo pone red.gd).
	# Ese jugador pasa a ser la "autoridad": el único que lo controla.
	set_multiplayer_authority(name.to_int())


func _ready() -> void:
	# El host (id 1) es rojo y el invitado azul. Se calcula igual en todas las PCs.
	color = colores[indice % colores.size()]
	posicion_red = position


func _physics_process(delta: float) -> void:
	queue_redraw()
	# Los contadores bajan en todas las PCs, así todos lo dibujan igual
	aturdido = maxf(aturdido - delta, 0.0)
	inmune = maxf(inmune - delta, 0.0)
	escudo = maxf(escudo - delta, 0.0)
	topetazo = maxf(topetazo - delta, 0.0)
	lanzado = maxf(lanzado - delta, 0.0)
	# Si este personaje no es mío, no leo input ni lo muevo:
	# su posición me llega por red desde la PC del dueño.
	if not is_multiplayer_authority():
		# Interpolación: en vez de saltar directo al último dato que llegó,
		# nos acercamos de a poco. Así se ve fluido aunque los datos lleguen a saltos.
		position = position.lerp(posicion_red, 1.0 - exp(-suavizado * delta))
		return
	_leer_input(delta)
	_mover(delta)
	posicion_red = position   # el dueño publica su posición real


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
	# Si recibió un topetazo, casi no frena y rebota fuerte: va y viene como bola de billar
	var friccion_actual := friccion_lanzado if lanzado > 0.0 else friccion
	var rebote_actual := rebote_lanzado if lanzado > 0.0 else rebote
	velocity = velocity.move_toward(Vector2.ZERO, friccion_actual * delta)
	var choque := move_and_collide(velocity * delta)
	if choque == null:
		return
	var otro := choque.get_collider()
	if otro is Jugador:
		# Choqué a otro jugador: le aviso al servidor y él decide si cuenta como golpe
		var partida := get_tree().get_first_node_in_group("partida")
		partida.reportar_golpe.rpc_id(1, otro.name.to_int(), velocity)
		# Le "pasé" mi velocidad: yo casi me freno
		velocity = velocity.bounce(choque.get_normal()) * 0.2
	else:
		# Pared: rebote normal
		velocity = velocity.bounce(choque.get_normal()) * rebote_actual


## El servidor la llama en TODAS las PCs cuando este jugador recibe un golpe válido.
## tiempo_lanzado > 0 = fue un topetazo: se desliza como bola de billar ese tiempo.
@rpc("any_peer", "call_local", "reliable")
func recibir_golpe(impulso: Vector2, tiempo_aturdido: float, tiempo_inmune: float, tiempo_lanzado: float) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return   # solo el servidor (id 1) puede mandar golpes
	aturdido = tiempo_aturdido
	inmune = tiempo_aturdido + tiempo_inmune
	lanzado = tiempo_lanzado
	cargando = false
	if is_multiplayer_authority():
		velocity = impulso   # solo el dueño mueve su personaje


## El servidor la llama en TODAS las PCs cuando este jugador agarra un escudo.
@rpc("any_peer", "call_local", "reliable")
func recibir_escudo(duracion: float) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return   # solo el servidor (id 1) puede dar objetos
	escudo = maxf(escudo, duracion)   # si agarra otro, se renueva (no se suma)


## El servidor la llama en TODAS las PCs: da el topetazo (duracion > 0) o lo gasta (duracion = 0).
@rpc("any_peer", "call_local", "reliable")
func poner_topetazo(duracion: float) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return   # solo el servidor (id 1) puede dar objetos
	topetazo = duracion


func _draw() -> void:
	var c := color
	if aturdido > 0.0:
		c = color.darkened(0.5)
	elif inmune > 0.0 and int(inmune * 10) % 2 == 0:
		c.a = 0.4   # parpadea mientras es inmune
	draw_circle(Vector2.ZERO, RADIO, c)
	if escudo > 0.0:
		# Anillo celeste. El último segundo y medio parpadea para avisar que se termina.
		if escudo > 1.5 or int(escudo * 8) % 2 == 0:
			draw_arc(Vector2.ZERO, RADIO + 7, 0, TAU, 40, Color(0.3, 0.9, 1.0), 4.0)
	if topetazo > 0.0:
		# Pinchos naranjas que laten. El último segundo y medio parpadean.
		if topetazo > 1.5 or int(topetazo * 8) % 2 == 0:
			var latido := 1.0 + sin(Time.get_ticks_msec() / 80.0) * 0.15
			for i in 8:
				var dir := Vector2.from_angle(i * TAU / 8)
				draw_line(dir * (RADIO + 3), dir * (RADIO + 12) * latido, Color(1.0, 0.5, 0.1), 4.0)
	if aturdido > 0.0:
		# "Estrellitas" girando arriba de la cabeza
		var giro := Time.get_ticks_msec() / 150.0
		for i in 3:
			var angulo := giro + i * TAU / 3
			draw_circle(Vector2(cos(angulo) * 18, -RADIO - 8 + sin(angulo) * 5), 4, Color.YELLOW)
	if cargando:
		var hacia := (get_global_mouse_position() - global_position).normalized()
		draw_line(Vector2.ZERO, hacia * (RADIO + 20 + 120 * carga), Color.WHITE, 4.0)
