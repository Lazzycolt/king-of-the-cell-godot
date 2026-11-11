extends CanvasLayer
## Pantallas de la partida: lobby, cuenta atrás, resultados y menú de pausa (Esc).
## Solo MUESTRA cosas: las decisiones las toman partida.gd (el host) y red.gd.

@export_group("Referencias")
@export var partida: Partida
## El nodo Red (código de sala, si somos host, salir al menú...).
@export var red: Node

@export_group("Lobby")
@export var panel_lobby: Control
@export var etiqueta_sala: Label
## Acá se agrega un texto por jugador, con su color.
@export var lista_lobby: VBoxContainer
@export var boton_iniciar: Button
@export var etiqueta_lobby: Label

@export_group("Cuenta atrás")
## Texto grande en el centro: 3, 2, 1, ¡YA!
@export var aviso: Label

@export_group("Resultados")
@export var panel_resultados: Control
@export var etiqueta_ganador: Label
## Tabla de 4 columnas (puesto, nombre, puntos, tiempo): una fila por jugador, del primero al último.
@export var lista_resultados: GridContainer
@export var boton_volver: Button

@export_group("Pausa")
@export var panel_pausa: Control
@export var etiqueta_pausa: Label
@export var boton_seguir: Button
@export var boton_salir: Button

@export_group("Jugadores (host)")
## Panel que abre el host con Tab: lista de jugadores con un botón "Expulsar" cada uno.
@export var panel_expulsar: Control
@export var lista_expulsar: VBoxContainer

@export_group("Avisos")
## Acá aparecen los avisos para todos ("X entró", "X se fue"...) y se desvanecen solos.
@export var lista_avisos: VBoxContainer
## Cuántos segundos queda cada aviso en pantalla.
@export_range(1.0, 10.0, 0.5, "suffix:s") var duracion_aviso := 3.5

var _lobby_dibujado := ""   # para no rearmar la lista del lobby en cada frame
var _aviso_anterior := ""   # para animar el aviso solo cuando cambia (3 → 2 → 1 → ¡YA!)
var _expulsar_dibujado := "" # para no rearmar la lista de expulsar en cada frame


func _ready() -> void:
	boton_iniciar.pressed.connect(red.iniciar_partida)
	boton_volver.pressed.connect(red.salir_al_menu)
	boton_seguir.pressed.connect(panel_pausa.hide)
	boton_salir.pressed.connect(_salir_desde_pausa)
	partida.resultados_listos.connect(_armar_resultados)
	red.aviso.connect(_mostrar_aviso)
	panel_expulsar.hide()
	panel_lobby.hide()
	panel_resultados.hide()
	panel_pausa.hide()
	aviso.text = ""


func _process(_delta: float) -> void:
	var en_sala: bool = red.esta_en_sala()
	# Con el panel de expulsar abierto, el lobby se oculta para que no se mezclen
	panel_lobby.visible = en_sala and partida.estado == Partida.Estado.LOBBY and not panel_expulsar.visible
	if panel_lobby.visible:
		_actualizar_lobby()
	else:
		_lobby_dibujado = ""
	# Los resultados quedan a la vista aunque el host ya se haya ido, hasta tocar "Volver al menú"
	panel_resultados.visible = not partida.resultado.is_empty()
	if not en_sala:
		panel_pausa.hide()
	# El panel de expulsar es solo del host, y solo con una sala abierta
	if not en_sala or not red.soy_host():
		panel_expulsar.hide()
	if panel_expulsar.visible:
		_actualizar_expulsar()
	partida.input_bloqueado = panel_pausa.visible or panel_expulsar.visible
	_actualizar_aviso(en_sala)


# Esc abre y cierra el menú de pausa (solo si estamos en una sala).
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and red.esta_en_sala():
		panel_pausa.visible = not panel_pausa.visible
		if red.soy_host():
			etiqueta_pausa.text = "Sos el host: si salís, se cierra la sala para todos."
		else:
			etiqueta_pausa.text = "Si salís, la partida sigue para los demás."
		get_viewport().set_input_as_handled()


