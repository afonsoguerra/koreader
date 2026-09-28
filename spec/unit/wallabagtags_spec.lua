describe("Wallabag tag collections plugin", function()
    local DataStorage, PluginLoader, ReadCollection, ffiUtil, lfs, util
    local WallabagTags, tt, Cfg
    local work_dir, download_dir, archive_dir
    local orig_write, write_count, last_changed

    -- Create a real file: ReadCollection:addItem goes through buildEntry, which
    -- returns nil (and makes addItem error) for anything that is not a real file.
    local function makeArticle(id, title)
        local path = download_dir .. "/[w-id_" .. id .. "] " .. (title or "Article") .. ".epub"
        local f = assert(io.open(path, "w"))
        f:write("x")
        f:close()
        return path
    end

    local function tags(...)
        local t = {}
        for _, label in ipairs({ ... }) do
            table.insert(t, { id = #t + 1, label = label, slug = label })
        end
        return t
    end

    local function realpath(p)
        return ffiUtil.realpath(p) or p
    end

    local function members(coll_name)
        local out = {}
        for file in pairs(ReadCollection.coll[coll_name] or {}) do
            table.insert(out, file)
        end
        table.sort(out)
        return out
    end

    setup(function()
        require("commonrequire")
        disable_plugins()
        -- The stock plugin must be loaded first: our plugin looks it up in
        -- PluginLoader.enabled_plugins in order to wrap it.
        load_plugin("wallabag.koplugin")
        load_plugin("wallabagtags.koplugin")

        DataStorage = require("datastorage")
        PluginLoader = require("pluginloader")
        ReadCollection = require("readcollection")
        ffiUtil = require("ffi/util")
        lfs = require("libs/libkoreader-lfs")
        util = require("util")

        for _, plugin in ipairs(PluginLoader.enabled_plugins) do
            if plugin.name == "wallabagtags" then WallabagTags = plugin end
        end
        assert.is_table(WallabagTags)
        tt = WallabagTags._testing
        Cfg = tt.Cfg

        work_dir = DataStorage:getDataDir() .. "/wallabagtags_spec"
        download_dir = work_dir .. "/wallabag"
        archive_dir = download_dir .. "/archive"
        util.makePath(archive_dir)
    end)

    teardown(function()
        ffiUtil.purgeDir(work_dir)
    end)

    before_each(function()
        -- Fresh collection state, with only the built-in Favorites.
        ReadCollection.coll = { favorites = {} }
        ReadCollection.coll_settings = { favorites = { order = 1 } }
        ReadCollection.coll_default = nil

        -- Never touch settings/collection.lua from the tests, and count the writes:
        -- one per reconcile() is part of the contract.
        orig_write = ReadCollection.write
        write_count, last_changed = 0, nil
        ReadCollection.write = function(_, changed)
            write_count = write_count + 1
            last_changed = changed
        end

        Cfg.enabled = true
        Cfg.prefix = "wb: "
        Cfg.untagged = false
        Cfg.prune_empty = true
        Cfg.uncollect_archived = true

        for entry in lfs.dir(download_dir) do
            if entry ~= "." and entry ~= ".." then
                local p = download_dir .. "/" .. entry
                if lfs.attributes(p, "mode") == "file" then os.remove(p) end
            end
        end
        for entry in lfs.dir(archive_dir) do
            if entry ~= "." and entry ~= ".." then
                local p = archive_dir .. "/" .. entry
                if lfs.attributes(p, "mode") == "file" then os.remove(p) end
            end
        end
    end)

    after_each(function()
        ReadCollection.write = orig_write
    end)

    local function wbStub()
        return { archive_directory = archive_dir, directory = download_dir }
    end

    it("puts a new article into one collection per tag", function()
        local path = makeArticle(1)
        tt.reconcile(wbStub(), { ["1"] = path }, {
            { id = 1, tags = tags("science", "lua") },
        })

        assert.same({ realpath(path) }, members("wb: science"))
        assert.same({ realpath(path) }, members("wb: lua"))
        assert.equals(1, write_count)
        assert.is_true(last_changed["wb: science"])
    end)

    it("adds the article to a new collection when a tag appears on the server", function()
        local path = makeArticle(1)
        local local_articles = { ["1"] = path }
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("science") } })
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("science", "physics") } })

        assert.same({ realpath(path) }, members("wb: science"))
        assert.same({ realpath(path) }, members("wb: physics"))
    end)

    it("removes the article and prunes the collection when a tag disappears", function()
        local path = makeArticle(1)
        local local_articles = { ["1"] = path }
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("science", "physics") } })
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("science") } })

        assert.same({ realpath(path) }, members("wb: science"))
        assert.is_nil(ReadCollection.coll["wb: physics"])
    end)

    it("keeps the emptied collection when pruning is off", function()
        local path = makeArticle(1)
        local local_articles = { ["1"] = path }
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("physics") } })
        Cfg.prune_empty = false
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("science") } })

        assert.is_table(ReadCollection.coll["wb: physics"])
        assert.same({}, members("wb: physics"))
    end)

    -- The critical guarantee of the whole feature.
    it("never touches a collection the user made by hand", function()
        local path = makeArticle(1)
        ReadCollection:addCollection("Reading list")
        ReadCollection:addItem(path, "Reading list")
        ReadCollection:addItem(path, "favorites")

        local local_articles = { ["1"] = path }
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("science") } })
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags() } })

        assert.same({ realpath(path) }, members("Reading list"))
        assert.same({ realpath(path) }, members("favorites"))
        assert.is_nil(ReadCollection.coll["wb: science"])
    end)

    it("collects untagged articles only when the option is on", function()
        local path = makeArticle(1)
        local local_articles = { ["1"] = path }
        local untagged = "wb: " .. tt.UNTAGGED_LABEL

        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags() } })
        assert.is_nil(ReadCollection.coll[untagged])

        Cfg.untagged = true
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags() } })
        assert.same({ realpath(path) }, members(untagged))

        -- Gaining a tag takes it back out of the untagged collection.
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("science") } })
        assert.is_nil(ReadCollection.coll[untagged])
        assert.same({ realpath(path) }, members("wb: science"))
    end)

    -- With filter_tag set, getArticleList only returns matching articles. Anything
    -- absent from the list must be left completely alone.
    it("does not touch articles missing from this run's list", function()
        local kept = makeArticle(1)
        local filtered = makeArticle(2)
        local local_articles = { ["1"] = kept, ["2"] = filtered }

        tt.reconcile(wbStub(), local_articles, {
            { id = 1, tags = tags("science") },
            { id = 2, tags = tags("science") },
        })
        assert.equals(2, #members("wb: science"))

        -- Second sync: a filter hides article 2 entirely.
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("science") } })
        assert.equals(2, #members("wb: science"))
    end)

    it("takes locally archived articles out of managed collections only", function()
        local path = makeArticle(1)
        ReadCollection:addCollection("Reading list")
        ReadCollection:addItem(path, "Reading list")
        local local_articles = { ["1"] = path }
        tt.reconcile(wbStub(), local_articles, { { id = 1, tags = tags("science") } })

        -- Exactly what Wallabag:archiveLocalArticle does: move the file, then let
        -- ReadCollection re-key the item under its new path.
        local archived = archive_dir .. "/" .. path:gsub(".*/", "")
        assert(os.rename(path, archived))
        ReadCollection:updateItem(path, archived)
        write_count = 0

        tt.reconcile(wbStub(), { }, { })
        assert.is_nil(ReadCollection.coll["wb: science"]) -- emptied, then pruned
        assert.same({ realpath(archived) }, members("Reading list"))
    end)

    it("leaves archived articles alone when the option is off", function()
        local path = makeArticle(1)
        tt.reconcile(wbStub(), { ["1"] = path }, { { id = 1, tags = tags("science") } })

        local archived = archive_dir .. "/" .. path:gsub(".*/", "")
        assert(os.rename(path, archived))
        ReadCollection:updateItem(path, archived)

        Cfg.uncollect_archived = false
        tt.reconcile(wbStub(), {}, {})
        assert.same({ realpath(archived) }, members("wb: science"))
    end)

    it("does not manage a collection named exactly the prefix", function()
        assert.is_false(tt.isManaged("wb: ", "wb: "))
        assert.is_true(tt.isManaged("wb: x", "wb: "))
    end)

    it("spares connected-folder and default collections when pruning", function()
        -- A connected-folder collection is empty only until its next scan, and the
        -- user's default collection must survive. Either can carry the prefix.
        ReadCollection:addCollection("wb: scanned")
        ReadCollection.coll_settings["wb: scanned"].folders = { ["/books"] = {} }
        ReadCollection:addCollection("wb: chosen")
        ReadCollection.coll_settings["wb: chosen"].default = true
        ReadCollection:addCollection("wb: ordinary")

        assert.equals(1, tt.pruneEmpty("wb: ", {}))
        assert.is_table(ReadCollection.coll["wb: scanned"])
        assert.is_table(ReadCollection.coll["wb: chosen"])
        assert.is_nil(ReadCollection.coll["wb: ordinary"])
    end)

    it("never removes Favorites, even when the prefix would match it", function()
        local path = makeArticle(1)
        ReadCollection:addItem(path, "favorites")
        assert.is_false(tt.isManaged("favorites", "fav"))

        Cfg.prefix = "fav"
        tt.reconcile(wbStub(), { ["1"] = path }, { { id = 1, tags = tags("science") } })
        assert.is_table(ReadCollection.coll.favorites)

        -- Emptying it must not make it prunable either.
        ReadCollection.coll.favorites = {}
        assert.equals(0, tt.pruneEmpty("fav", {}))
        assert.is_table(ReadCollection.coll.favorites)
    end)

    it("refuses to run with an empty or blank prefix", function()
        local path = makeArticle(1)
        ReadCollection:addCollection("wb: science")
        ReadCollection:addItem(path, "wb: science")

        for _, bad in ipairs({ "", "   ", "\t" }) do
            assert.is_false(tt.isValidPrefix(bad))
            Cfg.prefix = bad
            tt.reconcile(wbStub(), { ["1"] = path }, { { id = 1, tags = tags("science") } })
        end

        assert.equals(0, write_count)
        assert.is_table(ReadCollection.coll["wb: science"])
        assert.is_table(ReadCollection.coll.favorites)
    end)

    it("makes no changes at all when the article list was not captured", function()
        local path = makeArticle(1)
        ReadCollection:addCollection("wb: stale")
        tt.reconcile(wbStub(), { ["1"] = path }, nil)

        assert.equals(0, write_count)
        -- In particular it must not prune: a transient network error would
        -- otherwise delete every managed collection.
        assert.is_table(ReadCollection.coll["wb: stale"])
    end)

    it("is inert while disabled", function()
        local path = makeArticle(1)
        Cfg.enabled = false
        tt.reconcile(wbStub(), { ["1"] = path }, { { id = 1, tags = tags("science") } })

        assert.equals(0, write_count)
        assert.is_nil(ReadCollection.coll["wb: science"])
    end)

    it("skips articles whose file is gone", function()
        local path = makeArticle(1)
        os.remove(path)
        -- addItem would error on a missing file; the lfs guard must catch it first.
        assert.has_no.errors(function()
            tt.reconcile(wbStub(), { ["1"] = path }, { { id = 1, tags = tags("science") } })
        end)
        assert.is_nil(ReadCollection.coll["wb: science"])
    end)

    it("writes exactly once per reconcile, whatever the article count", function()
        local a, b = makeArticle(1), makeArticle(2)
        tt.reconcile(wbStub(), { ["1"] = a, ["2"] = b }, {
            { id = 1, tags = tags("science", "lua", "physics") },
            { id = 2, tags = tags("science", "art") },
        })
        assert.equals(1, write_count)
    end)

    it("makes no write when nothing changed", function()
        local path = makeArticle(1)
        local local_articles = { ["1"] = path }
        local articles = { { id = 1, tags = tags("science") } }
        tt.reconcile(wbStub(), local_articles, articles)
        write_count = 0
        tt.reconcile(wbStub(), local_articles, articles)
        assert.equals(0, write_count)
    end)

    describe("tag labels", function()
        it("trims whitespace and flattens control characters", function()
            assert.equals("a b", tt.sanitizeLabel(" a\nb "))
            assert.equals("a b", tt.sanitizeLabel("a\t\t\tb"))
            assert.equals("", tt.sanitizeLabel("   "))
            assert.equals("", tt.sanitizeLabel("\0\1\2"))
            assert.equals("", tt.sanitizeLabel(nil))
            assert.equals("", tt.sanitizeLabel(42))
        end)

        it("leaves valid multi-byte UTF-8 intact", function()
            assert.equals("naïve", tt.sanitizeLabel("naïve"))
            assert.equals("日本語", tt.sanitizeLabel("日本語"))
            assert.equals("café ☕", tt.sanitizeLabel("  café ☕  "))
        end)

        it("replaces invalid bytes with U+FFFD", function()
            local replacement = "\239\191\189" -- U+FFFD, the "�" used by sanitizeLabel
            -- A lone continuation byte.
            assert.equals("a" .. replacement .. "b", tt.sanitizeLabel("a\185b"))
            -- A truncated 3-byte sequence.
            assert.equals(replacement .. replacement .. "z", tt.sanitizeLabel("\228\184z"))
        end)

        it("never returns a label that is not valid UTF-8", function()
            for _, raw in ipairs({ "\255\254", "abc\237\160\128", "\240\159", "ok" }) do
                local clean = tt.sanitizeLabel(raw)
                assert.equals(clean, util.fixUtf8(clean, "?"))
            end
        end)

        it("caps the length on a character boundary", function()
            local long = string.rep("é", 400)
            local clean = tt.sanitizeLabel(long)
            assert.equals(100, #util.splitToChars(clean))
            -- Cutting mid-sequence would have reintroduced invalid UTF-8.
            assert.equals(clean, util.fixUtf8(clean, "?"))
        end)

        it("ignores unusable labels and malformed tag entries", function()
            local path = makeArticle(1)
            tt.reconcile(wbStub(), { ["1"] = path }, {
                { id = 1, tags = { { label = "  " }, "not a table", { label = "science" } } },
            })
            assert.same({ realpath(path) }, members("wb: science"))
            assert.is_nil(ReadCollection.coll["wb: "])
        end)

        it("handles an absent tags field", function()
            local path = makeArticle(1)
            assert.has_no.errors(function()
                tt.reconcile(wbStub(), { ["1"] = path }, { { id = 1 } })
            end)
        end)
    end)

    describe("prefix maintenance", function()
        it("counts and removes only managed collections", function()
            local path = makeArticle(1)
            ReadCollection:addCollection("Reading list")
            ReadCollection:addItem(path, "Reading list")
            tt.reconcile(wbStub(), { ["1"] = path }, { { id = 1, tags = tags("science", "lua") } })

            assert.equals(2, tt.countManaged("wb: "))
            assert.equals(2, tt.removeAllManaged("wb: "))
            assert.is_nil(ReadCollection.coll["wb: science"])
            assert.is_table(ReadCollection.coll["Reading list"])
            assert.is_table(ReadCollection.coll.favorites)
        end)

        it("renames managed collections onto a new prefix, keeping their settings", function()
            local path = makeArticle(1)
            tt.reconcile(wbStub(), { ["1"] = path }, { { id = 1, tags = tags("science") } })
            ReadCollection.coll_settings["wb: science"].collate = "strcoll"

            assert.equals(1, tt.rePrefix("wb: ", "tag/"))
            assert.is_nil(ReadCollection.coll["wb: science"])
            assert.same({ realpath(path) }, members("tag/science"))
            assert.equals("strcoll", ReadCollection.coll_settings["tag/science"].collate)
        end)

        it("skips a rename that would clobber an existing collection", function()
            local a, b = makeArticle(1), makeArticle(2)
            tt.reconcile(wbStub(), { ["1"] = a }, { { id = 1, tags = tags("science") } })
            ReadCollection:addCollection("tag/science")
            ReadCollection:addItem(b, "tag/science")

            assert.equals(0, tt.rePrefix("wb: ", "tag/"))
            assert.same({ realpath(a) }, members("wb: science"))
            assert.same({ realpath(b) }, members("tag/science"))
        end)

        it("refuses to re-prefix with an invalid prefix", function()
            local path = makeArticle(1)
            tt.reconcile(wbStub(), { ["1"] = path }, { { id = 1, tags = tags("science") } })
            assert.equals(0, tt.rePrefix("wb: ", ""))
            assert.equals(0, tt.rePrefix("", "tag/"))
            assert.equals(0, tt.removeAllManaged(""))
            assert.is_table(ReadCollection.coll["wb: science"])
        end)
    end)

    it("wrapped the stock Wallabag class exactly once", function()
        local Wallabag
        for _, plugin in ipairs(PluginLoader.enabled_plugins) do
            if plugin.name == "wallabag" then Wallabag = plugin end
        end
        assert.is_table(Wallabag)
        assert.is_true(rawget(Wallabag, "__wallabagtags_patched"))
    end)

    -- The wrapper is tested against a synthetic class rather than the stock one, so
    -- the capture/epoch logic can be driven without a Wallabag server.
    describe("the sync wrapper", function()
        -- @tparam table opts .list returned by getArticleList, .skip_list to model a
        -- sync that bails before fetching, .fail to model the stock code throwing.
        -- Returns "sentinel" so the wrapper's pass-through can be asserted.
        local function fakeStockClass(opts)
            local F = {
                archive_directory = archive_dir,
                directory = download_dir,
            }
            local get = function() return opts.list end
            local down = function(wb)
                if not opts.skip_list then wb:getArticleList() end
                if opts.fail then error("stock exploded") end
                return "sentinel"
            end
            tt.wrapStock(F, get, down)
            return F
        end

        it("reconciles using the list captured by getArticleList", function()
            local path = makeArticle(1)
            local F = fakeStockClass{ list = { { id = 1, tags = tags("science") } } }

            assert.equals("sentinel", F:downloadArticles({ ["1"] = path }))
            assert.same({ realpath(path) }, members("wb: science"))
        end)

        it("does nothing when getArticleList returned nothing", function()
            local path = makeArticle(1)
            local F = fakeStockClass{ list = nil }

            F:downloadArticles({ ["1"] = path })
            assert.equals(0, write_count)
        end)

        it("does nothing when the sync bailed before fetching the list", function()
            local path = makeArticle(1)
            ReadCollection:addCollection("wb: stale")
            local F = fakeStockClass{ skip_list = true }

            F:downloadArticles({ ["1"] = path })
            assert.equals(0, write_count)
            assert.is_table(ReadCollection.coll["wb: stale"])
        end)

        -- The capture slot is cleared on entry, so a list fetched by an earlier run
        -- can never be mistaken for this one's.
        it("does not reuse a list captured by a previous sync", function()
            local path = makeArticle(1)
            local opts = { list = { { id = 1, tags = tags("science") } } }
            local F = fakeStockClass(opts)

            F:downloadArticles({ ["1"] = path })
            assert.same({ realpath(path) }, members("wb: science"))

            -- Second run bails before fetching; the stale capture must be ignored,
            -- so nothing is added and (crucially) nothing is pruned either.
            ReadCollection.coll["wb: science"] = {}
            opts.skip_list = true
            write_count = 0
            F:downloadArticles({ ["1"] = path })
            assert.equals(0, write_count)
            assert.is_table(ReadCollection.coll["wb: science"])
        end)

        it("cannot be seeded by an out-of-band getArticleList call", function()
            local path = makeArticle(1)
            local opts = { list = { { id = 1, tags = tags("science") } } }
            local F = fakeStockClass(opts)

            F:getArticleList() -- fills the capture slot outside any sync
            opts.skip_list = true
            ReadCollection:addCollection("wb: stale")
            F:downloadArticles({ ["1"] = path })

            assert.equals(0, write_count)
            assert.is_nil(ReadCollection.coll["wb: science"])
            assert.is_table(ReadCollection.coll["wb: stale"])
        end)

        it("lets an error from the stock code propagate untouched", function()
            local F = fakeStockClass{ fail = true }
            assert.has_error(function() F:downloadArticles({}) end)
        end)

        it("survives a failure inside its own reconciliation", function()
            local path = makeArticle(1)
            local F = fakeStockClass{ list = { { id = 1, tags = tags("science") } } }
            local saved = ReadCollection.addItem
            ReadCollection.addItem = function() error("boom") end
            local ok, ret = pcall(function() return F:downloadArticles({ ["1"] = path }) end)
            ReadCollection.addItem = saved

            assert.is_true(ok)
            assert.equals("sentinel", ret) -- the user's sync still completed
        end)
    end)
end)
