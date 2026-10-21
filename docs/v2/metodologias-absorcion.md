# Metodologías de trabajo con agentes: qué absorber (GSD, Superpowers, Spec Kit, OpenSpec, BMAD)

> Nombre provisional: "Issue Runner" e `ir` son nombres de trabajo; el producto se renombrará.

Fecha: 2026-10-21. Modo: investigación y diseño. No se instaló ni ejecutó nada de estos repos; se leyeron como datos.

## 0. Resumen para humanos

- **Ninguno sustituye a nuestro diseño.** Los cinco son metodologías **escritas en prompts** para sesiones interactivas: un humano delante y un agente que sigue skills o comandos. Nuestro producto es una tubería desatendida con un coordinador determinista. Sus propias fuentes admiten los fallos que el coordinador evita:
  - En Superpowers, el agente se saltaba el design doc en 24 de 24 ejecuciones, y en 3 de 24 después del arreglo. Cuesta unos 13 USD por ejecución.
  - GSD reconoce que "the orchestrator cannot verify semantic correctness of agent output — only structural completeness". Su orquestación son 1.415 líneas de prosa parcheadas issue a issue, y depende de hooks.
- **Sí tienen técnicas valiosas a nivel de prompt y de formato.** Las meteríamos en nuestros prompts de rol, en el formato AI-Ready y en el Review Coordinator. Las propongo como **B1–B12** (§3).
- **Mucho ya lo teníamos.** La taxonomía `clarify` y los "unit tests for English" de Spec Kit, la congelación de la spec al aprobar, la lectura en frío, worktrees aislados, el test de reproducción que falla en la base, las waves con conflicto por ficheros y la espera por cuota ya estaban en el diseño. Lo marco para no duplicar.
- **Recomendación:** no adoptar ninguno como dependencia ni combinarlos. Copiar las ideas (todas son MIT, así que se pueden copiar textos conservando el aviso) y medirlas con nuestro Registry.

## 1. Hechos verificados y correcciones al resumen recibido

| Sistema | Revisado | Licencia | Correcciones |
|---|---|---|---|
| Get Shit Done | `gsd-build/get-shit-done` @ `bdcaab2` (2026-05-31) | MIT | **Archivado** el 2026-06-26. Su README apunta a GSD Core, pero GSD Core no menciona al original. El original solo declaraba soporte para Claude Code; la lista amplia de agentes es de GSD Core |
| GSD Core | `open-gsd/gsd-core` @ `812ddb5` (2026-10-21) | MIT | Instalación `npx @opengsd/gsd-core@latest` confirmada. Hay un paso opcional de UI entre discuss y plan. La verificación tiene dos partes: un agente verificador y una UAT con el usuario. Los "200k de contexto limpio" son una cifra de la documentación, no un límite que el sistema imponga |
| Superpowers | `obra/superpowers` @ `2ce8aa1`, v7.0.1 (2026-10-21) | MIT | Ya **no** usa tareas de "2–5 minutos": ahora cada paso es "one action with a checkable result". Ya **no** tiene dos revisores por tarea: queda un revisor con dos veredictos (spec y calidad), porque dos eran "expensive and easy to game" |
| Spec Kit | `github/spec-kit` main, v1.2.3.dev0 | MIT | Python 3.11+ y `uv` confirmados. Los comandos se escriben ahora `/speckit-specify` (con guion). Hay comandos nuevos: `converge` y `taskstoissues` |
| OpenSpec | `Fission-AI/OpenSpec` v1.14.3 | MIT | Node ≥ 20.19.0 confirmado. Los comandos son `/opsx:explore\|propose\|apply\|archive` |
| BMAD | `bmad-code-org/BMAD-METHOD` v6.12.4 (v7 en alfa) | MIT | Ya no hay agentes SM ni QA. Los *story files* son *shims* obsoletos. Las vías "quick/full" pasan a llamarse *planning paths* (Trivial / One session / Epic / Project). Las *QA gates* son un módulo enterprise aparte (TEA). No hay *sharding* en 6.12.4 |

El criterio final del resumen ("elegir uno según el problema y no combinarlos") es correcto para quien programa en sesión interactiva. Para nosotros la conclusión es otra: no adoptar ninguno, absorber ideas.

## 2. Qué ya teníamos (confirmación, sin cambios)

