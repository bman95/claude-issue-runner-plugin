# Issue Runner v2: registro de investigación

Fecha: 2026-10-19. Fase de investigación y diseño. No se ha ejecutado ningún experimento ni CLI, y no se ha hecho ninguna llamada a la API de GitHub que modifique algo.
Complementa a [`issue-runner-v2-spec.md`](issue-runner-v2-spec.md). Los cambios que esta investigación provoca en la especificación están en §9.

**Método.** Para cada fuente se registra:

- el mecanismo que propone;
- la evidencia que aporta y en qué condiciones se obtuvo (tareas, modelos, muestra);
- las limitaciones para nuestro caso;
- un veredicto: **ADOPTAR**, **ADAPTAR** o **DESCARTAR**.

Etiquetas de clase de información:

- **[EXP]**: resultado experimental.
- **[DOC]**: documentación oficial.
- **[REC]**: recomendación o anécdota.
- **[COM]**: afirmación comercial.
- **[TEST]**: requiere prueba local.

**Limitación transversal.** Las páginas web se leyeron con un *fetcher* que resume el contenido. Las citas son fragmentos cortos devueltos por esa herramienta, así que antes de citarlas literalmente hay que comprobar la redacción exacta. Hay tres excepciones, que se leyeron en texto completo o como markdown oficial:

- arXiv 2607.21656 y Springer 10.1007/s10515-026-00638-5, en texto completo.
- La documentación de GitHub, como markdown oficial. Las copias están en el scratchpad de la sesión.

---

## 1. Repositorio actual

**Commit inspeccionado:** `23b7092f059fe2b1510f53e4bfec03c74c1d2989` (`origin/main`, 2026-10-05, "Model and reviewer choices with a supported channel (#81)").
**Material revisado:** README, `skills/*` (SKILL, REFERENCE y ficheros satélite), los 10 scripts de `skills/*/scripts/` con sus tests, `scripts/test-*.sh`, `docs/design-notes.md`, `docs/scenarios.md`, `docs/archive/*` y el CHANGELOG desde la 0.7.0.

### 1.1 Invariantes que v2 debe conservar

Clave: **S** = la impone un script con test; **P** = solo está en prosa.

| # | Invariante | Origen | Dónde está hoy | Destino en v2 |
|---|---|---|---|---|
| I1 | El cascade-skip se ejecuta primero, se repite hasta estabilizarse e ignora la pausa. Una dependencia `failed` tiene prioridad sobre una `closed-externally`. | Bug de 0.7.0 y #9 | S, `scheduler.sh:152-189` | Scheduler (función pura) |
| I2 | Orden de diagnóstico: `run-paused`, luego `paused` (algún ancestro transitivo está `blocked` o `ready`), y solo entonces `cycle`, citando una dependencia que siga atascada. | Ciclo mal detectado en 0.7.0 | S, `scheduler.sh:243-329` | Scheduler |
| I3 | Un `blocked` sin dependientes es `paused`, nunca `done`. `ready` (sin merge) es terminal sin escalado, y sus dependientes esperan. | `c9d439f` | S | Scheduler y estados |
| I4 | Las aristas de conflicto se serializan en un orden total (orden topológico, la primera issue en orden de alcance). | — | P, `dag.md:73-80` | Scheduler, ahora con test |
| I5 | Un lock por repositorio. Un lock vivo se rechaza, nunca se borra. Toma de control de un lock obsoleto. **Defecto conocido**: la adquisición es *check-then-write* y no es atómica. | `8d923d3` | S, `run-state.sh` | `flock` + lease en SQLite (adquisición atómica) |
| I6 | Rotar el estado nunca destruye el de una ejecución caída. | `8d923d3` | S | Como SQLite no se rota, solo queda archivar |
| I7 | No duplicar PR. Hay tres sondas: rama `/issue-N-` (el guion final evita que `issue-7-` coincida con `issue-70-`), palabra de cierre sin ambigüedad fuera de bloques de código, y ramas huérfanas. Las listas se piden con `--limit 1000`. | Filas 7, 8, 22, 23 | S, `resume-check.sh` | `ir adopt` y reanudación |
| I8 | Una sonda que no ve el estado nunca devuelve "none": si falla, el ítem pasa a `blocked`. Así el bucle siempre tiene salida. | — | S | Reconciliación (un error de lectura nunca se toma por ausencia) |
| I9 | Una rama huérfana se reanuda; nunca se lanza una ejecución nueva encima. `stale` se borra con `--force-with-lease=<tip>`. | — | S | Reconciliación |
| I10 | **Prueba de merge**: `done` exige la issue CLOSED y un PR fusionado en la rama de prueba cuyo `headRefOid` sea igual a HEAD. CLOSED sin prueba es `closed-externally` (terminal, conserva la rama). Fusionado pero abierto pasa a un humano. Un error de consulta nunca equivale a "sin prueba". Nunca se consulta con `--head ""`. | Tres agujeros reales (`REFERENCE.md:40`) | S, `classify.sh:214-257` | Merger y reconciliación |
| I11 | El estado nunca se deduce del texto de un agente (`result.json` solo informa; `progress` solo sirve para detectar cuelgues). | #80 y otros | S/P | Principio 10 de la especificación |
| I12 | Nunca se relanza un agente que sigue vivo. Dos agentes nunca comparten worktree. | — | P | Attempts con lease y pid |
| I13 | La pausa se basa solo en el error de la herramienta (`credit|quota|billing|429|rate limit|usage limit`). Un reintento que no llegó a lanzarse no consume contador. | Filas 29-33 | P | Ledger y WAITING_QUOTA |
| I14 | Algunos bloqueos nunca se reintentan en la misma ejecución: los del contrato de validación (3, 4 y 5), contract-first, un bypass de hooks no autorizado, fusionado-pero-abierto y "classification failed". | `escalations.md:177-185` | P | Tabla de errores no reintentables, con test |
| I15 | **Convergencia de la revisión**: no quedan hallazgos nuevos que haya que aplicar. Si la última iteración aplicó fixes, hace falta una iteración de verificación. Nunca se entra en la puerta final con hallazgos conocidos sin arreglar. La última pasada nunca abre una ronda de corrección. Un *bouncing* (un fix que reaparece o que contradice otro) tiene prioridad. | 0.14.0, `142d8da` | P | Coordinator §6.6 y detector de estancamiento |
| I16 | La degradación depende solo del código de salida y stderr del CLI, nunca del texto de la revisión. Solo en la pasada 1, nunca en verificaciones. | Inyección en 0.7.0 | P | Runner |
| I17 | **Liveness del gate**: resultados en ficheros por intento (`.exit .head .attempt`). Un intento obsoleto no puede sobrescribir uno nuevo. Hay perro guardián y un relanzamiento como máximo. | `ff21270` | P | Attempts con id; se descarta un resultado tardío de un attempt detenido |
| I18 | Todo bloqueo devuelve el PR a draft, sin depender de estado y sin fallar abierto. | Fila 24 | P | Merger y Gateway |
| I19 | El contrato de validación se lee solo de la punta de `origin/<base>` recién descargada, nunca del worktree. Un fichero ausente no es lo mismo que uno ilegible. | #42 | S, `validation-contract.sh` | Validator (se porta tal cual) |
| I20 | Códigos de salida del contrato: 0 bien; 1 el comando falló (sus propios códigos 2-6 **se normalizan a 1** para que no puedan falsificar un veredicto); 2 entorno; 3 contrato inválido; 4 código 126/127; 5 el contrato cambió (lo revisa un humano). 3, 4 y 5 no se reintentan. | — | S (~71 tests) | Validator |
| I21 | **Orden del refresco**: árbol limpio, rama correcta, `check`, fast-forward solo hasta `headRefOid`, merge de la base **siempre** que haya avanzado (conflictos semánticos entre ficheros), luego `changed`, `preflight` y `full`, HEAD igual al oid validado, push sin forzar, y *rollback* ante cualquier fallo o señal. | `db9c2d6` | S (~51 tests) | Merger |
| I22 | **Merge anclado a la cabeza**: `--match-head-commit <oid validado>`; después se verifica MERGED **independientemente del código de salida**; no se reintenta. Un check pendiente cuenta como fallo; `none` se vuelve a consultar. | — | S, `merge-ready.sh:331-363` | Merger (con `merge-async` y `sha`, §7) |
| I23 | Aristas: solo un `#X` en `## Blocked by`. Las aristas fuera de alcance nunca se descartan en silencio. Una arista externa solo se satisface con un PR MERGED o con una issue cerrada como COMPLETED con un PR fusionado. `owner/repo` se valida con una regex antes de usarse con `-R`. | #85 | P | Scheduler y Gateway |
| I24 | Contract-first: documentar, hacer la parada duradera (draft PR con `Refs #N`, **no** `Closes`) y parar. Solo se abre una issue de dependencia con autorización por repositorio, deduplicada por un marcador. | #85 | P | Nuevo estado, §9 |
| I25 | Un texto no fiable (cuerpos, motivos de bloqueo) nunca llega a una shell ni a una decisión de autorización. | — | P | Gateway y Runner (listas de argumentos, nunca shell) |
| I26 | Los *hints* de integración son consultivos: 60 s como máximo, se matan por grupo de procesos, nunca bloquean. Un cambio en `.issue-runner/integration` se trata como un cambio del contrato. | #60 | S | Se conserva |

