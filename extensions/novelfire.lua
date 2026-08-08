-- NovelFire extension for Mythos
-- Site: https://novelfire.net
-- Chapter list strategy (from reverse-engineering the site's JS):
--   1. Fetch {novelUrl}/chapters page
--   2. Scan inline <script> tags for "/listChapterDataAjax"
--   3. Build the DataTables AJAX URL and fetch JSON → all chapters at once
--   4. Fallback: parse paginated HTML chapter list (used in Page Mode)
-- Page Mode (extension-specific toggle):
--   OFF (default) – fetch all chapters via AJAX in one call
--   ON            – use HTML pagination; parsePage() fetches each page lazily

local BASE   = "https://novelfire.net"
local logger = require("logger")

-- ── HTML pattern helpers ──────────────────────────────────────────────────────

local function attr(tag_html, name)
    return tag_html:match(name .. '="([^"]*)"')
        or tag_html:match(name .. "='([^']*)'")
end

local function strip_tags(s)
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&amp;",  "&")
        :gsub("&lt;",   "<")
        :gsub("&gt;",   ">")
        :gsub("&quot;", '"')
        :gsub("&#39;",  "'")
        :gsub("&nbsp;", " ")
    return s:match("^%s*(.-)%s*$")
end

-- Find all occurrences of a tag (shallow — does not handle nesting)
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
        table.insert(results, {open = html:sub(s, e), inner = inner})
        pos = ce + 1
    end
    return results
end

local function first_match(html, pat)
    return html:match(pat)
end

-- ── Chapter list parsers ──────────────────────────────────────────────────────

-- Parse <ul class="chapter-list"> from LightNovelWorld-style HTML
-- Returns list of {name, path}
local function parse_chapter_list_html(html, novel_root)
    local chapters = {}
    -- Find all <a> inside ul.chapter-list
    local ul = html:match('<ul[^>]*class="[^"]*chapter%-list[^"]*"[^>]*>(.-)</ul>')
    if not ul then return chapters end
    for a_tag, inner in ul:gmatch('(<a[^>]+>)(.-)</a>') do
        local href = attr(a_tag, "href") or ""
        local path = href:match("^https?://[^/]+(/.+)$") or href
        local title_el = inner:match('<[^>]*class="[^"]*chapter%-title[^"]*"[^>]*>(.-)</')
        local no_el    = inner:match('<[^>]*class="[^"]*chapter%-no[^"]*"[^>]*>(.-)</')
        local title = ""
        if no_el and no_el ~= "" then
            title = strip_tags(no_el) .. ": " .. strip_tags(title_el or "")
        else
            title = strip_tags(title_el or inner)
        end
        if path ~= "" then
            table.insert(chapters, { name = title, path = path })
        end
    end
    return chapters
end

-- Count total HTML pages from pagination bar
local function parse_total_pages(html)
    local max = 1
    for href in html:gmatch('<[^>]*class="[^"]*pagination[^"]*".->(.-)</ul>') do
        for page_num in href:gmatch('[?&]page=(%d+)') do
            local n = tonumber(page_num) or 1
            if n > max then max = n end
        end
    end
    -- Also try simpler pattern in case pagination ul is absent
    for page_num in html:gmatch('[?&]page=(%d+)') do
        local n = tonumber(page_num) or 1
        if n > max then max = n end
    end
    return max
end

-- Build the DataTables AJAX URL from script tag content (NovelFire-specific)
local function build_ajax_url(chapters_html, base_url)
    local prefix = "/listChapterDataAjax"
    for script_content in chapters_html:gmatch('<script[^>]*>(.-)</script>') do
        local start_idx = script_content:find(prefix, 1, true)
        if start_idx then
            -- Extract from prefix up to the next `",` (end of the URL fragment)
            local frag_end = script_content:find('",', start_idx, true)
            if not frag_end then frag_end = script_content:find("'", start_idx + 1, true) end
            if frag_end then
                local frag = script_content:sub(start_idx, frag_end - 1)
                local host = base_url:match("^https?://([^/]+)")
                if host then
                    -- Append DataTables parameters to fetch all chapters sorted by n_sort
                    local params = table.concat({
                        "draw=1",
                        "columns%5B0%5D%5Bdata%5D=title",
                        "columns%5B0%5D%5Bsearchable%5D=true",
                        "columns%5B0%5D%5Borderable%5D=false",
                        "columns%5B1%5D%5Bdata%5D=created_at",
                        "columns%5B1%5D%5Bsearchable%5D=true",
                        "columns%5B1%5D%5Borderable%5D=true",
                        "columns%5B2%5D%5Bdata%5D=n_sort",
                        "columns%5B2%5D%5Borderable%5D=true",
                        "order%5B0%5D%5Bcolumn%5D=2",
                        "order%5B0%5D%5Bdir%5D=asc",
                        "start=0",
                        "length=-1",
                        "search%5Bvalue%5D=",
                        "search%5Bregex%5D=false",
                    }, "&")
                    return "https://" .. host .. frag .. "&" .. params
                end
            end
        end
    end
    return nil
end

-- ── Balanced-div extractor (handles nested divs correctly) ───────────────────
-- Finds the first div matching open_pattern and returns its full inner content.
local function extract_div(html, open_pattern)
    local s, e = html:find(open_pattern)
    if not s then return nil end
    local tag_end = html:find('>', e)
    if not tag_end then return nil end
    local depth = 1
    local pos   = tag_end + 1
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
                return html:sub(tag_end + 1, close_pos - 1)
            end
            pos = close_pos + 6
        end
    end
    return nil
end

-- ── HTTP helper ───────────────────────────────────────────────────────────────

local function http_get(url)
    logger.dbg("NovelFire: http_get url=", url)
    local https = require("ssl.https")
    local http  = require("socket.http")
    local ltn12 = require("ltn12")
    local sink  = {}
    local req   = url:match("^https") and https or http
    local ok, code = req.request {
        url     = url,
        sink    = ltn12.sink.table(sink),
        headers = {
            ["User-Agent"]    = "Mozilla/5.0 (Linux; Android 9; KOReader)",
            ["Accept"]        = "text/html,application/xhtml+xml,*/*;q=0.8",
            ["Referer"]       = BASE .. "/",
        },
        timeout = 30,
    }
    logger.dbg("NovelFire: http_get code=", tostring(code), "ok=", tostring(ok))
    if not ok or code ~= 200 then
        logger.err("NovelFire: http_get FAILED url=", url, "code=", tostring(code))
        return nil, code
    end
    local body = table.concat(sink)
    logger.dbg("NovelFire: http_get body_len=", #body)
    return body
end

local function http_get_json(url)
    logger.dbg("NovelFire: http_get_json url=", url)
    local body, err = http_get(url)
    if not body then
        logger.err("NovelFire: http_get_json fetch failed:", tostring(err))
        return nil, err
    end
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok2, data = pcall(JSON.decode, body)
    if not ok2 then
        logger.err("NovelFire: JSON decode error:", tostring(data))
        return nil, "json_error"
    end
    logger.dbg("NovelFire: http_get_json decode ok, type=", type(data))
    return data
end

-- ── Extension table ───────────────────────────────────────────────────────────

local ext = {
    id              = "novelfire",
    name            = "NovelFire",
    site            = BASE,
    lang            = "en",
    version         = "1.0.0",
    supports_page_mode = true,  -- signals UI to show the Page Mode toggle
}

-- popularNovels(page, options) → {novels=[{name,path,cover}]}
-- Uses /ranking — novel cards are <li class="novel-item">
function ext:popularNovels(page, options)
    page = page or 1
    local url = BASE .. "/ranking?page=" .. page
    logger.dbg("NovelFire: popularNovels page=", page, "url=", url)
    local html, err = http_get(url)
    if not html then
        logger.err("NovelFire: popularNovels fetch failed:", tostring(err))
        return {novels = {}}
    end
    logger.dbg("NovelFire: popularNovels html_len=", #html)

    local novels = {}
    for li_open, li_inner in html:gmatch('(<li[^>]*class="[^"]*novel%-item[^"]*"[^>]*>)(.-)</li>') do
        -- href may be on the wrapping <a> or on a nested <a>
        local a_href = li_inner:match('<a[^>]*href="(/book/[^"]+)"')
            or li_inner:match('<a[^>]*href="([^"]+)"')
        -- title: <h2 class="title ..."> or <h4 class="novel-title ...">
        local title = strip_tags(
            li_inner:match('<h%d[^>]*class="[^"]*title[^"]*"[^>]*>(.-)</h%d>') or "")
        local cover = li_inner:match('<img[^>]*data%-src="([^"]+)"')
            or li_inner:match('<img[^>]*src="([^"]+)"')
        if a_href and title ~= "" then
            local path = a_href:match("^https?://[^/]+(/.+)$") or a_href
            table.insert(novels, { name = title, path = path, cover = cover })
        end
    end
    logger.dbg("NovelFire: popularNovels found", #novels, "novels")
    if #novels == 0 then
        logger.warn("NovelFire: popularNovels got 0 results. HTML snippet (first 500):", html:sub(1, 500))
    end
    return { novels = novels }
end

-- searchNovels(term, page) → {novels=[{name,path,cover}]}
function ext:searchNovels(term, page)
    page = page or 1
    local encoded = term:gsub(" ", "+"):gsub("([^%w%+%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end)
    local url  = BASE .. "/search?keyword=" .. encoded .. "&page=" .. page
    logger.dbg("NovelFire: searchNovels term=", term, "url=", url)
    local html = http_get(url)
    if not html then
        logger.err("NovelFire: searchNovels fetch failed")
        return {novels = {}}
    end
    logger.dbg("NovelFire: searchNovels html_len=", #html)

    -- Search page: <li class="novel-item"><a href="/book/...">...<h4 class="novel-title ...">
    local novels = {}
    for li_open, li_inner in html:gmatch('(<li[^>]*class="[^"]*novel%-item[^"]*"[^>]*>)(.-)</li>') do
        local a_href = li_inner:match('<a[^>]*href="(/book/[^"]+)"')
            or li_inner:match('<a[^>]*href="([^"]+)"')
        local title = strip_tags(
            li_inner:match('<h%d[^>]*class="[^"]*title[^"]*"[^>]*>(.-)</h%d>') or "")
        local cover = li_inner:match('<img[^>]*src="([^"]+)"')
            or li_inner:match('<img[^>]*data%-src="([^"]+)"')
        if a_href and title ~= "" then
            local path = a_href:match("^https?://[^/]+(/.+)$") or a_href
            table.insert(novels, { name = title, path = path, cover = cover })
        end
    end
    logger.dbg("NovelFire: searchNovels found", #novels, "novels")
    if #novels == 0 then
        logger.warn("NovelFire: searchNovels got 0 results. HTML snippet (first 500):", html:sub(1, 500))
    end
    return { novels = novels }
end

-- parseNovelMeta(path) → {name,path,cover,summary,author,status,total_chapters}
-- Fast path used by Mythos for chapter cache: fetches only the main novel page,
-- does NOT fetch the /chapters page. Returns total_chapters = 0 if the main page
-- doesn't expose a chapter count; Mythos will fall back to parseNovel in that case.
function ext:parseNovelMeta(path)
    local novel_url = (path:match("^https?://") and path) or (BASE .. path)
    local html = http_get(novel_url)
    if not html then return nil end
    logger.dbg("NovelFire: parseNovelMeta html_len=", #html)

    local title = strip_tags(html:match('<h1[^>]*itemprop="name"[^>]*>(.-)</h1>')
        or html:match('<h1[^>]*>(.-)</h1>') or "")

    local author = strip_tags(html:match('<span[^>]*itemprop="author"[^>]*>(.-)</span>') or "")

    local status = "Ongoing"
    local st_class = html:match('<strong class="([%a]+)">[^<]*</strong>[^<]*<small>[^<]*[Ss]tatus')
    if st_class then
        status = st_class:sub(1,1):upper() .. st_class:sub(2)
    end

    local cover = html:match('<meta[^>]*property="og:image"[^>]*content="([^"]+)"')
        or html:match('<figure[^>]*class="[^"]*cover[^"]*"[^>]*>%s*<img[^>]*src="([^"]+)"')

    local summary = ""
    local sum_pos = html:find('<div[^>]*class="[^"]*summary[^"]*"')
    if sum_pos then
        local p = html:sub(sum_pos):match('<p>(.-)</p>')
        summary = p and strip_tags(p) or ""
    end

    -- Try to read chapter count from header-stats on the main page.
    -- Avoids fetching /chapters; returns 0 if no match (triggers full parseNovel).
    local total_chapters = 0
    local stats_block = html:match('<[^>]*class="[^"]*header%-stats[^"]*"[^>]*>(.-)</div>')
    if stats_block then
        -- Pattern: <strong>2010</strong><small>Chapters</small>
        local s = stats_block:match('<strong>([%d,]+)</strong>%s*<small>[^<]*[Cc]hapter')
        -- Fallback: icon-book-open adjacent to number
        if not s then
            s = stats_block:match('icon%-book%-open[^<]*</i>%s*([%d,]+)')
        end
        if s then total_chapters = tonumber(s:gsub(",", "")) or 0 end
    end
    logger.dbg("NovelFire: parseNovelMeta title=", title, "total_chapters=", total_chapters)

    return {
        name           = title,
        path           = path,
        cover          = cover,
        summary        = summary,
        author         = author,
        status         = status,
        total_chapters = total_chapters,
    }
end

-- parseNovel(path) → {name,path,cover,summary,author,genres,status,chapters,totalPages}
function ext:parseNovel(path)
    local novel_url    = (path:match("^https?://") and path) or (BASE .. path)
    local chapters_url = novel_url:gsub("/?$", "/chapters")

    local main_html = http_get(novel_url)
    if not main_html then
        logger.err("NovelFire: parseNovel fetch failed for", novel_url)
        return nil
    end
    logger.dbg("NovelFire: parseNovel html_len=", #main_html)

    -- Title: <h1 itemprop="name" class="novel-title ...">
    local title = strip_tags(main_html:match('<h1[^>]*itemprop="name"[^>]*>(.-)</h1>')
        or main_html:match('<h1[^>]*>(.-)</h1>') or "")

    -- Author: <span itemprop="author">Name</span>
    local author = strip_tags(main_html:match('<span[^>]*itemprop="author"[^>]*>(.-)</span>') or "")

    -- Status: <strong class="completed">Completed</strong> <small>Status</small>
    local status = "Ongoing"
    local st_class = main_html:match('<strong class="([%a]+)">[^<]*</strong>[^<]*<small>[^<]*[Ss]tatus')
    if st_class then
        status = st_class:sub(1,1):upper() .. st_class:sub(2)
    end
    logger.dbg("NovelFire: parseNovel title=", title, "author=", author, "status=", status)

    -- Summary: first <p> inside <div class="summary">
    local summary = ""
    local sum_pos = main_html:find('<div[^>]*class="[^"]*summary[^"]*"')
    if sum_pos then
        local p = main_html:sub(sum_pos):match('<p>(.-)</p>')
        summary = p and strip_tags(p) or ""
    end

    -- Cover
    local cover = main_html:match('<meta[^>]*property="og:image"[^>]*content="([^"]+)"')
        or main_html:match('<figure[^>]*class="[^"]*cover[^"]*"[^>]*>%s*<img[^>]*src="([^"]+)"')

    -- Fetch /chapters (page 1)
    local chapters_html = http_get(chapters_url)
    if not chapters_html then
        logger.warn("NovelFire: parseNovel no chapters page for", chapters_url)
        return { name=title, path=path, cover=cover, author=author, status=status,
                 summary=summary, chapters={}, totalPages=1 }
    end
    logger.dbg("NovelFire: parseNovel chapters html_len=", #chapters_html)

    local chapters = {}

    -- Try AJAX first (some novels expose the DataTables endpoint)
    local ajax_url = build_ajax_url(chapters_html, chapters_url)
    if ajax_url then
        logger.dbg("NovelFire: parseNovel AJAX url=", ajax_url)
        local json = http_get_json(ajax_url)
        if json and json.data then
            local root = novel_url:gsub("/?$", "")
            for _, d in ipairs(json.data) do
                table.insert(chapters, {
                    name = d.title or ("Chapter " .. tostring(d.n_sort)),
                    path = root .. "/chapter-" .. tostring(d.n_sort),
                })
            end
            logger.dbg("NovelFire: parseNovel AJAX chapters=", #chapters)
        end
    end

    -- HTML pagination fallback: 100 chapters/page, total from input max attr
    if #chapters == 0 then
        -- Find total chapter count: <input id="gotochapno" ... max="130">
        local max_ch = tonumber(
            chapters_html:match('<input[^>]*id="gotochapno"[^>]*max="(%d+)"') or
            chapters_html:match('<input[^>]*max="(%d+)"[^>]*id="gotochapno"') or
            chapters_html:match('<input[^>]*max="(%d+)"[^>]*name="chapno"') or
            chapters_html:match('<input[^>]*name="chapno"[^>]*max="(%d+)"') or "0") or 0
        local total_pages = max_ch > 0 and math.ceil(max_ch / 100) or 1
        logger.dbg("NovelFire: parseNovel max_ch=", max_ch, "total_pages=", total_pages)

        chapters = parse_chapter_list_html(chapters_html, novel_url)
        logger.dbg("NovelFire: parseNovel page 1 chapters=", #chapters)

        for pg = 2, total_pages do
            logger.dbg("NovelFire: parseNovel fetching chapter page", pg)
            local pg_html = http_get(chapters_url .. "?page=" .. pg)
            if pg_html then
                local more = parse_chapter_list_html(pg_html, novel_url)
                logger.dbg("NovelFire: parseNovel page", pg, "chapters=", #more)
                for _, ch in ipairs(more) do table.insert(chapters, ch) end
            end
        end
        logger.dbg("NovelFire: parseNovel total chapters=", #chapters)
    end

    return {
        name       = title,
        path       = path,
        cover      = cover,
        summary    = summary,
        author     = author,
        status     = status,
        chapters   = chapters,
        totalPages = 1,
    }
end

-- parsePage(path, page) → {chapters=[{name,path}]}
-- Called by the UI when Page Mode is ON and the user requests additional pages.
function ext:parsePage(path, page)
    local novel_url    = (path:match("^https?://") and path) or (BASE .. path)
    local chapters_url = novel_url:gsub("/?$", "/chapters") .. "?page=" .. tostring(page)
    local html = http_get(chapters_url)
    if not html then return { chapters = {} } end
    local chapters = parse_chapter_list_html(html, novel_url)
    return { chapters = chapters }
end

-- parseChapter(path) → HTML string of chapter body
function ext:parseChapter(path)
    local url  = (path:match("^https?://") and path) or (BASE .. path)
    local html = http_get(url)
    if not html then return "<p>Error fetching chapter.</p>" end

    -- Extract chapter content using the balanced-div extractor so nested divs are handled.
    local content = extract_div(html, '<div[^>]*id="chapter%-content"')
        or extract_div(html, '<div[^>]*class="[^"]*chapter%-content[^"]*"')
        or extract_div(html, '<div[^>]*id="content"')

    if not content then return "<p>Could not extract chapter content.</p>" end

    -- Remove watermarks (elements with any class attribute, as per LightNovelWorldParser)
    content = content:gsub('<p[^>]*class="[^"]*"[^>]*>.-</p>', "")
    -- Remove nested strong watermarks
    content = content:gsub('<strong><strong>.-</strong></strong>', "")
    -- Collapse whitespace
    content = content:gsub("%s*\n%s*\n%s*", "\n\n")

    return content
end

return ext