| Idea externa | Dónde está ya en nuestro diseño |
|---|---|
| Taxonomía `clarify` y "unit tests for English" (Spec Kit) | Rúbrica del Spec Critic (preparación §6.1) |
| Máx. 3 `[NEEDS CLARIFICATION]`, léxico vago (Spec Kit) | Lint L5 y L6: no se admite ninguno |
| `frozen-after-approval` (BMAD) | Aprobación ligada al hash de la spec y PAUSED_SPEC_DRIFT. El hash es más fuerte |
| Builder check: un subagente nuevo lee el diseño sin poder preguntar (Superpowers) | Lectura en frío con Sonnet (preparación §5) |
| Requisito con escenario verificable por un tercero (OpenSpec) | AC en forma EARS o GWT con línea `Verify` (L2, L4) |
| Tope de preguntas y opción recomendada primero (Spec Kit, GSD) | Entrevista del Planner con un máximo de 5 preguntas por ronda |
| Waves por dependencias y solape de ficheros (GSD) | DAG con `Blocked by` y aristas de conflicto por `Files likely touched` |
| Revisor que no se fía del informe del implementador (Superpowers) | Los revisores no ven las notas del implementador (§5.6) |
| Test que falla por la razón correcta antes del arreglo (Superpowers TDD) | Test de reproducción que debe fallar en la base, ejecutado por el coordinador (§5.4) |
| `converge`: spec frente a código (Spec Kit) | `acceptance[]` de Code Review más la puerta 5 de Verify |
| Límite de uso a mitad de una wave (GSD #3095) | WAITING_QUOTA y reanudación |
| Worktree aislado (Superpowers) | Lo crea el coordinador |
| Contexto por rutas y resultado corto (GSD, Superpowers) | Sobre `ir.input.v1` con rutas y salida JSON por esquema |

## 3. Propuestas B1–B12

Notación: **[P]** propuesta, **[H]** hipótesis que medir. La columna "coste" es el trabajo añadido en v2.0.

### Preparación

**B1. Sección `Review focus` en AI-Ready** [P; Superpowers `writing-plans`]

- El Planner lista de 2 a 5 entradas o modos de fallo que la spec implica y que ningún criterio ejercita todavía (vacíos, concurrencia, permisos, límites, codificación…).
- Cada uno acaba de una de dos formas: como criterio con `Verify`, o como foco explícito para los revisores.
- Code Review y Security Review reciben la sección como lista de comprobación. El Spec Critic valora si falta un modo de fallo obvio.
- Lint: obligatoria en `feature` y `bug` con riesgo `medium` o superior.
- Por qué: los revisores LLM rinden mejor con un foco concreto que con "busca problemas", y esto lo fija quien conoce la intención.
- Coste: bajo.

**B2. Interfaces entre slices (`Produces` / `Consumes`)** [P; Superpowers "Interfaces", GSD `key_links`]

- Cuando un slice depende de otro (`Blocked by`), el productor declara en `## Context` la firma exacta que expone (`Produces:`) y el consumidor la que usa (`Consumes:`).
- Nuevo lint **L17**: las firmas deben coincidir textualmente.
- Tras el merge del productor, el coordinador comprueba con `git grep` que la firma existe en la base antes de despachar al consumidor. Si no, el consumidor vuelve a preparación.
- Coste: bajo. Ataca el fallo típico de slices que encajan mal.

**B3. Lectura en frío con tres montones y "un objetivo por slice"** [P; Superpowers builder check, BMAD step-01]

- El `ColdReadReport` clasifica cada duda como:
  - `answered_in_spec`, con cita: se descarta;
  - `minor`: el lector asumiría algo razonable, que se pasa a `Assumptions`;
  - `needs_human`.
- Solo `needs_human` vuelve a la entrevista. Las preguntas se ordenan por "cambiaría el plan".
- El lector señala `multiple_goals: true` si el `What to build` persigue más de un resultado. El coordinador lo trata como propuesta de corte, igual que L11.
- Coste: muy bajo. Reduce las rondas de entrevista por dudas que ya estaban respondidas.

**B4. Mapa del repo como contexto de confianza** [P/H; GSD `map-codebase`]

- `ir doctor --init` (y luego `ir map`) genera `.issue-runner/codebase.md` con stack, arquitectura, estructura, convenciones, cómo se testea y zonas delicadas.
- Lo genera una ejecución de solo lectura y entra en el repo **mediante un PR que revisa una persona**. Así pasa a ser contexto de confianza, coherente con el contrato de autosuficiencia.
- El fichero lleva el SHA del que se generó. El coordinador avisa cuando quedan obsoletos muchos de los ficheros que describe.
- Lo usan el Planner, la lectura en frío y el implementador.
- **H-32:** reduce los tokens de exploración y las rondas sin empeorar la calidad. Medirlo con y sin el mapa en el piloto.
- Coste: medio. Se puede aplazar a v2.1 si el piloto no lo pide.

### Implementación

**B5. Paquete de prompt del implementador** [P; Superpowers, GSD; texto MIT conservando el aviso]

Se añade a `roles/implementer.md`:

- **Tabla "afirmación → qué la demuestra → qué no basta"** (`verification-before-completion`). Ejemplo: "tests pasan → salida del comando en esta ronda; no basta con haberlos ejecutado antes".
- **"Un test rojo que viste pasar y no mencionaste es un informe falseado por omisión."**
- **Detenerse está bien:** "Es mejor parar que entregar trabajo malo; escalar no penaliza." Se añade el estado `completed_with_concerns`, con `concerns[]`. El coordinador pasa las `concerns` a los revisores como foco y a la tarjeta de aprobación.
- **Regla de desviación arquitectónica** (GSD, regla 4): si para cumplir la spec hace falta un cambio de arquitectura no previsto (nueva dependencia, nuevo módulo, cambio de esquema), el implementador para con `blocked`, `blocker.kind = architecture`, y el coordinador lo manda a preparación.
- **Depuración sistemática para `bug`:** primero la causa raíz, una hipótesis cada vez, y tras 3 arreglos fallidos del mismo síntoma responder `cannot_fix` en vez de seguir parcheando.
- **Commits por criterio:** un commit por AC o por paso lógico. Facilita la revisión del delta y localizar regresiones.
- Coste: muy bajo, solo texto. Se valida con B12.

**B6. Evidencia RED/GREEN declarada y contrastada** [P; Superpowers TDD]

- `ImplementationResult` gana `tdd_evidence[]`: comando, resultado esperado (`fail`/`pass`) y resumen de salida para los tests que dice haber escrito primero.
- El coordinador **no se lo cree**: vuelve a ejecutar esos comandos sobre el commit anterior y el posterior.
- Si lo declarado no coincide con lo observado, genera un hallazgo determinista `tests` con `ev = confirmed`.
- Coste: bajo, porque reutiliza el ejecutor de repros. Convierte una regla de prompt en una comprobación.

**B7. Barrido anti-stub y "cableado"** [P; GSD verifier, tres niveles]

Se amplía la pasada estática (A1) con comprobaciones deterministas sobre el diff:

- `TODO`/`FIXME`/`TBD`/`XXX` nuevos sin referencia a issue: hallazgo `major`.
- Cuerpos vacíos o de relleno nuevos (`pass`, `NotImplementedError`, `throw new Error("not implemented")`, `return null` como única sentencia en código no test): hallazgo `major`.
- Un símbolo exportado nuevo que no se usa en ningún sitio, ni siquiera en un test: aviso. Sería el nivel "cableado"; se detecta con `ast-grep` o `git grep`.
- Coste: bajo. Ataca un fallo frecuente de los agentes que el revisor LLM a veces deja pasar.

### Revisión y correcciones

**B8. Reglas de prompt del revisor** [P; Superpowers `task-reviewer-prompt`, BMAD]

- "La justificación que dé el autor nunca baja la severidad de un hallazgo."
- Clasificación del desajuste con la spec en `missing | extra | misunderstood`. Se mapea a `spec_mismatch` y `scope`, y el Judge la usa.
- **Defecto exigido por la spec:** si el código hace lo que la spec pide pero eso es incorrecto, se reporta como `objection_type: spec_defect`. El coordinador lo envía a B10, no al implementador.
- **Prohibido sesgar al revisor:** el coordinador nunca añade por ítem instrucciones como "no marques X" o "como mucho minor". Solo el prompt de rol fijo y datos. Es un test del coordinador.
- **Deduplicación por causa raíz** (BMAD): "la misma ubicación no implica la misma causa". El revisor agrupa sus propios hallazgos por causa antes de entregarlos, y el clustering de §6.3 sigue igual.
- Coste: muy bajo.

**B9. Re-revisión acotada** [P; Superpowers `fix-loop`]

Refuerza A15:

- En una re-revisión delta, el revisor responde por cluster `addressed | not_addressed | regressed` con `ruta:línea`. **"Haberlo intentado no es haberlo resuelto."**
- **Los hallazgos nuevos sobre código que el delta no toca no alargan el bucle:** solo entran si son de clase bloqueante con `ev ≥ concrete`. El resto va a DEFER con su registro.
- Así se cortan los bucles patológicos que Superpowers documentó, en los que cada ronda descubría cosas nuevas no relacionadas.
- Cada DEFER o DROP de algo bloqueante lleva una **resolución: por qué y qué cuesta si nos equivocamos**. Va a la tarjeta y al muestreo (A14).
- Coste: bajo.

**B10. Triage `spec_gap`: volver a preparación desde cualquier ronda** [P; BMAD intent_gap/bad_spec]

- Hoy solo el Judge en modo stall puede elegir `respecify`. Con B10 lo pueden activar tres cosas:
  - el Judge, con una disposición `SPEC_GAP`;
  - un hallazgo `spec_defect` confirmado;
  - un `blocked`/`architecture` del implementador (B5).

  En cualquiera de los tres casos el ítem pasa a PREPARING en modo **enmienda**: el Planner propone el cambio mínimo a la spec, se vuelve a pasar lint, lectura en frío y la aprobación ligada al hash.
- El candidato se conserva y se reanuda con la spec nueva (el snapshot cambia y se repite lo que dependía de ella).
- Se registra como **escape de preparación**. Es la métrica que mide la calidad de la fase 1 (H-P).
- Coste: medio. Evita rondas inútiles corrigiendo código contra una spec equivocada.

**B11. Última ronda con modelo superior** [P/H; Superpowers fix loop]

- Si en la ronda 4 (`impl_rounds = 4`) persisten los mismos clusters, la ronda la hace **Opus en sesión nueva** con el brief determinista, antes de declarar STALLED.
- Configurable: `fix_escalation: opus_last_round`, activado por defecto en riesgo `medium` y superior.
- **H-33:** reduce el uso del Codex Fixer y de AWAITING_HUMAN más de lo que cuesta.
- Coste: tokens de Opus solo en los ítems que se estancan.

### Transversal

**B12. Evaluación de prompts de rol con escenarios de presión** [P; Superpowers `writing-skills` y evals]

Amplía A13:

- Cada prompt de rol tiene un conjunto pequeño de escenarios con defectos plantados y presiones, por ejemplo:
  - una spec que invita a añadir algo fuera de alcance;
  - un test que es tentador saltarse;
  - un hallazgo falso pero convincente para el Judge.
- **Procedimiento:**
  1. Ejecutar primero sin la regla nueva (línea base) y después con ella, 5 veces cada una.
  2. La regla solo entra si mejora el resultado.
  3. Las versiones del prompt cambian `policy_hash`, así que entran en modo sombra (A5).
- **Regla de redacción** (hallazgo de Superpowers):
  - Las prohibiciones sirven contra la indisciplina, pero empeoran los problemas de **forma** de la salida. Para la forma funciona mejor un contrato positivo: esquema JSON o receta.
  - Las cláusulas de matiz ("salvo que…, en general…") vuelven la salida ruidosa; se evitan.
- Coste: medio, en v2.1 junto a A13.

### Aislamiento frente a metodologías instaladas (corrección de seguridad)

**B0. `IR_AGENT_HOME` sin plugins, skills ni hooks** [P; consecuencia de Superpowers]

- Superpowers se activa con un hook `SessionStart` que inyecta instrucciones "EXTREMELY_IMPORTANT" en cada sesión, y GSD usa hooks PreCompact y Stop.
- Si un desarrollador los tiene instalados a nivel de usuario y nuestros agentes heredaran su `HOME`, `--setting-sources user` los cargaría y cambiaría el comportamiento de nuestros roles sin que lo viéramos.
- El diseño ya usa `env -i HOME="$IR_AGENT_HOME"`. Falta hacerlo explícito:
  - `ir doctor` comprueba que `$IR_AGENT_HOME/.claude` no tiene `plugins/`, `skills/`, `hooks` ni `settings.json` con hooks, y que `$IR_CODEX_HOME` no tiene configuración ni `AGENTS.md` global ajenos;
  - si encuentra algo, el runner no arranca.
- Los ficheros de esas metodologías que vivan **en el repo** (`.planning/`, `docs/superpowers/`, `openspec/`) son contenido del repo:
  - el implementador puede leerlos, pero son datos, no instrucciones de rol;
  - si un PR los modifica, no es plano de control salvo que `policy.yml` lo declare.
- Coste: muy bajo. Prioridad alta, porque es un fallo silencioso.

## 4. Lo que se descarta

| Idea | Motivo |
|---|---|
| Orquestación en prosa (GSD `execute-phase.md`, controlador Opus de Superpowers) | Es justo lo que falló en v1. Además, el propio controlador de Superpowers se lleva la mitad del coste |
| Hooks para activar skills o vigilar el contexto | No usamos hooks (decisión previa) y B0 los bloquea |
| Personas multiagente: analista, PM, arquitecto (BMAD) | Ceremonia ajena a un coordinador de issues; nuestro Planner ya cubre la parte útil |
| PRD, arquitectura y épicas como artefactos obligatorios (BMAD, Spec Kit) | Demasiado pesado por issue. La issue AI-Ready es el único artefacto |
| UAT conversacional (GSD) | Nuestra verificación es `Verify` ejecutado por el coordinador |
| "Borrar el código escrito antes del test" (Superpowers) | No se puede comprobar después. B6 contrasta la evidencia RED/GREEN, que sí se puede |
| Gate de diseño impuesto solo por prompt | Superpowers lo incumplía 24 de 24 veces. Nuestras puertas son de código |
| `verify` que no bloquea (OpenSpec) | Nuestro merge exige evidencia |
| Dos revisores por tarea dentro del mismo modelo | Superpowers lo retiró por caro y fácil de engañar. Nuestros dos revisores son de familias distintas y con evidencia |
| Instalar cualquiera de estos sistemas como dependencia | Duplicaría planes, preguntas y revisiones, y acoplaría el producto a prompts de terceros que cambian cada semana (Superpowers v7 cambió dos mecanismos centrales) |

## 5. Aplazado

- **Specs vivas** (OpenSpec `archive`). Al fusionar, los criterios del slice se integran en `docs/specs/<dominio>.md` del repo mediante un PR. Útil para conservar el porqué de cada comportamiento, pero añade mantenimiento. Se reconsidera en v2.2 si las issues cerradas no bastan como historial.
- **Ancho por tamaño** (*planning paths* de BMAD). `ir plan --quick` ya cubre lo trivial. Una vía "proyecto" (más de 20 sesiones, varios epics) queda fuera del alcance de v2.

## 6. Dónde caería cada propuesta si se aprueba

| Propuesta | Documento y sección |
|---|---|
| B0 | Spec §8.2 y §8.4 (`ir doctor`), §13 |
| B1, B2, B3 | Preparación §1.2 (formato), §4 (lint L17), §5 (lectura en frío) |
| B4 | Preparación §2, spec §8.5; H-32 |
| B5, B6 | Spec §5.4 y §7.3 (`completed_with_concerns`, `concerns[]`, `tdd_evidence[]`, `blocker.kind = architecture`) |
| B7 | Spec §5.5 (A1) |
| B8, B9 | Spec §5.6, §6.4, §6.5b y §7.4 (`spec_defect`, `addressed\|not_addressed\|regressed`) |
| B10 | Spec §4.2 (transición a PREPARING en modo enmienda), §5.7 y §7.5 (`SPEC_GAP`); preparación §3 |
| B11 | Spec §4.3 y §5.8; H-33 |
| B12 | Spec §12.3 |

## Fuentes

- https://github.com/gsd-build/get-shit-done (README "GSD Has Moved")
- https://github.com/open-gsd/gsd-core:
  - `gsd-core/templates/phase-prompt.md`
  - `docs/explanation/context-engineering.md`
  - `gsd-core/references/context-budget.md`
  - `gsd-core/workflows/execute-phase.md`
  - `agents/gsd-verifier.md`
  - `agents/gsd-plan-checker.md`
  - `docs/CONFIGURATION.md`
  - issues #5080 y #4649; en el original, #3095 y #3309
- https://github.com/obra/superpowers:
  - `skills/brainstorming/`
  - `skills/writing-plans/SKILL.md`
  - `skills/test-driven-development/SKILL.md`
  - `skills/subagent-driven-development/` (`task-reviewer-prompt.md`, `re-review-prompt.md`, `references/fix-loop.md`)
  - `skills/receiving-code-review/SKILL.md`
  - `skills/verification-before-completion/`
  - `skills/systematic-debugging/`
  - `skills/writing-skills/SKILL.md`
  - `hooks/session-start`
  - `RELEASE-NOTES`
  - `docs/superpowers/specs/2026-06-10-strict-cost-sdd-design.md`
  - `docs/superpowers/specs/2026-07-15-sdd-fix-loop-redesign-design.md`
  - https://blog.fsck.com/2025/10/09/superpowers/
- https://github.com/github/spec-kit: `templates/commands/{clarify,specify,analyze,checklist,converge}.md` y `templates/{spec,plan,tasks}-template.md`
- https://github.com/Fission-AI/OpenSpec: `docs/concepts.md`, `docs/writing-specs.md`, `docs/cli.md` y `docs/reviewing-changes.md`
- https://github.com/bmad-code-org/BMAD-METHOD:
  - `src/bmm-skills/ship/bmad-build/` (step-01, step-02, step-04-review y spec-template)
  - `bmad-code-review/steps/`
  - `docs/plan/choose-a-planning-path`
