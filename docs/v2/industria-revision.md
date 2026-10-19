# Cómo construye y revisa código la industria (octubre de 2026): lecciones para Issue Runner v2

> **Nombre provisional.** "Issue Runner v2", "IR" y el comando `ir` son nombres de trabajo: habrá un cambio de marca y el nombre definitivo está pendiente. Se usan aquí solo como marcadores; los nombres de etiquetas (`ir:*`), comandos y ficheros se renombrarán de forma mecánica cuando se decida.

Fecha: 2026-10-19. Es un trabajo de investigación: no se ha hecho ningún experimento ni se ha contratado ningún servicio.

El documento sintetiza siete investigaciones paralelas sobre fuentes primarias, con foco especial en **la revisión de código y en cómo se valida el merge final**.

Se apoya en dos documentos: [`issue-runner-v2-spec.md`](issue-runner-v2-spec.md) (la implementación) y [`issue-runner-v2-preparacion.md`](issue-runner-v2-preparacion.md) (la preparación).

**Cómo leer las cifras.** Cada una va etiquetada así:

- **[EXP]**: medición con metodología publicada o estudio independiente.
- **[CASE]**: datos de uso interno publicados por la propia empresa.
- **[CLAIM]**: afirmación sin método.

Casi todas las cifras de proveedores son [CASE] o [CLAIM], y los benchmarks de proveedores se contradicen entre sí. Ningún número externo se traslada a nuestros repos sin medirlo aquí.

---

## 0. Resumen para humanos

1. **Nadie deja que una IA apruebe o bloquee un merge por su propia autoridad.** Ni Anthropic, ni OpenAI, ni GitHub, ni Stripe, ni LinkedIn, ni Atlassian, ni Datadog.
   - Claude Code Review "never approves or blocks"; publica un recuento de severidades para que CI decida.
   - Copilot no cuenta como aprobación por defecto.
   - La única excepción pública es OpenAI en su experimento de *harness engineering*, donde los agentes fusionan sus propios PR. Los propios autores advierten que "would be irresponsible in a low-throughput environment".

   Nuestro diseño ya va en esta línea: el juez recomienda y las puertas deterministas deciden.
2. **El gran problema de la revisión con IA es la precisión, no la exhaustividad.**
   - En un estudio con más de 31.000 comentarios reales de CodeRabbit, se rechazó el 56 % [EXP].
   - El mejor benchmark independiente de revisión no pasa de un ~20–24 % de F1 [EXP].
   - Los buscadores de bugs con agentes, sin verificación, tienen entre un 55 % y un 97 % de falsos positivos [EXP ligero].

   Todo el que lo hace bien **filtra antes de publicar**: verificación de cada hallazgo, supresión por categorías, recorte a las líneas cambiadas, tope de comentarios y aprendizaje a partir de lo rechazado.
3. **Lo que funciona como señal es la evidencia y el acuerdo, no la autoevaluación.**
   - La severidad o confianza que el modelo se pone a sí mismo es "nearly random" (Greptile).
   - Lo que sí sirve: un hallazgo con evidencia (`file:line`, un test que lo reproduce) o encontrado de forma independiente por dos revisores (LinkedIn).

   Esto respalda nuestro filtro contrafactual y la regla de que "una objeción solo estática no bloquea".
4. **Los jueces LLM fallan si no se calibran.**
   - Spotify retiró su juez por falsos bloqueos.
   - En Atlassian, el juez de corrección casi no aportó, y un clasificador pequeño entrenado con datos propios sí (+15–20 puntos).
   - Anthropic hace pasar a los revisores nuevos por **modo sombra** antes de que puedan bloquear.
5. **Que pasen los tests no basta, y el implementador puede hacer trampa.**
   - Un 30 % de los parches "plausibles" se comporta distinto del correcto [EXP].
   - Los modelos modifican tests para que pasen (ImpossibleBench) [EXP].

   Hacen falta tests de validación que el implementador no pueda tocar, ejecutar la suite completa y, a medio plazo, pruebas diferenciales.
6. **La seguridad básica tiene que ser determinista.** La revisión, humana o con IA, pasó por alto el **81 % de las credenciales filtradas** en PR de agentes [EXP]. El escaneo de secretos, el control de versiones fijas de dependencias y el análisis estático de seguridad (SAST) deben ser puertas obligatorias.
7. **El nuevo cuello de botella es la revisión humana** (Microsoft, Spotify, Salesforce, Meta). Agrava el problema que los revisores se desconectan en los PR grandes. Respuesta: limitar el tamaño de los PR y cuántos PR de agentes hay abiertos a la vez, y dar al aprobador un resumen de **intención y riesgo** (Anthropic: "examine the intent… as opposed to reading every line").
8. **Atar el merge al SHA exacto revisado no lo publica nadie** como mecanismo propio. CodeRabbit se acerca: comprueba que la cabeza no cambió justo antes de aprobar. Lo nuestro es una mejora coherente con los mecanismos nativos de GitHub.
9. **CodeRabbit:** **no comprarlo por ahora; copiar sus ideas**. Prueba opcional en modo sombra, gratuita y solo en un repo interno. Está en §5.

