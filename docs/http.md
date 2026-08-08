# HTTP

Extensions make requests using KOReader's built-in socket libraries. Everything is synchronous — there's no async/await. A request blocks until it finishes or times out.

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

Returns the response body as a string on success. On failure it returns `nil` and the HTTP status code (or an error string if the request itself failed). Always check for `nil` before using the result.

Some sites need extra headers to return proper responses — a `Referer` header pointing at the site's homepage is the most common one. Add it to the `headers` table if you're getting unexpected responses or empty results.

## http_get_json

For endpoints that return JSON (AJAX chapter lists, search APIs, etc.):

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

KOReader ships `rapidjson` on most devices but not all, so the fallback to the standard `json` library keeps things working everywhere. Returns the decoded Lua table on success, or `nil` on failure.

## Multiple requests

There's no parallel fetching. If you need chapters across multiple pages, loop sequentially:

```lua
for page = 2, total_pages do
    local html = http_get(base_url .. "?page=" .. page)
    if html then
        -- parse and append
    end
end
```

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

KOReader writes these to its log file. Dbg lines are filtered out in normal use.

## Cloudflare

Sites protected by Cloudflare will sometimes return a challenge page instead of real content. The request may come back with code 200, but the body will contain the challenge HTML rather than the novel.

Check for it before you try to parse anything:

```lua
local html = http_get(url)
if not html then return nil end

if html:match("Just a moment") or html:match("cf%-browser%-verification") then
    logger.err("Cloudflare challenge at:", url)
    return "<p>This site is protected by Cloudflare and cannot be accessed from KOReader.</p>"
end
```

There's no way to solve a Cloudflare challenge from inside an extension. If a site is fully behind it, the extension won't work reliably.
