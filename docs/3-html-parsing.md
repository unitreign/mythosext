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

## Dot doesn't match newlines

In Lua patterns, `.` matches any character **except a newline**. This catches people out when the HTML they're matching spans multiple lines:

```lua
-- This works if the title is all on one line
html:match('<h1[^>]*>(.-)</h1>')

-- This breaks if there's a newline between the tags
html:match('<div[^>]*class="description"[^>]*>(.-)</div>')
```

For single-line tags (`<h1>`, `<span>`, `<a>`) this is usually fine. For multi-line blocks like description divs or chapter content, use `extract_div` instead of a pattern with `.-`.

If you know the content won't contain `<` characters, `[^<]*` can substitute for `.-` and also works across newlines:

```lua
-- Matches across newlines as long as the content has no < in it
html:match('<title>([^<]*)</title>')
```

## Extracting JSON embedded in HTML

Some sites embed data directly in JavaScript variables on the page rather than serving it from an API. Royal Road does this with its chapter list:

```html
<script>
window.chapters = [{"id":123,"title":"Chapter 1","url":"/fiction/..."},...]
window.volumes  = [...]
</script>
```

Use `%b[]` (Lua's balanced-match) to grab the array without worrying about brackets inside string values:

```lua
local raw = html:match('window%.chapters%s*=%s*(%b[])')
```

`%b[]` matches a `[` paired with its closing `]`, tracking depth. Then decode with the JSON helper from [4-http.md](4-http.md):

```lua
if raw then
    local data = json_decode(raw)
    for _, item in ipairs(data or {}) do
        -- item.id, item.title, item.url, etc.
    end
end
```

If you only need a count and want to avoid a full JSON decode (e.g. in `parseNovelMeta`), count field occurrences in the raw string instead:

```lua
local total = 0
if raw then
    for _ in raw:gmatch('"id"%s*:') do total = total + 1 end
end
```

## Scanning past the first match with extract_div

The standard `extract_div` finds the **first** div matching a pattern. If you need to find divs at specific positions — for example, an author note that comes after a chapter content div — pass a starting position as the third argument and capture the end position as a second return value:

```lua
-- Extended signature (used when you need to scan past a div you already found):
local function extract_div(html, open_pattern, start_pos)
    local s, e = html:find(open_pattern, start_pos or 1)
    if not s then return nil, nil end
    local tag_end = html:find('>', e)
    if not tag_end then return nil, nil end
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
            if depth == 0 then
                return html:sub(tag_end + 1, close_pos - 1), close_pos + 6
            end
            pos = close_pos + 6
        end
    end
    return nil, nil
end
```

The second return value is the position immediately after the closing `</div>`. Use it to continue scanning:

```lua
local content, after = extract_div(html, '<div[^>]*class="chapter%-content"')
if after then
    -- look for an author note that comes after the chapter body
    local note = extract_div(html, '<div[^>]*class="author%-note"', after)
end
```

The version in `novelfire.lua` uses the 2-return form. If you only need the content, the second return value can be ignored.

## URL encoding for search

When building a search URL, you need to encode the user's input:

```lua
local function url_encode(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local url = BASE .. "/search?q=" .. url_encode(term)
```

Some sites accept `+` for spaces in query strings. Check what the site's own search form sends.