---

## 1. Qué hace cada uno, por fase

### 1.1 Especificación y planificación

| Quién | Práctica | Para nosotros |
|---|---|---|
| Factory | **Contrato de validación** con aserciones comprobables (`VAL-AUTH-001`) escrito *antes* de descomponer el trabajo, "para que no lo influya la implementación ya planeada" [CASE] | Ya lo tenemos: `AC-n` con `Verify:` en la preparación. **Confirmado** |
| Anthropic (harness) | Contrato del sprint entre generador y evaluador antes de escribir código [CASE] | Igual que arriba |
| Cognition | Lo mejor para Devin: requisitos claros al principio y resultado verificable, en tareas de 4–8 h de un junior. No soporta cambios de requisitos a mitad [CASE] | Confirma el congelado de la spec y PAUSED_SPEC_DRIFT |
| Anthropic (seguridad) | Revisión de seguridad del *proyecto* con Opus al planificar; los proyectos de riesgo bajo se auto-aprueban [CLAIM] | **Adaptar**: la preparación marca `risk` y las rutas de seguridad desde la spec |
| OpenAI | Tareas de ~1 h o unos cientos de líneas, redactadas como issues; AGENTS.md corto como índice de `docs/` [CASE] | Confirma el tamaño de slice y el CLAUDE.md o AGENTS.md cortos |

### 1.2 Implementación

| Quién | Práctica | Para nosotros |
|---|---|---|
| Stripe Minions | *Blueprints*: una máquina de estados que mezcla nodos deterministas (lint, push) y nodos de agente. Devboxes aislados y sin internet, así que no hacen falta prompts de permisos. **Como mucho 2 rondas de CI**. Más de 1.300 PR fusionados por semana [CASE] | Es exactamente nuestra arquitectura. **Adoptar** su límite de reintentos contra CI como referencia |
| Spotify Honk | Verificadores deterministas por sistema de build. No se abre un PR si alguno falla. Verificación en el CI real antes del PR [CASE] | Confirma "validar antes de que exista el PR" |
| Shopify Roast, Airbnb | Primero los *codemods* deterministas, y solo el resto va al agente. Máquina de estados por fichero, con el ciclo "muestrear, ajustar, barrer" [CASE] | **Adoptar** para trabajo en lote (migraciones) en v2.1 |
| Cognition | Un único agente escribe. Los agentes extra solo revisan [CASE] | Confirma un implementador por issue |
| Cursor | Más del 30 % de los PR fusionados vienen de agentes en la nube. Métrica *Keep Rate*: qué parte del código del agente sigue en el repo pasado un tiempo [CASE] | **Adoptar** *Keep Rate* (equivale a nuestra "supervivencia del código") |
| OpenAI | Linters y tests estructurales propios, cuyos mensajes **explican al agente cómo arreglar** el problema. Cuando un hallazgo de revisión se repite, se convierte en un lint ("promote the rule into code") [CASE] | **Adoptar** (§3, A7) |

### 1.3 Revisión: arquitecturas que funcionan

