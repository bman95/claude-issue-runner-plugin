# Faktory21: fase de preparación (de la petición a la issue AI-Ready)

> **Nombre.** El producto se llama **Faktory21** (decidido el 2026-10-21) y su comando es `fak`. En GitHub se usa siempre el nombre largo: etiquetas `faktory21:*`, commit status `faktory21/gate`, comandos de comentario `/faktory21 …`, ramas `faktory21/…` y trailers `Faktory21-*`. "Issue Runner" designa solo a la v1 (`claude-issue-runner-plugin`).

Estado: **propuesta de diseño**, 2026-10-19. No hay código.

Este documento completa [`faktory21-spec.md`](faktory21-spec.md), que cubre lo que pasa desde que una issue tiene `faktory21:ai-ready` hasta el merge. Aquí se diseña todo lo anterior. Usa la misma leyenda (**[A]** acuerdo, **[P]** propuesta, **[H]** hipótesis, **[Q]** pregunta, **[F]** hecho comprobado) y la misma infraestructura: coordinator determinista, SQLite, `gh` con el token del usuario, agentes como procesos acotados y sin hooks.

Las fuentes y la evidencia están en [`research-log.md`](research-log.md), §12.

---

## 0. Resumen para humanos

**Principio de partida [A].** El implementador obtiene de la issue `ai-ready` todo lo que necesita. Lo que no está en la issue, en el repositorio o en sus ficheros de contexto confiables (CLAUDE.md, AGENTS.md, `.faktory21/*` de la rama base) no existe para él. Por tanto, la fase de preparación tiene una sola responsabilidad: **producir un contrato autosuficiente y demostrar que lo es** antes de etiquetarlo.

**Por qué importa (evidencia):**

- Al construir SWE-bench Verified, los anotadores marcaron como poco especificadas un 38 % de las issues reales.
- Los modelos casi nunca preguntan por iniciativa propia, aunque el texto sea muy ambiguo: "models almost never interact, even for severely underspecified inputs" (Ambig-SWE, ICLR 2026).
- Una pista de solución equivocada en la issue empeora el resultado (Agentless).
- Un revisor LLM de requisitos detecta en torno a la mitad de los problemas que señalaría un experto (arXiv 2609.03230).

Conclusión: la ambigüedad hay que resolverla **aquí**, con comprobaciones deterministas primero y con más de un revisor.

**Flujo:**

1. **Entrada.** Una petición llega por `fak plan "<idea>"`, por un fichero, por una issue existente o por una issue marcada `faktory21:needs-prep`.
2. **Triage determinista.** Clasifica el tipo de trabajo y busca duplicados candidatos.
3. **Exploración y reconciliación (Opus).** Opus explora el repo y reconcilia la petición con el trabajo existente: issues, PR y decisiones.
4. **Entrevista.** Pocas preguntas, cada una con la respuesta recomendada, solo sobre lo que el repo no puede responder.
5. **Corte en slices.** Slices verticales del tamaño de un PR, que un humano aprueba.
6. **Redacción.** Cada slice se escribe con el formato AI-Ready v2: objetivo, contexto verificado, criterios con `Verify:`, restricciones, fuera de alcance, supuestos, datos y entorno.
7. **Puerta de autosuficiencia, en tres capas.**
   - *Lint* determinista.
   - **Lectura en frío**: Sonnet, el mismo modelo que implementará, lee solo la issue y el repo e intenta planificar el trabajo. Si le surgen preguntas bloqueantes, la issue no está lista.
   - **Revisión de la spec por Codex**, de otra familia de modelos y de solo lectura.
8. **Publicación y aprobación.** Se publica como `faktory21:prepared`. Un humano aplica `faktory21:ai-ready` sobre el texto exacto que pasó la puerta. Si el texto cambia, hay que volver a pasar la puerta.
9. **Caducidad.** La disponibilidad caduca: si el código que la issue cita cambió mucho antes de despacharla, se repite la lectura en frío.

**Primera versión.** Incluye:

- `fak plan` para texto, fichero o issue existente, con un camino rápido para una sola issue (`--quick`).
- Reconciliación, entrevista, corte y redacción.
- Lint, lectura en frío y revisión de Codex.
- Publicación y aprobación.

Queda aplazado:

- Entrada automática desde Slack o correo.
- Deduplicación por embeddings.
- Las issues de investigación.
- La caducidad automática (en v2.0 solo se comprueba el lint antes de despachar).

---

## 1. El contrato de autosuficiencia

### 1.1 Qué puede leer el implementador [A, P]

| Fuente | ¿Cuenta como contexto? | Por qué |
|---|---|---|
| Cuerpo de la issue `ai-ready` (texto con hash aprobado) | **Sí, y es la autoridad** | Es el contrato |
| Repositorio en la base, incluidos CLAUDE.md, AGENTS.md y `.faktory21/*` | Sí | Son contenido de confianza, fusionado por humanos |
| Issue de seguimiento (`Part of #P`) | **No** | Es el archivo humano del plan. Lo que el slice necesite de ella se copia en el slice |
| Comentarios de la issue | **No** | Son datos de conversación. Un cambio de requisitos se hace editando el cuerpo, lo que fuerza a repasar la puerta |
| Enlaces externos (documentos, Figma, chats) | **No** | El implementador no tiene red general, y su contenido puede cambiar. Lo necesario se **incorpora resumido** al cuerpo, indicando de dónde viene |
| Otras issues o PR referenciados | Solo como `Blocked by` | El runner comprueba que estén fusionados. Su contenido relevante, por ejemplo una interfaz, se copia en `## Context` |

