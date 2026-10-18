# Plan: sync Wallabag tags to KOReader collections

Target: a **standalone plugin** `wallabagtags.koplugin`, derived from the stock
`plugins/wallabag.koplugin`. It is installed outside the KOReader folder so that
official updates don't overwrite it. The stock Wallabag plugin gets disabled.
Source basis: KOReader `master` @ `caf5e93` (2026-09-28).
Keep a fork of `koreader/koreader` only as the place to track upstream changes
and diff against them.

## Goal

On every Wallabag sync, put each downloaded article into a KOReader collection
for each of its Wallabag tags. For example, an article tagged `science` goes into
the collection `wb: science`. Retagging on the server updates membership on the
next sync. Collections the user made by hand are never touched.

## Step 0: turn the stock plugin into a standalone one

Copy `plugins/wallabag.koplugin/` to a new repo (or a folder in your fork) as `wallabagtags.koplugin/`, then:

- **Folder name:** `wallabagtags.koplugin`. The plugin loader keys plugins by folder name, so it must differ from `wallabag`.
- **`main.lua` L51:** set `name = "wallabagtags"`.
- **`main.lua` L52:** set `settings_file = DataStorage:getSettingsDir() .. "/wallabagtags.lua"`.
  - On first run, if that file is missing and `wallabag.lua` exists, copy it over so the server credentials, directory, etc. carry across.
  - Also update the help text at ~L1567 that names `wallabag.lua`.
- **`main.lua` L58–75:** rename the Dispatcher action ids (`wallabag_download` → `wallabagtags_download`, etc.) so they never clash with stock gestures.
  - Keep the event handlers (`onSynchronizeWallabag`, …) as they are. The stock plugin is disabled, so there's no double handling.
- **`_meta.lua`:** set `fullname = _("Wallabag (tags → collections)")` and update the description.
- **Add `VERSION`** (or a `version` field in `_meta.lua`) plus a note of the upstream commit it was derived from (`caf5e93`).

The file stays a copy of upstream plus your additions. Keep the additions in clearly
marked blocks (`-- [wallabagtags] begin/end`) so future upstream merges are easy.

## Relevant existing code

### `plugins/wallabag.koplugin/main.lua` (~1850 lines)
- L29: `local ReadCollection = require("readcollection")` is already imported.
- L78 `init()` / L166 `onFlushSettings()`: settings live in `self.wb_settings.data.wallabag`.
- L680 `getArticleList()`: returns API entries. Each `article.tags` is a list of `{ id, label, slug }`.
- L760 `filterIgnoredTags()`: an example of iterating `article.tags` / `tag.label`.
- L795 `downloadArticle(article)`: returns the local path, named `[w-id_<id>] <title>.epub`.
- L850 `needToDownload()`: already-downloaded articles are skipped, but they are still in the list.
- L988 `downloadArticles(local_articles)`: the main sync loop. `local_articles[tostring(id)] = path`.
- L1158 `processRemoteDeletes()`: deletes locally via `FileManager:deleteFile`, which also removes the file from collections.
- L1407 `archiveLocalArticle()`: moves the file and calls `ReadCollection:updateItem(path, new_path)`.
- L288–320: the menu entries for tag filtering. Put the new menu entries here.

### `frontend/readcollection.lua`
- `ReadCollection.coll[name][realpath] = item`
- `ReadCollection.coll_settings[name]` holds `{ order, collate, folders, ... }`.
- `addCollection(name)` creates an empty collection.
- `addItem(file, name, attr)` adds a file. **Pass `ffiUtil.realpath(file)` yourself**, because `addItem` does not do it.
- `removeItem(file, name, no_write)` removes a file. Pass `no_write = true` inside loops.
- `getCollectionsWithFile(file)` returns the set of collection names containing the file.
- `removeCollection(name)`
- `write(updated_set)` persists `settings/collection.lua`. Pass nil to write everything, or `{ [name] = true }`.
- **Do not use `addRemoveItemMultiple`.** It removes the file from *every* collection that isn't in the given set, including manual ones.

## New settings

These go in `init` and `onFlushSettings`, following the existing pattern:

| key | default | meaning |
|---|---|---|
| `sync_tags_to_collections` | `false` | master toggle |
| `collection_prefix` | `"wb: "` | marks the collections the plugin owns |
| `untagged_collection` | `false` | also put untagged articles into `<prefix>(untagged)` |
| `remove_empty_tag_collections` | `true` | delete prefixed collections that end up empty |
| `uncollect_archived` | `true` | take locally archived articles out of the prefixed collections |

## New functions

```lua
--- Name of the KOReader collection for a Wallabag tag label.
function Wallabag:tagCollectionName(label)
    return self.collection_prefix .. label
end

function Wallabag:isTagCollection(name)
    return name:sub(1, #self.collection_prefix) == self.collection_prefix
end

--- Make the prefixed collections containing `path` match exactly `tags`.
-- Returns a set of the collection names that changed.
function Wallabag:syncArticleCollections(path, tags, changed)
    local file = ffiUtil.realpath(path) or path
    local wanted = {}
    for _, tag in ipairs(tags or {}) do
        wanted[self:tagCollectionName(tag.label)] = true
    end
    if next(wanted) == nil and self.untagged_collection then
        wanted[self:tagCollectionName("(untagged)")] = true
    end
    -- add
    for name in pairs(wanted) do
        if not ReadCollection.coll[name] then
            ReadCollection:addCollection(name)
        end
        if not ReadCollection.coll[name][file] then
            ReadCollection:addItem(file, name)
            changed[name] = true
        end
    end
    -- remove (prefixed collections only)
    for name in pairs(ReadCollection:getCollectionsWithFile(file)) do
        if self:isTagCollection(name) and not wanted[name] then
            ReadCollection:removeItem(file, name, true)
            changed[name] = true
        end
    end
end

function Wallabag:pruneEmptyTagCollections(changed)
    for name, coll in pairs(ReadCollection.coll) do
        if self:isTagCollection(name) and next(coll) == nil then
            ReadCollection:removeCollection(name)
            changed[name] = true
        end
    end
end
```