| Quién | Arquitectura | Control de ruido |
|---|---|---|
| **Claude Code Review** | Buscadores en paralelo, luego **verificación**, luego deduplicación y orden por severidad, y por último publicación. Solo lectura, sin ejecutar código | Severidades Important / Nit / Pre-existing. Máximo 5 nits. Cada afirmación necesita `file:line`. REVIEW.md **solo desde la rama base protegida**. Menos del 1 % marcado como incorrecto [CLAIM] |
| **Codex (OpenAI)** | Herramientas de todo el repo y **ejecución de código**, que mejoró a la vez precisión y exhaustividad frente a revisar solo el diff [EXP] | Solo P0 y P1. Se sacrifica exhaustividad a propósito por precisión. Un 52,7 % de los comentarios provoca un cambio de código, un 46 % en PR escritos por Codex [EXP] |
| **Cursor Bugbot** | v1: 8 pasadas con el diff en orden aleatorio, voto por mayoría, un modelo validador y filtro de categorías. Después, un único bucle agéntico, que fue "la mayor ganancia" | Métrica: tasa de resolución, del 52 % a más del 70 % [CASE]. Reglas aprendidas de votos negativos y respuestas |
| **LinkedIn** | Subagentes independientes (distinto modelo y *harness*) más uno de reglas propias. **Si dos coinciden, el hallazgo es de alta confianza; si solo lo ve uno, se verifica, no se descarta** | Aceptación tras el merge del 63,9 %. Por categoría: concurrencia 100 %, lógica 80 %, seguridad 40,6 % [EXP] |
| **Uber uReview** | Cadena de generar, puntuar (un *prompt* calificador con umbrales por asistente, lenguaje y categoría), filtrar y deduplicar. Tres asistentes: bugs, buenas prácticas y AppSec | Un 65 % de los comentarios se atienden en el mismo cambio, frente al 51 % de los humanos [CASE]. Los de estilo se valoran mal |
| **Atlassian RovoDev** | Claude, más la issue de Jira y la descripción del PR. Juez de corrección (impacto mínimo) y **filtro ModernBERT entrenado con "¿llevó a un cambio?"** (+15–20 puntos) | Un 38,7 % de los comentarios llevan a un cambio, frente a un 44,5 % de los humanos [EXP] |
| **Google AutoCommenter** | Umbrales por guía de estilo. **Solo líneas cambiadas**: el 80 % de las predicciones crudas caía en líneas no tocadas | La utilidad se estancó en el 54 %. Suprimiendo 17 categorías de poco valor subió al 66–74 %. Exigieron un 80 % antes de desplegar a todos [CASE] |
| **Greptile** | Bucle agéntico. Hooks que **obligan a examinar todos los ficheros** | El autoprompting y los *few-shot* fallaron, y la severidad autoasignada salió casi aleatoria. **Suprimir lo parecido a 3 o más rechazos previos** subió los atendidos del 19 % al 55 % [CASE] |
| **Qodo PR-Agent** (código abierto) | Revisa solo las líneas `+`. El texto del PR se trata como no fiable. "Si no puedes explicar un escenario concreto, no lo señales". Máximo 3 hallazgos | Una pasada de reflexión puntúa de 0 a 10. Puntúa 0 si el código citado no coincide con el real, y 0 automático en docstrings, imports o "verifica que…" |
| **Cognition Devin Review** | Revisor **sin contexto compartido** con el que escribe, que es lo que mejor funciona. El que escribe filtra los hallazgos contra las instrucciones del usuario. Seguridad obligatoria | Severo / no severo; Investigar / Informativo. Autofix sin tope (un riesgo) |
| **Factory** | Validadores que **nunca arreglan**, solo informan. El orquestador crea las tareas de arreglo. Converge en 2–4 rondas | Comparativa propia: GPT-5.2 con más precisión y Opus 4.6 con más exhaustividad, F1 parecida [EXP de proveedor] |
| **Amp** | Un subagente por cada *check* (`.agents/checks/`), "a stronger guarantee that each check will actually be checked" | — |

### 1.4 Validación del merge

| Quién | Mecanismo |
|---|---|
| GitHub (agente Copilot) | El solicitante no puede aprobar. El agente no puede marcar *ready* ni aprobar ni fusionar. El CI sobre código del agente necesita "Approve and run workflows". CodeQL, dependencias y secretos se analizan siempre. La aprobación de Copilot no cuenta por defecto y una nueva subida la invalida |
| Claude Code Review | Línea legible por máquina `bughunter-severity: {…}`. CI falla si `normal > 0`. **Si falta la línea, no hay veredicto: no cuenta como cero** |
| CodeRabbit | Aprueba solo si se cumplen cuatro condiciones: último commit revisado, hilos obligatorios resueltos, checks previos en verde, y **la cabeza no cambió justo antes de aprobar**. Las puertas empiezan en modo aviso y después pasan a error. `allow_author_approval: false` |
| Anthropic (interno) | Repos clasificados por riesgo. Lo crítico exige aprobación humana estricta. **Tests invariantes aprobados por humanos** que, si se tocan, fuerzan revisión manual. Toda aprobación queda registrada y se **vuelve a revisar una muestra ponderada por riesgo** de las automáticas |
| Meta RADAR | Aprobación automática solo de lo de bajo riesgo: clasificar autoría, criterios de elegibilidad, heurísticas estáticas, puntuación de riesgo del diff, revisión LLM, validación determinista y merge automático. Un tercio de *reverts* que el resto, con sesgo de selección [CASE] |
| Stripe, LinkedIn, Atlassian, Ramp, Datadog | **Un humano tiene la última palabra.** Ramp abre el PR con el token del solicitante para que no pueda aprobarse a sí mismo |
| Spotify | Merge automático solo para cambios de bajo riesgo y fáciles de revertir |
| Anthropic (control de versiones) | A escala de agentes (más de 30.000 merges al día) prescinden de la merge queue e invierten en tests post-merge y antes de desplegar, más bisect y revert automáticos |

