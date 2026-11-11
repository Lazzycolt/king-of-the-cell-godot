class_name Partida
extends Node2D
## Reglas de la partida. Solo el HOST las calcula; los clientes reciben el resultado
## por el MultiplayerSynchronizer y lo dibujan.
## La partida pasa por 4 estados: LOBBY → CUENTA_ATRAS → JUGANDO → FINALIZADO.

## Avisa cuando cambia el estado (en todas las PCs: en los clientes, cuando llega por red).
signal estado_cambiado(nuevo: Estado)
## Avisa que llegó el ranking final (en todas las PCs, por RPC confiable).
signal resultados_listos(filas: Array)

enum Estado { LOBBY, CUENTA_ATRAS, JUGANDO, FINALIZADO }

@export_group("Ronda")
## Duración de la ronda. Con el tiempo en 0 se termina la partida.
@export_range(30, 900, 10, "suffix:s") var duracion_ronda := 300.0
## Segundos de cuenta atrás antes de empezar (los jugadores esperan en su esquina).
@export_range(1, 10, 1, "suffix:s") var duracion_cuenta_atras := 3.0
## Jugadores necesarios para que el host pueda iniciar.
@export_range(1, 4, 1) var minimo_jugadores := 2
## Si a mitad de partida se corta alguien y queda uno solo, cuántos segundos se espera a que vuelva
## antes de terminar (la ronda queda en pausa mientras tanto). 0 = se termina enseguida.
@export_range(0, 120, 5, "suffix:s") var espera_reconexion := 30.0

@export_group("Reglas")
## Segundos que la celda se queda en un lugar antes de saltar a otro.
@export_range(5, 120, 1, "suffix:s") var duracion_celda := 30.0
## Puntos que suma por segundo quien está en la celda activa.
@export_range(1, 100, 1, "suffix:pts/s") var puntos_por_segundo := 10.0
## Si está activado, cuando hay 2 o más jugadores en la celda nadie suma (obliga a empujar).
@export var solo_suma_si_esta_solo := true
## Distancia mínima (en celdas) entre la celda vieja y la nueva.
@export_range(1, 4, 1) var distancia_minima := 2

@export_group("Caídas")
## Activado: la arena tiene paredes y nadie se cae (como antes).[br]Desactivado: no hay paredes y el que sale de la grilla se cae.
@export var con_paredes := false
## Segundos que el que se cayó queda afuera antes de volver a su esquina.
@export_range(1, 15, 0.5, "suffix:s") var tiempo_caido := 5.0
## Segundos de invulnerabilidad al volver (nadie lo puede golpear).
@export_range(0, 5, 0.5, "suffix:s") var invulnerable_al_volver := 2.0

@export_group("Golpes")
## Activado: el que sale volando por un golpe empuja a los que choca en el camino.
@export var empuje_en_cadena := true
## Qué parte de su velocidad le pasa el que va volando al siguiente (menos de 1 = la cadena se apaga sola).
@export_range(0.1, 1.0, 0.05) var fuerza_cadena := 0.7
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
## Las paredes de la arena. Se apagan si 'con_paredes' está desactivado.
@export var paredes: StaticBody2D
## Puntos de aparición (los mismos que usa red.gd). Al empezar, cada uno vuelve al suyo.
@export var spawns: Array[Marker2D]

# --- Estado sincronizado (lo escribe el host, lo leen todos) ---
var celda_activa := -1           # índice = fila * COLUMNAS + columna; -1 = sin celda (no se está jugando)
var tiempo_para_cambio := 0.0
var puntos := {}                 # { id_jugador: puntos }
var jugadores := {}              # { id_jugador: indice }  el indice (0 a 3) decide color y nombre
var nombres := {}                # { id_jugador: nombre de Steam }  (vacío en ENet: se usa el del color)
var tiempo_en_celda := {}        # { id_jugador: segundos } dentro de la celda (aunque esté compartida). Desempate.
var tiempo_restante := 0.0       # segundos que le quedan a la ronda
var cuenta_atras := 0.0          # segundos que le quedan a la cuenta atrás
var esperando := 0.0             # > 0: quedó uno solo y se espera a que vuelva el que se cortó (ronda en pausa)
var estado := Estado.LOBBY:
	set(nuevo):
		if nuevo == estado:
			return   # el synchronizer lo escribe todo el tiempo: solo avisamos si cambió de verdad
		estado = nuevo
		estado_cambiado.emit(nuevo)