Consecuencia práctica: la issue de v1 **no** era autosuficiente, porque el implementador seguía `Part of #P` y leía los comentarios. En v2 eso desaparece. El texto aprobado de la issue y el repo bastan.

### 1.2 Formato AI-Ready v2

Las cabeceras son tokens fijos en inglés, así que el coordinator las analiza de forma determinista. La prosa va en el idioma configurado del repo (**[Q-P2]**). Se conservan los tokens de v1 (`## What to build`, `## Acceptance criteria`, `## Blocked by` y `Files likely touched:` como última línea) por compatibilidad con issues existentes.

```markdown
Part of #120                                  ← opcional, informativo

## What to build
Objetivo y por qué, en 2–6 líneas. Describe el resultado, no las capas.

## Context
- Pattern to follow: `src/api/users.ts` (validación con zod + error unificado `ApiError`).
- Interface: `function listTasks(filter: TaskFilter): Promise<Task[]>` en `src/api/tasks.ts:42`.
- Consumes (provided_by: #118): `function archiveTask(id: number): Promise<void>` en `src/api/tasks.ts` (new).
- Decision (2026-10-12, #120 Decisions Q3): los ids no numéricos devuelven 400, no 404.
- From external doc "API errores v2" (Drive, 2026-10-01, resumido): formato `{error, code}`.

## Acceptance criteria
- [ ] AC-1: WHEN se pide `DELETE /api/tasks/{id}` con un id inexistente THE API SHALL responder 404 con `{"error":"task not found"}`.
      Verify (http): DELETE /api/tasks/999 → 404, body {"error":"task not found"}
- [ ] AC-2: La suite existente sigue pasando.
      Verify (cli): npm test → exit 0

## Unchanged behavior
- `DELETE /api/tasks/{id}` con un id existente sigue respondiendo 204.

## Constraints
- p95 de `GET /api/tasks` ≤ 200 ms con 10k tareas (medido con `npm run bench:tasks`).
- Sin migraciones de base de datos.

## Out of scope
- Paginación del listado.

## Assumptions
- A-1: Los ids son enteros positivos (confirmado en `src/db/schema.ts:12`).

## Test data & environment
- Fixtures: `tests/fixtures/tasks.json`.
- Env (names only): `DATABASE_URL` (provisto por la receta `verification` del repo).

## Human-only steps
- None

## Blocked by
None - can start immediately

Kind: bug · Risk: low · Size: S (~80 líneas)
Files likely touched: `src/api/tasks.ts`, `src/api/tasks.test.ts`
```

| Sección | Obligatoria | Regla |
|---|---|---|
| `What to build` | Sí | |
| `Context` | Sí (o `None` justificado) | Cada puntero a fichero, símbolo o línea **debe existir** en la base (lo comprueba el lint). Cada decisión cita su origen. Cada contenido externo se marca `From external doc …` con su fecha |
| `Acceptance criteria` | Sí | Ids `AC-n`. Forma EARS (While / When / Where / If…then / The … shall) o Given/When/Then. **Cada criterio lleva su `Verify (http\|cli\|inspection)`**. No hay `browser` [A, 2026-10-26]: un criterio de interfaz va como `cli` con tests de componente sin navegador, o como `inspection` |
| `Unchanged behavior` | Sí en `bug` y `refactor` | Protege contra regresiones. Se adapta del `bugfix.md` de Kiro |
| `Constraints` | Si hay requisitos no funcionales | Rendimiento, seguridad, compatibilidad, i18n, accesibilidad o migraciones, **con umbral numérico y cómo se mide**. "Rápido" sin número no pasa el lint |
| `Context`: `Produces` / `Consumes` [P; B2] | Si el slice tiene dependencias (`Blocked by`) o dependientes | El productor declara la firma exacta que expone (`Produces:`) y el consumidor la que usa (`Consumes (provided_by: #N):`). Lo comprueba L17 |
| `Review focus` [P; B1] | No (opcional) | De 2 a 5 modos de fallo que la spec implica y que ningún AC ejercita todavía. Cada uno se convierte, si se puede, en un AC con `Verify`. Lo que queda llega a los revisores como dato y no cambia la regla de evidencia (spec §5.6) |
| `Out of scope` | Sí | Al menos una línea, o `None` |
| `Assumptions` | Sí | Cada supuesto queda confirmado (con su fuente) o pendiente. Si hay alguno pendiente, la issue no está lista |
| `Test data & environment` | Sí | Fixtures, cuentas de prueba, servicios. Las variables de entorno solo por **nombre**. Si exige algo que la receta `verification` del repo no da, no está lista |
| `Human-only steps` | Sí (o `None`) | Pasos que ningún agente puede hacer (`prod-check`, credenciales, acceso al host). Se publican como issues `human-only` enlazadas, nunca se dejan en prosa |
| `Blocked by` | Sí | Solo issues del mismo repo que se puedan terminar. Una dependencia de otro repo sigue las reglas externas de v1 |
| Línea final de metadatos | Sí | `Kind` (`feature\|bug\|refactor\|chore\|docs\|research\|ops`), `Risk`, `Size` y `Files likely touched:` |

