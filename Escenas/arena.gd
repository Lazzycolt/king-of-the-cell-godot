class_name Arena
extends Node2D

const COLUMNAS := 7
const FILAS := 5
const TAM_CELDA := 120.0

func _draw() -> void:
	var ancho := COLUMNAS * TAM_CELDA
	var alto := FILAS * TAM_CELDA
	var esquina := Vector2(-ancho / 2, -alto / 2)
	draw_rect(Rect2(esquina, Vector2(ancho, alto)), Color(0.15, 0.15, 0.2))
	for c in range(COLUMNAS + 1):
		var x := esquina.x + c * TAM_CELDA
		draw_line(Vector2(x, esquina.y), Vector2(x, esquina.y + alto), Color(1, 1, 1, 0.15), 2.0)
	for f in range(FILAS + 1):
		var y := esquina.y + f * TAM_CELDA
		draw_line(Vector2(esquina.x, y), Vector2(esquina.x + ancho, y), Color(1, 1, 1, 0.15), 2.0)
	draw_rect(Rect2(esquina, Vector2(ancho, alto)), Color.WHITE, false, 6.0)
