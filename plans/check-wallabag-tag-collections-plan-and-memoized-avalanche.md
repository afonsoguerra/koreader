# Wallabag tags → KOReader collections

## Context

On every Wallabag sync, each downloaded article should land in a KOReader collection
per Wallabag tag — an article tagged `science` goes into `wb: science`. Retagging on
the server updates membership on the next sync. Collections the user made by hand are
never touched.

`wallabag-tag-collections-plan.md` (the earlier draft) proposed forking all 1854 lines
of `plugins/wallabag.koplugin/main.lua` into a standalone `wallabagtags.koplugin`. That
was rejected in favour of a **thin companion plugin**: ~450 new lines that monkey-patch
two methods on the stock Wallabag class. The stock plugin stays **enabled** and keeps
receiving upstream fixes; there is no duplicated code to 3-way-merge, and none of the
fork's rename work (settings file, dispatcher ids, menu key, external-link-dialog key,
class-level settings singleton) is needed.

Decisions already made: companion plugin, living at `plugins/wallabagtags.koplugin/`,
developed in Docker, verified by both a permanent busted spec and a temporary debug
menu action.

---

## Step 0 — Dev environment (do this first)

The host toolchain can't build KOReader: system `bash` is 3.2 and `make` is 3.81, both
too old for `kodev`. Use the CI image instead: `koreader/kobase:2.0.0-22.04`.

**0a. You must create `/Users/afonso/Software/koreader_ownFork/.claude/settings.json`
yourself** — that path is on the sandbox write-deny list, so I can't. Project-scoped,
as requested:

```json
{
  "sandbox": {
    "network": {
      "allowUnixSockets": ["/Users/afonso/.orbstack/run/docker.sock"]
    }
  },
  "permissions": {
    "allow": ["Bash(docker:*)"]
  }
}
```

Restart the session afterwards so the sandbox profile is rebuilt.

**0b. Container + build** (XQuartz is already installed, so the emulator window works):

```sh
xhost +localhost                      # once per XQuartz session, on the host
docker run -d --name ko \
  -v "$PWD:$PWD" -w "$PWD" \
  -e DISPLAY=host.docker.internal:0 \
  koreader/kobase:2.0.0-22.04 sleep infinity
docker exec -it ko ./kodev fetchthirdparty   # inits submodules + thirdparty
docker exec -it ko ./kodev build
docker exec -it ko ./kodev test front        # busted, headless
docker exec -it ko ./kodev run               # emulator window via XQuartz
```

If X11 turns out to be unusable, fall back to headless (`test front` + `luacheck`) and
test the UI on the device — the busted spec covers the logic either way.

---

## Architecture

Two files, no edits anywhere else in the tree:

```
plugins/wallabagtags.koplugin/
├── _meta.lua     ~8 lines   (fullname + description; both mandatory)
└── main.lua      ~450 lines
```

Our `main.lua` obtains the **stock class table** — never a re-`dofile`, which would
produce an unrelated copy — from the loader singleton:

```lua
for _, plugin in ipairs(require("pluginloader").enabled_plugins) do
    if plugin.name == "wallabag" then return plugin end
end
```

`plugin.name` is authoritative: `pluginloader.lua:249` overwrites whatever `main.lua`
declared with the folder name.

It then wraps exactly two methods:

- **`getArticleList`** (`wallabag.koplugin/main.lua:680`) — capture the returned array.
  This is the only place `article.tags` ever exists; tags are never persisted locally.
- **`downloadArticles`** (`:988`) — call the original **bare**, then reconcile.

Reconciling *after* the original returns is what makes this work: `local_articles`
(`[tostring(id)] = path`) is mutated in place by the original, so on return it reflects
post-sync reality — new downloads added, remotely-archived/deleted entries nil'd out.
Combined with the captured list it is a complete, consistent view.

Crucially this also covers **skipped** articles. `needToDownload` (`:850`) returns false
for files already on disk, but those articles are still in the list with their current
tags — which is exactly how server-side retagging propagates.

### Why not wrap `archiveLocalArticle`

It calls `ReadCollection:updateItem` (`:1433`), which re-keys the item **and writes
immediately** — wrapping it means one `collection.lua` write per archived file. Instead
do a post-pass that drops managed-collection members living under `archive_directory`.
That is also self-healing: it catches files archived by `movetoarchive.koplugin`, by a
manual move, or during a run when the option was off. Known blind spot:
`onUploadWallabagStatuses` archives outside our capture window, so those memberships
linger until the next sync. Document it.

### Patch mechanics

