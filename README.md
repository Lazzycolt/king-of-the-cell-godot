# King of the Cell

Juego multijugador online de 2 a 4 jugadores hecho en **Godot 4.7** para la materia *Desarrollo de Videojuegos Multiplayer* (UPSO).
Grupo **Pentanil**: Fabricio, Ignacio y Bruno.

Cada jugador es una bolita que se mueve **cargando y soltando saltos**. En la arena hay una celda iluminada que da puntos: el que se queda solo adentro suma, y los demás tienen que sacarlo a los empujones. Gana quien tenga más puntos al terminar la ronda.

> Versión actual: **0.5.0** (`application/config/version` en `project.godot`). El host rechaza a los clientes que tengan otra versión.

---

## Cómo se juega

| Acción | Control |
|---|---|
| Cargar salto | Mantener **clic izquierdo** |
| Saltar | Soltar el clic: sale hacia donde apunta el mouse; cuanto más cargaste, más fuerte |
| Menú de pausa / salir | **Esc** |
| Lista de jugadores para expulsar (solo host) | **Tab** |

**Reglas**

- La arena es una grilla de 7 × 5 celdas. Cada **30 s** se ilumina otra celda, lejos de la anterior.
- Estar dentro de la celda activa da **10 puntos por segundo**, pero solo si estás **solo** adentro.
- La ronda dura **5 minutos**. Si hay empate en puntos, gana el que pasó más tiempo total dentro de la celda (aunque la haya compartido).
- **Golpes:** si chocás a otro con suficiente velocidad, lo empujás y queda aturdido 1 s (no puede saltar). Con el empuje en cadena, el que sale volando le pasa el 70 % de la fuerza al que choque.
- **Caídas:** la arena no tiene paredes. El que se cae queda afuera 5 s y vuelve con 2 s de invulnerabilidad. No pierde puntos ni le da puntos a nadie.
- **Power-ups** (aparece uno cada 12 s; se agarran pasando por encima):
  - **Escudo:** 5 s sin poder ser golpeado.
  - **Topetazo:** durante 8 s, el próximo golpe que des lanza al rival con mucha más fuerza y lo deja deslizando como una bola de billar.

Todos estos valores se pueden ajustar desde el Inspector del nodo **Partida** en `Escenas/arena.tscn` (grupos *Ronda*, *Reglas*, *Caídas*, *Golpes* y *Objetos*). Las paredes y el empuje en cadena se activan o desactivan con `con_paredes` y `empuje_en_cadena`.

---

## Flujo de una partida

```
Menú ──► Lobby ──► Cuenta atrás (3 s) ──► Jugando (5 min) ──► Resultados ──► Menú
```

1. **Menú:** *Crear* arma una sala y muestra su código de 5 letras. *Unirse* entra con ese código.
2. **Lobby:** se ven los jugadores conectados. El host toca *Iniciar* cuando hay al menos 2.
3. **Jugando:** el HUD muestra los puntos de cada uno, el reloj de la ronda y el tiempo que le queda a la celda.
4. **Resultados:** ranking final con puntos y tiempo en la celda.

---

## Red

El que crea la sala hace de **host** y es la autoridad: corre las reglas (celda, puntos, reloj, objetos) y decide qué golpes valen. El resto de los jugadores son clientes.

- **Movimiento:** cada jugador mueve su propia bolita y publica su posición; en las demás PCs se muestra interpolada (`suavizado` en `jugador.gd`).
- **Golpes:** el cliente avisa "choqué a X" (`reportar_golpe`, RPC). El host lo valida (distancia, velocidad máxima posible, escudo, inmunidad) y recién ahí aplica el empuje en todas las PCs.
- **Replicación:** `MultiplayerSpawner` para jugadores y objetos, `MultiplayerSynchronizer` para el estado de la partida y `@rpc` para los eventos.

### Dos modos de conexión

Se elige con la propiedad **`usar_steam`** del nodo **Red** en `Escenas/arena.tscn`.

| Modo | Para qué | Cómo conecta |
|---|---|---|
| **Steam** (`usar_steam = true`, el que va en los builds) | Jugar por internet entre PCs distintas | Salas de Steam buscadas por código. Usa el relay de Steam, así que no hace falta abrir puertos ni usar VPN. |
| **ENet** (`usar_steam = false`) | Probar en una sola PC con varias ventanas | Conexión directa por IP al puerto **7777**. Si se deja la IP vacía, se conecta a `127.0.0.1`. |

En modo Steam se usa el App ID de prueba de Valve (**480**, "Spacewar"); las salas se marcan como `king_of_the_cell` para no mezclarse con las de otros juegos que usan el mismo ID.