### 1.5 Evidencia empírica clave

- **PR de agentes** (AIDev, con más de 930.000 PR):
  - Se aceptan menos que los humanos.
  - Fallan más los grandes, los de varios ficheros, los de rendimiento y los de bugs.
  - Los motivos de rechazo son duplicados, funcionalidades no pedidas y desalineación con lo que el proyecto necesita.
  - En PR de Claude Code, el 45 % de los fusionados necesitó retoques humanos [EXP].
- **dotnet/runtime** (Microsoft, 10 meses):
  - Un 67,9 % de merges del agente frente a un 87,1 % de los humanos. Tras ajustar las instrucciones, pasó del 41,7 % al ~71 %.
  - *Reverts*: un 0,6 % frente a un 0,8 %.
  - Una mediana de 10 comentarios de revisión frente a 7.
  - Los tests del agente a menudo **consolidan comportamiento incorrecto**.
  - El agente afirmaba mejoras de rendimiento sin pruebas, así que se exigen benchmarks [CASE].
- **Límites de los tests:**
  - Un 7,8 % de los parches "que pasan" fallan la suite completa.
  - Un 29,6 % de los plausibles se comporta distinto del correcto (PatchDiff).
  - Los modelos hacen trampa modificando tests (Claude) o con casos especiales (OpenAI).
  - Los tests de solo lectura y los ocultos funcionan.
  - Más reintentos aumentan la trampa (ImpossibleBench) [EXP].
- **Seguridad:**
  - El 38,9 % de los PR de agentes tienen algún olor de seguridad, el 82 % de cadena de suministro.
  - La revisión pasó por alto el **81 %** de las credenciales filtradas [EXP].
- **Benchmarks de revisión:**
  - SWR-Bench: la mejor F1 es del 19,4 %. Agregar 5–10 revisiones sube la F1 hasta un +44 % [EXP].
  - c-CRAB: los revisores con agentes, juntos, resuelven ~40 % de las tareas. Son complementarios a los humanos [EXP].
- **Velocidad frente a calidad:** adoptar Cursor da velocidad pasajera, pero aumenta de forma persistente los avisos de análisis estático y la complejidad [EXP, diferencias en diferencias].

---

## 2. Qué confirma de nuestro diseño

| Elemento nuestro | Quién lo confirma |
|---|---|
| Coordinator determinista. Los agentes no escriben en GitHub | Stripe (*blueprints*), gh-aw (*safe outputs*), Factory (validadores que no arreglan) |
| Revisores independientes y sin la conversación del implementador | Cognition, Factory, Anthropic (harness) |
| Claude y Codex en paralelo; el acuerdo como señal | LinkedIn; la comparativa de Factory (precisión y exhaustividad complementarias); SWR-Bench (la agregación sube la F1) |
| Una objeción solo estática no bloquea; evidencia ejecutable | Anthropic ("agents must prove their findings"), Qodo, Greptile (la autoseveridad es casi aleatoria), SM100 |
| Instrucciones de revisión solo desde la base protegida | Anthropic REVIEW.md. Copilot lee de la rama del PR, que es justo la debilidad que evitamos |
| Bloquear ante un resultado incierto o un revisor que falla | Claude Code Review ("missing = no verdict") |
| Límite de rondas y estancamiento | Stripe (2 rondas de CI), Factory (2–4), ImpossibleBench (reintentar aumenta la trampa) |
| Spec con criterios verificables antes de implementar | Factory, Anthropic, Cognition |
| Merge atado al SHA y nueva comprobación de la cabeza | CodeRabbit (lo más parecido); GitHub (aprobaciones descartadas al subir algo) |
| Aprobación humana por riesgo, y quien solicita no aprueba lo suyo | Anthropic, GitHub, Ramp, Meta RADAR |
| Métrica de "atendido" y supervivencia | Uber, Atlassian, Greptile, Cursor (*Keep Rate*), OpenAI |

---

## 3. Qué cambiaría o añadiría (propuestas)