### 1.2 Complejidad que v2 elimina

- **Lock basado en `$PPID`**, heartbeat tras cada pregunta y *bypass* por sesión. Se sustituye por `flock` + lease. Se mantiene la regla de toma de control de un lock obsoleto.
- **Sustitución literal de rutas** ("ninguna variable sobrevive a una llamada de herramienta"). Pasan a ser llamadas a funciones. Se mantiene que el script de validación nunca viene del worktree del PR.
- **Notificaciones intermedias** (`interim:`, cotas de cuelgue intermedias). La salida de un proceso no es ambigua. Se mantienen el timeout y el detector de estancamiento.
- **ListAgents/SendMessage**, `claude --resume` de la sesión orquestadora y `agent-trace.sh`. Se sustituyen por filas de attempts y `--resume <session_id>` guardado.
- **Paridad byte a byte de la edición Codex** (`parity-allowlist`, comprobación de lint 18). Un único coordinator usa los dos CLI.
- **Topes de palabras y líneas**, comprobaciones de punteros `(why:)` y scripts para evitar paráfrasis.
- **Lanzamiento de uno en uno** para detectar la pausa, despertares de Monitor y la regla de que el orquestador nunca entra en el worktree.
- **bash 3.2, trucos de CRLF/noglob y parser JSON en awk.** Se usa Python. Se mantiene tratar todo JSON de un agente como no fiable.
- **Subagente de refresco de `--merge-ready`** y llamadas a draft, ready o merge **dentro del prompt del agente**. Pasan al coordinator, que debe respetar I18, I21 e I22.

### 1.3 Material de tests reutilizable

Hay unos 640 asserts en 11 ficheros de test.

- **El más fácil de portar**: `test-scheduler.sh` (21 fixtures y 6 comprobaciones de fallo), tabla de entrada y salida.
- **Los más valiosos**: `test-classify.sh` (~146: prueba de merge, cuelgue, worktree; usa un stub de `gh` que registra las llamadas y un *bare origin* real), `test-merge-ready.sh` (~51), `test-validation-contract.sh` (~71), `test-run-state.sh` (~46) y `test-resume-check.sh` (~27).
- **Filas de `scenarios.md` solo en prosa** (sin test): 9, 10, 12, 13, 19, 20, 27, 28, 31, 33, 36, 38, 45-62, 73-75, 77 y 80-87.
- **Candidatas a nuevos tests de v2** con un `codex` falso: las filas 50 y 60-62 (tope y liveness del gate).

### 1.4 Casos límite que no se pueden olvidar