## Nombres que se muestran en el HUD, en el mismo orden que los colores.
const NOMBRES := ["Rojo", "Azul", "Verde", "Amarillo"]
## Color de cada jugador según su lugar (0 a 3). Lo usan jugador.gd y la interfaz.
const COLORES: Array[Color] = [Color.RED, Color.DODGER_BLUE, Color.LIME_GREEN, Color.GOLD]

## Ranking final que mandó el host (vacío mientras no terminó la partida).
## Cada fila: { id, indice, puntos, tiempo, salio }
var resultado: Array = []
## Lo pone la interfaz cuando el menú de pausa está abierto: el jugador local no carga el salto.
var input_bloqueado := false

var soy_host := false            # lo pone red.gd. Solo el host corre las reglas.
var tiempo_para_objeto := 0.0    # solo se usa en el host
var _reaparicion := {}           # solo host: { id_jugador: segundos que le faltan para volver }
var _gracia := {}                # solo host: { id_jugador: segundos } recién volvió, todavía no se puede caer
## Margen después de volver: por la red pueden llegar datos viejos (de cuando estaba afuera).
const GRACIA_AL_VOLVER := 0.5
var contador_objetos := 0        # solo se usa en el host (para darle un nombre único a cada objeto)

func _ready() -> void:
	add_to_group("partida")   # así los jugadores la encuentran para reportar golpes
	# Paredes: se prenden o apagan igual en todas las PCs (la escena es la misma en todas)
	for forma in paredes.get_children():
		forma.disabled = not con_paredes
	if get_parent() is Arena:
		get_parent().con_paredes = con_paredes   # para dibujar el borde como "peligro"
	# Le decimos al spawner CÓMO armar un objeto. Esta función corre en TODAS las PCs.
	spawner_objetos.spawn_function = _crear_objeto


## Lo llama red.gd en el host al crear la sala: queda en el lobby esperando jugadores.
func abrir_lobby() -> void:
	reiniciar()
	soy_host = true


## Vuelve todo a cero. Lo llama red.gd al volver al menú (en el host y en los clientes).
func reiniciar() -> void:
	soy_host = false
	estado = Estado.LOBBY
	celda_activa = -1
	tiempo_para_cambio = 0.0
	tiempo_restante = 0.0
	cuenta_atras = 0.0
	esperando = 0.0
	puntos = {}
	tiempo_en_celda = {}
	jugadores = {}
	nombres = {}
	resultado = []
	input_bloqueado = false
	_reaparicion = {}
	_gracia = {}
	_borrar_objetos()


## ¿Los jugadores pueden moverse y cargar el salto? En la cuenta atrás y al final, no.
func se_puede_mover() -> bool:
	return estado == Estado.LOBBY or estado == Estado.JUGANDO


func _physics_process(delta: float) -> void:
	if soy_host:
		_actualizar_host(delta)     # solo pasa en el host
	queue_redraw()                  # la celda se dibuja en todas las PCs (el HUD está en hud.gd)


# ---------- ESTADOS (solo host) ----------

## El host tocó "Iniciar". Devuelve false si todavía no se puede.
func empezar() -> bool:
	if not soy_host or estado != Estado.LOBBY:
		return false
	var en_sala := jugadores_conectados()
	if en_sala.size() < minimo_jugadores:
		return false
	puntos = {}
	tiempo_en_celda = {}
	celda_activa = -1
	esperando = 0.0
	_reaparicion = {}   # ir_a también levanta a los que estaban caídos
	_borrar_objetos()
	# Cada uno vuelve a su esquina. La posición la controla el dueño, así que se lo pedimos por RPC.
	for jugador: Jugador in en_sala:
		jugador.ir_a.rpc(spawns[jugador.indice].global_position)
	cuenta_atras = duracion_cuenta_atras
	estado = Estado.CUENTA_ATRAS
	return true