**Prohibido en el cuerpo:**

- Marcadores `TODO`, `TBD` o `[NEEDS CLARIFICATION]`.
- Instrucciones dirigidas al agente que modifiquen su rol, permisos o contrato ("ignora…", "usa la API key…").
- Pistas de solución que nadie ha verificado en el repo. Hay evidencia de que una pista equivocada perjudica (Agentless, `research-log.md` §5.1).

**El "cómo" solo cuando está verificado.** El planificador describe **qué** y cómo se comprueba. Solo da indicaciones del **cómo** cuando las ha confirmado explorando el repo, como un patrón existente o una interfaz real, y siempre con la ruta. Así se concilian dos advertencias de Anthropic: "the errors in the spec would cascade" y la petición de que las specs "name the files and interfaces involved".

**Presupuesto de tamaño.** El cuerpo no pasa de unos 6.000 tokens (**H-P1**). Si no cabe, el slice es demasiado grande y se parte.

---

## 2. Arquitectura y roles

Usa el mismo coordinator, la misma base de datos y el mismo Agent Runner que la fase de implementación. Las entidades nuevas son:

- **Request**: la petición original, guardada tal cual con su hash.
- **Plan**: el conjunto de slices de una petición. Se refleja en una issue de seguimiento `Plan: …`.
- **SliceDraft**: el borrador de cada slice.
- **ReadinessCheck**: el resultado de la puerta, ligado al hash del cuerpo.

| Rol | Motor | Permisos | Qué hace |
|---|---|---|---|
| Intake / Triage | Determinista | Lectura de GitHub vía `gh` | Normaliza la entrada y clasifica el tipo con reglas. Busca duplicados candidatos (`gh search issues` por términos y solape de `Files likely touched:` con issues y PR abiertos). Comprueba que el autor tenga permiso `write` |
| **Planner** | Claude Opus, effort high | Lectura del repo; sin red; sin escritura en GitHub | Explora, reconcilia (los 6 resultados de v1), entrevista, corta en slices, redacta y responde a las críticas |
| Spec Linter | Determinista | Lectura del repo | Reglas L1–L16 (§4) |
| **Cold Reader** | Claude **Sonnet**, el mismo modelo que implementará; sesión nueva | Solo lectura del repo; sin red; recibe **solo** el cuerpo de la issue | Intenta planificar la implementación y lista lo que le falta (§5) |
| **Spec Critic** | Codex `exec`, solo lectura | Solo lectura del repo; sin red | Revisa la spec al estilo del `analyze` de Spec Kit: ambigüedad, huecos, contradicciones, criterios no verificables (§6) |
| Human | — | `write` en el repo | Responde preguntas, aprueba el corte y aplica `faktory21:ai-ready` |

**El enlace entre roles lo resuelve el coordinator, no un agente.** El Planner nunca ve la conversación del Cold Reader ni del Critic, solo sus hallazgos estructurados. El Cold Reader nunca ve la conversación del Planner. Esa separación es la que da valor a la lectura en frío.

**Enlaces externos.** Ningún agente navega por la web: abrir páginas arbitrarias expondría a inyección de instrucciones y produciría contenido que cambia con el tiempo.

- Los enlaces a issues, PR y ficheros de GitHub del mismo repo, o de repos de la organización, los resuelve el coordinator con `gh`.
- Cualquier otro enlace (Drive, Notion, Figma, chats) se convierte en una pregunta: "pega el contenido relevante o márcalo como no relevante".
- El contenido pegado entra resumido en `## Context` con su procedencia (**[Q-P4]**: si se quieren conectores a Drive o Notion).

---

## 3. Workflow

### 3.1 Estados de una Request

```
RECEIVED ─► TRIAGED ─► EXPLORING (Opus) ─► INTERVIEWING ⇄ (respuestas humanas)
                                   │
                                   ▼
                           SLICING ─► AWAITING_SLICE_APPROVAL (humano) ─► DRAFTING (Opus)
                                                                          │
                     ┌──────────── GATING: lint ─► cold-read ∥ spec-critic ─► coordinate
                     │                     │ huecos de producto → INTERVIEWING
                     │                     │ huecos técnicos  → REVISING (Opus, ≤ 2 rondas)
                     │                     ▼
                     │               PUBLISHING (outbox: issue de seguimiento + slices `faktory21:prepared`)
                     │                     ▼
                     │               AWAITING_APPROVAL ─(humano aplica faktory21:ai-ready al hash aprobado)─► READY
                     │                     │ cuerpo editado → GATING de nuevo
                     └─────────────────────┘
Salidas: COVERED (todo existía ya) · DUPLICATE (humano confirma) · NEEDS_RESEARCH (se crea una issue de
investigación; el plan sigue en dos fases) · ABANDONED · STALE (sin respuesta humana tras N días; se avisa,
nunca se cierra de forma automática)
```

### 3.2 Pasos