- `--delete-branch` falla en local si un worktree tiene la rama, así que siempre se vuelve a leer MERGED. El squash descarta el commit vacío del checkpoint. El cuerpo del squash se corta en `## Review notes`.
- **CLOSED nunca es prueba**: un PR ajeno puede cerrar la issue, y un PR puede cerrar varias. GitHub también cierra con `owner/repo#N` y con URL.
- **Los nombres de rama se repiten entre ejecuciones** (el *slug* sale del título). Toda prueba se ancla en el oid.
- **Forks**: la prueba se ancla en HEAD, no en `isCrossRepository`. Defecto conocido: el estado `ready` no está anclado a la cabeza.
- **CI en drafts** (`ready_for_review` además de los tipos por defecto). Hay que distinguir `none-after-ready`, `all-skipped` y `unchanged-after-ready`.
- **Fusionado pero abierto**: va a un humano, nunca se cierra la issue automáticamente.
- **La base avanza sin solapar ficheros**: igualmente hay que hacer merge y re-validar.
- **Valores por defecto de `gh`**: el límite de 30 resultados es insuficiente. `gh pr view <branch>` puede devolver un PR cerrado, así que se filtra por OPEN.
- **`fetch` concurrente** entre worktrees: compiten por el lock de refs, así que se reintenta 3 veces.
- **Reutilización de PID**: un lock obsoleto puede parecer vivo.
- **Cada lanzamiento nuevo** cuenta las pasadas desde 1 y limpia los ficheros del intento. Un resultado tardío de un intento detenido se descarta.

---

## 2. Arquitecturas y harnesses de Anthropic

### 2.1 *Building effective agents* (Schluntz y Zhang, 2024-12-19; editado después: menciona Agent SDK y Sonnet 4.5, y remite a Managed Agents para "the current approach")

- **Mecanismo [REC]**:
  - Workflows ("predefined code paths") frente a agentes.
  - Cinco patrones: encadenamiento con *gates*, routing, paralelización (*sectioning* y *voting*), orquestador-trabajadores y evaluador-optimizador.
  - Llamadas separadas por cada preocupación.
  - Condiciones de parada, sandbox, revisión humana en código.
  - Diseño de la interfaz agente-ordenador (ACI) a prueba de errores (*poka-yoke*).
- **Evidencia**: anécdotas de clientes y trabajo en SWE-bench. No hay comparaciones controladas.
- **Limitaciones**: es anterior a los agentes de varias sesiones.
- **Veredicto**:
  - **ADOPTAR**: coordinator = workflow; juicio solo en estados con nombre; *sectioning* para los revisores (uno por preocupación); evaluador-optimizador con tope de rondas; routing entre Sonnet y Opus; esquemas estrictos y rutas absolutas.
  - **ADAPTAR**: orquestador-trabajadores **dentro** del implementador (Claude Code puede usar sus propios subagentes); el bucle exterior sigue siendo determinista.

### 2.2 *Effective harnesses for long-running agents* (Young, 2025-11-26)

- **Mecanismo [REC]**:
  - Agente inicializador (`init.sh`, `claude-progress.txt`, lista de funcionalidades en JSON con `passes` que **solo se puede cambiar de valor**, nunca editar).
  - Git como memoria.
  - Una funcionalidad por sesión.
  - Rutina de inicio de sesión: leer el log y el progreso, y hacer un *smoke test* antes de tocar código.
- **Evidencia**: anecdótica; "no benchmarks or metrics". Una sola familia de tareas: una aplicación web nueva.
- **Limitaciones**: nuestro trabajo es una issue en un repo existente y suele caber en una sesión. El modelo se verifica a sí mismo.
- **Veredicto**:
  - **ADOPTAR**: AC en JSON inmutable. **El implementador no decide si se cumplen** (lo deciden el revisor y el coordinator). Smoke test (el `preflight` de la base) antes de empezar.
  - **ADAPTAR**: el inicializador pasa a ser código del coordinator más la preparación con Opus.
  - **DESCARTAR**: la autoverificación como control de calidad principal.

### 2.3 *Harness design for long-running application development* (Rajasekaran, 2026-03-24)

- **Mecanismo [REC + EXP con n=1]**:
  - Separar generador y evaluador: "agents reliably skew positive when grading their own work"; un evaluador escéptico es "far more tractable".
  - Calibrar el evaluador: criterios ponderados, umbral duro por criterio, ejemplos *few-shot* con puntuaciones desglosadas, y ajuste iterativo leyendo sus logs.
  - *Sprint contracts*: el generador y el evaluador acuerdan qué significa "hecho".
  - Traspasos mediante ficheros.
  - Con Opus 4.5 y 4.6 se eliminaron los reinicios de contexto y los sprints. El planificador se mantuvo porque sostenía resultados.
  - "Every component encodes an assumption"; los componentes se quitan de uno en uno.
- **Evidencia**: ejecuciones únicas.
  - El harness completo costó más de 20 veces la ejecución en solitario (200 USD frente a 9).
  - Cada ronda de control de calidad costó 3–4 USD, frente a 6–71 USD por ronda de construcción.
  - El control de calidad seguía encontrando funcionalidades a medio hacer (*stubs*).
- **Limitaciones**: aplicaciones nuevas, criterios subjetivos, el gusto del autor como verdad, evaluador de la misma familia.
- **Veredicto**:
  - **ADOPTAR**: evaluador independiente; calibración con umbral por criterio y opción de abstenerse; auditoría humana periódica de los logs de los revisores; traspasos en ficheros; ablación de componentes con cada modelo nuevo (encaja con el Registry).
  - **ADAPTAR**: el *sprint contract* pasa a ser el SpecSnapshot con un plan de verificación aprobado en la preparación (sin negociación de varias rondas). La profundidad del evaluador se escala con el riesgo.
  - **DESCARTAR**: reinicios de contexto y sprints dentro de un ítem.

### 2.4 Publicaciones posteriores que actualizan las anteriores

- **Multi-agent research system** (2025-06-13) **[EXP interno]**:
  - Un agente consume "about 4×" los tokens de un chat, y un sistema multiagente "about 15×".
  - El uso de tokens explica el 80 % de la varianza.
  - Los dominios con contexto compartido o muchas dependencias "are not a good fit… today", **con la programación citada como ejemplo**.
  - **Conclusión: deja de compensar añadir implementadores para el mismo cambio acoplado.** Se paralelizan solo los revisores independientes y las issues independientes.
- **Context engineering** (2025-09-29) **[REC]**: los subagentes devuelven resúmenes de 1–2k tokens; "do the simplest thing that works".
- **Demystifying evals** (2026-01-09) **[REC]**:
  - Calibrar los jueces con expertos humanos.
  - Un juez aislado por dimensión.
  - Opción "Unknown".
  - Evaluar resultados, no caminos.
  - "read the transcripts".