func _actualizar_host(delta: float) -> void:
	if estado == Estado.LOBBY or estado == Estado.JUGANDO:
		_actualizar_caidas(delta)   # en el lobby también: sirve para practicar
	match estado:
		Estado.CUENTA_ATRAS:
			cuenta_atras = maxf(cuenta_atras - delta, 0.0)
			if cuenta_atras <= 0.0:
				_arrancar_ronda()
		Estado.JUGANDO:
			if esperando > 0.0:
				# Quedó uno solo: la ronda no avanza hasta que vuelva alguien o se acabe la espera
				esperando = maxf(esperando - delta, 0.0)
				if esperando <= 0.0:
					_finalizar()
				return
			tiempo_restante = maxf(tiempo_restante - delta, 0.0)
			_actualizar_reglas(delta)
			if tiempo_restante <= 0.0:
				_finalizar()


func _arrancar_ronda() -> void:
	tiempo_restante = duracion_ronda
	tiempo_para_objeto = intervalo_objetos
	_cambiar_celda()
	estado = Estado.JUGANDO


## Se acabó (por tiempo o porque quedó uno solo). Arma el ranking y se lo manda a todos.
func _finalizar() -> void:
	esperando = 0.0
	estado = Estado.FINALIZADO
	var filas := []
	for id in jugadores:
		var sigue := _esta_conectado(id)
		var pts := roundi(puntos.get(id, 0.0))
		if not sigue and pts == 0:
			continue   # se fue sin puntos: no aparece
		filas.append({
			"id": id,
			"indice": jugadores[id],
			"nombre": nombre_jugador(id),
			"puntos": pts,
			"tiempo": snappedf(tiempo_en_celda.get(id, 0.0), 0.1),
			"salio": not sigue,
		})
	filas.sort_custom(_va_antes)
	mostrar_resultados.rpc(filas)


## Orden del ranking: primero los que siguen conectados, después más puntos y,
## si empatan en puntos, más tiempo dentro de la celda (desempate del GDD).
static func _va_antes(a: Dictionary, b: Dictionary) -> bool:
	if a["salio"] != b["salio"]:
		return not a["salio"]
	if a["puntos"] != b["puntos"]:
		return a["puntos"] > b["puntos"]
	return a["tiempo"] > b["tiempo"]


## El host la llama en TODAS las PCs con el ranking final. Así todos ven exactamente lo mismo.
@rpc("authority", "call_local", "reliable")
func mostrar_resultados(filas: Array) -> void:
	resultado = filas
	resultados_listos.emit(filas)


## Lo llama red.gd en el host cuando se va un jugador (su nodo ya está marcado para borrarse).
## puede_volver = se cortó o salió (no fue expulsado): sus puntos lo esperan por si reconecta.
func jugador_salio(id: int, puede_volver := false) -> void:
	if not soy_host:
		return
	match estado:
		Estado.LOBBY:
			jugadores.erase(id)   # en el lobby no tiene puntos: lo sacamos de la lista
			nombres.erase(id)
		Estado.CUENTA_ATRAS:
			jugadores.erase(id)
			nombres.erase(id)
			if jugadores_conectados().size() < minimo_jugadores:
				estado = Estado.LOBBY   # no da para empezar: volvemos a esperar
		Estado.JUGANDO:
			# Sus puntos quedan en la tabla (y los recupera si vuelve). Si queda uno solo,
			# se espera un rato a que vuelva; si no puede volver, se termina.
			if jugadores_conectados().size() < 2:
				if puede_volver and espera_reconexion > 0.0:
					esperando = espera_reconexion
				else:
					_finalizar()


