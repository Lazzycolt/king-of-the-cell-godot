class_name Jugador
extends CharacterBody2D

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
@export_group("Emotes")
## Las imágenes que se pueden mandar. La primera va con la tecla 1, la segunda con la 2, y así.
@export var emotes: Array[Texture2D] = []
## Cuántos segundos queda el emote arriba de la cabeza.
@export_range(0.5, 5.0, 0.5, "suffix:s") var duracion_emote := 2.0

var emote_actual := -1    # qué emote se está mostrando (-1 = ninguno)
var tiempo_emote := 0.0   # segundos que le quedan visible
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

# --- Caídas (las cambia el servidor con caer / reaparecer) ---
var caido := false            # se cayó de la arena y espera para volver
var _tiempo_cayendo := 0.0    # para la animación de caída (se achica y se desvanece)
const DURACION_ANIMACION_CAIDA := 0.6


func _enter_tree() -> void:
	# El nombre del nodo es el id del jugador dueño (lo pone red.gd).
	# Ese jugador pasa a ser la "autoridad": el único que lo controla.
	set_multiplayer_authority(name.to_int())


var _partida: Partida


func _ready() -> void:
	# El color sale del lugar (0 a 3) y la lista está en Partida.COLORES (la misma que usa la interfaz).
	color = Partida.color_de(indice)
	posicion_red = position
	_partida = get_tree().get_first_node_in_group("partida")


func _physics_process(delta: float) -> void:
	queue_redraw()
	# Los contadores bajan en todas las PCs, así todos lo dibujan igual
	aturdido = maxf(aturdido - delta, 0.0)
	inmune = maxf(inmune - delta, 0.0)
	escudo = maxf(escudo - delta, 0.0)
	topetazo = maxf(topetazo - delta, 0.0)
	lanzado = maxf(lanzado - delta, 0.0)
	tiempo_emote = maxf(tiempo_emote - delta, 0.0)
	if caido:
		_tiempo_cayendo += delta
	# Si este personaje no es mío, no leo input ni lo muevo:
	# su posición me llega por red desde la PC del dueño.
	if not is_multiplayer_authority():
		# Interpolación: en vez de saltar directo al último dato que llegó,
		# nos acercamos de a poco. Así se ve fluido aunque los datos lleguen a saltos.
		position = position.lerp(posicion_red, 1.0 - exp(-suavizado * delta))
		return
	if caido:
		# Sigue de largo hacia el vacío, sin chocar a nadie, mientras se achica
		position += velocity * delta
		velocity = velocity.move_toward(Vector2.ZERO, friccion * delta)
		posicion_red = position
		return
	if not _partida.se_puede_mover():
		# Cuenta atrás o partida terminada: quieto y sin cargar
		velocity = Vector2.ZERO
		cargando = false
		posicion_red = position
		return
	if _partida.input_bloqueado:
		cargando = false   # menú de pausa abierto: no cargo, pero sigo deslizándome
	else:
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


## El servidor la llama en TODAS las PCs al empezar la partida: lo pone en su esquina, quieto
## y sin efectos. Se aplica en todas las PCs para que las copias no "viajen" interpolando.
@rpc("any_peer", "call_local", "reliable")
func ir_a(destino: Vector2) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return   # solo el servidor (id 1) puede mover a los jugadores
	_levantar()
	position = destino
	posicion_red = destino
	velocity = Vector2.ZERO
	cargando = false
	carga = 0.0
	aturdido = 0.0
	inmune = 0.0
	escudo = 0.0
	topetazo = 0.0
	lanzado = 0.0


## El servidor la llama en TODAS las PCs cuando este jugador se sale de la arena.
@rpc("any_peer", "call_local", "reliable")
func caer() -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return   # solo el servidor (id 1) decide quién se cayó
	caido = true
	_tiempo_cayendo = 0.0
	cargando = false
	$CollisionShape2D.set_deferred("disabled", true)   # mientras cae no choca a nadie


## El servidor la llama en TODAS las PCs cuando termina el tiempo de castigo:
## vuelve a su esquina, quieto e invulnerable un rato (parpadea como con la inmunidad).
@rpc("any_peer", "call_local", "reliable")
func reaparecer(destino: Vector2, tiempo_invulnerable: float) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	_levantar()
	position = destino
	posicion_red = destino
	velocity = Vector2.ZERO
	cargando = false
	aturdido = 0.0
	lanzado = 0.0
	inmune = tiempo_invulnerable


func _levantar() -> void:
	caido = false
	_tiempo_cayendo = 0.0
	$CollisionShape2D.set_deferred("disabled", false)


## Segundos que le faltan para volver (para el cartel "¡Afuera!"). Aproximado: el que manda es el host.
func tiempo_para_volver() -> float:
	return maxf(_partida.tiempo_caido - _tiempo_cayendo, 0.0) if caido else 0.0