- **C compiler with parallel Claudes** (2026-02-05) **[REC, un informe]**:
  - El paralelismo falló en una tarea monolítica: todos los agentes chocaban con el mismo bug.
  - El verificador debe ser casi perfecto, y la salida de los tests debe ser corta.
- **Managed Agents** (2026-04-08) **[REC]**:
  - "Harnesses encode assumptions that go stale".
  - Log de eventos duradero fuera del contexto.
  - Contenedores desechables.
  - Credenciales fuera del sandbox.
  - **ADOPTAR** (coincide con el diseño).

**Vigencia.** El índice de ingeniería no tiene nada posterior al 2026-05-25. Ninguna de las cinco publicaciones se ha retirado. La de 2024 remite a Managed Agents para las herramientas, pero no para los principios.

---

## 3. Integración real con Claude Code y Codex

Las URL de `developers.openai.com/codex/*` redirigen (308) a `learn.chatgpt.com/docs/*`.

| Tema | Claude Code | Codex |
|---|---|---|
| **Superficie recomendada** | `claude -p` es "the Agent SDK via the CLI"; el SDK "runs the Claude Code binary" [DOC] | `codex exec` está marcado **Stable** [DOC]. El SDK de TS lanza el CLI (JSONL). El SDK de Python usa `app-server` por JSON-RPC. **`app-server` es "experimental and aren't supported for production workloads"** [DOC] |
| **Salida estructurada** | `--json-schema` → `structured_output` (draft-07). Si no coincide, vuelve a pedir la respuesta; al agotarse, `error_max_structured_output_retries`. Un `success` sin `structured_output` también es fallo [DOC]. La forma en `-p` y el código de salida exacto son [TEST] | `--output-schema`, `-o` [DOC]. El comportamiento ante un desajuste y el subconjunto de esquema admitido son [TEST] |
| **Uso y coste** | `total_cost_usd` (estimación), `modelUsage` (incluye subagentes), `usage` (solo el bucle principal), `permission_denials`, `terminal_reason` [DOC] | `turn.completed` con tokens de entrada, de caché, de salida y de razonamiento. **No hay coste en USD** [DOC] |
| **Sesiones** | `--session-id <uuid>` asignado por quien llama, `--resume`, `--fork-session`, `--no-session-persistence`. Al reanudar, el coste es **acumulado**, y los totales anteriores no cuentan para `--max-budget-usd` [DOC] | `exec resume <id>`, `--ephemeral` [DOC]. Fork solo en app-server. Uso acumulado o por turno: [TEST] |
| **Cancelación** | SIGTERM da código 143, "records no result" y mata el árbol de Bash. SIGINT termina el turno (código: [TEST]). **No hay flag de tiempo de reloj**: el timeout lo pone el coordinator [DOC] | `exec`: códigos de salida y recogida de nietos **sin documentar** [TEST]. `turn/interrupt` solo en app-server |
| **Permisos** | `dontAsk`, `--permission-prompts none` (v2.1.259+), `plan`. Orden de evaluación: hooks → deny → ask → mode → allow. **El modo por defecto puede ser `auto`, así que siempre hay que pasarlo** [DOC] | `exec` usa sandbox de solo lectura por defecto. `workspace-write` sin red. **`.git`, `.codex` y `.agents` son de solo lectura dentro de `workspace-write`** [DOC] |
| **Qué carga del repo** | Sin `--bare`, `-p` ejecuta los hooks de `.claude/settings.json` y los servidores de `.mcp.json` "even in a folder you've never trusted" [DOC]. Controles: `--setting-sources`, `--strict-mcp-config`, `--safe-mode`, `--disable-slash-commands` [DOC]; si bastan sin `--bare`: [TEST] | AGENTS.md se lee de la raíz hasta el cwd (32 KiB). No hay interruptor documentado para desactivarlo [TEST]. `--ignore-user-config`, `--ignore-rules`, `trust_level="untrusted"` [DOC] |
| **Autenticación** | Precedencia: `ANTHROPIC_API_KEY` **siempre gana en `-p`**, por delante de `CLAUDE_CODE_OAUTH_TOKEN` y de `/login`. `setup-token` da un token de un año "for CI pipelines and scripts". `--bare` no lee OAuth. `claude auth status` devuelve 0 o 1 [DOC] | API key "for programmatic… CI/CD" (recomendado). Login de ChatGPT en CI marcado como "(advanced)", solo repos privados, persistiendo `auth.json`, que se refresca solo [DOC]. Precedencia entre `auth.json` y `CODEX_API_KEY`: [TEST] |
| **Política de uso** | Los límites de Pro y Max "assume ordinary, individual usage of Claude Code and the Agent SDK". Para productos, API key. Un usuario final puede usar "the unmodified Claude Code binary with their own Claude subscription" [DOC] | — |
| **Liveness y límites** | `tool_progress` con `heartbeat:true` cada 30 s (no dentro de subagentes). `system/api_retry` con categorías (`rate_limit`, `billing_error`…). **`rate_limit_event` con `status`, `resetsAt` y `utilization`**; `credits_required` [DOC]. Si aparece igual en el stream-json del CLI: [TEST] | `exec --json` no documenta heartbeat ni eventos de límite [TEST]. app-server tiene `account/rateLimits/updated` y `UsageLimitExceeded` |

**Veredicto**:

- **ADOPTAR** `claude -p --output-format stream-json` (CLI, no SDK). Es el binario sin modificar, que es la vía claramente permitida con suscripción propia, y documenta todo lo que hace falta.
- **ADOPTAR** `codex exec --json`, porque es estable.
- **DESCARTAR** `app-server` mientras sea experimental. Se reconsiderará si las pruebas de cancelación y de señales de límite de `exec` fallan.
- **DESCARTAR** `--bare` con suscripción.

**Las 10 pruebas locales pendientes** (fase F0 de la especificación):