| # | Propuesta | Fuente | Dónde en la spec | Esfuerzo |
|---|---|---|---|---|
| **A1** | **Pasada determinista previa** a los revisores LLM: linters del proyecto, `semgrep`/`opengrep`, `ast-grep`, `gitleaks` (secretos) y `osv-scanner` (dependencias). Sus resultados son **hallazgos propios** y además **contexto** para los revisores. Secretos y dependencias vulnerables o sin versión fija son **puertas obligatorias** | CodeRabbit, Uber, Meta (filtros deterministas antes), estudio de seguridad (81 % de credenciales sin detectar) | §5.5–§5.6, §6.4 (nueva R1b) | S |
| **A2** | **Filtro barato antes del juez**, en este orden: validar que el hallazgo cae en líneas añadidas o cambiadas; comprobar que el código citado coincide con el diff real; suprimir categorías sin valor (docstrings, tipos, imports, "verifica que…", rotura especulativa fuera del diff); tope de 3–5 hallazgos por revisor. Se guarda un **registro de lo suprimido con su motivo** | Qodo (reflexión), Google (solo líneas cambiadas), Graphite (validación de rango), Ellipsis (registro) | §6.2 | S |
| **A3** | **Aprendizajes por supresión.** Cada hallazgo rechazado (por el filtro contrafactual, el juez o un humano) se guarda por repo. Uno nuevo parecido (misma ruta o categoría y texto similar) a **3 o más rechazos distintos** se suprime. Sin embeddings al principio: palabras clave y ruta bastan a nuestra escala | Greptile (19 % → 55 %), CodeRabbit (learnings), Bugbot (reglas aprendidas) | §6.4, §9.3 | M |
| **A4** | **Convertir hallazgos repetidos en reglas deterministas.** Un tipo de hallazgo confirmado más de 3 veces se propone como lint, test, regla `ast-grep` o regla de REVIEW.md, con mensaje que explique el arreglo, mediante un PR revisado por un humano | OpenAI, Amp (*checks*), LinkedIn (incidentes → reglas) | §9.3, §12 | M |
| **A5** | **Revisores y juez en modo sombra antes de bloquear.** Cada revisor, categoría o versión de prompt nueva empieza en **aviso**. Pasa a poder bloquear solo cuando su tasa de hallazgos atendidos o confirmados en nuestros datos supera un umbral (**H-28**, por ejemplo ≥ 60 % en hallazgos `major` o superiores). El juez Opus también se calibra contra decisiones humanas antes de que sus confirmaciones estáticas bloqueen | Anthropic (sombra), Google (puerta del 80 %), CodeRabbit (aviso → error), Spotify (juez retirado), Atlassian | §6.4–§6.5, §12 | S |
| **A6** | **Tests que el implementador no puede tocar.** Los tests de los `Verify` y de reproducción que crea el coordinator, y los tests existentes que cubren los AC, se marcan como **oráculo**. Cualquier cambio del implementador en ellos es un debilitamiento de tests (bloqueante). Además se ejecuta **la suite completa** en MERGE_PREP, no un subconjunto | ImpossibleBench, el estudio de SWE-bench, dotnet (tests que consolidan comportamiento erróneo) | §5.4, §8.3 (regla 5) | S |
| **A7** | **Prueba diferencial ligera** en v2.1: ejecutar los tests nuevos del candidato también sobre la base. Deben fallar en la base si prueban comportamiento nuevo; si pasan, no prueban nada. Más adelante, comparar el comportamiento entre base y candidato (estilo PatchDiff) | PatchDiff, UTBoost, Meta (tests guiados por mutaciones) | §5.5 | M |
| **A8** | **Taxonomía de dos ejes:** severidad (crítica / mayor / menor / info) por categoría (seguridad, corrección, datos, rendimiento, mantenibilidad). **Solo pueden bloquear** las críticas o mayores en seguridad, corrección o datos. Rendimiento solo bloquea con un benchmark como evidencia; mantenibilidad y estilo, nunca | CodeRabbit, LinkedIn (aceptación por categoría), dotnet (benchmarks) | §6.4 | S |
| **A9** | **Codex limitado a P0/P1** en su salida, como en su producto. Su evidencia pesa igual que la de Claude: ninguno bloquea solo sin prueba | OpenAI docs; Cursor (Codex 45 % de resolución); SM100 (Codex el de más precisión) | §5.6 | S |
| **A10** | **Capacidad de revisión humana.** Tope de PR de agentes esperando aprobación humana por repo (por ejemplo 3). Tope de tamaño de PR. Una **tarjeta de aprobación** con la intención (de la spec), el riesgo por fichero, las decisiones técnicas tomadas y los hallazgos descartados con su motivo | Microsoft, Salesforce, Anthropic (revisar la intención), Spotify | §5.11, §11 | S |
| **A11** | **Comprobación de alcance y duplicados** en la revisión: ¿el PR hace solo lo que pide la spec? Es la primera causa de rechazo de los PR de agentes. Code Review recibe `Out of scope` y señala lo que sobra | AIDev, Spotify (el motivo más común del veto de su juez), Cognition | §5.6 | S |
| **A12** | **Métricas principales:** por revisor y categoría, la tasa de **atendido** (el hallazgo se corrige en un commit posterior, comprobado de forma determinista por el diff), la tasa de confirmados por el filtro contrafactual y la tasa de rechazados por el juez o un humano. Por ítem: *Keep Rate* a 30 días, *reverts* y comentarios humanos por PR. **Las reacciones no son una métrica** | Uber, Atlassian, Greptile, Cursor, LinkedIn ("vanity metric") | §12.1 | S |
| **A13** | **Evaluación offline propia:** 20–50 PR propios ya fusionados con **bugs inyectados** (método Qodo), más bugs reales encontrados después del merge. Se puntúa con deduplicación, emparejamiento por juez y F-beta (β≈0,5 para hallazgos que bloquean). Se separan las métricas *grounded* de las *augmented* (ReviewBench), sin puntuar a un revisor contra sus propios hallazgos | Qodo, Martian, ReviewBench | §12.3 (sustituye parte del *replay*) | M |
| **A14** | **Muestreo de aprobaciones automáticas:** si se activa el merge automático en riesgo bajo, un humano revisa cada semana una muestra ponderada por riesgo de lo fusionado sin humano | Anthropic, Meta RADAR | §5.11, §12 | S |
| **A15** | **Revisión incremental formal:** revisar `last_reviewed_sha..head`, arrastrar los hallazgos abiertos y marcar como resueltos de forma **determinista** los que el nuevo commit atiende. Ya existe en parte (re-revisión delta). Se añade: **nunca dar un hallazgo por resuelto solo porque un LLM lo diga**; resuelto = repro en verde, o revisor que lo confirma sobre el nuevo SHA | CodeRabbit, Bugbot (el fallo del "resuelto" juzgado por LLM tras un commit ajeno) | §6.5b | S |

