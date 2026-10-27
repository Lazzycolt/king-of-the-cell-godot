class_name Objeto
extends Node2D
## Objeto que aparece en la arena y se agarra pasando por encima.
## Lo crea el HOST (partida.gd) y el MultiplayerSpawner de objetos lo replica en todas las PCs.
## Para sumar un objeto nuevo: agregalo al enum, dibujalo en _draw() y aplicá su efecto en partida.gd (_aplicar_objeto).

enum Tipo { ESCUDO, TOPETAZO }

const RADIO := 16.0

var tipo: Tipo = Tipo.ESCUDO


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var flote := Vector2(0, sin(Time.get_ticks_msec() / 1000.0 * 3.0) * 3.0)   # sube y baja un poquito
	match tipo:
		Tipo.ESCUDO:
			var c := Color(0.3, 0.9, 1.0)
			draw_circle(flote, RADIO, Color(c, 0.25))
			draw_arc(flote, RADIO, 0, TAU, 32, c, 3.0)
			# Dibujito de escudo en el medio
			var forma := PackedVector2Array([
				Vector2(-8, -9), Vector2(8, -9), Vector2(8, 0), Vector2(0, 10), Vector2(-8, 0)
			])
			for i in forma.size():
				forma[i] += flote
			draw_colored_polygon(forma, c)
		Tipo.TOPETAZO:
			var c := Color(1.0, 0.5, 0.1)
			draw_circle(flote, RADIO, Color(c, 0.25))
			draw_arc(flote, RADIO, 0, TAU, 32, c, 3.0)
			# Estallido: estrella de 8 puntas que gira despacio
			var giro := Time.get_ticks_msec() / 1000.0
			var estrella := PackedVector2Array()
			for i in 16:
				var largo := 11.0 if i % 2 == 0 else 5.0
				estrella.append(flote + Vector2.from_angle(giro + i * TAU / 16) * largo)
			draw_colored_polygon(estrella, c)