1. Autenticación OAuth sin `ANTHROPIC_API_KEY`, y aislamiento sin `--bare`.
2. Fallo de esquema en Claude.
3. Fallo de esquema en Codex.
4. Señales y códigos de salida, y recogida de nietos, en los dos CLI.
5. Precedencia de credenciales en Codex.
6. Aprobaciones en `exec`.
7. Qué carga Codex de un repo no confiable.
8. Bloqueo real de escritura en los revisores Claude.
9. Heartbeat y `rate_limit_event` en el CLI con suscripción.
10. Uso al reanudar.

---

## 4. Motores de ejecución durable

| | Temporal | LangGraph | DBOS (alternativa ligera) | Propio (SQLite + outbox) |
|---|---|---|---|---|
| **Recuperación** [DOC] | *Replay* del historial; exige determinismo | Checkpoint por *super-step*; hace falta `durability="sync"` | Desde el último paso completado; exige determinismo | La que construyamos |
| **Cancelar un paso largo** | Por heartbeat, integrado: "Activities that don't Heartbeat can't receive a Cancellation" | No hay para nodos en ejecución | Entre pasos, o pasos asíncronos `preemptible` | Propio (supervisor + pgid) |
| **Espera humana con plazo** | Signals/Updates y temporizadores duraderos sin límite | `interrupt()`; **sin temporizadores**; al reanudar, el nodo se repite entero | `recv(timeout)`, eventos, `sleep` duradero | `wake_at` + bandeja de entrada (sencillo) |
| **Versionado en curso** | `patched()`, Worker Versioning, tests con Replayer | Reglas de topología limitadas, sin API de parches | `application_version` (por defecto un hash del código: **una edición deja huérfanos los workflows en curso** si no se fija) y `patch` | Propio (`workflow_version` por ítem) |
| **Idempotencia en GitHub** | **Nuestra**: "enforced by the service you are calling" | **Nuestra**: "Use idempotency keys or verify existing results" | **Nuestra** (el workflow-ID evita duplicar ejecuciones) | Nuestra |
| **Operación** | Servidor (el de desarrollo "not intended for production") o Cloud de pago | Biblioteca | Biblioteca; Postgres recomendado en producción | Nada |
| **Tests** | Los mejores (salto de tiempo, Replayer) | Básicos | Básicos | Propios (reloj inyectado y fallos inyectados) |

**Conclusiones**:

- Ningún framework hace *exactly-once* los efectos en GitHub. Supervisar subprocesos y reconciliar antes de actuar es trabajo nuestro en las cuatro opciones.
- **LangGraph: DESCARTAR.** Su valor son los grafos dirigidos por LLM, que excluimos. No tiene temporizadores ni cancelación de nodos en ejecución.
- **Temporal: DESCARTAR mientras haya un solo host.** Se reconsidera si hay varios hosts, más de unos pocos ítems a la vez, workflows que cambian con frecuencia mientras hay ejecuciones de días en curso, o si se acepta Temporal Cloud.
- **Propio: ADOPTAR**, con la ventaja estructural de que no hay *replay* (sin restricciones de determinismo y estado inspeccionable con SQL), y con presupuesto explícito para:
  - recuperación al arrancar con adopción por pid y hora de inicio;
  - outbox con reconciliación;
  - versionado manual;
  - **tests con fallos inyectados en cada frontera de estado**, donde suelen fallar las máquinas de estado escritas a mano.
- **DBOS: alternativa viable** si crecen los tipos de workflow. Habría que fijar `application_version`.

---

## 5. Pipelines de reparación y verificación

### 5.1 Agentless (Xia et al., arXiv 2407.01489; SWE-bench Lite; gpt-4o-2024-05-13)

- **Mecanismo**:
  - Localización jerárquica (fichero, luego clase o función, luego línea).
  - 40 parches por bug.
  - Test de reproducción que **solo se conserva si falla en el código original**.
  - Selección de tests de regresión.
  - Voto mayoritario normalizado por AST.
- **Evidencia [EXP]**:

  | Selección | Resuelto |
  |---|---|
  | Solo voto | 25,67 % |
  | + regresión | 27,0 % |
  | + reproducción | 32,0 % (+0,25 USD por issue) |

  - El oráculo (alguna muestra correcta) llega al 42 %.
  - Una única muestra greedy por localización ya da 80 de los 96 aciertos.
  - **De los tests que "reproducían", solo 94 de 213 pasaban con el parche correcto**: más de la mitad estaban mal o eran demasiado específicos.
  - El 4,3 % de las issues contenían el parche exacto.
- **Limitaciones**: solo Python, solo SWE-bench, contaminación admitida, modelos obsoletos. La brecha frente a los agentes es de 2024. Los números de Claude del README no tienen ablación [COM].
- **Veredicto**:
  - **ADAPTAR** el test de reproducción con la puerta "falla en la base por la razón de la issue". Se trata como evidencia, no como verdad, y el revisor comprueba que prueba el comportamiento de la issue y no el propio parche.
  - **ADOPTAR** la comparación de tests entre base y candidato (barata).
  - **DESCARTAR** el muestreo masivo y la localización como etapa separada.

### 5.2 SWE-Gym (Pan et al., arXiv 2412.21139, ICML 2025)

- **Mecanismo**:
  - 2.438 tareas ejecutables de 11 repos Python, con entorno preparado a mano (unas 200 horas humanas y 10k horas de CPU).
  - Validación: el parche de referencia pasa más tests que el original.
  - Verificador entrenado (Qwen2.5-32B) sobre 2.636 trayectorias etiquetadas por los tests.
- **Evidencia [EXP]** (OpenHands sobre Verified):

  | k | Oráculo | Verificador |
  |---|---|---|
  | 8 | 37,8 % | 29,8 % |
  | 16 | 42,8 % | 32,0 % |

  - **No hay precisión, recall ni comparación con el azar.**
  - Con datos de otra política se estanca en torno al 22 %.
  - La automejora hizo bajar el resultado (15,3 % → 8,7 %).
- **Limitaciones**: modelos abiertos obsoletos, solo Python. El verificador necesita miles de trayectorias **del mismo agente**.
- **Veredicto**:
  - **ADOPTAR** como especificación del *replay*: base fijada, dependencias, comando de test, validación "falla antes, pasa después".
  - **ADOPTAR** el log de trayectorias con etiquetas de resultado.
  - **DESCARTAR** el verificador entrenado por ahora.