## RECONEXIÓN (clase 14, paso 8). Lo llama red.gd en el host cuando vuelve alguien que se había
## ido a mitad de partida. Volvió con OTRO id de conexión, así que le pasamos lo que tenía el id viejo.
func reincorporar(id_viejo: int, id_nuevo: int) -> void:
	if not soy_host:
		return
	for tabla: Dictionary in [puntos, tiempo_en_celda]:
		if tabla.has(id_viejo):
			tabla[id_nuevo] = tabla[id_viejo]
			tabla.erase(id_viejo)
	jugadores.erase(id_viejo)   # su lugar nuevo ya lo anotó red.gd en jugadores[id_nuevo]
	nombres.erase(id_viejo)
	if jugadores_conectados().size() >= 2:
		esperando = 0.0   # volvió: sigue la ronda


# ---------- CAÍDAS (solo host) ----------

func _actualizar_caidas(delta: float) -> void:
	if con_paredes:
		return
	for id in _gracia.keys():
		_gracia[id] -= delta
		if _gracia[id] <= 0.0:
			_gracia.erase(id)
	for jugador: Jugador in jugadores_conectados():
		var id := jugador.name.to_int()
		if _gracia.has(id):
			continue
		if jugador.caido:
			# Esperando para volver
			_reaparicion[id] = _reaparicion.get(id, tiempo_caido) - delta
			if _reaparicion[id] <= 0.0:
				_reaparicion.erase(id)
				_gracia[id] = GRACIA_AL_VOLVER
				jugador.reaparecer.rpc(spawns[jugador.indice].global_position, invulnerable_al_volver)
		elif celda_en_posicion(jugador.posicion_red) == -1:
			# Su centro salió de la grilla: se cayó. Usamos posicion_red (el dato real del dueño).
			_reaparicion[id] = tiempo_caido
			jugador.caer.rpc()
			print("Se cayó el jugador ", id)


## Los jugadores que están en la arena (sin contar los que se están borrando).
func jugadores_conectados() -> Array:
	var lista := []
	for jugador in contenedor_jugadores.get_children():
		if not jugador.is_queued_for_deletion():
			lista.append(jugador)
	return lista


func _esta_conectado(id: int) -> bool:
	var jugador := contenedor_jugadores.get_node_or_null(str(id))
	return jugador != null and not jugador.is_queued_for_deletion()


func _borrar_objetos() -> void:
	for objeto in contenedor_objetos.get_children():
		objeto.queue_free()


# ---------- REGLAS (solo host, mientras se juega) ----------

func _actualizar_reglas(delta: float) -> void:
	tiempo_para_cambio -= delta
	if tiempo_para_cambio <= 0.0:
		_cambiar_celda()
	_actualizar_objetos(delta)

	var adentro := []
	for jugador: Jugador in jugadores_conectados():
		if not jugador.caido and celda_en_posicion(jugador.position) == celda_activa:
			adentro.append(jugador)
	# El tiempo en la celda cuenta siempre, aunque esté compartida: sirve para desempatar.
	# (Los puntos solos no alcanzan: con 'solo_suma_si_esta_solo' son tiempo-solo × puntos/s,
	# así que si dos empatan en puntos también empatan en tiempo-solo.)
	for jugador in adentro:
		var id: int = jugador.name.to_int()
		tiempo_en_celda[id] = tiempo_en_celda.get(id, 0.0) + delta
	if solo_suma_si_esta_solo and adentro.size() > 1:
		return
	for jugador in adentro:
		var id: int = jugador.name.to_int()
		puntos[id] = puntos.get(id, 0.0) + puntos_por_segundo * delta