# ---------- EMOTES ----------

## Solo en la PC del dueño: si aprieta 1, 2, 3 o 4, les avisa a todas las PCs qué emote mostrar.
func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return   # es la bolita de otro: no leo sus teclas
	if tiempo_emote > 0.0:
		return   # todavía se ve el anterior: así nadie lo spamea
	for i in emotes.size():
		if event.is_action_pressed("emote_%d" % (i + 1)):
			mostrar_emote.rpc(i)   # mandamos SOLO el número, no la imagen
			return


## Corre en TODAS las PCs (también en la mía, por "call_local"). Muestra el emote arriba de esta bolita.
@rpc("any_peer", "call_local", "reliable")
func mostrar_emote(indice_emote: int) -> void:
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return   # solo el dueño de esta bolita le puede poner un emote
	if indice_emote < 0 or indice_emote >= emotes.size():
		return   # número que no existe: lo ignoramos
	emote_actual = indice_emote
	tiempo_emote = duracion_emote

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
	if caido:
		# Animación de caída: gira, se achica y se desvanece. Después no se dibuja.
		var k := 1.0 - _tiempo_cayendo / DURACION_ANIMACION_CAIDA
		if k <= 0.0:
			return
		draw_set_transform(Vector2.ZERO, _tiempo_cayendo * 8.0, Vector2.ONE * k)
		draw_circle(Vector2.ZERO, RADIO, Color(color, k))
		draw_arc(Vector2.ZERO, RADIO, 0, TAU, 40, Color(color.darkened(0.45), k), 3.0)
		return
	var c := color
	if aturdido > 0.0:
		c = color.darkened(0.5)
	elif inmune > 0.0 and int(inmune * 10) % 2 == 0:
		c.a = 0.4   # parpadea mientras es inmune
	draw_circle(Vector2(3, 5), RADIO, Color(0, 0, 0, 0.35))      # sombra
	draw_circle(Vector2.ZERO, RADIO, c)
	draw_circle(Vector2(-7, -8), RADIO * 0.35, Color(1, 1, 1, 0.25 * c.a))   # brillo
	draw_arc(Vector2.ZERO, RADIO, 0, TAU, 40, c.darkened(0.45), 3.0)     # borde
	_dibujar_nombre()
	_dibujar_emote()
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
			draw_circle(Vector2(cos(angulo) * 18, -RADIO - 34 + sin(angulo) * 5), 4, Color.YELLOW)   # arriba del nombre
	if cargando:
		var hacia := (get_global_mouse_position() - global_position).normalized()
		draw_line(Vector2.ZERO, hacia * (RADIO + 20 + 120 * carga), Color.WHITE, 4.0)


# El nombre (de Steam, o el del color en ENet) arriba del jugador. El mío va en dorado.
func _dibujar_nombre() -> void:
	if _partida == null:
		return
	# La cámara aplasta la vista en vertical (arena "inclinada"): estiramos el texto para que se lea derecho
	var camara := get_viewport().get_camera_2d()
	var estirar := 1.0 if camara == null else camara.zoom.x / camara.zoom.y
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, estirar))
	var nombre := _partida.nombre_jugador(name.to_int())
	var fuente := ThemeDB.fallback_font
	var tamano := 15
	var ancho := fuente.get_string_size(nombre, HORIZONTAL_ALIGNMENT_LEFT, -1, tamano).x
	var pos := Vector2(-ancho / 2, -RADIO - 10)   # arriba de la cabeza, como en el boceto
	var color_texto := Color(1.0, 0.85, 0.3) if is_multiplayer_authority() else Color.WHITE
	draw_string_outline(fuente, pos / Vector2(1.0, estirar), nombre, HORIZONTAL_ALIGNMENT_LEFT, -1, tamano, 4, Color(0, 0, 0, 0.8))
	draw_string(fuente, pos / Vector2(1.0, estirar), nombre, HORIZONTAL_ALIGNMENT_LEFT, -1, tamano, color_texto)
	draw_set_transform(Vector2.ZERO)


# El emote arriba de la cabeza (más arriba que el nombre y las estrellitas).
func _dibujar_emote() -> void:
	if tiempo_emote <= 0.0 or emote_actual < 0 or emote_actual >= emotes.size():
		return
	var ancho := 40.0
	# La cámara aplasta la vista en vertical (igual que con el nombre): lo estiramos para que se vea derecho
	var camara := get_viewport().get_camera_2d()
	var alto := ancho if camara == null else ancho * camara.zoom.x / camara.zoom.y
	var alfa := minf(tiempo_emote / 0.3, 1.0)   # se desvanece en el último ratito
	var lugar := Rect2(-ancho / 2, -RADIO - 46 - alto, ancho, alto)
	draw_texture_rect(emotes[emote_actual], lugar, false, Color(1, 1, 1, alfa))
