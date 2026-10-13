# Plan: issue-runner como harness diario y lo más autónomo posible

## Contexto

El plugin `issue-runner` (issue-plan → issue-runner → gh-issue) ya es mucho más sólido que el harness local de Obsidian (`~/.claude/skills/{new-task,work-task,review-task,run-waves}`). Tiene scheduler determinista con tests, prueba de merge fuerte, recovery, Codex gate y revisores en paralelo. Le faltan tres cosas para usarlo cada día sin estar encima:

1. **Cosas buenas del harness local que el plugin no tiene**:
   - QA funcional criterio a criterio (Playwright, evidencia ✅/❌/⚠️).
   - Distinción entre `done` y `produccion` ("aprobado en local, falta comprobar en real").
   - Notas de intento legibles para retomar.
   - Prudencia con el merge en cambios de riesgo.
2. **Puntos donde la autonomía se rompe**:
   - Hace muchas preguntas sueltas en los Steps 0–2.
   - Hay implementadores que se quedan ociosos tras el Codex gate (#95).
   - No avisa cuando el usuario no está delante.
   - Lo que solo puede hacer un humano no tiene sitio (#86).
3. **Deuda que señalan la revisión del Issue Runner (artifact compartido) y #96**:
   - Bug confirmado de truncado en `continuation.md`.
   - Ruta fija de `--body-file` compartida entre implementadores.
   - Versiones del frontmatter desalineadas.
   - Líneas de más de 1.500 caracteres en los sub-docs.

Decisiones del usuario: **solo GitHub issues** (el vault de Obsidian queda fuera); **merge autónomo con gate de riesgo**; prueba **primero ficticia, luego real** (almacen21 o tap-clock).

Restricción de diseño: `skills/issue-runner/SKILL.md` está a 4.999/5.000 palabras y lint lo vigila (`scripts/lint.sh`). Todo lo nuevo va en ficheros hermanos enlazados y SKILL.md solo gana punteros de una línea.

## Qué se trae del harness local (y qué no)

| Del harness local | Se trae como |
|---|---|
| `review-task` 4a: Playwright por criterio, con evidencia | Clave `e2e:` en el contrato de validación + tabla de criterios en el PR (punto 2) |
| `review-task` 5b: `done` vs `produccion` | Checklist de verificación en producción, que pasa a ser un issue human-only (punto 4) |
| `work-task` 9b: sección "Intento N" | Comentario en el issue al fallar o bloquearse (punto 5) |
| `run-waves`: nunca mergear | Se sustituye por el gate de riesgo (punto 1). El resto del plugin ya es superior. |
| `new-task`: alta rápida con recon | `/issue-plan --quick "título"` (punto 6) |
| Vault, IDs `EFI-NNN`, Base Board | **No se trae** (decisión: solo GitHub) |

## Hoja de ruta (por orden de valor)

### Fase 1: autonomía y fiabilidad (lo que hoy obliga a vigilar el run)

1. **Gate de riesgo antes del merge.**
   - Nuevo fichero opcional `.issue-runner/risk` con globs. Se lee de la punta de `origin/<base>`, igual que `.issue-runner/validation` en `skills/gh-issue/scripts/validation-contract.sh`.
   - Por defecto (sin fichero) usa la lista de la lente de seguridad de `skills/gh-issue/review-loop.md:36` (`auth/`, `.env*`, `secrets*`, …) más migraciones, `.github/workflows/`, infra (Dockerfile, k8s, terraform) y manifests de dependencias.
   - Si el diff toca alguno de esos paths: gh-issue se para en la sección "No-merge stop" de `skills/gh-issue/merge.md` (ya existe para `--no-merge`). El PR queda listo y verde con el label `awaiting-approval`, y el estado nuevo es `awaiting-approval`.
   - `classify.sh` y `scheduler.sh` lo tratan como `ready`: los dependientes esperan y el trabajo independiente sigue.
   - `/issue-runner --merge-ready` (`merge-ready.sh`) lo mergea cuando el usuario lo aprueba.
   - `summary.sh` lo lista aparte.
   - Tests: extender `test-classify.sh`, `test-scheduler.sh`, `test-merge-ready.sh` y `test-validation-contract.sh`.
2. **Las preguntas se juntan al principio y el run sigue sin humano.**
   - Recoger en una sola tanda de `AskUserQuestion` las preguntas de los Steps 0–2 (parked, árbol sucio, aristas fuera de scope y externas, contrato). Ya lo propone la revisión del Issue Runner.
   - Nuevo `--unattended`: aplica las respuestas recomendadas y, en ejecución, **aparca el issue y no el run**. Todo bloqueo que necesite humano se convierte en un issue `human-only` (punto 4) y el resto del DAG continúa.
   - Archivos: `skills/issue-runner/preflights.md`, `open-issues.md`, `dag.md`, `escalations.md`, `user-decisions.md`, más un fichero nuevo `unattended.md`.
3. **Notificaciones push.**
   - Usar la herramienta `PushNotification` de Claude Code cuando:
     - el run aparca una decisión;
     - un PR queda en `awaiting-approval`;
     - el run se pausa por créditos;
     - el run termina (resumen de 1 línea).
   - Si la herramienta no está, no pasa nada (best-effort).
   - Archivos: nuevo `notify.md`; puntero en Step 3/Step 5 de SKILL.md.
4. **Trabajo human-only (#86) y verificación en producción.**
   - Label `human-only` añadido a los parked de `open-issues.md:7`.
   - Plantilla corta: primera línea con el porqué; comando(s); comando de verificación; una línea de contexto. Se crea con `--body-file` desde una ruta privada.
   - Deduplicado por línea marcador, como en contract-first.
   - Step 5 lista los human-only abiertos.
   - gh-issue decide `done` vs "falta en real" con la lista de `review-task` 5b (dispositivo real, infra de prod, datos reales, integraciones con credenciales de prod) y abre el checklist como human-only.
   - Responde las preguntas de #86 y lo cierra.
5. **Fiabilidad del run:**
   - #95: espera del gate con despertador acotado que no se puede perder.
   - #96: ruta privada obligatoria para `--body-file` y releer el cuerpo antes del merge; prohibir `git merge -s ours` en merges de base; sincronizar las versiones del frontmatter con los manifests y comprobarlo en lint.
   - Al fallar o bloquearse, el implementador comenta en el issue con "Qué intenté / Dónde quedé / Qué falta / Archivos". Antes hay que comprobar qué escribe hoy `escalations.md`.

### Fase 2: calidad de la entrega

6. **QA funcional por criterio.**
   - El contrato de validación gana la clave opcional `e2e:` (por ejemplo `npx playwright test`). Se ejecuta en `full`, antes del ready.
   - gh-issue escribe en el PR `## Acceptance criteria` con ✅/❌/⚠️ y una línea de evidencia por cada checkbox del issue. También lo guarda en `result.json` como `criteria[]`.
   - Un ❌ bloquea el merge.
   - Archivos: `skills/gh-issue/validation.md`, `merge.md`, `result-file.md`, `validation-contract.sh`.
7. **`/issue-plan --quick "título"`.**
   - Un solo issue con recon del repo: contexto y criterios verificables, sin entrevista ni tracking.
   - Es el equivalente de `/new-task` para el día a día y propone `Blocked by` sin escribirlo nunca solo (la lección de almacen21).
   - Archivos: `skills/issue-plan/SKILL.md` (puntero) y un fichero nuevo `quick.md`.

### Fase 3: deuda de la spec (revisión del Issue Runner)

8. Bug de `continuation.md:7`: `--limit 200` sin la regla "truncado → preguntar". Hoy puede duplicar slices.
9. Partir las líneas de más de 1.500 caracteres en `dag.md`, `hung.md`, `reconcile.md` y `handoff.md`, y extender el check 23 de `lint.sh` a todos los `.md`. Agrupar por paso el índice de notas "Why".
10. `classify.sh` deriva `outcome` y `blocker` de `result.json`; el LLM solo los escribe en el caso de reserva en prosa.
11. Mostrar el peor caso en tiempo junto a la estimación de agentes (`--plan`).
12. Tabla salida → `gate_state` → mensaje del Codex gate, en un fichero enlazado y sincronizado por lint.

Todo cambio en `skills/` se replica en `codex/issue-runner/canonical/` (lint exige que sea byte-idéntico), y se añade una fila en `docs/scenarios.md` y una entrada en `CHANGELOG.md [Unreleased]`.

## Cómo se ejecuta

1. **Dogfooding.** Publicar esta hoja de ruta con `/issue-runner:issue-plan` en `bman95/claude-issue-runner-plugin`, como tracking issue más slices. Antes de crear issues en GitHub se pide confirmación.
2. Ejecutar la Fase 1 con `/issue-runner:issue-runner <nums>` (o issue a issue con `gh-issue` si algo toca el propio orquestador en caliente), con `--no-merge` hasta que el gate de riesgo exista.
3. Fases 2 y 3 igual, ya con el gate de riesgo activo.

## Verificación

- **Unitaria:** `scripts/lint.sh`, `skills/issue-runner/scripts/test-*.sh`, `scripts/test-validation-contract.sh`, `scripts/test-integration-contract.sh` y `scripts/test-review-profile.sh` en verde (también en CI, `.github/workflows/lint.yml`).
- **E2E ficticio:** ampliar `scripts/smoke/` (fixture más `setup.sh` y `check.sh`) a un repo sandbox desechable con un DAG de 5 issues:
  - (a) una cadena A→B;
  - (b) un conflicto de archivos;
  - (c) un issue que toca `migrations/`, que debe acabar en `awaiting-approval` sin merge;
  - (d) un criterio de aceptación que falla y debe reintentar, fallar y saltar en cascada a su dependiente;
  - (e) un issue `human-only`, que no se despacha y sale listado en el resumen.

  Lanzarlo con `--unattended` y comprobar que el run termina sin preguntas a mitad, con notificaciones y con `check.sh` en verde.
- **E2E real:** 3–4 issues pequeños en almacen21 o tap-clock creados con `/issue-plan --quick`, en run `--unattended`. Revisar el resumen, los PRs mergeados y los aparcados.