# Tab abre y cierra la lista de jugadores del host. Va en _input (no en _unhandled_input)
# porque si un botón tiene el foco, la interfaz se "come" el Tab para pasar al siguiente.
func _input(event: InputEvent) -> void:
	var tecla := event as InputEventKey
	if tecla == null or not tecla.pressed or tecla.echo or tecla.keycode != KEY_TAB:
		return
	if not red.esta_en_sala() or not red.soy_host():
		return   # expulsar es una decisión del host: a los clientes ni les aparece
	panel_expulsar.visible = not panel_expulsar.visible
	_expulsar_dibujado = ""
	get_viewport().set_input_as_handled()


func _salir_desde_pausa() -> void:
	panel_pausa.hide()
	red.salir_al_menu()


# ---------- LOBBY ----------

func _actualizar_lobby() -> void:
	var cantidad := partida.jugadores.size()
	var soy_host: bool = red.soy_host()
	etiqueta_sala.text = "Sala: %s" % red.codigo_sala if red.codigo_sala != "" else "Partida por IP (ENet)"
	boton_iniciar.visible = soy_host
	boton_iniciar.disabled = cantidad < partida.minimo_jugadores
	if not soy_host:
		etiqueta_lobby.text = "Esperando a que el host inicie la partida..."
	elif cantidad < partida.minimo_jugadores:
		etiqueta_lobby.text = "Hacen falta al menos %d jugadores para empezar." % partida.minimo_jugadores
	else:
		etiqueta_lobby.text = "¡Listo! Tocá Iniciar cuando estén todos.\n(Tab: ver jugadores y expulsar)"

	# La lista se rearma solo si cambió quién está
	var clave := str(partida.jugadores) + str(partida.nombres)
	if clave == _lobby_dibujado:
		return
	_lobby_dibujado = clave
	for hijo in lista_lobby.get_children():
		hijo.queue_free()
	var mi_id := multiplayer.get_unique_id()
	for id in partida.jugadores:
		var indice: int = partida.jugadores[id]
		var texto := "● " + partida.nombre_jugador(id)
		if id == 1:
			texto += "  (host)"
		if id == mi_id:
			texto += "  (vos)"
		lista_lobby.add_child(_etiqueta(texto, Partida.color_de(indice), 20))


# ---------- CUENTA ATRÁS ----------

func _actualizar_aviso(en_sala: bool) -> void:
	var yo: Jugador = null
	if en_sala:   # sin conexión no tenemos id propio
		yo = partida.contenedor_jugadores.get_node_or_null(str(multiplayer.get_unique_id())) as Jugador
	if not en_sala:
		aviso.text = ""
	elif yo != null and yo.caido and partida.estado != Partida.Estado.FINALIZADO:
		aviso.text = "¡Afuera!\n%d" % maxi(ceili(yo.tiempo_para_volver()), 1)
	elif partida.estado == Partida.Estado.CUENTA_ATRAS:
		aviso.text = str(maxi(ceili(partida.cuenta_atras), 1))
	elif partida.estado == Partida.Estado.JUGANDO and partida.tiempo_restante > partida.duracion_ronda - 1.0:
		aviso.text = "¡YA!"   # el primer segundo de la ronda
	else:
		aviso.text = ""
	if aviso.text != _aviso_anterior:
		_aviso_anterior = aviso.text
		if aviso.text != "":
			_animar_aviso()


# Cada número "golpea" la pantalla: aparece grande y se achica.
func _animar_aviso() -> void:
	aviso.pivot_offset = aviso.size / 2
	aviso.scale = Vector2.ONE * 1.8
	aviso.modulate.a = 0.0
	var tween := create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(aviso, "scale", Vector2.ONE, 0.35)
	tween.tween_property(aviso, "modulate:a", 1.0, 0.15)
	# "¡YA!" en dorado, los números en blanco
	var color := Color.WHITE
	if aviso.text == "¡YA!":
		color = Color(1.0, 0.8, 0.1)
	elif aviso.text.begins_with("¡Afuera!"):
		color = Color(1.0, 0.45, 0.2)
	aviso.add_theme_color_override("font_color", color)


# ---------- RESULTADOS ----------

