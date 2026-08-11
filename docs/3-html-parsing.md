# HTML Parsing

Parsing HTML in a Mythos extension means working directly with strings. Lua provides a pattern-matching system (similar to regex but with a slightly different syntax) and that is all you need — no external libraries, no DOM.

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
-- Returns content, end_pos — end_pos lets you continue scanning past this div.
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

## Common patterns

| What you want | Pattern |
|---|---|
| Text inside a tag | `html:match('<h1[^>]*>(.-)</h1>')` |
| Text inside a class-matched tag | `html:match('<[^>]*class="[^"]*my%-class[^"]*"[^>]*>(.-)</')` |
| `href` from an `<a>` | `html:match('<a[^>]*href="([^"]+)"')` |
| `src` from an `<img>` | `html:match('<img[^>]*src="([^"]+)"')` |
| `data-src` from an `<img>` (lazy-loaded) | `html:match('<img[^>]*data%-src="([^"]+)"')` |
| `og:title` meta tag | `html:match('<meta[^>]*property="og:title"[^>]*content="([^"]+)"')` |
| `og:image` meta tag | `html:match('<meta[^>]*property="og:image"[^>]*content="([^"]+)"')` |
| Trim whitespace | `s:match("^%s*(.-)%s*$")` |
| Remove a tag and its content | `html:gsub('<script[^>]*>.-</script>', '')` |
| Iterate over list items | `for open, inner in html:gmatch('(<li[^>]*class="[^"]*item[^"]*"[^>]*>)(.-)</li>') do` |

## Prefer og: tags for title and cover

Most sites set standard `<meta property="og:...">` tags in their `<head>`. These are more stable than class-based selectors because sites rarely change them, and they're consistent across pages.

For title and cover, try `og:` first and use class-based patterns as a fallback:

```lua
local title = html:match('<meta[^>]*property="og:title"[^>]*content="([^"]+)"')
           or html:match('<meta[^>]*content="([^"]+)"[^>]*property="og:title"')
           or html:match('<h1[^>]*>([^<]+)</h1>')
           or ""

local cover = html:match('<meta[^>]*property="og:image"[^>]*content="([^"]+)"')
           or html:match('<meta[^>]*content="([^"]+)"[^>]*property="og:image"')
```

## Check data-src before src on images

Many sites lazy-load cover images. The `src` attribute points to a placeholder; the real URL is in `data-src`. Always check `data-src` first:

```lua
local cover = html:match('<img[^>]*class="[^"]*cover[^"]*"[^>]*data%-src="([^"]+)"')
           or html:match('<img[^>]*class="[^"]*cover[^"]*"[^>]*src="([^"]+)"')
```

Some sites use protocol-relative URLs (`//img.example.com/...`) instead of full URLs. Prepend `https:` if that's the case:

```lua
if cover and not cover:match("^https?:") then
    cover = "https:" .. cover
end
```

## Escaping special characters

Lua patterns treat these characters as special: `. % + - * ? [ ^ $ ( )`

Prefix them with `%` to match them literally:

```
-  →  %-
.  →  %.
(  →  %(
)  →  %)
```

This comes up constantly with CSS class names. For example, matching `class="novel-item"`:

```lua
-- Wrong — the - is a pattern quantifier
html:match('class="novel-item"')

-- Right
html:match('class="novel%-item"')
```

## When to use extract_div vs a simple pattern

Simple patterns work fine for `<span>`, `<p>`, `<li>`, `<h1>` and other tags that don't nest inside themselves.

Use `extract_div` when targeting a `<div>` that can contain other `<div>` tags — which is almost every content container on a novel site. A `.-` pattern closes at the first `</div>` it finds, cutting off everything else.

```lua
-- Breaks if the content div has any nested divs
local content = html:match('<div[^>]*id="chapter%-content"[^>]*>(.-)</div>')

-- Tracks nesting depth correctly
local content = extract_div(html, '<div[^>]*id="chapter%-content"')
```

## Dot doesn't match newlines

In Lua patterns, `.` matches any character **except a newline**. For single-line tags (`<h1>`, `<span>`, `<a>`) this is usually fine. For multi-line blocks, use `extract_div` instead.

If you know the content has no `<` characters, `[^<]*` works as a cross-line substitute for `.-`:

```lua
-- Works across newlines as long as there's no < inside
html:match('<title>([^<]*)</title>')
```

## Scanning past the first match

`extract_div` returns two values: the content, and the position immediately after the closing `</div>`. Use the second value to continue scanning past a div you already found:

```lua
local content, after = extract_div(html, '<div[^>]*class="chapter%-content"')
if after then
    -- find an author note that comes after the chapter body
    local note = extract_div(html, '<div[^>]*class="author%-note"', after)
end
```

If you only need the content, the second return value can be ignored.

## Extracting JSON embedded in HTML

Some sites embed data as a JavaScript variable instead of serving it from an API:

```html
<script>
window.chapters = [{"id":123,"title":"Chapter 1","url":"/fiction/..."},...]
</script>
```

Use `%b[]` (Lua's balanced-match) to grab the array:

```lua
local raw = html:match('window%.chapters%s*=%s*(%b[])')
```

`%b[]` tracks bracket depth, so nested brackets inside JSON strings are handled correctly. Decode with the `json_decode` helper from [4-http.md](4-http.md):

```lua
if raw then
    local data = json_decode(raw)
    for _, item in ipairs(data or {}) do
        -- item.id, item.title, item.url, etc.
    end
end
```

If you only need a count, scan the raw string instead of decoding:

```lua
local total = 0
if raw then
    for _ in raw:gmatch('"id"%s*:') do total = total + 1 end
end
```

## URL encoding for search

```lua
local function url_encode(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local url = BASE .. "/search?q=" .. url_encode(term)
```

Some sites accept `+` for spaces in query strings. Check what the site's own search form sends.