- Try to patch at module scope **and** again as the first statement of `init()`. In our
  layout `plugins/wallabag.koplugin` sorts before `plugins/wallabagtags.koplugin`, so
  module scope succeeds — but the `init()` retry keeps it correct if the folder ever
  moves to an `extra_plugin_paths` location that sorts first.
- Idempotency guard must live **on the shared class table** (`rawset(W, "__wallabagtags_patched", true)`),
  not in a module local: `PluginLoader` uses `dofile`, not `require`, so a
  double-discovered folder runs our `main.lua` twice with independent upvalues.
- Use `rawget` to capture the originals — `WidgetContainer:extend` installs `__index`,
  so a plain index could return an inherited method.
- **Never wrap an `on*` method.** `sandboxPluginEventHandlers` (`pluginloader.lua:158`)
  has already replaced them with callable `HandlerSandbox` *tables*, not functions.
- **Don't `pcall` the stock call.** `onSynchronizeWallabag` already runs inside
  `HandlerSandbox`, which `xpcall`s with a `debug.traceback` handler. `pcall` only our
  own `reconcile`; on failure log and show
  `Notification:notify(msg, Notification.SOURCE_ALWAYS_SHOW)`.
- If stock is absent or has an unexpected shape, log a warning and render a single
  disabled menu row explaining it. Never crash.

### Stale-capture guard

Use a monotonic epoch, not a boolean or a depth counter. Bump `capture.epoch` on entry
to the `downloadArticles` wrapper; `getArticleList` stamps its result with the current
epoch; only consume the capture if the stamps match. This handles all three failure
modes with no cleanup path an error can skip: `getArticleList` returning nil, the early
`return false` at `:998` when the bearer token fails, and any out-of-band call. (A depth
counter leaks when the stock code throws; an epoch has no cleanup obligation.)

---

## Reconciliation

Per-article, **never wholesale**. Nothing outside this run's captured list is considered,
so articles excluded by `filter_tag`, archived server-side (the query hardcodes
`archive=0` at `:697`), or past `articles_per_sync` can never lose a membership.

For each article with a path in `local_articles` that passes `lfs.attributes(path,"mode")=="file"`:

1. Build `wanted = { [prefix..label] = true }` from `article.tags` (each tag is
   `{id, label, slug}` — use `tag.label`). If there are no usable tags and the
   `untagged` option is on, add `prefix.."untagged"`.
2. **Remove:** for each name in `ReadCollection:getCollectionsWithFile(file)`, if
   `isManaged(name)` and not wanted → `removeItem(file, name, true)`.
3. **Add:** for each wanted name, `addCollection` it if missing, then `addItem` if the
   file isn't already a member.

Then `purgeArchived` (if enabled), `pruneEmpty` (if enabled), and finally a **single**
`ReadCollection:write(changed)`.

Mirror `plugins/calibre.koplugin/wireless.lua:918-987` (`CalibreWireless:updateCollections`)
— it is already this exact guarded add/remove/single-write shape.

### Ownership predicate — the safety keystone

```lua
local function isManaged(name, prefix)
    return #name > #prefix
       and name:sub(1, #prefix) == prefix
       and name ~= ReadCollection.default_collection_name
end
```

Every destructive path routes through this: the removal step above, `purgeArchived`,
`pruneEmpty`, `removeAllManaged`, `rePrefix`. There must be no other call to
`removeItem` or `removeCollection` in the plugin. The `default_collection_name` test is
**not** redundant — a user who sets the prefix to `fav` would otherwise have `favorites`
adopted and pruned.

### `ReadCollection` footguns (verified)

| Call | Behaviour |
|---|---|
| `addItem(file, name, attr)` | **Errors** if the file doesn't exist (`buildEntry` returns nil → indexes `item.file`) **and** if the collection doesn't exist (`getCollectionNextOrder` indexes `coll_settings[name].collate`). Does realpath internally. No write. |
| `addCollection(name)` | On an **existing** name, **wipes** that collection's items and settings. Always guard with `if not ReadCollection.coll[name]`. No write. |
| `removeItem(file, name, no_write)` | **Writes by default.** Pass `no_write = true` in every loop. |
| `write(changed)` | Always purges on-disk collections absent from `self.coll` *first*, regardless of the argument — so removals persist even though `changed` is only used to select rewrites. Still set `changed[name]` for removed collections: it's what makes the `if next(changed)` gate fire. Worth a comment, it looks redundant and isn't. |
| `addRemoveItemMultiple` | Do not use — removes the file from every collection not in the given set, including manual ones. |

No collection-change event exists anywhere in the codebase; refresh is pull-based.

