# HTTP

Extensions make HTTP requests using KOReader's built-in socket libraries. Requests are synchronous — each one blocks until it finishes or times out before the next one runs.

## http_get

```lua
local function http_get(url)
    local https = require("ssl.https")
    local http  = require("socket.http")
    local ltn12 = require("ltn12")
    local sink  = {}
    local req   = url:match("^https") and https or http
    local ok, code = req.request {
        url     = url,
        sink    = ltn12.sink.table(sink),
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (Linux; Android 9; KOReader)",
            ["Accept"]     = "text/html,application/xhtml+xml,*/*;q=0.8",
        },
        timeout = 30,
    }
    if not ok or code ~= 200 then
        logger.err("http_get failed:", url, tostring(code))
        return nil, code
    end
    return table.concat(sink)
end
```

Returns the response body as a string on success. On failure returns `nil` and the HTTP status code (or an error string if the connection itself failed). Always check for `nil` before using the result.

Some sites need extra headers — a `Referer` pointing at the site's homepage is the most common. Add it to the `headers` table if you're getting unexpected responses or empty results. Some sites also check for a desktop `User-Agent`; swap the default one if needed.

## http_get_json

For endpoints that return JSON directly (search APIs, AJAX chapter lists, etc.):

```lua
local function http_get_json(url)
    local body, err = http_get(url)
    if not body then return nil, err end
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, body)
    if not ok then
        logger.err("JSON decode error:", tostring(data))
        return nil, "json_error"
    end
    return data
end
```

KOReader ships `rapidjson` on most devices but not all, so the fallback to the standard `json` library keeps things working everywhere.

## Decoding JSON extracted from HTML

`http_get_json` decodes an entire response as JSON. When you extract a JSON string from inside an HTML page (e.g. a `window.variable = [...]` assignment), use a standalone helper instead:

```lua
local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end
```

```lua
local raw = html:match('window%.chapters%s*=%s*(%b[])')
local data = raw and json_decode(raw)
if data then
    for _, item in ipairs(data) do
        -- item fields here
    end
end
```

See [3-html-parsing.md](3-html-parsing.md) for the `%b[]` balanced-match technique.

## Building URLs from paths

Paths you store and receive can be in different forms — a full URL, a root-relative path starting with `/`, or just the path segment. A small helper normalises all three:

```lua
local function to_url(path)
    if path:match("^https?://") then return path end
    if path:match("^/")        then return BASE .. path end
    return BASE .. "/" .. path
end
```

Use it anywhere you turn a stored path into a fetchable URL:

```lua
local html = http_get(to_url(path))
```

## Multiple requests

If you need content across multiple pages, loop sequentially:

```lua
for page = 2, total_pages do
    local html = http_get(base_url .. "?page=" .. page)
    if html then
        -- parse and append chapters
    end
end
```

Some novels need a separate request for their chapter list (e.g. a `/catalog` endpoint). Just make that request inside `parseNovel` after fetching the main page — two sequential requests is fine.

## Debugging

Use `logger.dbg` during development and `logger.err` for actual failures:

```lua
logger.dbg("MyExt: fetching url=", url)
local html = http_get(url)
logger.dbg("MyExt: got body_len=", html and #html or 0)
if not html then
    logger.err("MyExt: fetch failed for", url)
    return nil
end
```

KOReader writes these to its log file. `dbg` lines are filtered out in normal use.

## Cloudflare

Sites behind Cloudflare sometimes return a challenge page instead of real content. The response comes back with code 200 but the body contains the challenge HTML rather than the novel page.

Check for it before parsing:

```lua
local function is_cloudflare(html)
    return html:match("Just a moment") ~= nil
        or html:match("cf%-browser%-verification") ~= nil
        or html:match("Checking your browser") ~= nil
end

local html = http_get(url)
if not html then return nil end
if is_cloudflare(html) then
    logger.err("Cloudflare challenge at:", url)
    return "<p>This site is protected by Cloudflare and cannot be accessed from KOReader.</p>"
end
```

There is no way to solve a Cloudflare challenge from inside an extension. If a site is fully behind it, the extension will not work reliably.