1. **Entrada [P].**
   - `fak plan "<texto>"`, `fak plan --file spec.md`, `fak plan #123` (una issue existente) o el polling de issues con `faktory21:needs-prep`.
   - Se guarda la petición literal con su hash y su autor.
   - Si el autor no tiene `write`, la petición queda en TRIAGED con `needs-maintainer` hasta que un mantenedor la adopte. Una petición de un tercero nunca llega a READY sin pasar por un humano con permisos.
   - `--quick` sigue el mismo flujo, pero salta el corte (un único slice) y la issue de seguimiento. Es el equivalente del `/new-task` diario (rama de vela).
2. **Triage determinista.**
   - **Tipo de trabajo** por reglas: palabras clave, plantilla de la issue, etiquetas. Si no está claro, lo decide el Planner en el paso 3.
   - **Duplicados candidatos** en tres pasadas:
     - `gh search issues` con los términos principales;
     - solape de rutas mencionadas con `Files likely touched:` de issues abiertas y con los ficheros de PR abiertos;
     - issues con etiquetas de aparcadas.
   - Los candidatos son una lista para el Planner, nunca un resultado: el triage no cierra ni descarta nada (patrón de GitHub `ai-inference`, que comenta y no cierra).
   - **Lecturas fallidas** se registran como `not scanned`, nunca como 0 (regla de v1).
3. **Exploración y reconciliación (Opus).**
   - Mapa del código afectado y de los registros de diseño del repo (ADR, design notes, CLAUDE.md).
   - Clasificación de cada solape con los 6 resultados de v1: `covered`, `extend`, `depends`, `supersedes`, `conflict`, `new`.
   - `conflict` y `supersedes` exigen pregunta. El Planner nunca cierra issues ajenas.
   - Regla de v1 que se mantiene: **no se pregunta lo que el repo puede responder**.
4. **Entrevista [P].**
   - Rondas de **3 a 5 preguntas como máximo**. Cada una incluye la respuesta recomendada y las opciones, y solo se pregunta lo que cambiaría la implementación o la verificación (criterio de `clarify` de Spec Kit).
   - **Canales:**
     - interactivo, en el terminal de `fak plan`;
     - asíncrono, con un comentario marcado en la issue de seguimiento o de origen y respuestas `/faktory21 answer Q2: …` de un usuario con `write`.
   - **Quién decide qué:**
     - Las decisiones de **producto** son solo humanas.
     - Las decisiones **técnicas** las puede tomar el Planner, pero quedan escritas como `Decision` en `## Context` y en el registro de decisiones, con su razón, y el humano las ve al aprobar.
   - El registro de decisiones vive en la issue de seguimiento (`## Decisions`, formato de v1). **Cada decisión que afecta a un slice se copia en el `## Context` de ese slice.** El coordinator lo comprueba: una decisión con `affects: [slice]` que no aparece en el slice es un fallo de lint (L12).
5. **Corte en slices.**
   - Slices verticales (*tracer bullets*), cada uno verificable por sí mismo y con ficheros disjuntos cuando sea posible.
   - Solo se declaran las dependencias reales. Cada slice cabe en un PR (**H-4**, ~400 líneas).
   - El humano aprueba el corte (`fak approve-slices` o un comentario). Es la única aprobación previa a la redacción.
6. **Redacción (Opus).** El Planner devuelve un `PlanDraft` (§7) con un `IssueSpec` por slice. El coordinator **renderiza** el cuerpo con una plantilla; el Planner no escribe Markdown libre. Así las cabeceras y el orden son siempre correctos, y el lint comprueba contenido, no formato.
7. **Puerta de autosuficiencia (§4–§6).** Primero el lint. Después, la lectura en frío y la revisión de Codex en paralelo. Por último, la coordinación determinista (§6.3).
8. **Publicación (outbox con `gh`).**
   - Primero la issue de seguimiento (`Plan: …`, con Input, Decisions, Existing work, Slices y Plan file, como en v1). Después los slices en orden de dependencias, con `faktory21:prepared`, su `<!-- faktory21:readiness hash=… -->` y el resumen de la puerta en un comentario marcado.
   - Es idempotente: si un marcador ya existe, se edita; nunca se duplica (v1 continuation).
   - **Publicar no es aprobar.** El runner nunca toma una issue `faktory21:prepared`.
9. **Aprobación [A: la etiqueta es humana; Q3 decide si hay auto-aprobación con riesgo bajo].**
   - El humano aplica `faktory21:ai-ready`, por slice o en bloque con `/faktory21 approve-plan #P`.
   - El coordinator comprueba dos cosas:
     - que el actor tenga `write`;
     - que el **hash del cuerpo actual coincida con el que pasó la puerta**.
   - Si no coincide (alguien editó después), se retira la etiqueta, se explica en un comentario y se vuelve a pasar la puerta.
10. **Caducidad de la disponibilidad [P].** Antes de despachar, el runner hace dos cosas:
    - vuelve a pasar el lint (es barato): rutas y símbolos de `Context` existentes, y `Blocked by` resueltos. Las entradas `Consumes` (B2) ya no están exentas de L8: tras el merge del productor, su firma tiene que existir en la base, y si no, el consumidor vuelve a preparación;
    - si la base acumuló más de N commits en los `Files likely touched` desde la puerta (**H-P5**), repite la lectura en frío.

    Si aparecen preguntas bloqueantes, el ítem vuelve a preparación y no se despacha. En v2.0 solo se repite el lint.

