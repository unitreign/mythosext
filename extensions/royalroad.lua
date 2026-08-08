-- Royal Road extension for Mythos
-- Site: https://www.royalroad.com
--
-- Chapter list strategy:
--   The novel page embeds all chapters as  window.chapters = [...]  in an
--   inline <script> tag.  One page fetch gets everything — no pagination.
--
-- Anti-scraping note:
--   RR injects hidden <span> elements with a random CSS class name into chapter
--   text.  They contain junk words and are hidden via  display:none  in a
--   <style> block.  We detect the class name from that style rule and strip
--   matching elements before returning the content.

local BASE   = "https://www.royalroad.com"
local logger = require("logger")

-- ── HTML helpers ──────────────────────────────────────────────────────────────

local function attr(tag_html, name)
    return tag_html:match(name .. '="([^"]*)"')
        or tag_html:match(name .. "='([^']*)'")
end

local function strip_tags(s)
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&amp;",  "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
        :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
    return s:match("^%s*(.-)%s*$")
end

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

-- Balanced-div extractor.  Returns inner content and the position immediately
-- after the closing </div>, so callers can continue scanning past it.
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

-- ── HTTP helpers ──────────────────────────────────────────────────────────────

local function http_get(url)
    logger.dbg("RoyalRoad: http_get", url)
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
        logger.err("RoyalRoad: http_get FAILED", url, tostring(code))
        return nil, code
    end
    local body = table.concat(sink)
    logger.dbg("RoyalRoad: http_get body_len=", #body)
    return body
end

local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

local function url_encode(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- ── Novel list parser (popular + search share the same card layout) ───────────

-- Novel cards on browse/search pages live inside <figure> tags:
--   <figure>
--     <a href="/fiction/ID/slug">
--       <img alt="Novel Title" src="cover_url" class="thumbnail ...">
--     </a>
--   </figure>
local function parse_novel_list(html)
    local novels = {}
    local seen   = {}
    for fig_inner in html:gmatch('<figure[^>]*>(.-)</figure>') do
        -- Only grab figures that link to a fiction (numeric ID in path)
        local href = fig_inner:match('<a[^>]*href="(/fiction/%d+/[^"]+)"')
        if href then
            local path = href:match("^/(.+)") or href
            if not seen[path] then
                seen[path] = true
                local img   = fig_inner:match('<img[^>]*/?>') or ""
                local name  = img:match('alt="([^"]*)"') or ""
                local cover = img:match('src="([^"]*)"')
                if name ~= "" then
                    table.insert(novels, { name = name, path = path, cover = cover })
                end
            end
        end
    end
    return novels
end

-- ── Shared metadata extractor ─────────────────────────────────────────────────

-- Extracts title, author, cover, status, summary and genres from a novel page.
-- Used by both parseNovelMeta and parseNovel to avoid duplication.
local function parse_meta(html)
    local title  = strip_tags(html:match('<h1[^>]*>(.-)</h1>') or "")
    local author = strip_tags(html:match('<a[^>]*href="/profile/[^"]*"[^>]*>(.-)</a>') or "")

    -- Cover: img with class "thumbnail"
    local cover = html:match('<img[^>]*class="[^"]*thumbnail[^"]*"[^>]*src="([^"]+)"')
               or html:match('<img[^>]*src="([^"]+)"[^>]*class="[^"]*thumbnail[^"]*"')

    -- Status: RR shows two label-sm spans; the second is the novel status.
    -- e.g. <span class="label-sm label-default">ORIGINAL</span>
    --      <span class="label-sm label-warning">ONGOING</span>
    local status  = "Unknown"
    local label_n = 0
    for inner in html:gmatch('<span[^>]*class="[^"]*label%-sm[^"]*"[^>]*>(.-)</span>') do
        label_n = label_n + 1
        if label_n == 2 then
            local t = strip_tags(inner):upper()
            if     t == "ONGOING"   then status = "Ongoing"
            elseif t == "HIATUS"    then status = "Hiatus"
            elseif t == "COMPLETED" then status = "Completed"
            elseif t == "DROPPED"   then status = "Cancelled"
            end
            break
        end
    end

    -- Summary: div.description contains HTML with <p>, <br>, <hr>
    local summary = ""
    local desc = extract_div(html, '<div[^>]*class="[^"]*description[^"]*"')
    if desc then
        desc = desc:gsub('<br[^>]*/?>',   '\n')
               :gsub('<hr[^>]*/?>',       '\n---\n')
               :gsub('</p>',              '\n\n')
        summary = strip_tags(desc):gsub('\n\n\n+', '\n\n'):match("^%s*(.-)%s*$")
    end

    -- Genres/tags: <span class="tags"><a href="/tag/...">Tag</a> ...</span>
    local genres = {}
    local tags_s = html:find('<span[^>]*class="[^"]*tags[^"]*"')
    if tags_s then
        local tags_e = html:find('</span>', tags_s)
        if tags_e then
            for a_inner in html:sub(tags_s, tags_e):gmatch('<a[^>]*>(.-)</a>') do
                local t = strip_tags(a_inner)
                if t ~= "" then table.insert(genres, t) end
            end
        end
    end

    return {
        title   = title,
        author  = author,
        cover   = cover,
        status  = status,
        summary = summary,
        genres  = table.concat(genres, ", "),
    }
end

-- ── Chapter path helper ───────────────────────────────────────────────────────

-- Converts a full chapter URL from window.chapters into a routable path.
-- Input:  /fiction/12345/novel-slug/chapter/67890/chapter-slug
-- Output: fiction/12345/chapter/67890
-- RR routes by numeric ID; the slugs are only for SEO and can be dropped.
local function chapter_url_to_path(url)
    local parts = {}
    for p in url:gmatch("[^/]+") do table.insert(parts, p) end
    -- [1]=fiction [2]=novelID [3]=novel-slug [4]=chapter [5]=chapterID
    if parts[1] and parts[2] and parts[4] and parts[5] then
        return parts[1] .. "/" .. parts[2] .. "/" .. parts[4] .. "/" .. parts[5]
    end
    return url:match("^/(.+)") or url
end

-- ── Extension table ───────────────────────────────────────────────────────────

local ext = {
    id      = "royalroad",
    name    = "Royal Road",
    site    = BASE,
    lang    = "en",
    version = "1.0.0",
}

function ext:popularNovels(page, options)
    page = page or 1
    local url = BASE .. "/fictions/search?page=" .. page .. "&orderBy=popularity"
    logger.dbg("RoyalRoad: popularNovels page=", page)
    local html = http_get(url)
    if not html then return { novels = {} } end
    local novels = parse_novel_list(html)
    logger.dbg("RoyalRoad: popularNovels found", #novels)
    return { novels = novels }
end

function ext:searchNovels(term, page)
    page = page or 1
    local url = BASE .. "/fictions/search?page=" .. page
        .. "&title=" .. url_encode(term) .. "&globalFilters=true"
    logger.dbg("RoyalRoad: searchNovels term=", term)
    local html = http_get(url)
    if not html then return { novels = {} } end
    local novels = parse_novel_list(html)
    logger.dbg("RoyalRoad: searchNovels found", #novels)
    return { novels = novels }
end

-- parseNovelMeta: fast path for chapter cache.
-- Fetches the novel page once and counts chapters from window.chapters
-- without doing a full JSON decode — just counts "id": occurrences.
function ext:parseNovelMeta(path)
    local url = (path:match("^https?://") and path) or (BASE .. "/" .. path)
    local html = http_get(url)
    if not html then return nil end

    local meta = parse_meta(html)

    local total_chapters = 0
    local raw = html:match('window%.chapters%s*=%s*(%b[])')
    if raw then
        for _ in raw:gmatch('"id"%s*:') do
            total_chapters = total_chapters + 1
        end
    end

    logger.dbg("RoyalRoad: parseNovelMeta title=", meta.title, "total_chapters=", total_chapters)
    return {
        name           = meta.title,
        path           = path,
        cover          = meta.cover,
        summary        = meta.summary,
        author         = meta.author,
        status         = meta.status,
        total_chapters = total_chapters,
    }
end

function ext:parseNovel(path)
    local url = (path:match("^https?://") and path) or (BASE .. "/" .. path)
    logger.dbg("RoyalRoad: parseNovel", url)
    local html = http_get(url)
    if not html then
        logger.err("RoyalRoad: parseNovel fetch failed", url)
        return nil
    end

    local meta = parse_meta(html)

    -- Chapter list from embedded window.chapters JSON
    local chapters = {}
    local raw = html:match('window%.chapters%s*=%s*(%b[])')
    if raw then
        local data = json_decode(raw)
        if data then
            for _, ch in ipairs(data) do
                if ch.url then
                    table.insert(chapters, {
                        name           = ch.title or ("Chapter " .. tostring(ch.order or #chapters + 1)),
                        path           = chapter_url_to_path(ch.url),
                        chapter_number = ch.order,
                    })
                end
            end
            logger.dbg("RoyalRoad: parseNovel chapters=", #chapters)
        else
            logger.warn("RoyalRoad: parseNovel could not decode window.chapters")
        end
    else
        logger.warn("RoyalRoad: parseNovel window.chapters not found in page")
    end

    return {
        name       = meta.title,
        path       = path,
        cover      = meta.cover,
        summary    = meta.summary,
        author     = meta.author,
        genres     = meta.genres,
        status     = meta.status,
        chapters   = chapters,
        totalPages = 1,
    }
end

function ext:parseChapter(path)
    local url = (path:match("^https?://") and path) or (BASE .. "/" .. path)
    local html = http_get(url)
    if not html then return "<p>Error fetching chapter.</p>" end

    -- Detect RR's hidden-text class from the inline style block.
    -- RR adds  .randomClassName { display: none; }  and injects spans with that
    -- class into the chapter text to break naive scrapers.
    local hidden_class = html:match('<style>%s*%.([%w_%-]+)%s*{[^}]-display%s*:%s*none')
    if hidden_class then
        logger.dbg("RoyalRoad: hidden class detected:", hidden_class)
    end

    -- Collect positions of all author-note-portlet divs
    local portlet_positions = {}
    do
        local p = 1
        while true do
            local s = html:find('<div[^>]*class="[^"]*author%-note%-portlet[^"]*"', p)
            if not s then break end
            table.insert(portlet_positions, s)
            p = s + 1
        end
    end

    local content_pos = html:find('<div[^>]*class="[^"]*chapter%-content[^"]*"')

    local out = {}

    -- Author note(s) before chapter content
    for _, pp in ipairs(portlet_positions) do
        if content_pos and pp < content_pos then
            local note = extract_div(html, '<div[^>]*class="[^"]*author%-note%-portlet[^"]*"', pp)
            if note then
                table.insert(out, '<div class="author-note">' .. note .. '</div>')
                table.insert(out, '<hr>')
            end
        end
    end

    -- Chapter body
    local content, content_end = extract_div(html, '<div[^>]*class="[^"]*chapter%-content[^"]*"')
    if not content then
        return "<p>Could not extract chapter content.</p>"
    end

    -- Strip hidden spam elements by their class
    if hidden_class then
        local esc = hidden_class:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1')
        content = content:gsub('<[^>]*class="[^"]*' .. esc .. '[^"]*"[^>]*>(.-)</', '</')
    end

    table.insert(out, content)

    -- Author note(s) after chapter content
    for _, pp in ipairs(portlet_positions) do
        if content_end and pp >= content_end then
            local note = extract_div(html, '<div[^>]*class="[^"]*author%-note%-portlet[^"]*"', pp)
            if note then
                table.insert(out, '<hr>')
                table.insert(out, '<div class="author-note">' .. note .. '</div>')
            end
            break  -- only the first after-note
        end
    end

    return table.concat(out, '\n')
end

return ext