### No refresh on the sync path

`onSynchronizeWallabag` (`:1770`) calls `self:refreshFileManager()` immediately after
`downloadArticles` returns, i.e. after our hook, and `filechooser.lua:306` recomputes the
collection star from `ReadCollection` at item-build time. Adding a second
`onRefresh()` just costs an extra e-ink repaint. Only the manual menu actions need their
own refresh.

### UI feedback

Log only on the sync path. The stock summary `InfoMessage` (`:1109`) has **no timeout**
and is still on screen when we run; stacking anything on it is worse than a `crash.log`
line. The one exception is the `pcall` failure `Notification`. Manual menu actions use
`InfoMessage{timeout = 2}`.

---

## Settings and menu

Keep config in a **module-level `Cfg` table**, mutated in place, never reassigned. This
dissolves the "which instance does the wrapper read?" problem: the plugin is instantiated
twice (FileManager and ReaderUI), but the wrappers live on the stock *class* and close
over `Cfg`, so a toggle in the reader takes effect immediately for a sync started from
the file manager, and the patch survives after `PluginLoader:finalize()` unpins our
instances. The stock instance arrives as the receiver of the wrapped method, which is by
definition the one performing this sync — read `wb.archive_directory` off it rather than
holding any reference across calls.

`settings/wallabagtags.lua` via `LuaSettings`. Type-check each field on load so a
hand-edited file degrades to defaults. Flush immediately from each menu callback rather
than the stock `self.updated` / `onFlushSettings` dance — five rarely-toggled values, and
it removes the two-instance ambiguity. Expose `settings_file` on the class so the plugin
manager offers "delete settings", and implement `deletePluginSettings()` to reset
in-memory state so it can't resurrect the file.

| key | default |
|---|---|
| `enabled` | `false` |
| `prefix` | `"wb: "` |
| `untagged` | `false` |
| `prune_empty` | `true` |
| `uncollect_archived` | `true` |

Menu registration uses **`sorting_hint = "more_tools"`**, not `insert_menu.add()`.
`menusorter.lua:161-182` places hinted orphans into the target submenu without the
`NEW: ` prefix; `more_tools` exists in both order tables; precedent at
`plugins/hello.koplugin/main.lua:36`, `plugins/httpinspector.koplugin/main.lua:145`,
`plugins/bookshortcuts.koplugin/main.lua:106`. It also needs no once-per-process
guarantee, which `insert_menu` does (it would append the key twice on a double `dofile`).

Use `sub_item_table_func` (the `movetoarchive.koplugin` idiom) so the submenu
re-evaluates on open. Seven rows: master toggle (with the ownership contract in
`help_text`), prefix, the three sub-options (all `enabled_func` on the master),
"Synchronize Wallabag now", and "Remove all managed collections (N)" — the last one
deliberately *not* gated on `enabled`, since its main use is cleaning up after turning
the feature off.

**Write our own prefix `InputDialog`; do not reuse the stock `setTagsDialog`** (`:1529`).
It is a method on the stock *instance*, it clobbers `self.tags_dialog` there, it sets
`self.updated = true` causing a spurious rewrite of the user's `wallabag.lua`, it calls
`touchmenu_instance:updateItems()` unguarded, and — decisively — it has no validation
hook, so it cannot reject input and keep the dialog open.

---

## Edge cases

- **Empty/whitespace prefix is fatal** — `isManaged` would match everything. Guard in
  three places: the input dialog (reject, keep open), `loadSettings` (fall back to
  default), and the top of `reconcile`/`pruneEmpty`/`removeAllManaged`/`rePrefix`.
  `isValidPrefix(p) = type(p)=="string" and p ~= "" and util.trim(p) ~= ""` —
  `util.trim` is at `frontend/util.lua:52`; a legitimate trailing space survives.
- **Prefix change** orphans the old collections, and "Remove all managed" then operates
  on the new prefix and can't reach them. Offer `MultiConfirmBox` → Rename / Delete /
  Keep. `rePrefix` must be **two-pass** (collect, then apply): `renameCollection` adds
  keys to `ReadCollection.coll`, and inserting during `pairs` traversal is undefined.
  Skip any rename whose target already exists — `renameCollection` has no collision
  check and would silently clobber.
- **`pruneEmpty` must skip** collections whose settings carry `folders` (connected-folder
  scan) or `default`.
- **Tag label = existing manual collection name** — it gets adopted. That is the
  unavoidable consequence of prefix-as-ownership; do *not* try to fix it with a
  provenance list, which drifts stale the moment the user hand-edits `collection.lua` or
  restores a backup, and a stale "I own this" is far more destructive than a stale
  prefix. State the contract in `help_text` and keep the unlikely `"wb: "` default.