**Descartado tras la investigación:**

- **Revisores que se aprueban o fusionan solos** (OpenAI *harness*): es un compromiso de alto volumen que sus propios autores no recomiendan en entornos como el nuestro.
- **Autofix sin tope** (Devin): ya tenemos tope de rondas.
- **Una "puntuación de confianza" textual del revisor como puerta** (Greptile, 0–5): es frágil y autoevaluada.
- **Entrenar un clasificador propio de rechazo** antes de tener datos: Atlassian lo entrenó con más de 50.000 etiquetas, y nosotros tendremos unos centenares. Se reconsidera con más de 1.000 hallazgos etiquetados.
- **Prescindir de la merge queue** como Anthropic: a nuestra escala, el merge atado al SHA es barato y correcto.

---

## 4. Riesgos y contradicciones que aparecen

1. **Precisión frente a exhaustividad.** Todo el que lo hace bien sacrifica exhaustividad para ganar confianza. Nuestras puertas deterministas (CI, `Verify`, A1) cubren la parte de exhaustividad que más importa. El resto de la revisión con IA debe tomarse como **información útil, no como garantía**: una revisión limpia no prueba que el código sea correcto (c-CRAB: los revisores encuentran ~40 %).
2. **El juez Opus es un punto débil conocido.** Dos casos reales (Spotify, Atlassian) muestran jueces LLM poco útiles o dañinos. Mitigación: A5 (modo sombra), confirmaciones con contraejemplo (ya existe) y la métrica `judge_static` (H-21).
3. **Revisar con Claude el código de Claude.** CodeRabbit pone muchos comentarios de refactor en PR de Claude Code (un 35 % frente a un 10,5 % en PR de Copilot) [EXP]. Los revisores de la misma familia comentan más. Mitigación: A8 (la mantenibilidad nunca bloquea) y el tope de nits.
4. **Más rondas de corrección aumentan la trampa** (ImpossibleBench). Refuerza A6 (oráculo intocable) y el límite de rondas.
5. **El cuello de botella se desplaza a los humanos.** Si el runner produce más PR de los que podemos revisar, los aprobadores se desconectan (Salesforce). A10 limita el flujo, y es mejor eso que bajar el listón.

---

## 5. CodeRabbit: ¿comprarlo, probarlo o copiarlo?

### 5.1 Por qué se considera bueno

Lo que publica [CLAIM salvo indicación]:

- **Entorno aislado por revisión** (microVMs de Cloud Run) donde el agente **genera scripts** (`cat`, `grep`, `ast-grep`, Python) para comprobar sus sospechas.
- **Más de 20–40 linters y escáneres** ejecutados antes.
- **Contexto rico:** grafo de código regenerado en cada revisión, issues enlazadas (comprueba el PR contra el ticket), PR anteriores, aprendizajes por repo u organización, instrucciones por ruta y ficheros de guía de agentes.
- **Revisión incremental** en cada push, con pausa automática tras 5 commits revisados.
- **Combinación de modelos** (Anthropic y OpenAI) y un juez que filtra.
- **Evalúa cada modelo nuevo** con 100 PR de código abierto y una rúbrica fija antes de cambiarlo.