# Llega igual a todas las PCs (RPC confiable del host), así que todos ven el mismo ranking.
func _armar_resultados(filas: Array) -> void:
	for hijo in lista_resultados.get_children():
		hijo.queue_free()
	if filas.is_empty():
		etiqueta_ganador.text = "Partida terminada"
		return

	var primero: Dictionary = filas[0]
	var segundo: Dictionary = filas[1] if filas.size() > 1 else {}
	var empate_puntos: bool = not segundo.is_empty() and not segundo["salio"] and segundo["puntos"] == primero["puntos"]
	var empate_total: bool = empate_puntos and is_equal_approx(segundo["tiempo"], primero["tiempo"])
	if empate_total:
		etiqueta_ganador.text = "¡Empate!"
		etiqueta_ganador.remove_theme_color_override("font_color")
	else:
		etiqueta_ganador.text = "¡Ganó %s!" % primero["nombre"]
		etiqueta_ganador.add_theme_color_override("font_color", Partida.color_de(primero["indice"]))
		if empate_puntos:
			etiqueta_ganador.text += "\n(desempate por tiempo en la celda)"

	# Encabezado de la tabla
	var gris := Color(0.6, 0.6, 0.7)
	for titulo in ["", "Jugador", "Puntos", "En la celda"]:
		lista_resultados.add_child(_etiqueta(titulo, gris, 15))
	for i in filas.size():
		var fila: Dictionary = filas[i]
		var color := Partida.color_de(fila["indice"])
		var ganador: bool = i == 0 and not empate_total
		var tamano := 24 if ganador else 18
		var nombre: String = fila["nombre"] + ("  (salió)" if fila["salio"] else "")
		var celdas := [
			_etiqueta("%dº" % (i + 1), Color.WHITE, tamano),
			_etiqueta(nombre, color, tamano),
			_etiqueta(str(fila["puntos"]), Color.WHITE, tamano),
			_etiqueta("%.1f s" % fila["tiempo"], gris, tamano),
		]
		# El nombre ocupa el espacio que sobra; si es muy largo se corta con "…"
		celdas[1].size_flags_horizontal = Control.SIZE_EXPAND_FILL
		celdas[1].custom_minimum_size.x = 180
		celdas[1].text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		for celda: Label in celdas:
			if fila["salio"]:
				celda.modulate.a = 0.5
			lista_resultados.add_child(celda)


# ---------- EXPULSAR (host) ----------

func _actualizar_expulsar() -> void:
	var ids: Array = red.jugadores_expulsables()
	var clave := str(ids) + str(partida.nombres)
	if clave == _expulsar_dibujado:
		return
	_expulsar_dibujado = clave
	for hijo in lista_expulsar.get_children():
		hijo.queue_free()
	if ids.is_empty():
		lista_expulsar.add_child(_etiqueta("No hay otros jugadores.", Color(0.6, 0.62, 0.72), 16))
		return
	for id in ids:
		var fila := HBoxContainer.new()
		fila.add_theme_constant_override("separation", 12)
		var nombre := _etiqueta("● " + partida.nombre_jugador(id), Partida.color_de(partida.jugadores[id]), 18)
		nombre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var boton := Button.new()
		boton.text = "Expulsar"
		boton.pressed.connect(red.expulsar.bind(id))
		fila.add_child(nombre)
		fila.add_child(boton)
		lista_expulsar.add_child(fila)


# ---------- AVISOS ----------

# Aparece abajo, se queda un rato y se desvanece. Si hay muchos, se van los más viejos.
func _mostrar_aviso(texto: String) -> void:
	var etiqueta := _etiqueta(texto, Color.WHITE, 17)
	etiqueta.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	etiqueta.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	etiqueta.add_theme_constant_override("outline_size", 6)
	lista_avisos.add_child(etiqueta)
	while lista_avisos.get_child_count() > 4:
		lista_avisos.get_child(0).free()
	var tween := etiqueta.create_tween()
	tween.tween_interval(duracion_aviso)
	tween.tween_property(etiqueta, "modulate:a", 0.0, 0.6)
	tween.tween_callback(etiqueta.queue_free)


func _etiqueta(texto: String, color: Color, tamano: int) -> Label:
	var etiqueta := Label.new()
	etiqueta.text = texto
	etiqueta.add_theme_color_override("font_color", color)
	etiqueta.add_theme_font_size_override("font_size", tamano)
	return etiqueta