## Un jugador avisa "choqué a otro". Corre SOLO en el servidor, que valida y decide.
@rpc("any_peer", "call_local", "reliable")
func reportar_golpe(id_victima: int, velocidad: Vector2) -> void:
	if not soy_host or estado != Estado.JUGANDO:
		return   # en el lobby o con la partida terminada no hay golpes
	var id_atacante := multiplayer.get_remote_sender_id()
	var atacante := contenedor_jugadores.get_node_or_null(str(id_atacante)) as Jugador
	var victima := contenedor_jugadores.get_node_or_null(str(id_victima)) as Jugador
	if atacante == null or victima == null or atacante == victima:
		return
	if atacante.caido or victima.caido:
		return   # los que se están cayendo ya no cuentan

	# --- Validaciones: el servidor no se cree todo lo que le dicen ---
	# Un aturdido no puede saltar, así que si viene rápido es porque lo golpearon y va volando:
	# con 'empuje_en_cadena' le pasa parte de esa velocidad al que choca.
	var en_cadena := atacante.aturdido > 0.0
	if en_cadena and not empuje_en_cadena:
		return   # un aturdido no puede pegar
	if victima.inmune > 0.0:
		return   # ya está aturdido o recién salió
	if victima.escudo > 0.0:
		return   # tiene escudo: no se lo puede golpear
	if velocidad.length() < velocidad_minima_golpe:
		return   # fue un roce, no un golpe
	# Usamos posicion_red (el último dato real que llegó), NO position:
	# en el host, la position de un jugador remoto está interpolada y va unos píxeles atrás.
	if atacante.posicion_red.distance_to(victima.posicion_red) > distancia_maxima_golpe:
		print("Golpe rechazado: están demasiado lejos (", id_atacante, " → ", id_victima, ")")
		return
	# Nadie puede ir más rápido que el salto máximo (un poco de margen).
	# El que va volando puede ir más rápido (un topetazo lo lanza a fuerza_topetazo × salto máximo).
	var tope := atacante.fuerza_maxima * (maxf(fuerza_topetazo, 1.0) if en_cadena else 1.0) * 1.1
	var rapidez := minf(velocidad.length(), tope)

	# --- Golpe válido: se lo aplicamos a la víctima en todas las PCs ---
	var direccion := (victima.posicion_red - atacante.posicion_red).normalized()
	if en_cadena:
		# EMPUJE EN CADENA: pasa una parte de su velocidad. Cada eslabón pierde fuerza y la cadena se apaga.
		# La inmunidad del golpeado evita que dos se golpeen de ida y vuelta sin parar.
		victima.recibir_golpe.rpc(direccion * rapidez * fuerza_cadena, duracion_aturdido, duracion_inmunidad, 0.0)
		print("Golpe en cadena: ", id_atacante, " → ", id_victima)
		return
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
		for jugador: Jugador in jugadores_conectados():
			if jugador.caido:
				continue
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
		for jugador: Jugador in jugadores_conectados():
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


static func nombre_de(indice: int) -> String:
	return NOMBRES[indice % NOMBRES.size()]


## El nombre de Steam del jugador; si no hay (modo ENet), el de su color.
func nombre_jugador(id: int) -> String:
	var nombre: String = nombres.get(id, "")
	if nombre == "":
		return nombre_de(jugadores.get(id, 0))
	return nombre


static func color_de(indice: int) -> Color:
	return COLORES[indice % COLORES.size()]


# ---------- DIBUJO (todas las PCs) ----------

func _draw() -> void:
	if celda_activa == -1 or estado != Estado.JUGANDO:
		return
	var color := Color(1.0, 0.8, 0.1)   # dorado
	# "Respira" suave para llamar la atención
	var pulso := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 250.0)
	var relleno := 0.35 + 0.15 * pulso
	# Los últimos 5 segundos parpadea para avisar que se va a mover
	if tiempo_para_cambio < 5.0 and int(tiempo_para_cambio * 4) % 2 == 0:
		relleno = 0.1
	var rect := rect_de_celda(celda_activa)
	draw_rect(rect.grow(-4), Color(color, relleno))
	draw_rect(rect.grow(-4), Color(color, 0.9), false, 4.0)
	draw_rect(rect.grow(-4 + 4 * pulso), Color(color, 0.25 * (1.0 - pulso)), false, 3.0)   # onda hacia afuera
	# Rayado en diagonal, como en el boceto de la "celda objetivo"
	var interior := rect.grow(-10)
	for i in range(1, 8):
		var d := interior.size.x * i / 8.0
		draw_line(interior.position + Vector2(d, 0), interior.position + Vector2(0, d), Color(color, 0.35), 2.0)
		draw_line(interior.end - Vector2(d, 0), interior.end - Vector2(0, d), Color(color, 0.35), 2.0)
