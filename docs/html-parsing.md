# HTML Parsing

Extensions run in KOReader's Lua environment. There's no DOM, no CSS selectors, no XPath. Everything is raw string matching using Lua patterns, which work similarly to regex but with a different syntax.

## The four helpers

Copy these into every extension. They handle the most common parsing tasks.

```lua
-- Read a named attribute out of an opening tag string.
-- Works with both single and double quotes.
local function attr(tag_html, name)
    return tag_html:match(name .. '="([^"]*)"')
        or tag_html:match(name .. "='([^']*)'")
end

-- Strip all HTML tags from a string and decode common entities.
-- Also trims leading and trailing whitespace.
local function strip_tags(s)
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&amp;",  "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
    return s:match("^%s*(.-)%s*$")
end

-- Find all occurrences of a tag with an optional class filter.
-- Returns a list of { open, inner } tables.
-- Shallow only — does not handle tags that nest inside themselves.
local function find_all(html, tag, class_pat)
    local results = {}
    local open_pat = class_pat
        and ('<' .. tag .. '[^>]*class="[^"]*' .. class_pat .. '[^"]*"[^>]*>')
        or  ('<' .. tag .. '[^>]*>')
    local close_pat = '</' .. tag .. '>'
    local pos = 1
    while true do
        local s, e = html:find(open_pat, pos)
        if not s then break end
        local cs, ce = html:find(close_pat, e + 1)
        if not cs then break end
        local inner = html:sub(e + 1, cs - 1)
        table.insert(results, { open = html:sub(s, e), inner = inner })
        pos = ce + 1
    end
    return results
end

-- Extract the full inner content of the first <div> matching open_pattern.
-- Handles nested <div> tags correctly by tracking depth.
-- Use this for chapter content containers and any div that can contain other divs.
local function extract_div(html, open_pattern)
    local s, e = html:find(open_pattern)
    if not s then return nil end
    local tag_end = html:find('>', e)
    if not tag_end then return nil end
    local depth, pos = 1, tag_end + 1
    while depth > 0 and pos <= #html do
        local open_pos  = html:find('<div', pos, true)
        local close_pos = html:find('</div>', pos, true)
        if not close_pos then break end
        if open_pos and open_pos < close_pos then
            depth = depth + 1
            pos   = open_pos + 4
        else
            depth = depth - 1
            if depth == 0 then return html:sub(tag_end + 1, close_pos - 1) end
            pos = close_pos + 6
        end
    end
    return nil
end
```

## Common patterns

| What you want | Lua pattern |
|---|---|
| Text inside a tag | `html:match('<h1[^>]*>(.-)</h1>')` |
| Text inside a class-matched tag | `html:match('<[^>]*class="[^"]*my%-class[^"]*"[^>]*>(.-)</')` |
| `src` from an `<img>` | `html:match('<img[^>]*src="([^"]+)"')` |
| `data-src` from an `<img>` | `html:match('<img[^>]*data%-src="([^"]+)"')` |
| `href` from an `<a>` | `html:match('<a[^>]*href="([^"]+)"')` |
| Trim whitespace | `s:match("^%s*(.-)%s*$")` |
| Remove a tag and its content | `html:gsub('<script[^>]*>.-</script>', '')` |
| Iterate over list items | `for open, inner in html:gmatch('(<li[^>]*class="[^"]*item[^"]*"[^>]*>)(.-)</li>') do` |

## Escaping special characters

Lua patterns treat these characters as special: `. % + - * ? [ ^ $ ( )`

If any of them appear in the text you want to match literally, prefix them with `%`:

```
-  →  %-
.  →  %.
(  →  %(
)  →  %)
```

This comes up constantly with class names. For example, matching `class="novel-item"`:

```lua
-- Wrong — the - acts as a lazy quantifier
html:match('class="novel-item"')

-- Right
html:match('class="novel%-item"')
```

## When to use extract_div vs a pattern

Simple patterns work fine for `<span>`, `<p>`, `<li>`, `<h1>` and other tags that don't usually nest inside themselves.

Use `extract_div` when you're targeting a `<div>` that can have other `<div>` tags inside it, which is almost every content container on a novel site. A simple `.-` pattern will close at the first `</div>` it finds, cutting off everything else.

```lua
-- This will break if the content div has nested divs inside
local content = html:match('<div[^>]*id="chapter%-content"[^>]*>(.-)</div>')

-- This tracks depth correctly
local content = extract_div(html, '<div[^>]*id="chapter%-content"')
```

## URL encoding for search

When building a search URL, you need to encode the user's input:

```lua
local function url_encode(str)
    return str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end)
end

local url = BASE .. "/search?q=" .. url_encode(term)
```

Some sites accept `+` for spaces in query strings. Check what the site's own search form sends.