**Lo que no hace:** no ejecuta la suite de tests ni construye tests de reproducción. Su verificación consiste en scripts que consultan el código, más los linters. Eso es **más débil que nuestro filtro contrafactual**.

### 5.2 Calidad independiente

En un estudio de 31.073 comentarios reales en 239 repos [EXP]:

- **Un 36,4 % se aceptan, un 7,3 % se discuten y un 56,3 % se rechazan.**
- Motivos de rechazo: falsos positivos, redundancia, fuera de alcance y choque con las prácticas del equipo.
- Sus comentarios funcionales son los que más fallan.

En el Martian Code Review Bench, que es independiente, está en la parte alta, pero no claramente primero: cada proveedor se proclama primero en alguna instantánea. Conclusión: **bueno, no mágico**. Uno de cada tres comentarios se atiende.

### 5.3 Precio (página oficial, octubre de 2026)

| Plan | Anual | Mensual | Revisiones/hora por dev | Notas |
|---|---|---|---|---|
| Essentials | 24 $ | 30 $ | 5 | — |
| Team | 48 $ | 60 $ | 8 | Checks personalizados en lenguaje natural |
| Advanced | 72 $ | ~90 $ (fuente secundaria) | 10 | Revisión de seguridad |
| Enterprise | A medida | A medida | 12 | Autoalojado o región SaaS elegida (UE) |

- Solo se pagan los desarrolladores que crean PR. Nuestros PR de agentes salen con el token de cada usuario, así que cuentan como suyos y consumen su cupo por hora.
- Por encima del cupo cuesta 0,25 $ por fichero revisado.
- **Coste estimado:** con 3–6 desarrolladores, ~70–145 $/mes en Essentials, ~145–290 $/mes en Team y ~215–430 $/mes en Advanced (necesario para la revisión de seguridad), más los excesos que generen los agentes.
- **Rompe la política de gasto incremental 0 €** [A, Q11].

### 5.4 Privacidad

- **Retención:** dice que no guarda el código tras revisar [CLAIM]. Sí guarda embeddings para los aprendizajes y el índice, y se puede desactivar.
- **Entrenamiento:** no entrena con repos privados; con los de código abierto sí.
- **Certificaciones y contratos:** SOC 2 Type II. Contrato de tratamiento de datos (DPA) con cláusulas contractuales tipo (SCC). Dice cumplir ISO 27001, pero no estar certificado.
- **Ubicación:** servidores en **EE. UU.**; región UE solo en Enterprise.
- **Proveedores de modelos:** el código se envía a OpenAI y Anthropic.
- **No hemos podido leer la lista de subencargados.**
- Para repos de clientes con NDA haría falta **consentimiento del cliente**, o Enterprise con región UE.

### 5.5 Encaje

Sí podría ser un revisor más, mediante su CLI: `cr review --agent --base <sha>` devuelve NDJSON que nuestro coordinator puede leer. **No debe ser la puerta de merge**: su bloqueo funciona mediante solicitar cambios o aprobar, no con un estado ligado al SHA. Además, solaparía en gran parte con nuestros revisores Claude y Codex, que usan los mismos modelos de fondo.

### 5.6 Recomendación

1. **Copiar ya sus ideas.** Coste 0 €, con nuestra infraestructura, en este orden:
   - pasada de linters, SAST y `ast-grep` (**A1**);
   - reglas por ruta (en `policy.yml` y REVIEW.md);
   - revisión incremental (**A15**);
   - aprendizajes por supresión (**A3**);
   - comprobación contra la issue (ya la tenemos, porque Code Review recibe la spec);
   - resumen del PR para el aprobador (**A10**).

   Son sus diferencias reales.
2. **Prueba opcional en modo sombra**, solo en un **repo interno sin código de clientes**: CLI gratuita o prueba de 14 días sin tarjeta, como revisor que no bloquea. Medir cuántos hallazgos **confirmados por evidencia** aporta que Claude y Codex no vieron.
3. **Comprarlo (Team, ~150–300 $/mes) solo si se cumplen las cuatro condiciones:**
   - la prueba en sombra muestra ≥ 15 % más verdaderos positivos confirmados con ruido aceptable;
   - se aprueba una excepción a la política de 0 €;
   - se resuelve la protección de datos: lista de subencargados, DPA y SCC firmados, y consentimiento de los clientes o Enterprise con región UE;
   - se usa como revisor informativo que alimenta nuestro coordinator, **nunca como puerta**.

**Código abierto reutilizable:**