### 5.3 OpenHands, *Learning to Verify AI-Generated Code* (blog 2026-03-05; paper arXiv 2603.03800)

- **Mecanismo**:
  - Un crítico de 4B entrenado con 38k conversaciones de producción.
  - 24 rúbricas de comportamiento etiquetadas por o3.
  - Etiquetas escasas de resultado: PR fusionado y **supervivencia del código** en el diff final.
- **Evidencia [EXP]**:
  - Sobre 386 conversaciones reales:
    - Un crítico entrenado con benchmarks obtiene AUC 0,45–0,48, **peor que el azar**.
    - Entrenado con supervivencia del código, AUC 0,69, con precisión 0,60 y recall 0,87.
  - En Verified, solo sobre el subconjunto de 148 instancias con resultados mixtos:
    - Best@8 73,8 % frente a 57,9 % al azar.
    - Con Opus el resultado degrada por debajo del azar ("overfits to Sonnet 4.5").
- **Comercial [COM]**: titulares calculados sobre un subconjunto elegido; dice "better-calibrated" sin análisis de calibración; tiene un gancho de producto.
- **Veredicto**:
  - **ADOPTAR** la taxonomía de rúbricas como lista de comprobación del Judge y los revisores.
  - **ADOPTAR** la supervivencia del código y el PR fusionado como etiquetas del Registry.
  - **ADAPTAR** la parada temprana (segundo candidato solo si el primero falla).
  - **DESCARTAR** el crítico publicado, porque se entrenó con otros agentes y otra población.

**Respuestas a las preguntas de la investigación**:

- **(a) Tests de reproducción**: sí, para issues de tipo bug con harness de tests, escritos **antes** del fix y validados por el coordinator en la base.
- **(b) Muestreo frente a revisión**:
  - Toda selección pierde casos.
  - La ganancia barata viene de señales de ejecución, no de verificadores LLM.
  - Por eso el diseño es un candidato con tests y revisión, y un segundo solo si fracasa.
  - Selección: primero tests, después el Judge.
- **(c) Registry y *replay***: entornos fijados; descartar tareas cuyo texto contiene la solución; tener en cuenta la contaminación de issues antiguas; supervivencia del código.
- **(d) Precisión y recall de los verificadores**: datos escasos. El único dato real indica que en torno al 40 % de las alarmas son falsas. Hay que medir nuestra propia precisión.

---

## 6. Riesgos de la revisión con modelos

### 6.1 Xiang, Zhang, Zhang, Xu, *Cross-Model LLM Code Review* (arXiv 2607.21656v1, 2026-07-22; taller SE 3.0)

- **Condiciones**:
  - Claude Opus 4.7 (Claude Code 2.1.50) y GPT-5.5 (Codex CLI), ambos con esfuerzo high.
  - 116 tareas LiveCodeBench de un solo fichero Python.
  - Una ejecución por condición, McNemar con corrección BH.
  - **El revisor es estático y siempre reescribe**: devuelve el programa final. No hay brazo de solo lectura.
- **Resultados [EXP]** (A = Claude, O = Codex; escritor y luego revisor):

  | Condición | Pass rate | Fixes / regresiones |
  |---|---|---|
  | A solo | 91,4 % (no superado por ninguna condición) | — |
  | O solo | 71,6 % | — |
  | OA | 89,7 % | 26 / 5 |
  | OO | 84,5 % | 21 / 6 |
  | AA | 91,4 % | 3 / 3 |
  | AO | 82,8 % | **3 / 13** |

  - AO frente a OA no es estadísticamente separable.
- **Interpretación de los autores (no medida)**: una revisión dañina "throws away a working draft and rewrites it". Proponen decidir primero si intervenir y conservar la estructura del escritor.
- **Limitaciones**:
  - Un par de modelos y un benchmark.
  - La diferencia entre los resultados en solitario se confunde con la dirección de la revisión.
  - "does not generalize to repository-scale bug fixing".
  - No hay ni revisión de solo lectura ni seguridad.
- **Veredicto**:
  - **ADOPTAR** Codex en solo lectura por defecto, que ya era [A].
  - **ADOPTAR** contar fixes y regresiones por separado en toda ruta que reescriba (Codex Fixer).
  - **ADOPTAR** la instrucción "intervenir solo si hace falta; parche mínimo que conserve la estructura".
  - **No extrapolar** que "Codex revisa peor a Claude" a Sonnet como escritor, a PR de repositorio ni a una revisión que solo comenta.

### 6.2 Jin y Chen, *Are LLMs reliable code reviewers? Systematic overcorrection…* (Automated Software Engineering, nov. 2026, acceso abierto)

- **Condiciones**:
  - Unas 1.400 parejas correcto/defectuoso (HumanEval-X-Bugs, MBPP reconstruido, QuixBugs).
  - GPT-4o, Claude-4.5-sonnet, Gemini-2.0-flash, Llama-3.1-8B y Mistral-24B.
  - Tres modos de prompt: Sí/No, + explicación, + explicación y fix.
- **Resultados [EXP]**:
  - **Pedir explicación y fix dispara los rechazos falsos.**
    - GPT-4o: FNR del 26,2 % al 73,2 % en HumanEval.
    - Claude-4.5-sonnet: la misma tendencia, más suave. FNR del 26 % al 36 % en HumanEval y del 40 % al 50 % en QuixBugs.
    - Incluso en el mejor caso rechaza en torno a 1 de cada 4 programas correctos.
  - El 48 % de las objeciones falsas son "Logic Error" sin contraejemplo verificable.
  - Los veredictos contradicen su propia justificación.
  - El revisor acierta en "hay un fallo" (95–100 %) pero no en la causa (41–71 %).
  - **Filtro de verificación guiado por el fix**: ejecutar el original y el fix propuesto contra los tests más tests generados desde la especificación. Si se comportan igual, el rechazo se anula; si el fix rompe algo, también. El FNR baja del 54,8 % al 16,3 % y el FPR sube unos 2,5 puntos como máximo.
- **Limitaciones**:
  - Funciones pequeñas y autocontenidas, una sola versión de Claude.
  - Cada test sigue una sola lectura de la especificación.
  - "may not directly transfer to industrial settings".