### Reglas de conexión (sesión)

El host revisa a cada jugador antes de dejarlo entrar (`auth_callback` en `red.gd`) y lo rechaza con un mensaje si:

- tiene **otra versión** del juego;
- fue **expulsado** de esa sala;
- ya hay alguien conectado con **la misma cuenta** de Steam;
- la partida **ya empezó** (y no es alguien que se había caído);
- la sala está **llena** (4 jugadores).

**Reconexión:** si un jugador se desconecta en medio de la ronda, puede volver a *Unirse* con el mismo código y recupera sus puntos. Si queda un solo jugador, la ronda se pausa hasta 30 s esperando que vuelva el otro.

Cuando alguien entra o se va, a todos les aparece un aviso en pantalla. Arriba de todo se ve el estado de la conexión y el ping.

---

## Cómo correrlo

### Requisitos

- [Godot 4.7](https://godotengine.org/) (versión estándar, no la de .NET).
- Para el modo Steam: **Steam abierto y con la sesión iniciada** en cada PC. Con el App ID 480 no hace falta tener ningún juego comprado.
- El addon [GodotSteam](https://godotsteam.com/) (GDExtension) ya viene incluido en `addons/godotsteam`.

### Probar en una sola PC (ENet)

1. Abrir el proyecto en Godot.
2. En `Escenas/arena.tscn`, seleccionar el nodo **Red** y desactivar `usar_steam`.
3. En **Depurar → Personalizar instancias de ejecución**, habilitar varias instancias (2 a 4).
4. Ejecutar (F5). En una ventana tocar *Crear*; en las otras, *Unirse* con el campo vacío.

> Con Steam no se puede probar en una sola PC: todas las ventanas usarían la misma cuenta y el host las rechaza por cuenta duplicada.
> **Antes de commitear o exportar, volver a activar `usar_steam`.**

### Jugar por internet (Steam)

1. Verificar que `usar_steam` esté activado.
2. Exportar con el preset de Windows (**Proyecto → Exportar**). El ejecutable se genera en `../Builds/`.
3. Pasarle el build a los demás. Todos tienen que tener **la misma versión**.
4. Uno toca *Crear* y les pasa el código; los demás lo escriben y tocan *Unirse*.

Si `steam_appid.txt` (con el `480`) está junto al ejecutable o en la carpeta del proyecto, Steam reconoce el juego sin tener que lanzarlo desde la biblioteca.

---

## Estructura del proyecto

```
├── jugador.gd               Movimiento, carga del salto, golpes recibidos, caídas, dibujo de la bolita
├── Escenas/
│   ├── arena.tscn           Escena principal: arena, jugadores, spawners, HUD e interfaz
│   ├── arena.gd             Dibuja la grilla de 7 × 5 celdas
│   ├── jugador.tscn         Escena del jugador (con su MultiplayerSynchronizer)
│   ├── partida.gd           Reglas (solo host): estados, celda activa, puntos, golpes, caídas, objetos
│   ├── red.gd               Conexión Steam/ENet, salas con código, autenticación, expulsar, reconexión
│   ├── objeto.gd            Power-ups (Escudo y Topetazo)
│   ├── hud.gd               Puntos, reloj de ronda y tiempo de la celda
│   ├── interfaz.gd          Lobby, cuenta atrás, resultados, pausa, expulsar y avisos
│   ├── estado_conexion.gd   Indicador de conexión y ping
│   └── tema.tres            Tema visual de la interfaz
├── addons/godotsteam/       GodotSteam (GDExtension)
├── steam_appid.txt          App ID de Steam (480)
└── project.godot
```

### Agregar un power-up nuevo

1. Sumarlo al enum `Tipo` en `Escenas/objeto.gd`.
2. Dibujarlo en `_draw()` del mismo archivo.
3. Aplicar su efecto en `_aplicar_objeto()` de `Escenas/partida.gd`.

---

## Ramas

| Rama | Contenido |
|---|---|
| `godotsteam` | **Rama de trabajo.** Steam con salas por código, power-ups, lobby, ronda completa, reglas de conexión y reconexión. |
| `main` | Versión inicial. |
| `Branch_nacho` | Power-ups y bots con ENet (los power-ups ya se integraron en `godotsteam`). |
| `gd-sync` | Prueba con GD-Sync, abandonada. |

---

## Créditos

- Grupo Pentanil: Fabricio, Ignacio y Bruno.
- [GodotSteam](https://godotsteam.com/) por GP Garcia, Chris Ridenour y colaboradores (licencia MIT, ver `addons/godotsteam/license.md`).
