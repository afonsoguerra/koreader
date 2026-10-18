# Resume: Wallabag tags → collections — build & verify

## Context

Full design: `plans/check-wallabag-tag-collections-plan-and-memoized-avalanche.md`.
The code is already written (build-order steps 1–5):
- `plugins/wallabagtags.koplugin/_meta.lua`, `main.lua` (770 lines)
- `spec/unit/wallabagtags_spec.lua` (550 lines, ~35 cases)

Nothing has been built or run yet. The session was restarted so that Step 0a
(`.claude/settings.json` allowing the OrbStack docker socket) takes effect — confirmed:
`docker ps` now works. No `ko` container, no `kobase` image, submodules uninitialised.

Note: implementation replaced the plan's "epoch" stale-capture guard with
clear-on-entry of `capture.list`; the spec covers the same failure modes. Keep it.

## Steps

1. **Container** (Step 0b):
   ```sh
   docker run -d --name ko -v "$PWD:$PWD" -w "$PWD" \
     -e DISPLAY=host.docker.internal:0 koreader/kobase:2.0.0-22.04 sleep infinity
   ```
2. `docker exec ko ./kodev fetchthirdparty` (inits submodules — writes into repo,
   network-heavy; run in background).
3. `docker exec ko ./kodev build` (long; background).
4. **Tests:** `docker exec ko ./kodev test front wallabagtags_spec.lua`, then the whole
   front suite to make sure load order / `disable_plugins` didn't break other specs.
   Fix failures in `main.lua`/spec (systematic-debugging; no behaviour changes to the
   design without asking).
5. **Lint:** `docker exec ko luacheck plugins/wallabagtags.koplugin spec/unit/wallabagtags_spec.lua`.
6. **Emulator (optional, needs `xhost +localhost` by the user on the host):**
   `docker exec ko ./kodev run` with `DEBUG_MENU = true` temporarily — check menu under
   Tools ▸ More tools (no `NEW:`), prefix dialog rejects empty, debug reconcile rounds,
   MultiConfirmBox on prefix change, "Remove all managed". Revert `DEBUG_MENU` after.
   If X11 fails, fall back to device testing.

## Verification

- Spec passes; full `test front` shows no new failures vs. baseline.
- luacheck clean.
- `git status` shows only the plugin, spec, and plan files as changes (submodule
  checkouts aside); `DEBUG_MENU` is `false`.