- **Veredicto**:
  - **ADOPTAR** que cada objeción es una hipótesis que pide evidencia ejecutable (test, entrada concreta o escenario reproducible). Sin ella, no bloquea por sí sola.
  - **ADOPTAR** el filtro contrafactual para el Codex Fixer y para las alternativas propuestas.
  - **ADOPTAR** que el coordinator lee campos estructurados, nunca la prosa.
  - **ADAPTAR** que las objeciones de tipo "requisito añadido" o "especificación mal leída" se contrastan con los AC (Judge).
  - **No extrapolar** los niveles de FNR, solo la dirección del efecto.

### 6.3 craigkitterman/cross-model-code-review-skill (commit único `2e3916b`, 2026-03-16, MIT)

- **Código inspeccionado**: no hay scripts. Es un paquete de prompts (SKILL.md de 318 líneas y ficheros de referencia).
- **Mecanismo real**:
  - Lanza `codex exec --full-auto`, `gemini -p` y `aider --yes` en segundo plano con un timeout de 5 minutos. **Los "revisores" pueden escribir en el árbol** y nada lo impide.
  - Agrupa hallazgos a ±5 líneas.
  - Votos: 3 o más modelos = "CRITICAL CONSENSUS".
  - "highest severity… wins" y "Security concerns always win".
  - Hasta 3 iteraciones.
- **Evidencia**: ninguna.
- **Valoración**: la agregación amplifica los falsos positivos, al contrario de lo que indica §6.2. El orquestador revisa y además arbitra.
- **Veredicto**:
  - **ADOPTAR** el esquema normalizado de hallazgos y el seguimiento FIXED/NOT_FIXED más "nuevos introducidos".
  - **ADAPTAR** el emparejamiento, implementado en código determinista; los votos sirven solo como desempate.
  - **DESCARTAR** revisores con `--full-auto`, escalado por la severidad máxima, "consenso = certeza" y mezclar los roles de revisor y árbitro.

### 6.4 iCoder (Information and Software Technology, oct. 2026, DOI 10.1016/j.infsof.2026.108224)

- **Accesibilidad**: ScienceDirect y SSRN 6027954 devuelven 403. Crossref, Semantic Scholar y OpenAlex no tienen resumen. No hay versión en arXiv ni de los autores (el "iCoder-27B" de arXiv es otro trabajo).
- **Solo hay** un fragmento de resumen de un buscador, sin verificar (cuatro agentes RABot, UMLBot, DevBot y ReviewBot; SRDD; GPT-3.5 y GPT-4o).
- **Veredicto: no se usa como evidencia.** No se cita ninguna cifra de fuentes secundarias. Vía pendiente: el PDF de SSRN con acceso institucional.

### 6.5 Síntesis sobre revisión

- **Asimetría escritor/revisor**: solo §6.1 la estudia, y en tareas algorítmicas. Revisar ayudó a un escritor más débil y fue neutro o dañino para uno más fuerte.
  - Con Sonnet escribiendo y Opus o Codex revisando, la dirección "revisor más fuerte" es plausiblemente favorable, pero **no está establecida** para Sonnet ni para PR.
  - Ninguna fuente mide la autopreferencia en código. El trabajo de Panickssery de 2024 es sobre resúmenes.
- **Objeciones falsas**: son frecuentes, y empeoran si se pide explicar o arreglar. Si se obedecen sin evidencia, se "arregla" código correcto.
- **Solo lectura frente a reescritura**: no hay comparación directa. El daño observado procede de reescrituras. Afirmar que la solo lectura "evita" regresiones sería extrapolar.

---

## 7. Integración y aprobación en GitHub

Material: markdown oficial de docs.github.com.

- **Merge con SHA fijado [DOC]**:
  - `PUT /pulls/{n}/merge` con `sha`: 409 si la cabeza no coincide, 405 si no se puede fusionar.
  - **GitHub recomienda ahora `PUT /pulls/{n}/merge-async`**:
    - Con `sha`: si hay un push entre la petición y la ejecución, "the merge will be cancelled".
    - Opciones `merge_action=direct_merge|merge_queue` y `bypass_rules=false`.
    - 202 con un UUID.
    - **Una repetición devuelve 409 con el UUID pendiente, o 200 si ya está fusionado.**
    - El resultado se consulta en `GET …/merge-async/{uuid}` (`pending|merged|enqueued|failed`) y se conserva 24 h.
    - Las reglas de protección no se evalúan en la fase de petición.
  - `GET …/merge`: 204 = fusionado, 404 = no.
  - `mergeable` se calcula en segundo plano (`null` significa reintentar).
- **Actualizar la rama [DOC]**: `update-branch` con `expected_head_sha` (422 si no coincide); crea un SHA nuevo que nadie ha revisado.
- **Check runs frente a commit statuses [DOC]**:
  - **Solo una GitHub App puede crear check runs**; un PAT no.
  - Un commit status lo puede crear cualquiera con push.
  - **La protección de rama o un ruleset puede exigir que el check venga de una App concreta**: "If the status is set by any other person or integration, merging won't be allowed".
  - Los checks requeridos deben pasar en el último SHA. `neutral` y `skipped` cuentan como éxito.
  - Si un check y un status tienen el mismo nombre, deben pasar los dos.
  - Un check de workflow solo cuenta si lo disparó `push`/`pull_request`/… (no vale `workflow_dispatch`); esto no aplica a una App externa.
- **Webhooks [DOC]**:
  - Hay que responder en 10 s.
  - `X-GitHub-Delivery` es un GUID que se mantiene en las reentregas.
  - **GitHub no reentrega automáticamente**: hay una API para listar y reentregar, con una ventana de 3 días (la documentación dice 3 y 7; se asume 3).
  - Ni orden ni *exactly-once* están garantizados (inferido).
- **Actions [DOC]**:
  - Un evento disparado por `GITHUB_TOKEN` no lanza workflows, así que el push debe hacerse con token de App o PAT.
  - `pull_request` no corre si hay conflictos de merge.
  - `GITHUB_SHA` es el merge de prueba.
  - Los grupos de concurrencia no garantizan orden, así que los resultados tardíos se asocian al SHA.
