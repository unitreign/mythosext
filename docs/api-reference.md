# API Reference

## Extension table fields

These go in the `ext = { ... }` table at the top of your file.

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Unique identifier. Lowercase, no spaces (e.g. `"royalroad"`) |
| `name` | string | yes | Display name shown in the UI |
| `site` | string | yes | Base URL of the site, no trailing slash |
| `lang` | string | yes | Language code: `"en"`, `"zh"`, `"ko"`, etc. |
| `version` | string | yes | Version string in `"1.0.0"` format |
| `supports_page_mode` | boolean | no | Shows a Page Mode toggle in Sources settings. Set this if you implement `parsePage` |
| `chapters_per_page` | number | no | How many chapters appear per HTML page. Set this for paginated sites to enable delta fetching of new chapters |

---

## Required methods

### popularNovels(page, options)

Returns the browse or popular listing for a given page number. `options` is passed in but Mythos doesn't send filter values yet, so you can ignore it.

```lua
function ext:popularNovels(page, options)
    -- fetch and parse the popular/ranking page
    return {
        novels = {
            { name = "Novel Title", path = "/novel/slug", cover = "https://..." },
        }
    }
end
```

Return `{ novels = {} }` on failure rather than returning nil or erroring out.

---

### searchNovels(term, page)

Same return shape as `popularNovels`. `term` is the raw string the user typed into the search box.

```lua
function ext:searchNovels(term, page)
    return {
        novels = {
            { name = "Novel Title", path = "/novel/slug", cover = "https://..." },
        }
    }
end
```

---

### parseNovel(path)

Returns the full novel detail: metadata and the complete chapter list.

```lua
function ext:parseNovel(path)
    return {
        name       = "Novel Title",
        path       = path,
        cover      = "https://...",
        summary    = "Novel description...",
        author     = "Author Name",
        genres     = "Action, Fantasy",     -- comma-separated string
        status     = "Ongoing",             -- see status values below
        chapters   = {
            {
                name           = "Chapter 1: Title",
                path           = "/novel/slug/chapter-1",
                chapter_number = 1,          -- optional
                locked         = false,      -- optional, see locked-chapters.md
            },
        },
        totalPages = 1,
    }
end
```

`chapter_number` is optional but nice to have — Mythos shows it as "Ch.1" in the chapter list. `locked` is covered in [locked-chapters.md](locked-chapters.md).

**Status values:** `"Ongoing"`, `"Completed"`, `"Hiatus"`, `"Cancelled"`, `"Unknown"`

---

### parseChapter(path)

Returns the chapter body as an HTML string. Mythos renders this directly, so keep the markup clean — just `<p>`, `<h1>`-`<h6>`, `<br>`, `<em>`, `<strong>`, `<img>` and similar.

```lua
function ext:parseChapter(path)
    return "<p>Chapter content...</p>"
end
```

Return a short error message in a `<p>` tag if fetching fails, rather than an empty string.

---

## Optional methods

### parseNovelMeta(path)

A lighter version of `parseNovel` for cache checking. Mythos calls this first when a user reopens a novel it has seen before. If `total_chapters` matches the cached count, the full chapter list fetch is skipped.

Only fetch the main novel page here. No chapter pages, no AJAX calls.

```lua
function ext:parseNovelMeta(path)
    return {
        name           = "Novel Title",
        path           = path,
        cover          = "https://...",
        summary        = "...",
        author         = "...",
        status         = "Ongoing",
        total_chapters = 150,
    }
end
```

Return `0` for `total_chapters` if the main page doesn't show the count. Mythos will fall back to `parseNovel`.

When this works well, reopening a cached novel with no new chapters costs exactly 1 HTTP request.

---

### parsePage(path, page)

Called when `supports_page_mode = true` and the user has Page Mode enabled. Returns one page worth of chapters.

```lua
function ext:parsePage(path, page)
    return {
        chapters = {
            { name = "Chapter 1", path = "/novel/slug/chapter-1" },
        }
    }
end
```

Only implement this if your site paginates its chapter list. Set `ext.chapters_per_page = N` alongside it so Mythos can calculate which pages contain new chapters.