---

## 4. Spec Linter (determinista)

| Regla | Comprueba | Si falla |
|---|---|---|
| L1 | Están las secciones obligatorias según `Kind`, con las cabeceras exactas | Lo arregla la plantilla del coordinator; si persiste, error interno |
| L2 | Cada `AC-n` es único y tiene una línea `Verify (…)` de un tipo válido | Hallazgo bloqueante |
| L3 | El tipo de `Verify` tiene receta `verification` en `policy.yml` de la base (`http` necesita `start`/`ready`). `browser` no es un tipo válido | Bloqueante: el repo necesita la receta, o el criterio se reformula. Nunca se inventa una receta (regla de dev-harness) |
| L4 | Forma del criterio: EARS (`^(While\|When\|Where\|If .* then\|The .* shall)`) o Given/When/Then | Aviso en `feature`/`bug`, bloqueante con riesgo alto. No se exige en `refactor`/`docs` |
| L5 | Léxico vago sin número: "rápido", "robusto", "intuitivo", "fácil", "adecuado", "como se espera", "etc." (lista por idioma en `policy.yml`) | Bloqueante si aparece en un criterio o restricción; aviso en el resto |
| L6 | Ningún `TODO`, `TBD`, `[NEEDS CLARIFICATION`, `???` ni supuesto pendiente | Bloqueante |
| L7 | Las rutas de `Context` y `Files likely touched:` existen en la base (`git ls-files` / `git cat-file`), salvo las marcadas `(new)` | Bloqueante |
| L8 | Los símbolos citados con `ruta:línea` existen (`git grep -n` en la base) | Aviso; bloqueante si están en una `Interface`, salvo las entradas `Consumes` con `provided_by` mientras el productor no esté fusionado (L17) |
| L9 | `Blocked by` apunta a issues abiertas del mismo repo que no son de seguimiento, y el DAG no tiene ciclos | Bloqueante |
| L10 | Sin URLs externas fuera de bloques `From external doc` | Bloqueante: hay que resumir o descartar |
| L11 | Tamaño del cuerpo ≤ el presupuesto (**H-P1**) y `Size` coherente con `Files likely touched` | Bloqueante, con propuesta de corte |
| L12 | Toda decisión del registro con `affects` incluye ese slice en su `Context` | Bloqueante |
| L13 | `Unchanged behavior` existe si `Kind ∈ {bug, refactor}` | Bloqueante |
| L14 | Si es `bug`: reproducción (pasos o test) o `no_repro_reason` | Bloqueante |
| L15 | Sin patrones de instrucción dirigida a agentes ni secretos (escáner de secretos y patrones de inyección) | Bloqueante, con aviso privado a los `owners` |
| L16 | `Risk` presente. Las reglas de ruta de `policy.yml` lo **suben** si hace falta, nunca lo bajan | Se corrige solo, con aviso |
| L17 | Si un slice declara `Consumes` con `provided_by: #N` (B2), la firma coincide, **normalizada** (espacios y genéricos), con el `Produces` del slice #N, y #N está en `Blocked by`. Estas entradas quedan exentas de L8 hasta que se fusiona el productor | Bloqueante |
| L18 | Heurística de C1: frases como "is accepted", "se acepta", "per worker" o "por instancia" fuera de los AC, sin un AC que recoja ese límite | Aviso para el Spec Critic |

El lint corre en tres momentos: en cada borrador, en el cuerpo publicado antes de la aprobación y otra vez antes de despachar.

---

## 5. Lectura en frío (el lector es el futuro implementador)

**Qué es.** Un `claude -p` con **Sonnet**, el mismo modelo que implementará, en sesión nueva, con solo lectura del repo y sin red. Recibe **únicamente** el cuerpo de la issue. Responde con un `ColdReadReport`:

```json
{
  "restatement": "qué entiende que hay que hacer, ≤ 80 palabras",
  "plan_sketch": [{"step": "…", "files": ["src/api/tasks.ts"]}],
  "blocking_questions": [{"id": "CQ-1", "question": "…", "why_blocking": "sin esto no puedo decidir X", "spec_ref": "AC-2"}],
  "assumptions_i_would_make": [{"text": "…", "spec_ref": null}],
  "verify_feasibility": [{"ac": "AC-1", "status": "clear|unclear|impossible", "note": "…"}],
  "contradictions": [{"between": ["AC-1", "Constraints#2"], "note": "…"}],
  "multiple_goals": false
}
```

**Instrucción clave:** "Lista solo preguntas sin cuya respuesta no podrías implementar o verificar correctamente. No sugieras mejoras." Se incluye porque un revisor al que se pide buscar huecos "will usually report some, even when the work is sound" (guía de Claude Code). Por la misma razón, `blocking_questions: []` es una respuesta válida y esperada.

**Lo que el coordinator compara de forma determinista:**