- **Tag label sanitising** — apply `util.trim(label:gsub("%c", " "))` and skip empties.
  This is **cosmetic**, not a data-safety measure: I tested all 256 byte values through
  LuaJIT's `string.format("%q")` (what `dump.lua:48` uses) and every one round-trips, so
  control characters in labels cannot corrupt `collection.lua`. They would just render
  badly in the menu. Also `type`-guard `article.tags` and each entry.
- **`filter_tag` set** — only filtered articles appear, so nothing else is touched (the
  protection we want); and `<prefix><filter_tag>` becomes a collection holding everything.
  Expected; note it in the README.
- **Currently-open document** — no file I/O on the article, only the in-memory
  `ReadCollection` singleton. Stock `archiveLocalArticle`/`deleteLocalArticle` both refuse
  to touch `self.ui.document.file` (`:1409`, `:1446`). An already-open collection list
  won't live-update; harmless.
- **Tag containing the prefix** → `wb: wb: science`. Managed, distinct, reversible. Leave it.
- **Feature off** — existing managed collections are left alone forever; "Remove all
  managed collections" is the cleanup path.
- **Plugin disabled in the manager** — `main.lua` is never `dofile`d (`_discover` swaps in
  `_meta.lua`), so no patch exists and stock is bit-for-bit unchanged.
- **Remote deletes** need no handling: `deleteLocalArticle` → `FileManager:deleteFile` →
  `ReadCollection:removeItem(file)` already purges from all collections.

---

## Build order

Each step ends in something observable, so the riskiest part (the patch) is proven before
any destructive code exists.

1. `_meta.lua` + skeleton (requires, `Cfg`, settings I/O, `extend`, `init`,
   `addToMainMenu` with a stub submenu).
   **Verify:** appears under Tools ▸ More tools *without* a `NEW:` prefix, and under
   Plugin management ▸ User plugins with a working "delete settings" button.
2. `findStockWallabagClass` / `ensurePatched` / `wrapStock`, log-only bodies.
   **Verify in `crash.log`:** both wrappers fire on a sync and the captured `#articles`
   matches stock's own "Received a list of N articles" message.
3. `isValidPrefix`, `sanitizeLabel`, `isManaged`, `reconcileOne`, `reconcile`.
4. `purgeArchived`, `pruneEmpty`.
5. Full menu, `setPrefixDialog`, `confirmPrefixChange`, `rePrefix`, `removeAllManaged`,
   `countManaged`.
6. Edge-case pass; `luacheck plugins/wallabagtags.koplugin` (`.luacheckrc` sets
   `std = "luajit"`, `self = false`).

**Files to create:** `plugins/wallabagtags.koplugin/main.lua`,
`plugins/wallabagtags.koplugin/_meta.lua`, `spec/unit/wallabagtags_spec.lua`.
**Files to modify:** none.

---

## Verification

**Automated — `spec/unit/wallabagtags_spec.lua`**, run with
`docker exec -it ko ./kodev test front`. Use the existing plugin harness (`load_plugin`
/ `disable_plugins` globals, declared in `.luacheckrc:29-34`; see
`spec/unit/pluginloader_spec.lua` for the mocking style). Drive `reconcile` directly with
hand-built article tables and real temp files. Cases:

- new tagged article → lands in `wb: <tag>` for each tag
- tag added server-side → joins the new collection on next sync
- tag removed server-side → leaves it; empty collection pruned when enabled
- **a manual collection holding a wb article is untouched** (the critical assertion)
- untagged article with the option on → `wb: untagged`; with it off → no collection
- `filter_tag` set → no collateral removals
- locally archived file → removed from managed collections, left in manual ones
- `favorites` is never removed, even with prefix `fav`
- empty/whitespace prefix → `reconcile` refuses and changes nothing
- prefix change → `rePrefix` renames, skips collisions, doesn't clobber
- exactly one `ReadCollection:write` per `reconcile` call (spy on it)

**Manual — temporary debug menu row** (removed before shipping), calling `reconcile`
against fake article lists and real files in the download folder. This exercises the real
UI path end to end without a Wallabag server.

**Manual — emulator** (`docker exec -it ko ./kodev run`): menu placement, the prefix
dialog rejecting an empty value, the `MultiConfirmBox` migration, "Remove all managed
collections", and that star marks refresh after a sync.

**Manual — on device**, against the real server: the full sync round trip, then restart
KOReader and confirm `settings/collection.lua` persisted everything.
