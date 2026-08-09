-- WebNovel extension for Mythos
-- Site: https://www.webnovel.com
--
-- Chapter list strategy:
--   Novel detail page has no chapter list. Chapters come from a separate
--   /catalog page — parseNovel makes two HTTP requests (novel + catalog).
--
-- Cloudflare note:
--   WebNovel is behind Cloudflare. Requests may return a challenge page
--   instead of real content. The extension checks for this and returns
--   empty/error results rather than silently passing junk through.
--
-- Locked chapters:
--   The catalog page shows a lock SVG inside locked chapter <li> items.
--   These are flagged with locked = true.

local BASE   = "https://www.webnovel.com"
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
        table.insert(results, { open = html:sub(s, e), inner = html:sub(e + 1, cs - 1) })
        pos = ce + 1
    end
    return results
end

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

-- ── HTTP helper ───────────────────────────────────────────────────────────────

local function http_get(url)
    logger.dbg("WebNovel: http_get", url)
    local https = require("ssl.https")
    local http  = require("socket.http")
    local ltn12 = require("ltn12")
    local sink  = {}
    local req   = url:match("^https") and https or http
    local ok, code = req.request {
        url     = url,
        sink    = ltn12.sink.table(sink),
        headers = {
            -- WN checks for a plausible desktop UA
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            ["Accept"]     = "text/html,application/xhtml+xml,*/*;q=0.8",
            ["Referer"]    = BASE,
        },
        timeout = 30,
    }
    if not ok or code ~= 200 then
        logger.err("WebNovel: http_get FAILED", url, tostring(code))
        return nil, code
    end
    local body = table.concat(sink)
    logger.dbg("WebNovel: http_get body_len=", #body)
    return body
end

local function is_cloudflare(html)
    return html:match("Just a moment") ~= nil
        or html:match("cf%-browser%-verification") ~= nil
        or html:match("Checking your browser") ~= nil
end

local function url_encode(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- ── Novel list parser ─────────────────────────────────────────────────────────

-- Category pages  (.j_category_wrapper li):  cover from data-original
-- Search pages    (.j_list_container li):    cover from src
-- Both use  a.g_thumb[href, title] > img[cover_attr]
local function parse_novel_list(html, is_search)
    local novels = {}
    local seen   = {}
    local cover_attr = is_search and "src" or "data%-original"

    for li_inner in html:gmatch('<li[^>]*>(.-)</li>') do
        -- The g_thumb anchor has both href and title
        local a_tag = li_inner:match('<a[^>]*class="[^"]*g_thumb[^"]*"[^>]*>')
        if not a_tag then
            -- fallback: any anchor linking into /book/
            a_tag = li_inner:match('<a[^>]*href="[^"]*/book/[^"]*"[^>]*>')
        end
        if a_tag then
            local href  = a_tag:match('href="([^"]+)"')
            local name  = a_tag:match('title="([^"]+)"')
            local img   = li_inner:match('<img[^>]*/?>') or ""
            local cover = img:match(cover_attr .. '="([^"]+)"')
            if cover and not cover:match("^https?:") then
                cover = "https:" .. cover
            end
            if href and name and not seen[href] then
                seen[href] = true
                local path = href:match("^/?(.+)") or href
                table.insert(novels, { name = name, path = path, cover = cover })
            end
        end
    end
    return novels
end

-- ── Catalog parser ────────────────────────────────────────────────────────────

-- Parses the /catalog page into a flat chapter list.
-- Volume containers (class="volume-item") hold a heading + <li> items.
-- Each <li> has:  a[href, title]  and optionally <svg> for lock icon.
local function parse_catalog(html)
    local chapters = {}
    local pos = 1

    while true do
        -- Find the next volume-item container
        local vol_start = html:find('class="[^"]*volume%-item[^"]*"', pos)
        if not vol_start then break end

        -- Slice up to the next volume-item (or end of html) as this volume's block
        local next_vol = html:find('class="[^"]*volume%-item[^"]*"', vol_start + 1)
        local vol_block = html:sub(vol_start, next_vol and next_vol - 1 or #html)

        -- Volume name from the first heading tag inside this block
        local vol_raw = vol_block:match('<h[1-6][^>]*>(.-)</h[1-6]>')
                     or vol_block:match('<p[^>]*class="[^"]*volume[^"]*"[^>]*>(.-)</p>')
        local vol_name
        if vol_raw then
            local num = strip_tags(vol_raw):match("[Vv]ol[ume%.]*%.?%s*(%d+)")
            vol_name = num and ("Volume " .. num) or strip_tags(vol_raw)
        end
        vol_name = (vol_name and vol_name ~= "") and vol_name or "Unknown Volume"

        -- Chapter <li> items
        for li_inner in vol_block:gmatch('<li[^>]*>(.-)</li>') do
            local href    = li_inner:match('href="([^"]+)"')
            local title   = li_inner:match('title="([^"]+)"')
                         or strip_tags(li_inner:match('<a[^>]*>(.-)</a>') or "")
            local is_locked = li_inner:match('<svg') ~= nil

            if href and href ~= "" then
                local ch_path = href:match("^/?(.+)") or href
                table.insert(chapters, {
                    name   = vol_name .. ": " .. strip_tags(title),
                    path   = ch_path,
                    locked = is_locked or nil,
                })
            end
        end

        pos = next_vol or (#html + 1)
    end

    return chapters
end

-- ── Shared novel metadata extractor ──────────────────────────────────────────

local function parse_meta(html)
    -- Title: try og:title first (most reliable), then g_thumb alt, then h1, then <title>
    local title = html:match('<meta[^>]*property="og:title"[^>]*content="([^"]+)"')
               or html:match('<meta[^>]*content="([^"]+)"[^>]*property="og:title"')
               or html:match('<img[^>]*class="[^"]*g_thumb[^"]*"[^>]*alt="([^"]+)"')
               or html:match('<img[^>]*alt="([^"]+)"[^>]*class="[^"]*g_thumb[^"]*"')
               or html:match('<h1[^>]*>([^<]+)</h1>')
               or html:match('<title>([^<|]+)')
               or ""
    title = strip_tags(title):match("^%s*(.-)%s*$")

    -- Cover: try data-src (lazy-load) before src, then og:image
    local cover = html:match('<img[^>]*class="[^"]*g_thumb[^"]*"[^>]*data%-src="([^"]+)"')
               or html:match('<img[^>]*data%-src="([^"]+)"[^>]*class="[^"]*g_thumb[^"]*"')
               or html:match('<img[^>]*class="[^"]*g_thumb[^"]*"[^>]*src="([^"]+)"')
               or html:match('<img[^>]*src="([^"]+)"[^>]*class="[^"]*g_thumb[^"]*"')
               or html:match('<meta[^>]*property="og:image"[^>]*content="([^"]+)"')
               or html:match('<meta[^>]*content="([^"]+)"[^>]*property="og:image"')
    if cover and not cover:match("^https?:") then
        cover = "https:" .. cover
    end

    -- Genres: a.det-hd-tag[title] holds the genre string
    local genres = html:match('<a[^>]*class="[^"]*det%-hd%-tag[^"]*"[^>]*title="([^"]+)"')
               or  html:match('<a[^>]*title="([^"]+)"[^>]*class="[^"]*det%-hd%-tag[^"]*"')
               or  ""

    -- Summary: div.j_synopsis > p (with <br> converted to newlines)
    local summary = ""
    local syn = extract_div(html, '<div[^>]*class="[^"]*j_synopsis[^"]*"')
    if syn then
        local p = syn:match('<p[^>]*>(.-)</p>')
        if p then
            p = p:gsub('<br[^>]*/?>%s*', '\n')
            summary = strip_tags(p):gsub('\n\n\n+', '\n\n'):match("^%s*(.-)%s*$")
        end
    end

    -- Author: "Author:" label followed by the name in the next element
    -- Typical pattern: <span class="c_s">Author:</span><a ...>Name</a>
    local author = html:match('[Aa]uthor:%s*</[^>]+>%s*<[^>]+>([^<]+)')
               or  html:match('[Aa]uthor:%s*<[^>]+>([^<]+)')
               or  ""
    author = strip_tags(author):match("^%s*(.-)%s*$")

    -- Status: SVG with title="Status" is followed by an element containing the text
    local status = "Unknown"
    local svg_pos = html:find('title="Status"')
    if svg_pos then
        local svg_end = html:find('</svg>', svg_pos)
        if svg_end then
            local status_text = html:sub(svg_end + 6):match('<[^>]+>([^<]+)')
            if status_text then
                local t = status_text:upper()
                if     t:match("ONGOING")   or t:match("ACTIVE")    then status = "Ongoing"
                elseif t:match("COMPLETED")                          then status = "Completed"
                elseif t:match("HIATUS")                             then status = "Hiatus"
                elseif t:match("CANCELLED") or t:match("CANCELED")  then status = "Cancelled"
                end
            end
        end
    end

    return {
        title   = title,
        cover   = cover,
        genres  = genres,
        summary = summary,
        author  = author,
        status  = status,
    }
end

-- ── URL builder ───────────────────────────────────────────────────────────────

local function to_url(path)
    if path:match("^https?://") then return path end
    if path:match("^/")        then return BASE .. path end
    return BASE .. "/" .. path
end

-- ── Extension table ───────────────────────────────────────────────────────────

local ext = {
    id      = "webnovel",
    name    = "WebNovel",
    site    = BASE,
    lang    = "en",
    version = "1.1.0",
}

function ext:popularNovels(page, options)
    page = page or 1
    local url  = BASE .. "/stories/novel?orderBy=1&pageIndex=" .. page
    local html = http_get(url)
    if not html or is_cloudflare(html) then
        logger.err("WebNovel: popularNovels blocked or failed")
        return { novels = {} }
    end
    local novels = parse_novel_list(html, false)
    logger.dbg("WebNovel: popularNovels found", #novels)
    return { novels = novels }
end

function ext:searchNovels(term, page)
    page = page or 1
    local url  = BASE .. "/search?keywords=" .. url_encode(term) .. "&pageIndex=" .. page
    local html = http_get(url)
    if not html or is_cloudflare(html) then
        logger.err("WebNovel: searchNovels blocked or failed")
        return { novels = {} }
    end
    local novels = parse_novel_list(html, true)
    logger.dbg("WebNovel: searchNovels found", #novels)
    return { novels = novels }
end

-- parseNovelMeta: fast cache check using just the novel main page.
-- Chapter count may be embedded in the page JSON — returns 0 if not found,
-- which causes Mythos to fall back to parseNovel.
function ext:parseNovelMeta(path)
    local html = http_get(to_url(path))
    if not html or is_cloudflare(html) then return nil end

    local meta  = parse_meta(html)
    local total = tonumber(html:match('"chapterNum"%s*:%s*"?(%d+)"?'))
               or tonumber(html:match('"totalNum"%s*:%s*(%d+)'))
               or 0

    logger.dbg("WebNovel: parseNovelMeta title=", meta.title, "total=", total)
    return {
        name           = meta.title,
        path           = path,
        cover          = meta.cover,
        summary        = meta.summary,
        author         = meta.author,
        status         = meta.status,
        total_chapters = total,
    }
end

function ext:parseNovel(path)
    logger.dbg("WebNovel: parseNovel", path)
    local html = http_get(to_url(path))
    if not html or is_cloudflare(html) then
        logger.err("WebNovel: parseNovel blocked or failed for", path)
        return nil
    end

    local meta = parse_meta(html)

    -- Chapter list from separate /catalog page
    local cat_path = path:match("^(.-)/?$") or path
    local cat_url  = to_url(cat_path) .. "/catalog"
    logger.dbg("WebNovel: fetching catalog", cat_url)
    local cat_html = http_get(cat_url)

    local chapters = {}
    if cat_html and not is_cloudflare(cat_html) then
        chapters = parse_catalog(cat_html)
        logger.dbg("WebNovel: catalog chapters=", #chapters)
    else
        logger.warn("WebNovel: catalog fetch failed for", cat_url)
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
    local html = http_get(to_url(path))
    if not html then return "<p>Error fetching chapter.</p>" end
    if is_cloudflare(html) then
        return "<p>This page is protected by Cloudflare and cannot be accessed from KOReader.</p>"
    end

    -- Extract the chapter body, then strip inline comment annotations
    local title_html = extract_div(html, '<div[^>]*class="[^"]*cha%-tit[^"]*"') or ""
    local body_html  = extract_div(html, '<div[^>]*class="[^"]*cha%-words[^"]*"') or ""

    -- Remove .para-comment spans (inline annotations WN adds to chapter text)
    body_html = body_html:gsub('<span[^>]*class="[^"]*para%-comment[^"]*"[^>]*>([^<]*)</span>', '')
    body_html = body_html:gsub('<div[^>]*class="[^"]*para%-comment[^"]*"[^>]*>([^<]*)</div>', '')

    if title_html == "" and body_html == "" then
        return "<p>Could not extract chapter content.</p>"
    end

    return title_html .. "\n" .. body_html
end

return ext