| Herramienta | Licencia | Uso |
|---|---|---|
| Qodo PR-Agent | Apache-2.0, según fuentes; comprobar el fichero LICENSE | Prompts, lógica incremental y troceado del diff |
| `ast-grep` | MIT | Reglas estructurales |
| Opengrep / Semgrep CE | LGPL; las reglas del registro de Semgrep tienen licencia restrictiva | Análisis estático de seguridad |
| `gitleaks`, `osv-scanner` | — | Secretos y dependencias |

---

## 6. Fuentes principales

Las URL completas están en los informes de cada agente, guardados como notas de trabajo. Las más relevantes:

**Anthropic**
- Claude Code Review: https://code.claude.com/docs/en/code-review · https://claude.com/blog/code-review
- Seguridad del SDLC: https://claude.com/resources/articles/how-anthropic-secures-its-ai-native-software-development-lifecycle
- Control de versiones: https://www.anthropic.com/engineering/redesigning-source-control

**OpenAI**
- Harness engineering: https://openai.com/index/harness-engineering/
- Verificación a escala: https://alignment.openai.com/scaling-code-verification/
- Codex en GitHub: https://learn.chatgpt.com/docs/third-party/github

**GitHub**
- Riesgos del agente Copilot: https://docs.github.com/en/copilot/concepts/agents/coding-agent/risks-and-mitigations
- Copilot code review: https://docs.github.com/en/copilot/concepts/agents/code-review
- 60 millones de revisiones: https://github.blog/ai-and-ml/github-copilot/60-million-copilot-code-reviews-and-counting/
- ReviewBench: https://github.blog/ai-and-ml/github-copilot/reviewbench-an-open-benchmark-for-ai-code-review/

**Google**
- AutoCommenter: https://arxiv.org/abs/2405.13565
- Resolución de comentarios con ML: https://research.google/blog/resolving-code-review-comments-with-ml/

**Meta**
- RADAR: https://arxiv.org/abs/2605.30208
- TestGen-LLM: https://arxiv.org/abs/2402.09171
- Diff Risk Score: https://engineering.fb.com/2025/08/06/developer-tools/diff-risk-score-drs-ai-risk-aware-software-development-meta/

**Microsoft**
- Revisión con IA a escala: https://devblogs.microsoft.com/engineering-at-microsoft/enhancing-code-quality-at-scale-with-ai-powered-code-reviews/
- Diez meses en dotnet/runtime: https://devblogs.microsoft.com/dotnet/ten-months-with-cca-in-dotnet-runtime/

**Empresas que programan con agentes**
- Cursor: https://cursor.com/blog/building-bugbot · https://cursor.com/blog/bugbot-learning
- Cognition: https://cognition.com/blog/multi-agents-working
- Factory: https://factory.com/news/missions-architecture · https://factory.com/news/code-review-benchmark
- Amp: https://ampcode.com/news/liberating-code-review
- Stripe: https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents
- Spotify: https://engineering.atspotify.com/2025/12/feedback-loops-background-coding-agents-part-3
- Uber: https://www.uber.com/blog/ureview/
- Atlassian: https://arxiv.org/abs/2601.01129
- LinkedIn: https://www.linkedin.com/blog/engineering/ai/high-signal-ai-code-review-that-adapts-to-your-codebase-at-scale
- Salesforce: https://engineering.salesforce.com/scaling-code-reviews-adapting-to-a-surge-in-ai-generated-code/
- Ramp: https://builders.ramp.com/post/why-we-built-our-background-agent

**Proveedores de revisión**
- Greptile: https://greptile.com/blog/make-llms-shut-up
- CodeRabbit: https://docs.coderabbit.ai/pr-reviews/request-changes-workflow · https://www.coderabbit.ai/pricing · https://www.coderabbit.ai/legal/dpa
- Qodo PR-Agent: https://github.com/qodo-ai/pr-agent
- Martian Code Review Bench: https://github.com/withmartian/code-review-benchmark

**Evidencia empírica**
- AIDev: https://arxiv.org/abs/2602.09185
- Dónde fallan los agentes: https://arxiv.org/abs/2601.15195
- PR de Claude Code: https://arxiv.org/abs/2509.14745
- CodeRabbit in the wild: https://arxiv.org/abs/2607.03316
- SWR-Bench: https://arxiv.org/abs/2509.01494
- c-CRAB: https://arxiv.org/abs/2603.23448
- ¿SWE-bench resuelto de verdad?: https://arxiv.org/abs/2503.15223
- ImpossibleBench: https://arxiv.org/abs/2510.20270
- Deuda de seguridad de los agentes: https://arxiv.org/abs/2607.12428
- Cursor, velocidad frente a calidad: https://arxiv.org/abs/2511.04427
