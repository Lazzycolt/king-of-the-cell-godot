class_name Arena
extends Node2D

const COLUMNAS := 7
const FILAS := 5
const TAM_CELDA := 120.0

## Colores del piso (dos tonos que se alternan como un tablero) y del borde.
const COLOR_PISO_A := Color(0.13, 0.14, 0.21)
const COLOR_PISO_B := Color(0.16, 0.17, 0.25)
const COLOR_BORDE := Color(0.55, 0.75, 1.0)
## Grosor y color del costado de la plataforma (debajo del borde de abajo).
const ALTO_COSTADO := 44.0
const COLOR_COSTADO := Color(0.09, 0.1, 0.16)
## Borde cuando no hay paredes: naranja, para que se note que ahí te caés.
const COLOR_BORDE_PELIGRO := Color(1.0, 0.45, 0.2)

## Lo pone partida.gd: sin paredes, el borde se dibuja como "peligro".
var con_paredes := true:
	set(valor):
		con_paredes = valor
		queue_redraw()

func _draw() -> void:
	var ancho := COLUMNAS * TAM_CELDA
	var alto := FILAS * TAM_CELDA
	var esquina := Vector2(-ancho / 2, -alto / 2)
	var area := Rect2(esquina, Vector2(ancho, alto))

	# Brillo alrededor de la arena: varios bordes cada vez más grandes y transparentes
	var color_borde := COLOR_BORDE if con_paredes else COLOR_BORDE_PELIGRO
	for i in range(6, 0, -1):
		var c := color_borde
		c.a = 0.05
		draw_rect(area.grow(4 + i * 5), c, false, 10.0)

	# Costado de la plataforma (se ve el "grosor" de la arena, como en el boceto).
	# Las rayitas siguen las columnas de la grilla.
	var costado := Rect2(Vector2(esquina.x, esquina.y + alto), Vector2(ancho, ALTO_COSTADO))
	draw_rect(costado, COLOR_COSTADO)
	draw_rect(Rect2(costado.position, Vector2(ancho, 4)), COLOR_COSTADO.lightened(0.25))
	for c in range(1, COLUMNAS):
		var x := esquina.x + c * TAM_CELDA
		draw_line(Vector2(x, costado.position.y), Vector2(x, costado.end.y), Color(0, 0, 0, 0.35), 2.0)

	# Piso a cuadros
	for f in FILAS:
		for c in COLUMNAS:
			var celda := Rect2(esquina + Vector2(c, f) * TAM_CELDA, Vector2.ONE * TAM_CELDA)
			draw_rect(celda, COLOR_PISO_A if (c + f) % 2 == 0 else COLOR_PISO_B)

	# Líneas de la grilla
	for c in range(1, COLUMNAS):
		var x := esquina.x + c * TAM_CELDA
		draw_line(Vector2(x, esquina.y), Vector2(x, esquina.y + alto), Color(1, 1, 1, 0.06), 2.0)
	for f in range(1, FILAS):
		var y := esquina.y + f * TAM_CELDA
		draw_line(Vector2(esquina.x, y), Vector2(esquina.x + ancho, y), Color(1, 1, 1, 0.06), 2.0)

	# Borde: con paredes, una línea llena; sin paredes, rayas (es un precipicio, no una pared)
	if con_paredes:
		draw_rect(area, COLOR_BORDE, false, 6.0)
		return
	var puntas := [area.position, Vector2(area.end.x, area.position.y), area.end, Vector2(area.position.x, area.end.y)]
	for i in 4:
		draw_dashed_line(puntas[i], puntas[(i + 1) % 4], color_borde, 5.0, 18.0)
