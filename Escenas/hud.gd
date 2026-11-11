extends CanvasLayer
## HUD de la partida, armado según el boceto (Proyecto - King of the cell/Boceto HUD.png):
##  - Arriba: una columna por jugador con su nombre, sus puntos y una barra (llena = va ganando).
##  - Debajo: el tiempo de la ronda en cajitas tipo reloj digital y el tiempo hasta que cambia la celda.
##  - Abajo a la izquierda: los controles.
## Solo muestra datos: los calcula el host (partida.gd) y llegan por el MultiplayerSynchronizer.

@export var partida: Partida
## El nodo Red (para saber si estamos en una sala).
@export var red: Node
@export_group("Nodos")
@export var arriba: Control
@export var fila_jugadores: HBoxContainer
@export var reloj: HBoxContainer
@export var celda: Control
@export var digitos_celda: HBoxContainer
@export var controles: Control

## Ancho de cada columna de jugador y de su barra.
const ANCHO_COLUMNA := 150.0
const COLOR_CAJA := Color(0.06, 0.07, 0.11, 0.9)
const COLOR_BORDE_CAJA := Color(1, 1, 1, 0.18)

var _columnas := {}          # { id: { "nombre": Label, "puntos": Label, "barra": ColorRect, "raiz": Control } }
var _armado_para := ""       # para rearmar las columnas solo cuando cambian los jugadores
var _digitos_reloj: Array[Label] = []
var _digitos_celda: Array[Label] = []


func _ready() -> void:
	# Reloj "MM:SS": 4 cajitas y los dos puntos en el medio
	for i in 4:
		if i == 2:
			var dos_puntos := _texto(":", 34, Color.WHITE)
			reloj.add_child(dos_puntos)
		var caja := _caja(34, Vector2(38, 50))
		reloj.add_child(caja)
		_digitos_reloj.append(caja.get_child(0))
	# Contador de cambio de celda "SS": 2 cajitas más chicas
	for i in 2:
		var caja := _caja(22, Vector2(28, 36))
		digitos_celda.add_child(caja)
		_digitos_celda.append(caja.get_child(0))


func _process(_delta: float) -> void:
	var en_sala: bool = red.esta_en_sala() or not partida.resultado.is_empty()
	var jugando := partida.estado == Partida.Estado.JUGANDO or partida.estado == Partida.Estado.FINALIZADO
	arriba.visible = en_sala and jugando
	controles.visible = en_sala
	if not arriba.visible:
		return
	_actualizar_jugadores()
	_actualizar_reloj()


# ---------- JUGADORES ----------

func _actualizar_jugadores() -> void:
	# Qué columnas mostrar: los que están y los que se fueron con puntos (sus puntos quedan, como dice el GDD)
	var ids := []
	for id in partida.jugadores:
		var sigue := partida.contenedor_jugadores.get_node_or_null(str(id)) != null
		if sigue or roundi(partida.puntos.get(id, 0.0)) > 0:
			ids.append(id)
	var clave := str(ids) + str(partida.nombres)
	if clave != _armado_para:
		_armado_para = clave
		_armar_columnas(ids)

	var maximo := 1.0
	for id in ids:
		maximo = maxf(maximo, partida.puntos.get(id, 0.0))
	for id in ids:
		var col: Dictionary = _columnas[id]
		var pts: float = partida.puntos.get(id, 0.0)
		col["puntos"].text = str(roundi(pts))
		# Barra proporcional al líder: el que va ganando la tiene llena
		col["barra"].size.x = ANCHO_COLUMNA * clampf(pts / maximo, 0.04, 1.0)
		var salio := partida.contenedor_jugadores.get_node_or_null(str(id)) == null
		col["raiz"].modulate.a = 0.45 if salio else 1.0


func _armar_columnas(ids: Array) -> void:
	for hijo in fila_jugadores.get_children():
		hijo.queue_free()
	_columnas.clear()
	for id in ids:
		var indice: int = partida.jugadores[id]
		var color := Partida.color_de(indice)
		var raiz := VBoxContainer.new()
		raiz.custom_minimum_size.x = ANCHO_COLUMNA
		raiz.add_theme_constant_override("separation", 0)
		var nombre := _texto(partida.nombre_jugador(id), 20, color)
		nombre.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nombre.custom_minimum_size.x = ANCHO_COLUMNA
		var puntos := _texto("0", 30, Color.WHITE)
		# Barra: un fondo gris y encima la parte llena del color del jugador
		var fondo := ColorRect.new()
		fondo.color = Color(1, 1, 1, 0.1)
		fondo.custom_minimum_size = Vector2(ANCHO_COLUMNA, 5)
		var barra := ColorRect.new()
		barra.color = color
		barra.size = Vector2(0, 5)
		fondo.add_child(barra)
		raiz.add_child(nombre)
		raiz.add_child(puntos)
		raiz.add_child(fondo)
		fila_jugadores.add_child(raiz)
		_columnas[id] = {"nombre": nombre, "puntos": puntos, "barra": barra, "raiz": raiz}


# ---------- RELOJES ----------

func _actualizar_reloj() -> void:
	var segundos := ceili(partida.tiempo_restante)
	var texto := "%02d%02d" % [mini(segundos / 60, 99), segundos % 60]
	# El último medio minuto el reloj se pone rojo
	var color := Color(1.0, 0.33, 0.33) if segundos <= 30 else Color.WHITE
	for i in 4:
		_digitos_reloj[i].text = texto[i]
		_digitos_reloj[i].add_theme_color_override("font_color", color)
	celda.visible = partida.estado == Partida.Estado.JUGANDO
	var para_cambio := "%02d" % mini(ceili(partida.tiempo_para_cambio), 99)
	for i in 2:
		_digitos_celda[i].text = para_cambio[i]


# ---------- AYUDANTES ----------

func _texto(texto: String, tamano: int, color: Color) -> Label:
	var etiqueta := Label.new()
	etiqueta.text = texto
	etiqueta.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	etiqueta.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	etiqueta.add_theme_font_size_override("font_size", tamano)
	etiqueta.add_theme_color_override("font_color", color)
	etiqueta.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	etiqueta.add_theme_constant_override("outline_size", 6)
	return etiqueta


# Una cajita con un dígito adentro (como un reloj digital).
func _caja(tamano: int, medida: Vector2) -> PanelContainer:
	var caja := PanelContainer.new()
	caja.custom_minimum_size = medida
	var estilo := StyleBoxFlat.new()
	estilo.bg_color = COLOR_CAJA
	estilo.border_color = COLOR_BORDE_CAJA
	estilo.set_border_width_all(2)
	estilo.set_corner_radius_all(6)
	caja.add_theme_stylebox_override("panel", estilo)
	var digito := _texto("0", tamano, Color.WHITE)
	caja.add_child(digito)
	return caja
