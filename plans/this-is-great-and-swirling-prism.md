# "Open next file" stays within the collection (wallabagtags plugin)

## Context
Articles are now sorted into `wb: <tag>` collections, but at end of book KOReader's
"Open next file" (`ReaderStatus:onOpenNextOrPreviousFileInFolder`,
`frontend/apps/reader/modules/readerstatus.lua:175`) walks the **folder** (all Wallabag
downloads), not the collection. Goal: when an article was opened from a collection,
next/previous follows that collection, in the order the collection view shows.
Decisions: follow the collection it was **opened from**; implement **only in the
wallabagtags plugin** (core untouched, same wrap-at-load approach as the existing patches).

## Approach (all in `plugins/wallabagtags.koplugin/main.lua`)

1. **Remember where the book was opened from.** Wrap `FileManagerCollection.onMenuSelect`
   (`frontend/apps/filemanager/filemanagercollection.lua:201`; `onShowColl` passes
   `self.onMenuSelect` fresh each time, so a module-level wrap takes effect). Inside it
   `self` is the BookList, so `self.path` = collection name. Record
   `context = { file = item.file, coll = self.path }` (module state) before calling the original.
   Skip when in select mode or on a search-results collection.

2. **Ordered collection list using the collection's own sort.** New helper
   `getCollectionFiles(coll_name)` mirroring `FileManagerCollection:setCollate` /
   `updateItemTable` (lines 125–149, 706–731): items from `ReadCollection.coll[name]`;
   if `coll_settings.collate` set, use `BookList.collates[id]` (`item_func`,
   `init_sort_func`, honour `collate_reverse`), else sort by `item.order`.

3. **Override next/previous.** Wrap `ReaderStatus.onOpenNextOrPreviousFileInFolder(prev)`:
   if `context.file == self.document.file` and the file is still in `context.coll`, find the
   next (or previous) entry that exists, `DocumentRegistry:hasProvider`, and
   `BookList.getBookStatus ~= "complete"` (same filters as `FileChooser:getNextOrPreviousFileInFolder`).
   Open it via `UIManager:nextTick(filemanagerutil.openFile(...))`, update
   `context.file` to it so the chain continues through the whole collection. At the end,
   show "This is the last article in collection X." Otherwise call the original (folder behaviour).

4. **Date/access sort gate.** `onEndOfBook` disables next-file when the *file browser* sort
   is date/access. Wrap `ReaderStatus.onEndOfBook`: if in collection context and
   `end_document_action == "next_file"`, mark-finished-if-configured then call the
   collection next directly; otherwise defer to the original. (Pop-up button remains
   governed by core's gate — acceptable limitation, note it.)

5. Applies to whichever collection the book was opened from (not just `wb:` ones) — it's
   free and matches the request. Install the wraps once in `ensurePatched()`.

## Tests
Extend `spec/unit/wallabagtags_spec.lua`: ordering by manual order and by a collate;
next skips completed/missing files; previous works; chain advances `context`; falls back
to folder behaviour when opened outside a collection or file removed from the collection.

## Verification
- `./kodev test front wallabagtags_spec.lua` (or `busted` per repo setup).
- Emulator (`./kodev run`): open a `wb:` collection, open article, jump to end → next
  article in that collection opens; repeat; open same article from History → folder behaviour.