## Hook into `downloadArticles()`

1. Before the article loop: `local coll_changed = {}`.
2. At the end of each loop iteration, whether the article was downloaded or skipped:
   ```lua
   local p = local_articles[tostring(article.id)]
   if self.sync_tags_to_collections and p then
       self:syncArticleCollections(p, article.tags, coll_changed)
   end
   ```
3. After `processRemoteDeletes`:
   ```lua
   if self.sync_tags_to_collections then
       if self.remove_empty_tag_collections then self:pruneEmptyTagCollections(coll_changed) end
       if next(coll_changed) then ReadCollection:write() end
   end
   ```
   Use a full `write()`, because a removed collection must be dropped from the file.
4. Optional: add `- collections updated: N` to the sync summary message.

## Hook into `archiveLocalArticle()`

After `ReadCollection:updateItem(path, new_path)`, if `uncollect_archived` is on,
remove `new_path` from every prefixed collection, then `write()`.

## Menu

Add these under the tag settings (~L320):
- A checkbox: "Sync tags to collections".
- A text input: "Collection prefix". Reuse `setTagsDialog()` or a similar `InputDialog`.
- Checkboxes for the three sub-options, enabled only when the master toggle is on.
- Help text: "Creates a KOReader collection per Wallabag tag. Only collections starting with the prefix are managed."

## Edge cases

- **`filter_tag` is set:** only the filtered articles are in the list. Only sync those articles and never infer "untagged" from absence. The loop above already behaves this way.
- **Changing the prefix:** old prefixed collections become orphans. Document this, or offer a "remove managed collections" menu action.
- **Tag label characters:** labels are free text. Collection names are Lua table keys, so any string is fine.
- **Currently open document:** membership changes are harmless; there's no file I/O on the EPUB.
- **Manual ordering:** `addItem` appends using `getCollectionNextOrder`, so existing items keep their order.
- **First run with many articles:** keep the single `write()` at the end, with no writes per article.

## Test checklist

- [ ] With the stock plugin disabled, the new plugin shows up and the settings carried over from `wallabag.lua`.
- [ ] After a KOReader OTA update, the plugin is still present and still enabled.
- [ ] Toggle off: behaviour is identical to upstream.
- [ ] New tagged article: it lands in `wb: <tag>` collection(s).
- [ ] Tag added on the server, then sync: the article joins the new collection.
- [ ] Tag removed on the server, then sync: the article leaves it, and the empty collection is pruned (if enabled).
- [ ] A manual collection holding a wb article stays untouched.
- [ ] Remote archive/delete: the file disappears from the collections.
- [ ] Local archive with `uncollect_archived`: removed from the prefixed collections.
- [ ] `filter_tag` set: no collateral removals.
- [ ] Prefix change behaves as documented.
- [ ] Restart KOReader: `settings/collection.lua` persists the collections.

## Installation (survives KOReader updates)

1. Put `wallabagtags.koplugin/` in a folder **outside** the KOReader install dir, e.g. `/mnt/onboard/.adds/koplugins/` on Kobo.
2. In `koreader/settings.reader.lua`, add or extend:
   ```lua
   ["extra_plugin_paths"] = { "/mnt/onboard/.adds/koplugins/" },
   ```
   - `PluginLoader:_discover()` accepts a string or a table.
   - If the setting is unset and the data dir isn't `.`, KOReader auto-sets it to `<data_dir>/plugins/`. Check what's already there before overwriting.
   - Edit this while KOReader is **closed**, or it will overwrite the file on exit.
3. In KOReader, go to Plugin manager: disable **Wallabag** (stock) and enable **Wallabag (tags → collections)**. This is stored in `plugins_disabled`.
4. Restart KOReader.

OTA updates replace only the KOReader folder, so both the plugin and the disabled state persist.

## Keeping up with upstream

- Watch `plugins/wallabag.koplugin/main.lua` upstream, e.g. with a GitHub watch or occasional `git log caf5e93..upstream/master -- plugins/wallabag.koplugin`.
- When it changes, re-copy upstream and re-apply the marked blocks plus the Step 0 renames, or 3-way merge. Then bump `VERSION` and the base commit note.
- Once it's accepted upstream (see the last section), drop the plugin and re-enable stock.

## Dev loop

- **Quick:** copy `wallabagtags.koplugin/` into the extra plugin folder on the device, then restart KOReader.
- **Full:** run the desktop emulator (`./kodev build && ./kodev run` in a koreader checkout) with the plugin in `plugins/` or in an `extra_plugin_paths` folder.
- **Logs:** `crash.log`. Use `logger.dbg("Wallabag:syncArticleCollections: ...")` to match the plugin's style.
- **Lint:** run `luacheck plugins/wallabag.koplugin` before any upstream PR.

## Later: upstream PR

Port only the marked blocks back into `plugins/wallabag.koplugin/main.lua`, reverting
the Step 0 renames. Keep the change self-contained in the plugin, off by default,
with translatable strings wrapped in `_()`. Search KOReader issues for "wallabag tags collections" first.
