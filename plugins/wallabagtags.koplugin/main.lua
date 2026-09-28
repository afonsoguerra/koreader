--[[--
Puts each downloaded Wallabag article into a KOReader collection per Wallabag tag.

This is a companion to the built-in `wallabag` plugin, not a replacement: at load
time it wraps two of that plugin's methods, so both plugins must be enabled. The
stock plugin is never modified on disk, which means it keeps receiving upstream
fixes untouched.

Ownership contract: every collection whose name starts with the configured prefix
is owned by this plugin and may be modified or deleted at any time. Collections
without the prefix are never touched.

@module koplugin.wallabagtags
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local Notification = require("ui/widget/notification")
local PluginLoader = require("pluginloader")
local ReadCollection = require("readcollection")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

-- constants
local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/wallabagtags.lua"
local DEFAULT_PREFIX = "wb: "
-- Deliberately not translated: this ends up inside a collection name, and switching
-- the interface language must not orphan the collection a previous sync created.
-- The parentheses also keep it distinct from a real Wallabag tag named "untagged".
local UNTAGGED_LABEL = "(untagged)"
-- Tag labels are unbounded on the server side; a collection name has to stay
-- readable in a menu row. Counted in characters, not bytes.
local MAX_LABEL_CHARS = 100
-- Marker written onto the *stock* class table, so a second copy of this file (the
-- plugin folder being discovered twice) cannot wrap the same methods again.
local PATCH_MARK = "__wallabagtags_patched"

-- Set to true during development to expose the offline reconciliation test action.
local DEBUG_MENU = false

-- Configuration lives at module level, not on the instance: this plugin is
-- instantiated twice (once for the FileManager, once for the ReaderUI), while the
-- wrappers live on the stock *class* and close over this single table. One source
-- of truth, and it outlives our instances.
local Cfg = {
    enabled            = false,
    prefix             = DEFAULT_PREFIX,
    untagged           = false,
    prune_empty        = true,
    uncollect_archived = true,
}

local settings -- LuaSettings singleton

-- Patch state. "pending" means "not found yet, try again"; "absent" means "found
-- something we don't understand, give up permanently".
local patch_state = "pending"

-- Capture slot for the remote article list, which is the only place tags ever exist
-- (they are never persisted locally). Cleared at the start of every sync, so
-- whatever is in it when the sync returns was necessarily captured by that sync.
local capture = { list = nil }

-- helpers

--- A prefix that is empty or all whitespace would make every collection "managed".
local function isValidPrefix(p)
    return type(p) == "string" and p ~= "" and util.trim(p) ~= ""
end

--- Tag labels are free text from a remote server and go straight into a collection
-- name that gets rendered in the UI, so treat them as untrusted.
local function sanitizeLabel(label)
    if type(label) ~= "string" then return "" end
    -- Repair invalid UTF-8 first. A truncated multi-byte sequence or a stray
    -- continuation byte would render as garbage and can upset the text layout.
    label = util.fixUtf8(label, "�")
    -- Flatten control characters (newlines and tabs wreck the menu layout) and
    -- collapse the whitespace runs they leave behind.
    label = label:gsub("%c", " "):gsub("%s+", " ")
    label = util.trim(label)
    -- Cap the length on a character boundary, never a byte one: cutting mid-sequence
    -- would reintroduce exactly the invalid UTF-8 we just repaired.
    local chars = util.splitToChars(label)
    if #chars > MAX_LABEL_CHARS then
        label = table.concat(chars, "", 1, MAX_LABEL_CHARS)
    end
    return label
end

--- The ownership predicate. Every destructive path in this plugin goes through it.
local function isManaged(name, prefix)
    return #name > #prefix
       and name:sub(1, #prefix) == prefix
       -- Not redundant: a prefix of "fav" would otherwise adopt (and prune) Favorites.
       and name ~= ReadCollection.default_collection_name
end

local function collectionName(prefix, label)
    return prefix .. label
end

local function refreshUI()
    -- Required lazily: pulling in the FileManager at plugin load time would couple
    -- us to its load order for no benefit.
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

-- settings

local function loadSettings()
    if settings then return end
    settings = LuaSettings:open(SETTINGS_FILE)
    local d = settings.data
    -- Type-check every field so a hand-edited or truncated file degrades to the
    -- defaults instead of exploding inside the sync wrapper.
    if type(d.enabled)            == "boolean" then Cfg.enabled            = d.enabled end
    if type(d.untagged)           == "boolean" then Cfg.untagged           = d.untagged end
    if type(d.prune_empty)        == "boolean" then Cfg.prune_empty        = d.prune_empty end
    if type(d.uncollect_archived) == "boolean" then Cfg.uncollect_archived = d.uncollect_archived end
    if isValidPrefix(d.prefix) then Cfg.prefix = d.prefix end
end

local function saveSettings()
    if not settings then return end
    settings:reset({
        enabled            = Cfg.enabled,
        prefix             = Cfg.prefix,
        untagged           = Cfg.untagged,
        prune_empty        = Cfg.prune_empty,
        uncollect_archived = Cfg.uncollect_archived,
    })
    settings:flush()
end

-- reconciliation

--- Make the managed collections containing `path` match exactly `tags`.
-- @tparam string path Local path of the article
-- @tparam table tags Array of Wallabag tag objects, `{ id, label, slug }`
-- @tparam string prefix Collection prefix
-- @tparam table changed Set of collection names to persist, added to in place
-- @treturn int, int, int memberships added, memberships removed, collections created
local function reconcileOne(path, tags, prefix, changed)
    -- ReadCollection keys items by realpath.
    local file = ffiUtil.realpath(path) or path
    local added, removed, created = 0, 0, 0

    local wanted, n_tags = {}, 0
    if type(tags) == "table" then
        for _, tag in ipairs(tags) do
            if type(tag) == "table" then
                local label = sanitizeLabel(tag.label)
                if label ~= "" then
                    wanted[collectionName(prefix, label)] = true
                    n_tags = n_tags + 1
                end
            end
        end
    end
    if n_tags == 0 and Cfg.untagged then
        wanted[collectionName(prefix, UNTAGGED_LABEL)] = true
    end

    -- Remove, from managed collections only. getCollectionsWithFile returns a fresh
    -- table, so mutating ReadCollection.coll while iterating it is safe.
    for name in pairs(ReadCollection:getCollectionsWithFile(file)) do
        if isManaged(name, prefix) and not wanted[name] then
            if ReadCollection:removeItem(file, name, true) then -- no_write
                changed[name] = true
                removed = removed + 1
            end
        end
    end

    -- Add.
    for name in pairs(wanted) do
        if not ReadCollection.coll[name] then
            -- Guarded: addCollection on an existing name wipes its items and settings.
            ReadCollection:addCollection(name)
            changed[name] = true
            created = created + 1
        end
        if not ReadCollection.coll[name][file] then
            -- Both of addItem's error cases are excluded by construction here: the
            -- collection exists (just ensured) and the file exists (caller checked).
            ReadCollection:addItem(file, name)
            changed[name] = true
            added = added + 1
        end
    end

    return added, removed, created
end

--- Drop managed-collection members that live under the Wallabag archive folder.
-- Preferred over hooking archiveLocalArticle: that would cost one collection.lua
-- write per archived file, and this pass is self-healing — it also catches files
-- archived by movetoarchive.koplugin, by hand, or while this option was off.
local function purgeArchived(wb, prefix, changed)
    local dir = wb and wb.archive_directory
    if type(dir) ~= "string" or dir == "" then return 0 end
    dir = ffiUtil.realpath(dir) or dir
    if dir:sub(-1) ~= "/" then dir = dir .. "/" end

    local n = 0
    for name, coll in pairs(ReadCollection.coll) do
        if isManaged(name, prefix) then
            for file in pairs(coll) do
                if util.stringStartsWith(file, dir) then
                    if ReadCollection:removeItem(file, name, true) then -- no_write
                        changed[name] = true
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

local function pruneEmpty(prefix, changed)
    if not isValidPrefix(prefix) then return 0 end
    local n = 0
    for name, coll in pairs(ReadCollection.coll) do
        if isManaged(name, prefix) and next(coll) == nil then
            local s = ReadCollection.coll_settings[name]
            -- Never drop a connected-folder collection (it is empty only until its
            -- next scan) or the user's default one.
            if not (s and (s.folders or s.default)) then
                ReadCollection:removeCollection(name)
                changed[name] = true
                n = n + 1
            end
        end
    end
    return n
end

--- The single entry point called from the sync wrapper. Always pcall'd.
-- @tparam table wb The stock Wallabag instance performing this sync
-- @tparam table local_articles `[tostring(id)] = path`, post-sync
-- @tparam table articles Remote article list captured this run, or nil
local function reconcile(wb, local_articles, articles)
    if not Cfg.enabled then return end

    local prefix = Cfg.prefix
    if not isValidPrefix(prefix) then
        logger.warn("wallabagtags: refusing to run, invalid prefix:", tostring(prefix))
        return
    end
    if type(articles) ~= "table" then
        -- The sync failed before the article list arrived. Make no claims at all:
        -- in particular do not prune, or a transient network error would delete
        -- every managed collection.
        logger.info("wallabagtags: no article list captured this run, nothing to do")
        return
    end

    local changed = {}
    local n_files, n_add, n_del, n_new, n_gone = 0, 0, 0, 0, 0

    -- Per-article, never wholesale. Nothing outside this run's list is considered,
    -- so articles hidden by filter_tag, archived server-side (getArticleList
    -- hardcodes archive=0) or past articles_per_sync can never lose a membership.
    for _, article in ipairs(articles) do
        local path = local_articles and local_articles[tostring(article.id)]
        if path and lfs.attributes(path, "mode") == "file" then
            local a, d, c = reconcileOne(path, article.tags, prefix, changed)
            n_add, n_del, n_new = n_add + a, n_del + d, n_new + c
            n_files = n_files + 1
        end
    end

    if Cfg.uncollect_archived then
        n_del = n_del + purgeArchived(wb, prefix, changed)
    end
    if Cfg.prune_empty then
        n_gone = pruneEmpty(prefix, changed)
    end

    -- A single write for the whole sync. Note that ReadCollection:write purges
    -- on-disk collections missing from ReadCollection.coll regardless of what is in
    -- `changed`, so removals persist; `changed` still has to be populated for
    -- removed collections, because it is what makes this `next` test fire at all.
    if next(changed) then
        ReadCollection:write(changed)
    end

    logger.info("wallabagtags: reconciled", n_files, "articles;",
                "+" .. n_add, "-" .. n_del, "memberships;",
                "+" .. n_new, "-" .. n_gone, "collections")
    -- No UI refresh here: onSynchronizeWallabag calls refreshFileManager() right
    -- after downloadArticles returns, i.e. right after us.
    return n_files, n_add, n_del, n_new, n_gone
end

-- maintenance

local function countManaged(prefix)
    if not isValidPrefix(prefix) then return 0 end
    local n = 0
    for name in pairs(ReadCollection.coll) do
        if isManaged(name, prefix) then n = n + 1 end
    end
    return n
end

local function removeAllManaged(prefix)
    if not isValidPrefix(prefix) then return 0 end
    local changed, n = {}, 0
    for name in pairs(ReadCollection.coll) do
        if isManaged(name, prefix) then
            ReadCollection:removeCollection(name)
            changed[name] = true
            n = n + 1
        end
    end
    if next(changed) then ReadCollection:write(changed) end
    return n
end

--- Move managed collections from one prefix to another, preserving their order,
-- collate and connected folders (renameCollection carries coll_settings across).
local function rePrefix(old_prefix, new_prefix)
    if not (isValidPrefix(old_prefix) and isValidPrefix(new_prefix)) then return 0 end
    if old_prefix == new_prefix then return 0 end

    -- Two passes: renameCollection *inserts* a key into ReadCollection.coll, and
    -- adding keys during a pairs() traversal is undefined behaviour.
    local renames = {}
    for name in pairs(ReadCollection.coll) do
        if isManaged(name, old_prefix) then
            local new_name = new_prefix .. name:sub(#old_prefix + 1)
            -- renameCollection has no collision check and would silently clobber.
            if not ReadCollection.coll[new_name] then
                renames[name] = new_name
            end
        end
    end

    local changed, n = {}, 0
    for from, to in pairs(renames) do
        ReadCollection:renameCollection(from, to)
        changed[from], changed[to] = true, true
        n = n + 1
    end
    if next(changed) then ReadCollection:write(changed) end
    return n
end

-- patching the stock plugin

local function findStockWallabagClass()
    -- PluginLoader holds the one true class table. Never dofile the stock main.lua
    -- ourselves: that would produce a second, unrelated class.
    local enabled = PluginLoader.enabled_plugins
    if type(enabled) ~= "table" then return nil end
    for _, plugin in ipairs(enabled) do
        -- Authoritative: PluginLoader overwrites `name` with the folder name.
        if plugin.name == "wallabag" then return plugin end
    end
    return nil
end

local function wrapStock(W, orig_get, orig_down)
    W.getArticleList = function(wb, ...)
        local list = orig_get(wb, ...)
        capture.list = list
        return list
    end

    W.downloadArticles = function(wb, local_articles, ...)
        -- Clear before, not after: clearing here is what guarantees we can never
        -- reconcile against a list left behind by an earlier sync, and unlike a
        -- cleanup step it cannot be skipped by the stock code throwing.
        capture.list = nil

        -- Called bare, deliberately. onSynchronizeWallabag already runs inside
        -- PluginLoader's HandlerSandbox, which xpcalls with a traceback handler;
        -- pcall-and-rethrow here would throw that traceback away.
        local ret = orig_down(wb, local_articles, ...)

        -- Still nil if getArticleList returned nothing, or if the sync bailed
        -- before reaching it (e.g. the bearer token failed).
        local articles = capture.list
        capture.list = nil -- don't pin the payload until the next sync

        local ok, err = pcall(reconcile, wb, local_articles, articles)
        if not ok then
            logger.err("wallabagtags: reconciliation failed:", err)
            Notification:notify(_("Wallabag tag collections: update failed"),
                                Notification.SOURCE_ALWAYS_SHOW)
        end

        return ret
    end
end

local function ensurePatched()
    if patch_state == "done"   then return true end
    if patch_state == "absent" then return false end

    local W = findStockWallabagClass()
    if not W then return false end -- stay "pending"; init() will try again

    if rawget(W, PATCH_MARK) then
        patch_state = "done"
        return true
    end

    -- rawget, because WidgetContainer:extend installs an __index metatable and a
    -- plain index could hand us an inherited method instead of Wallabag's own.
    local orig_get = rawget(W, "getArticleList")
    local orig_down = rawget(W, "downloadArticles")
    if type(orig_get) ~= "function" or type(orig_down) ~= "function" then
        logger.warn("wallabagtags: the Wallabag plugin's API has changed, not patching")
        patch_state = "absent"
        return false
    end

    wrapStock(W, orig_get, orig_down)
    -- The marker lives on the shared class table, not in a module local: PluginLoader
    -- uses dofile, not require, so a twice-discovered folder runs this file twice
    -- with independent upvalues.
    rawset(W, PATCH_MARK, true)
    patch_state = "done"
    logger.info("wallabagtags: wrapped the Wallabag plugin")
    return true
end

-- plugin

local WallabagTags = WidgetContainer:extend{
    name = "wallabagtags",
    settings_file = SETTINGS_FILE,
}

function WallabagTags:init()
    -- Second attempt. The module-scope call succeeds when both plugins live in
    -- plugins/ (wallabag sorts first), but not if this folder is discovered from an
    -- extra_plugin_paths entry that sorts ahead of it. By init() time loadPlugins()
    -- has returned, so enabled_plugins is complete.
    ensurePatched()
    loadSettings()
    self.ui.menu:registerToMainMenu(self)
end

function WallabagTags:deletePluginSettings()
    -- PluginLoader removes the file itself right after this returns.
    Cfg.enabled            = false
    Cfg.prefix             = DEFAULT_PREFIX
    Cfg.untagged           = false
    Cfg.prune_empty        = true
    Cfg.uncollect_archived = true
    if settings then settings:reset({}) end
end

function WallabagTags:addToMainMenu(menu_items)
    menu_items.wallabagtags = {
        text = _("Wallabag tag collections"),
        -- MenuSorter places hinted orphans into more_tools without the "NEW: "
        -- prefix, and unlike insert_menu.add() this needs no once-per-process
        -- guarantee (it would append the key twice on a double dofile).
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
    }
end

function WallabagTags:getSubMenuItems()
    if patch_state ~= "done" then
        return {
            {
                text = _("The Wallabag plugin is not enabled"),
                enabled = false,
                keep_menu_open = true,
                help_text = _("This plugin extends the built-in Wallabag plugin. Enable Wallabag under Plugin management, then restart KOReader."),
            },
        }
    end

    local items = {
        {
            text = _("Sort articles into collections by tag"),
            help_text = T(_([[Puts each downloaded Wallabag article into one collection per tag, named "%1" followed by the tag.

Every collection whose name starts with that prefix belongs to this plugin and may be changed or deleted at any time. Collections without the prefix are never touched, so do not add files to prefixed collections by hand.]]), Cfg.prefix),
            keep_menu_open = true,
            checked_func = function()
                return Cfg.enabled
            end,
            callback = function()
                Cfg.enabled = not Cfg.enabled
                saveSettings()
            end,
            separator = true,
        },
        {
            text_func = function()
                return T(_("Collection prefix: %1"), Cfg.prefix)
            end,
            keep_menu_open = true,
            enabled_func = function()
                return Cfg.enabled
            end,
            callback = function(touchmenu_instance)
                self:setPrefixDialog(touchmenu_instance)
            end,
        },
        {
            text = T(_("Also collect untagged articles in \"%1\""), collectionName(Cfg.prefix, UNTAGGED_LABEL)),
            keep_menu_open = true,
            enabled_func = function()
                return Cfg.enabled
            end,
            checked_func = function()
                return Cfg.untagged
            end,
            callback = function()
                Cfg.untagged = not Cfg.untagged
                saveSettings()
            end,
        },
        {
            text = _("Delete collections that become empty"),
            keep_menu_open = true,
            enabled_func = function()
                return Cfg.enabled
            end,
            checked_func = function()
                return Cfg.prune_empty
            end,
            callback = function()
                Cfg.prune_empty = not Cfg.prune_empty
                saveSettings()
            end,
        },
        {
            text = _("Remove locally archived articles from collections"),
            help_text = _("Articles moved to the Wallabag archive folder are taken out of the collections managed by this plugin. They are left in any collection you made yourself."),
            keep_menu_open = true,
            enabled_func = function()
                return Cfg.enabled
            end,
            checked_func = function()
                return Cfg.uncollect_archived
            end,
            callback = function()
                Cfg.uncollect_archived = not Cfg.uncollect_archived
                saveSettings()
            end,
            separator = true,
        },
        {
            text = _("Synchronize with Wallabag now"),
            enabled_func = function()
                return Cfg.enabled
            end,
            callback = function()
                self.ui:handleEvent(Event:new("SynchronizeWallabag"))
            end,
        },
        {
            -- Deliberately not gated on Cfg.enabled: its main use is cleaning up
            -- after turning the feature off, or after changing the prefix.
            text_func = function()
                return T(_("Remove all managed collections (%1)"), countManaged(Cfg.prefix))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:confirmRemoveAll(touchmenu_instance)
            end,
        },
    }

    if DEBUG_MENU then
        table.insert(items, {
            text = _("[debug] Reconcile with fake tags"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:debugReconcile(touchmenu_instance)
            end,
        })
    end

    return items
end

--- Own dialog rather than the stock setTagsDialog: that one is a method on the
-- stock instance, clobbers its self.tags_dialog, sets its `updated` flag (causing a
-- spurious rewrite of the user's wallabag.lua) and, decisively, offers no way to
-- reject the input and keep the dialog open.
function WallabagTags:setPrefixDialog(touchmenu_instance)
    local old = Cfg.prefix
    local dialog
    dialog = InputDialog:new{
        title = _("Collection prefix"),
        description = _("Collections whose name starts with this prefix are managed by this plugin. It cannot be empty."),
        input = old,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new = dialog:getInputText()
                        if not isValidPrefix(new) then
                            UIManager:show(InfoMessage:new{
                                text = _("The prefix cannot be empty."),
                                timeout = 2,
                            })
                            return -- keep the dialog open
                        end
                        UIManager:close(dialog)
                        if new == old then return end
                        Cfg.prefix = new
                        saveSettings()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        self:confirmPrefixChange(old, new, touchmenu_instance)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Changing the prefix orphans the old collections, and "Remove all managed
-- collections" then works on the new prefix and can no longer reach them.
function WallabagTags:confirmPrefixChange(old, new, touchmenu_instance)
    local n = countManaged(old)
    if n == 0 then return end
    UIManager:show(MultiConfirmBox:new{
        text = T(_("%1 collection(s) still use the old prefix \"%2\".\n\nWhat should happen to them?"), n, old),
        choice1_text = _("Rename"),
        choice1_callback = function()
            local k = rePrefix(old, new)
            refreshUI()
            if touchmenu_instance then touchmenu_instance:updateItems() end
            UIManager:show(InfoMessage:new{
                text = T(_("Renamed %1 collection(s)."), k),
                timeout = 2,
            })
        end,
        choice2_text = _("Delete"),
        choice2_callback = function()
            local k = removeAllManaged(old)
            refreshUI()
            if touchmenu_instance then touchmenu_instance:updateItems() end
            UIManager:show(InfoMessage:new{
                text = T(_("Removed %1 collection(s)."), k),
                timeout = 2,
            })
        end,
        -- Cancel: they become ordinary collections and are never touched again.
        cancel_text = _("Keep"),
    })
end

function WallabagTags:confirmRemoveAll(touchmenu_instance)
    local n = countManaged(Cfg.prefix)
    if n == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("There are no collections starting with \"%1\"."), Cfg.prefix),
            timeout = 2,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Remove %1 collection(s) starting with \"%2\"?\n\nThe articles themselves are not deleted."), n, Cfg.prefix),
        ok_text = _("Remove"),
        ok_callback = function()
            local k = removeAllManaged(Cfg.prefix)
            refreshUI()
            if touchmenu_instance then touchmenu_instance:updateItems() end
            UIManager:show(InfoMessage:new{
                text = T(_("Removed %1 collection(s)."), k),
                timeout = 2,
            })
        end,
    })
end

--- Development aid: run the real reconciliation path against synthetic tags over
-- the articles actually present in the Wallabag download folder. Invoking it
-- repeatedly rotates the tag assignment, which exercises retag, untag and prune
-- without needing a Wallabag server. Enabled by DEBUG_MENU.
local debug_round = 0
function WallabagTags:debugReconcile(touchmenu_instance)
    local wb = PluginLoader:getPluginInstance("wallabag")
    if not wb then
        UIManager:show(InfoMessage:new{ text = "No Wallabag instance", timeout = 2 })
        return
    end

    local local_articles = wb:getLocalArticles()
    debug_round = debug_round + 1
    local tag_sets = {
        { { label = "alpha" }, { label = "beta" } },
        { { label = "beta" } },
        {},
        { { label = "gamma" }, { label = "alpha" } },
    }

    local articles, i = {}, 0
    for id in pairs(local_articles) do
        i = i + 1
        table.insert(articles, {
            id = id,
            tags = tag_sets[((i + debug_round) % #tag_sets) + 1],
        })
    end

    local n_files, n_add, n_del, n_new, n_gone = reconcile(wb, local_articles, articles)
    refreshUI()
    if touchmenu_instance then touchmenu_instance:updateItems() end
    UIManager:show(InfoMessage:new{
        text = string.format("round %d: %s articles, +%s/-%s items, +%s/-%s colls",
            debug_round, n_files or "-", n_add or "-", n_del or "-", n_new or "-", n_gone or "-"),
    })
end

-- Best-effort early patch: succeeds when both plugins live in plugins/, because
-- "plugins/wallabag.koplugin" sorts before "plugins/wallabagtags.koplugin" and the
-- stock class is therefore already in enabled_plugins. init() retries otherwise.
ensurePatched()

-- Exposed for the unit tests; not part of the plugin's runtime surface.
WallabagTags._testing = {
    Cfg = Cfg,
    capture = capture,
    wrapStock = wrapStock,
    reconcile = reconcile,
    reconcileOne = reconcileOne,
    purgeArchived = purgeArchived,
    pruneEmpty = pruneEmpty,
    isManaged = isManaged,
    isValidPrefix = isValidPrefix,
    sanitizeLabel = sanitizeLabel,
    countManaged = countManaged,
    removeAllManaged = removeAllManaged,
    rePrefix = rePrefix,
    UNTAGGED_LABEL = UNTAGGED_LABEL,
}

return WallabagTags