- Hay `blocking_questions`. Se vuelve a la entrevista o a la revisión del Planner (§6.3).
- Hay `assumptions_i_would_make` que no están en `## Assumptions`. Es un supuesto implícito, y el Planner debe confirmarlo o descartarlo.
- Los ficheros del `plan_sketch` difieren de `Files likely touched`. Si el lector toca ficheros no declarados, falta un fichero o el alcance no está claro.
- Algún criterio tiene `verify_feasibility` en `unclear` o `impossible`.
- Hay `contradictions`.
- `multiple_goals: true` [P; B3, BMAD]: el `What to build` persigue más de un resultado. Se trata como una propuesta de corte, igual que L11.

Las `blocking_questions` se ordenan por "cambiaría el plan", primero las que más lo cambiarían (B3).

**Por qué Sonnet y no Opus.** La pregunta es si **este** implementador tiene lo que necesita. Ambig-SWE midió que Sonnet 4 detecta especificaciones incompletas con un 0,74 de acierto (prompt neutro) a un 0,89 (prompt explícito) cuando se le pide. Eso se aprovecha aquí, antes de implementar, que es justo cuando no lo haría solo. Cuesta una ejecución de solo lectura por slice, mucho menos que una implementación fallida (**H-P2**).

---

## 6. Revisión de la spec por Codex y coordinación

### 6.1 Spec Critic (Codex)

Un `codex exec --sandbox read-only` con salida JSON por esquema. Recibe el cuerpo y tiene acceso de lectura al repo. Su rúbrica combina tres fuentes:

- La taxonomía de `clarify` de Spec Kit: alcance, modelo de datos, estados, requisitos no funcionales, integraciones, casos límite, terminología, señales de fin.
- Las "unit tests for English" de Spec Kit, que hacen preguntas sobre la spec, no sobre el código.
- Los dos criterios de anotación de SWE-bench Verified: si está suficientemente especificada, y si los `Verify` aceptarían cualquier solución válida y rechazarían las incorrectas.

**Reglas:**

