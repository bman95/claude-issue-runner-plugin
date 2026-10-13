# Traspaso: mejoras «daily autonomy» del issue-runner

Estado al 2026-10-13, 11:15. Rama local `feat/daily-autonomy`, sin push. No hay nada publicado en el repo del plugin (bman95/claude-issue-runner-plugin).

## Contexto

Objetivo: que el issue-runner sea el harness diario, lo más autónomo posible. Se comparó con el harness local de Obsidian (`~/.claude/skills/{new-task,work-task,review-task,run-waves}`) y con la revisión del Issue Runner, un artifact compartido.

- Plan completo: `docs/handoff/plan.md` (15 cambios en 3 fases).
- Visual: `docs/handoff/issue-runner-mejoras.html`, publicado en https://claude.ai/artifact/1qRNdM96UrePzjKydfiFQD.

Decisiones del usuario:
- Solo GitHub issues (sin vault).
- Merge autónomo con gate de riesgo.
- Prueba ficticia primero y real después (almacen21 o tap-clock).
- No publicar la propuesta como issues hasta discutirla.

## Hecho (Fase 1)

1. Gate de riesgo: `skills/gh-issue/scripts/risk-gate.sh` y `scripts/test-risk-gate.sh` (17 tests), sección «Risk gate» de `merge.md`, check de lint 32, label `awaiting-approval` y `.issue-runner/risk`.
2. `human-only`: `skills/gh-issue/human-only.md`; label parked y excluido también con números explícitos; Step 5 lo convierte en issues (`summary-report.md`).
3. `--unattended` y preguntas en tanda: `skills/issue-runner/unattended.md` (tabla de respuestas y `unattended.txt`).
4. Notificaciones push: `skills/issue-runner/notify.md`.
5. #95: el gate se lanza desde `codex-launch-K.sh` con `run_in_background`; el despertador es un bucle Bash acotado, no Monitor (`review-loop.md`). Nota de intento en el issue al bloquearse o fallar (`result-file.md`).
6. #96: `pr-body.md` por issue, relectura del `Closes` antes del merge, prohibido `merge -s ours`.

Además:
- Dieta de `skills/issue-runner/SKILL.md`: 4.995 palabras, por debajo del límite de 5.000 que ya fallaba en `main`. Se movió texto tal cual a `arguments.md` y a `resume-check.md`.
- Filas 88–93 en `docs/scenarios.md` (los pins `EXPECTED_ROW_COUNT=93` de los 5 tests están actualizados), CHANGELOG `[Unreleased]` y README.
- Smoke `setup.sh --autonomy` y `scripts/smoke/check-autonomy.sh`.

Lint: sin fallos nuevos respecto a `main`. Los fallos de fixtures que quedan son de entorno: macOS con bash 3.2 y rutas `/private/var`; en Linux también fallan con `main` limpio.

Copia canónica de Codex: tras cualquier cambio en `skills/` hay que ejecutar `bash docs/handoff/sync-canonical.sh`. Hace un rsync a `codex/issue-runner/canonical/` excluyendo `test-*.sh` y `agent-trace.sh`.

## Prueba E2E en curso (cortada por el límite de uso)

- Repo sandbox privado: `vela91/issue-runner-smoke-20261013-081831`.
- Clon: `~/issue-runner-smoke/issue-runner-smoke-20261013-081831`.
- Estado del run: `~/.local/state/issue-runner/issue-runner-smoke-20261013-081831-62cdcc76/`.
- Issues: tracking #1; #2 independiente; #3 bloqueado por #2; #4 en conflicto de archivos con #2; #5 con migración (debe acabar en `awaiting-approval`); #6 `human-only`.

Comprobado en real:
- #6 quedó excluido (`Excluded #6: human-only`, anotado en `unattended.txt`).
- Ninguna llamada a `AskUserQuestion`.
- El lanzamiento del gate de #95 se usó tal cual.
- #2 se mergeó solo (PR #7) y #3 y #4 se despacharon después.
- La recuperación en la misma sesión funcionó.

Cuando se cortó, #3 (PR #9, iteración 3), #4 (PR #10) y #5 (PR #8) estaban en `implementing`. El corte fue el límite de sesión de Claude a las 10:46, que se reinicia a las 13:40 (Europe/Madrid). El proceso headless se detuvo a mano.

Para reanudar, desde el clon:

```bash
cd ~/issue-runner-smoke/issue-runner-smoke-20261013-081831
SID=$(cat ~/.local/state/issue-runner/issue-runner-smoke-20261013-081831-62cdcc76/session)
(printf '%s\n' '{"type":"user","message":{"role":"user","content":"/issue-runner:issue-runner --unattended 2 3 4 5 6"}}'; sleep 21600) \
  | env -u ANTHROPIC_API_KEY claude -p --resume "$SID" --input-format stream-json --output-format stream-json --verbose \
      --plugin-dir /Users/vela/dev/sicma21/claude-issue-runner-plugin --dangerously-skip-permissions > /tmp/run4.jsonl 2>&1
```

- `env -u ANTHROPIC_API_KEY` hace falta porque el shell trae una API key inválida.
- Para ver qué hace: `python3 docs/handoff/peek.py /tmp/run4.jsonl 40`.
- Al terminar: `scripts/smoke/check-autonomy.sh issue-runner-smoke-20261013-081831`.
- Para borrar el sandbox: `scripts/smoke/teardown.sh issue-runner-smoke-20261013-081831` (necesita el scope `delete_repo`).

## Hallazgos de la prueba (pendientes)

1. Headless con `claude -p` mata a los implementadores al acabar el primer turno. Ya documentado en el README («Headless runs must keep the session alive»).
2. Cuando el propio orquestador agota la cuota no se escribe `$RUN_ROOT/paused`: `pause.md` solo cubre el fallo de un dispatch. Debería detectarlo y notificarlo.
3. #3, #4 y #5 pasaron mucho tiempo en la iteración 1 de revisión. Revisar si los revisores son lentos o si hay otro atasco de wake-up.

## Pendiente

- Terminar la E2E y pasar `check-autonomy.sh`. Lo clave es que #5 acabe en `awaiting-approval` sin mergearse.
- Fase 2: tabla de criterios ✅/❌/⚠️ más `criteria[]`; clave `e2e:` en el contrato; verificación en producción como `human-only`; `/issue-plan --quick`.
- Fase 3: bug de `--limit 200` en `continuation.md`; líneas de más de 1.500 caracteres en los sub-docs; `classify.sh` leyendo `result.json`; peor caso en tiempo; tabla del Codex gate.
- Prueba real en almacen21 o tap-clock.
- Decidir si se publica (issues o PR) en bman95/claude-issue-runner-plugin.
