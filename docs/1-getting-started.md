# Getting Started

## What is an extension?

An extension is a single Lua file that teaches Mythos how to interact with a website. It handles browsing, searching, fetching novel details, and reading chapters. Mythos calls the functions you define and takes care of everything else (UI, caching, epub export).

## Repo layout

```
extensions/
    novelfire.lua     ← one .lua file per site
index.json            ← registry listing all extensions
docs/                 ← you are here
```

Each extension file lives in `extensions/` and has a matching entry in `index.json` so Mythos knows it exists.

## The index.json entry

When you add an extension, you need to add a record to `index.json`:

```json
{
    "id": "sitename",
    "name": "Display Name",
    "version": "1.0.0",
    "lang": "en",
    "site": "https://example.com",
    "description": "Short description of the site.",
    "url": "https://raw.githubusercontent.com/unitreign/mythosext/refs/heads/main/extensions/sitename.lua"
}
```

The `url` field must point to the raw GitHub URL of your `.lua` file. Keep the `id` lowercase with no spaces.

## Basic extension skeleton

Every extension is a Lua table that you return at the end of the file:

```lua
local BASE   = "https://example.com"
local logger = require("logger")

local ext = {
    id      = "sitename",
    name    = "Site Name",
    site    = BASE,
    lang    = "en",
    version = "1.0.0",
}

function ext:popularNovels(page, options)
    return { novels = {} }
end

function ext:searchNovels(term, page)
    return { novels = {} }
end

function ext:parseNovel(path)
    return { name = "", path = path, chapters = {}, totalPages = 1 }
end

function ext:parseChapter(path)
    return "<p></p>"
end

return ext
```

`popularNovels`, `searchNovels`, `parseNovel`, and `parseChapter` are required. Everything else is optional and described in [2-api-reference.md](2-api-reference.md).

## What to read next

- [2-api-reference.md](2-api-reference.md) — all methods, fields, and return shapes
- [3-html-parsing.md](3-html-parsing.md) — parsing HTML with Lua patterns
- [4-http.md](4-http.md) — how to make HTTP requests
- [5-locked-chapters.md](5-locked-chapters.md) — handling paywalled chapters