- Cada hallazgo **cita el texto** de la spec al que se refiere y la consecuencia para la implementación.
- Severidad `blocking|major|minor`, con un máximo de 10 hallazgos.
- Se excluye explícitamente el estilo.
- **Decisiones dentro del criterio [P; C1, `vela91/dev-harness` #11].** El Spec Critic comprueba de forma explícita que ninguna decisión de `What to build`, `Context` o `Assumptions` contradiga un AC o lo acote sin estar escrita en él. Si una decisión acota o relaja un criterio, por ejemplo con "se acepta que…", un alcance, una precisión o "por proceso" frente a "por instancia", ese límite se escribe **en el texto del AC**, porque los revisores validan contra el criterio y no contra la descripción. El prompt incluye el caso ALM-86 antes y después:
  - Antes: `What to build` aceptaba que el límite contara por worker, y el AC decía "más de 10 logins/min → 429".
  - Después: "AC-1: WHEN un mismo worker recibe más de 10 logins/min THE API SHALL responder 429 (el límite es por worker, no global; decisión D-2)".

### 6.2 Por qué dos revisores

La evidencia de revisión de requisitos con LLM indica baja exhaustividad por modelo: un 47 % de los problemas del experto con el mejor modelo de Anthropic, y un 11 % de falsas alarmas. La lectura en frío (Sonnet, el consumidor) y la crítica (Codex, otra familia) **se suman para cubrir más**, y la exigencia de citar el texto filtra las falsas alarmas. Opus, que escribió la spec, nunca la revisa: ya se sabe que un evaluador puntúa demasiado bien su propio trabajo.

### 6.3 Coordinación (determinista)

| Entrada | Clase | Destino |
|---|---|---|
| Lint bloqueante | FIX_DRAFT | REVISING (Planner) |
| Pregunta bloqueante de la lectura en frío, o hallazgo `blocking` del Critic, sobre **producto** (comportamiento, alcance, prioridad). El Planner lo clasifica, con `spec_ref` | ASK_HUMAN | INTERVIEWING (nueva ronda, con un máximo de 5 preguntas) |
| Lo mismo, pero **técnico** | FIX_DRAFT | REVISING: el Planner responde a cada punto con `fixed` (cambio en el borrador) o `rejected` (razón citando el repo) |
| `rejected` de un punto `blocking` | SHOW_HUMAN | No bloquea, pero aparece en la tarjeta de aprobación para que el humano lo vea antes de aprobar |
| `major`/`minor` | ADVISORY | Se registra; el Planner puede aplicarlo |
| Ninguna de las anteriores | READY_TO_PUBLISH | PUBLISHING |

**Límites:**

- Como máximo 2 rondas de REVISING por slice. A la tercera, AWAITING_HUMAN con el informe.
- Cada ronda de revisión vuelve a pasar el lint y la lectura en frío.
- Codex solo se repite si su hallazgo afectaba a lo cambiado (**H-P3**).

---

## 7. Contratos (JSON Schema, versión 1)

- **`RequestInput`**: texto literal, origen (`cli|file|issue`), autor, hash.
- **`TriageResult`** (determinista): tipo propuesto, duplicados candidatos con motivo (`title_terms|file_overlap|label`), fuentes `not scanned`.
- **`ReconcileResult`** (Opus): lista de `{ref, outcome ∈ covered|extend|depends|supersedes|conflict|new, reason}`.
- **`InterviewRound`**: preguntas `{id, question, options[], recommended, kind: product|technical, affects: [slice]}`.
- **`PlanDraft`** (Opus): `slices[]`, cada uno con un `IssueSpec`:
  - `what`, `context[]` (cada uno `{type: pattern|interface|produces|consumes|decision|external, text, source, provided_by}`; `provided_by` solo en `consumes`);
  - `review_focus[]` (opcional, B1);
  - `acceptance[]` (`{id, text, form: ears|gwt|free, verify: {kind, check, expected}}`);
  - `unchanged[]`, `constraints[]` (`{text, threshold, how_measured}`), `out_of_scope[]`;
  - `assumptions[]` (`{id, text, status: confirmed|pending, source}`);
  - `test_env {fixtures[], env_names[], services[]}`, `human_only[]`;
  - `blocked_by[]`, `kind`, `risk`, `risk_reasons[]`, `size {class, est_lines}`, `files_likely[]`, `repro`/`no_repro_reason`.
- **`ColdReadReport`** (§5) y **`SpecCriticReport`** (§6.1).
- **`PlannerResponse`**: por cada punto, `{ref, action: fixed|rejected|asked, rationale, change_summary}`.

Todos llevan el sobre de resultado firmado por el runtime y el token de fencing de la especificación principal (§4.1 y §9.1 de allí).

---

## 8. Persistencia, trazabilidad y memoria

- **Tablas nuevas:** `requests`, `plans`, `slice_drafts`, `interview_questions`, `decisions` (compartida con la fase de implementación), `readiness_checks`. `readiness_checks` guarda el hash del cuerpo, las versiones de las reglas, los informes y el resultado.
- **Trazabilidad:**
  - Cada criterio `AC-n` y cada decisión llevan id estable.
  - La fase de implementación vincula los hallazgos `spec_mismatch` y las pruebas `Verify` a esos ids.
  - Desde la issue se puede seguir el rastro de cada criterio hasta la decisión o el texto de la petición que lo originó.
- **Memoria:** el Planner recibe CLAUDE.md, AGENTS.md y los registros de diseño del repo. Los `knowledge_candidates` de la fase de implementación también pueden señalar huecos frecuentes de las specs, por ejemplo "las issues de este repo nunca traen fixtures". Esos huecos alimentan los *checklists* de `policy.yml` mediante PR humanos.

---

## 9. Evidencia y métricas

La pregunta que se mide es **si la puerta predice el éxito de la implementación**. Para cada slice se registra:

- **En la puerta:** número de preguntas de la lectura en frío, hallazgos del Critic por severidad, rondas de revisión y de entrevista, y tiempo humano.
- **En la implementación:**
  - entradas en AWAITING_INPUT o `needs_clarification`, que **deberían ser ~0**;
  - hallazgos `spec_mismatch` y `misread_spec`;
  - rondas;
  - fallos de `Verify`;
  - escalados.

**Hipótesis:**

| Id | Hipótesis | Cómo se verifica |
|---|---|---|
| H-P1 | Un cuerpo de hasta ~6k tokens basta para un slice del tamaño de un PR | Piloto |
| H-P2 | La lectura en frío reduce las peticiones de aclaración y los `spec_mismatch` en implementación más de lo que cuesta. Se mide en modo sombra: en una muestra se ejecuta pero no bloquea | Sombra en el piloto |
| H-P3 | Repetir Codex solo cuando su hallazgo afecta a lo cambiado no pierde calidad | Piloto |
| H-P4 | Exigir EARS o Given/When/Then reduce los `spec_mismatch` (sin evidencia controlada previa; el artículo de EARS es un caso, no un experimento) | Comparación por tipo de issue |
| H-P5 | El umbral de N commits sobre los `Files likely touched` detecta las issues que caducaron | Piloto |
| H-P6 | Opus clasifica bien producto frente a técnico (lo mide la tasa de decisiones técnicas que un humano revoca al aprobar) | Piloto |

---

## 10. Estados sin salida y contradicciones

**Estados sin salida y su salida:**

| # | Situación | Salida |
|---|---|---|
| P-D1 | Quien pidió el trabajo no responde | Recordatorios a las 48 h y a los 7 días, luego STALE con `faktory21:stale`. Nunca se cierra solo, y se reanuda con cualquier respuesta |
| P-D2 | La lectura en frío sigue encontrando preguntas tras 2 revisiones | AWAITING_HUMAN con las preguntas. El humano responde, corta el slice o aprueba explícitamente con la pregunta abierta, lo que deja una Authorization y una marca en la issue |
| P-D3 | El Planner y Codex discrepan sobre un punto bloqueante | Nunca deciden entre ellos. El rechazo del Planner aparece en la tarjeta de aprobación y decide el humano |
| P-D4 | La petición es demasiado grande para un plan | Se propone un corte. Si incluso así hay incertidumbre técnica, NEEDS_RESEARCH: se crea una issue de investigación (nota 9 de v1, siempre hoja del DAG) y el plan de código se publica después, en dos fases |
| P-D5 | Una dependencia está en otro repo | Reglas de v1: `run-elsewhere`, `override`, `drop` o `contract-first`. Nunca entra en el DAG |
| P-D6 | El repo no tiene receta `verification` para el tipo de `Verify` que exige un criterio | L3 bloquea. La salida es un slice previo de "configurar verificación" (por ejemplo, `fak doctor --init`) o reformular el criterio como `cli`/`inspection` |
| P-D7 | Alguien edita la issue tras la aprobación | El hash no coincide, se retira `faktory21:ai-ready` y se vuelve a pasar la puerta. Si ya estaba en implementación, aplica PAUSED_SPEC_DRIFT de la especificación principal |

**Contradicciones revisadas:**

1. **Planificador de alto nivel frente a issue autosuficiente.** El "cómo" solo aparece cuando está verificado y con ruta, y L7/L8 comprueban que las rutas existen.
2. **Duplicar decisiones (seguimiento y slice) frente a una sola fuente de verdad.** Para el implementador la autoridad es el slice. La issue de seguimiento es el archivo humano. L12 detecta las decisiones que no se copiaron.
3. **Pocas preguntas frente a resolver toda la ambigüedad.** El tope por ronda es de 5 preguntas, pero puede haber varias rondas. Solo se pregunta lo que cambia la implementación o la verificación, y lo técnico lo decide el Planner, a la vista del humano.
4. **Un LLM revisor con poca exhaustividad frente a fiarse de la puerta.** Las capas son complementarias: lint determinista, dos modelos distintos, y la medición posterior de lo que se escapó.
5. **Etiqueta humana frente a autonomía.** La puerta reduce el trabajo humano a leer la tarjeta y aprobar. La auto-aprobación con riesgo bajo es una decisión del usuario (Q3), y la tarjeta muestra siempre las decisiones técnicas tomadas sin consulta.

---

## 11. Primera versión y plan

**Incluido en v2.0:**

- Entradas: `fak plan` con texto, fichero o `#issue`, más `--quick`.
- Triage determinista con duplicados candidatos.
- Planner con Opus: exploración, reconciliación, entrevista interactiva y asíncrona, corte en slices y redacción con plantilla.
- Puerta completa: Spec Linter, lectura en frío y Spec Critic con Codex, más la coordinación.
- Publicación idempotente y aprobación ligada al hash.
- Lint previo al despacho.

**Fases** (amplían la F5 del plan principal):

| Fase | Entregable | Criterio de aceptación | Días |
|---|---|---|---|
| P1 | Formato AI-Ready v2: renderizador, parser y Spec Linter (L1–L16) | Tests de tabla por regla. Las issues de v1 existentes se analizan sin error y sus carencias se informan | 3 |
| P2 | Entrada, triage y duplicados candidatos | Fixtures con un duplicado plantado, un solape de ficheros y una lectura fallida (`not scanned`) | 2 |
| P3 | Planner: reconciliación, entrevista (CLI y `/faktory21 answer`), corte y `PlanDraft` | Una petición vaga produce preguntas; con las respuestas, slices aprobables | 4 |
| P4 | Lectura en frío, Spec Critic y coordinación | Una spec con un hueco plantado (falta un umbral, falta una decisión) se detecta y no llega a publicarse. Una spec completa pasa sin preguntas | 4 |
| P5 | Publicación, aprobación ligada al hash y lint previo al despacho | Una edición posterior a la aprobación retira la etiqueta. Una ruta borrada en la base bloquea el despacho | 2 |

**Aplazado:**

| Aplazado | Por qué |
|---|---|
| Entrada desde Slack, correo o formularios | Primero hay que estabilizar el formato |
| Deduplicación por embeddings | La búsqueda y el solape de ficheros bastan al principio |
| Conectores a Drive o Notion | Pendiente de Q-P4 |
| Issues de investigación y planes en dos fases | Siguen la nota 9 de v1 en v2.1 |
| Caducidad con lectura en frío repetida | **H-P5** |
| Auto-aprobación con riesgo bajo | Q3 |

---

## 12. Decisiones sobre las preguntas (2026-10-19)

| Pregunta | Decisión [A] |
|---|---|
| **Q-P1 Origen** | Normalmente pide el trabajo el desarrollador, desde el terminal (`fak plan`) o dejando una issue en GitHub (`faktory21:needs-prep`). Otras entradas, más adelante |
| **Q-P2 Idioma** | **Inglés por defecto** en todas las issues AI-Ready y artefactos, porque los consumen agentes. La interacción con el desarrollador (preguntas de la entrevista, resúmenes) puede ir en su idioma (`fak config language es`) |
| **Q-P3 Quién aprueba** | Cualquier usuario con `write` |
| **Q-P4 Documentación externa** | Se pega el contenido relevante; sin conectores por ahora |
| **Q-P5 Entrevista** | Las dos: en el terminal y en comentarios de la issue |
| **Q6 (spec principal)** | La preparación reescribe el cuerpo con el formato AI-Ready y conserva el original |
| **Autonomía de la preparación** | Coherente con Q3: con nivel de autonomía L2 o superior en el repo, una issue de riesgo `low` que pasa la puerta completa (lint, lectura en frío sin preguntas y Critic sin bloqueantes) **puede auto-aprobarse** como `ai-ready`, siempre que no haya decisiones técnicas tomadas sin consulta. Si las hay, o el riesgo es mayor, la aprueba un humano |