- **Protección y cola [DOC]**:
  - Opciones: modo estricto (rama actualizada); descartar aprobaciones obsoletas; "most recent reviewable push must be approved by someone other than the person who pushed it"; los administradores pueden saltarse la protección salvo que se active "Do not allow bypassing".
  - La merge queue prueba ramas `gh-readonly-queue/*` con un SHA distinto del revisado. El auto-merge no fija el SHA.
- **Límites de uso [DOC]**:
  - REST: 5.000 por hora con PAT; App de 5.000 a 12.500.
  - Límites secundarios: 80 escrituras por minuto y 500 por hora.
  - Mutaciones en serie con al menos 1 s entre ellas.
  - Las peticiones condicionales (ETag, respuesta 304) no consumen cuota primaria.
  - Respetar `retry-after`.
- **Otros [DOC]**: el *timeline* incluye el `actor` de los eventos de etiqueta; hay un endpoint de permiso de un colaborador.
- **Veredicto**:
  - **ADOPTAR**:
    - GitHub App con check run `issue-runner/gate` sobre `head_sha`, **fijado a la App en el ruleset**.
    - `merge-async` con `sha` y `direct_merge`, guardando el UUID antes de seguir.
    - Push con `--force-with-lease=<rama>:<sha esperado>` y reconciliación con `ls-remote`.
    - Polling con ETag; los webhooks solo como pista.
    - Activar descartar aprobaciones obsoletas, aprobación del último push y "Do not allow bypassing".
  - **DESCARTAR** merge queue y auto-merge, porque no fijan el SHA revisado.

---

## 8. Matriz resumen

| Fuente | Adoptar | Adaptar | Descartar |
|---|---|---|---|
| Repo v1 | I1–I26, contratos, tests | Stub de `gh` y *bare origin* para tests de integración | Lock por PPID, prosa, paridad con Codex |
| Building effective agents | Workflow determinista, *sectioning*, evaluador-optimizador con tope, routing, ACI | Subagentes dentro del implementador | — |
| Long-running harnesses | AC inmutables (no los valida el implementador), smoke test | El inicializador pasa a ser código + Opus | Autoverificación |
| Harness design 2026 | Evaluador independiente y calibrado, abstención, auditoría de transcripciones, ablación | Contrato de "hecho" en la preparación; profundidad según riesgo | Reinicios de contexto, sprints |
| Multi-agent / evals / Managed Agents | Un implementador por issue; log duradero; credenciales fuera del sandbox; juez por dimensión con "Unknown" | — | Multiagente sobre el mismo cambio |
| Claude Code / Codex | `claude -p` stream-json; `codex exec --json`; timeouts propios; limpiar el entorno | Aislamiento sin `--bare` | app-server (experimental), `--bare` con suscripción |
| Temporal / LangGraph | Máquina de estados propia + outbox + tests con fallos inyectados | DBOS si crece | LangGraph; Temporal por ahora |
| Agentless / SWE-Gym / OpenHands | Comparar tests base/candidato; log de trayectorias; supervivencia del código; rúbricas | Test de reproducción con puerta en la base; segundo candidato solo si falla | Muestreo masivo; verificador entrenado; crítico publicado |
| Riesgos de revisión | Evidencia ejecutable; filtro contrafactual; fixes y regresiones por separado; intervención mínima | Contrastar con los AC en el Judge | Escalado por severidad máxima; consenso como verdad; revisores que escriben |
| GitHub | App + check run fijado; `merge-async` con `sha`; push con lease; ETag | — | Merge queue, auto-merge, commit status como puerta |
| iCoder | — | — | No se usa (inaccesible) |

---

## 9. Cambios en la especificación derivados de esta investigación

Aplicados en `issue-runner-v2-spec.md`; cada uno lleva su sección indicada:

1. **§5.6 y §6**: evidencia ejecutable.
   - Campo `evidence_kind` (`test|input|trace|static`) y `repro` opcional en los hallazgos.
   - El coordinator ejecuta los `repro` de los revisores en un worktree temporal (**filtro contrafactual**).
   - Un hallazgo `major` solo con razonamiento estático pasa a VERIFY, no a MUST_FIX. La seguridad deja de ser fail-closed sin evidencia en riesgo bajo o medio (con riesgo alto sigue siéndolo).
   - La corroboración entre familias sube la confianza un nivel como máximo y nunca sustituye a la evidencia.
2. **§5.4**: tests de reproducción. En issues de tipo bug con harness, el implementador escribe primero el test, y el coordinator verifica que **falla en la base** y pasa en el candidato. El revisor audita que prueba el comportamiento de la issue.
3. **§5.9**: puerta contrafactual del Codex Fixer.
   - Fixes y regresiones por separado.
   - Instrucción de parche mínimo.
   - **El coordinator hace el commit**, porque `.git` es de solo lectura en `workspace-write`.
4. **Prompts de revisor**: "sin hallazgos" es un resultado válido y esperado; se permite abstenerse (`unknown`); `proposed_fix` deja de pedirse; y se incluye una lista de rúbricas.
5. **§5.11 y §5.12**: GitHub App con check run fijado al ruleset; `merge-async` con `sha`; push con lease; ETag; protección recomendada.
6. **§8.2**: stream-json; siempre `--permission-mode` explícito; timeouts propios; `--setting-sources`/`--strict-mcp-config`/`--disable-slash-commands`; `claude auth status` como comprobación previa; Codex por `exec`, no app-server.
7. **§10.3**: `rate_limit_event.utilization`/`resetsAt` como señal primaria de cuota si F0 confirma que aparece en el CLI. La estimación por tokens queda como respaldo.
8. **§9.5 y §15**: tests con fallos inyectados en cada frontera de estado; `workflow_version` por ítem; portar los ~640 asserts de v1 donde apliquen.
9. **§12**: etiquetas de supervivencia del código y de fixes/regresiones por revisor; especificación del *replay* (base fijada, fallar antes y pasar después, descartar issues que contienen la solución, advertencia de contaminación).
10. **§1.2 y §5.3**: invariantes I1–I26 trazadas; nuevo estado CONTRACT_FIRST_STOP; vuelta a draft ante cualquier bloqueo.
11. **§17**: nuevas preguntas Q10 (GitHub App frente a PAT) y Q11 (línea de facturación de Codex, ahora que la documentación recomienda API key para automatización).
