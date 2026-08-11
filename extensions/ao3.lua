-- Archive of Our Own (AO3) extension for Mythos
-- Site: https://archiveofourown.org
--
-- Age gate:
--   Mature/Explicit works show an age confirmation page. Appending
--   ?view_adult=true to any work URL bypasses it entirely — no WebView needed.
--
-- No cover images:
--   AO3 does not provide cover art. Cover is left nil.
--
-- Login-restricted works:
--   Works set to "Registered users only" require an AO3 account session.
--   These cannot be accessed from an extension. parseChapter detects the
--   login wall and returns a readable message instead of a blank page.
--
-- Chapter list strategy:
--   All chapter data is embedded in the novel page itself. No separate
--   chapter-list request is made. Three detection methods in order:
--     1. Dropdown (#chapter_index select) — standard multi-chapter works
--     2. Inline headings (#chapters h3.title a) — works rendered inline
--     3. Fallback — single-chapter works, use the work URL as the chapter path

local BASE   = "https://archiveofourown.org"
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
    logger.dbg("AO3: http_get", url)
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
        logger.err("AO3: http_get FAILED", url, tostring(code))
        return nil, code
    end
    local body = table.concat(sink)
    logger.dbg("AO3: http_get body_len=", #body)
    return body
end

local function url_encode(str)
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- ── URL helpers ───────────────────────────────────────────────────────────────

local function to_url(path)
    if path:match("^https?://") then return path end
    if path:match("^/")        then return BASE .. path end
    return BASE .. "/" .. path
end

-- Appends ?view_adult=true to bypass the age confirmation page.
-- AO3 shows a "Yes, Continue" gate for Mature/Explicit works — the URL
-- behind that button is simply the work URL with this parameter appended.
local function adult_url(path)
    local url = to_url(path)
    return url .. (url:match("%?") and "&" or "?") .. "view_adult=true"
end

-- ── Tag collector ─────────────────────────────────────────────────────────────

-- AO3 organises metadata as <dd class="TAGTYPE tags"><ul><li><a class="tag">
-- This collects all tag text for a given dd class into a comma-separated string.
local function collect_tags(html, dd_class)
    local tags = {}
    local dd_pos = html:find('<dd[^>]*class="[^"]*' .. dd_class .. '[^"]*"')
    if not dd_pos then return "" end
    local dd_end = html:find('</dd>', dd_pos)
    if not dd_end then return "" end
    local block = html:sub(dd_pos, dd_end)
    for tag in block:gmatch('<a[^>]*class="[^"]*tag[^"]*"[^>]*>([^<]+)</a>') do
        table.insert(tags, tag:match("^%s*(.-)%s*$"))
    end
    return table.concat(tags, ", ")
end

-- ── Novel list parser ─────────────────────────────────────────────────────────

-- Work listing pages use <li class="work ..."> items.
-- Each item has <h4 class="heading"> where the first <a> is the work title link.
-- We scan by h4.heading position to avoid multi-line li matching issues.
local function parse_novel_list(html)
    local novels = {}
    local pos    = 1
    while true do
        local h4_s = html:find('<h4[^>]*class="[^"]*heading[^"]*"', pos)
        if not h4_s then break end
        local h4_e = html:find('</h4>', h4_s)
        if not h4_e then break end
        local h4_block = html:sub(h4_s, h4_e)
        -- First anchor pointing to a /works/ path is the title
        local href = h4_block:match('href="(/works/%d+)"')
                  or h4_block:match('href="(/works/%d+/[^"]*)"')
        local name = href and h4_block:match(
            'href="' .. href:gsub('([%(%)%[%]%.%+%-%*%?%^%$%%])', '%%%1') .. '"[^>]*>([^<]+)</a>'
        )
        if href and name then
            local path = href:match("^/?(.+)") or href
            table.insert(novels, { name = name:match("^%s*(.-)%s*$"), path = path })
        end
        pos = h4_e + 5
    end
    return novels
end

-- ── Extension table ───────────────────────────────────────────────────────────

local ext = {
    id      = "ao3",
    name    = "Archive of Our Own",
    site    = BASE,
    lang    = "multi",
    version = "1.0.0",
}

-- Browse by hits (most popular), all languages.
-- Filters aren't supported in Mythos yet, so we use fixed defaults.
function ext:popularNovels(page, options)
    page = page or 1
    local url = BASE .. "/works/search?commit=Search" ..
        "&page=" .. page ..
        "&work_search[sort_column]=hits" ..
        "&work_search[sort_direction]=desc"
    local html = http_get(url)
    if not html then return { novels = {} } end
    local novels = parse_novel_list(html)
    logger.dbg("AO3: popularNovels found", #novels)
    return { novels = novels }
end

function ext:searchNovels(term, page)
    page = page or 1
    local url = BASE .. "/works/search?commit=Search" ..
        "&page=" .. page ..
        "&work_search[query]=" .. url_encode(term)
    local html = http_get(url)
    if not html then return { novels = {} } end
    local novels = parse_novel_list(html)
    logger.dbg("AO3: searchNovels found", #novels)
    return { novels = novels }
end

-- parseNovelMeta: fast cache check.
-- Chapter count comes from dd.chapters which shows "current/total" or "current/?".
-- We use the current (published) count as total_chapters.
function ext:parseNovelMeta(path)
    local html = http_get(adult_url(path))
    if not html then return nil end

    -- Title (h2.title.heading may span lines, use position-based extraction)
    local title = "Untitled"
    local h2_s  = html:find('<h2[^>]*class="[^"]*title[^"]*"')
    if h2_s then
        local h2_e = html:find('</h2>', h2_s)
        if h2_e then
            title = strip_tags(html:sub(h2_s, h2_e)):match("^%s*(.-)%s*$")
            if title == "" then title = "Untitled" end
        end
    end

    -- Authors
    local authors = {}
    for name in html:gmatch('<a[^>]*rel="author"[^>]*>([^<]+)</a>') do
        table.insert(authors, name:match("^%s*(.-)%s*$"))
    end

    -- Status: dd.status contains "Updated" for works in progress
    local status_dt = html:match('<dt[^>]*class="[^"]*status[^"]*"[^>]*>([^<]+)</dt>') or ""
    local status    = status_dt:match("Updated") and "Ongoing" or "Completed"

    -- Published chapter count from dd.chapters ("5/10", "5/?", "1/1")
    local ch_text        = html:match('<dd[^>]*class="[^"]*chapters[^"]*"[^>]*>([^<]+)</dd>') or ""
    local total_chapters = tonumber(ch_text:match("^%s*(%d+)")) or 0

    logger.dbg("AO3: parseNovelMeta title=", title, "total=", total_chapters)
    return {
        name           = title,
        path           = path,
        cover          = nil,
        author         = table.concat(authors, ", "),
        status         = status,
        total_chapters = total_chapters,
    }
end

function ext:parseNovel(path)
    logger.dbg("AO3: parseNovel", path)
    local html = http_get(adult_url(path))
    if not html then
        logger.err("AO3: parseNovel fetch failed", path)
        return nil
    end

    -- Title
    local title = "Untitled"
    local h2_s  = html:find('<h2[^>]*class="[^"]*title[^"]*"')
    if h2_s then
        local h2_e = html:find('</h2>', h2_s)
        if h2_e then
            title = strip_tags(html:sub(h2_s, h2_e)):match("^%s*(.-)%s*$")
            if title == "" then title = "Untitled" end
        end
    end

    -- Authors (multiple authors are joined with ", ")
    local authors = {}
    for name in html:gmatch('<a[^>]*rel="author"[^>]*>([^<]+)</a>') do
        table.insert(authors, name:match("^%s*(.-)%s*$"))
    end
    local author = table.concat(authors, ", ")

    -- Status
    local status_dt = html:match('<dt[^>]*class="[^"]*status[^"]*"[^>]*>([^<]+)</dt>') or ""
    local status    = status_dt:match("Updated") and "Ongoing" or "Completed"

    -- Tags by category
    local fandom  = collect_tags(html, "fandom")
    local rating  = collect_tags(html, "rating")
    local warning = collect_tags(html, "warning")
    local genres  = collect_tags(html, "freeform")
    local rels    = collect_tags(html, "relationship")
    local chars   = collect_tags(html, "character")

    -- Summary from blockquote.userstuff (the actual author notes/summary block)
    local raw_summary = ""
    local bq_s = html:find('<blockquote[^>]*class="[^"]*userstuff[^"]*"')
    if bq_s then
        local bq_e = html:find('</blockquote>', bq_s)
        if bq_e then
            local bq = html:sub(bq_s, bq_e)
            bq = bq:gsub('<br[^>]*/?>%s*', '\n'):gsub('</p>%s*', '\n\n')
            raw_summary = strip_tags(bq):gsub('\n\n\n+', '\n\n'):match("^%s*(.-)%s*$")
        end
    end

    -- Build a structured summary block so readers have full context
    local parts = {}
    if fandom      ~= "" then table.insert(parts, "Fandom: "        .. fandom)      end
    if rating      ~= "" then table.insert(parts, "Rating: "        .. rating)      end
    if warning     ~= "" then table.insert(parts, "Warning: "       .. warning)     end
    if raw_summary ~= "" then table.insert(parts, "Summary:\n"      .. raw_summary) end
    if rels        ~= "" then table.insert(parts, "Relationships: " .. rels)        end
    if chars       ~= "" then table.insert(parts, "Characters: "    .. chars)       end
    local summary = table.concat(parts, "\n\n")

    -- Work ID (needed to build chapter paths)
    local work_id = path:match("works/(%d+)") or ""

    -- ── Chapter list ──────────────────────────────────────────────────────────

    local chapters = {}

    -- Method 1: chapter dropdown inside #chapter_index
    -- <select> options have value=chapterID, text=chapter name
    local ci_pos = html:find('id="chapter_index"')
    if ci_pos then
        local sel_s = html:find('<select', ci_pos)
        local sel_e = html:find('</select>', ci_pos)
        if sel_s and sel_e then
            local sel_block = html:sub(sel_s, sel_e)
            for opt_open, opt_text in sel_block:gmatch('(<option[^>]*>)([^<]*)') do
                local val  = opt_open:match('value="([^"]+)"')
                local name = opt_text:match("^%s*(.-)%s*$")
                if val and name ~= "" then
                    table.insert(chapters, {
                        name = name,
                        path = "works/" .. work_id .. "/chapters/" .. val,
                    })
                end
            end
            logger.dbg("AO3: chapters from dropdown:", #chapters)
        end
    end

    -- Method 2: inline chapter headings inside #chapters
    -- <h3 class="title"><a href="/works/ID/chapters/CHID">Chapter N: Name</a>
    if #chapters == 0 then
        local ch_div_pos = html:find('id="chapters"')
        if ch_div_pos then
            local area = html:sub(ch_div_pos)
            local pos2 = 1
            while true do
                local h3_s = area:find('<h3[^>]*class="[^"]*title[^"]*"', pos2)
                if not h3_s then break end
                local h3_e = area:find('</h3>', h3_s)
                if not h3_e then break end
                local h3_block = area:sub(h3_s, h3_e)
                local ch_id    = h3_block:match('/chapters/(%d+)')
                if ch_id then
                    local full_name = strip_tags(h3_block):match("^%s*(.-)%s*$")
                    -- Strip "Chapter N: " prefix, keep subtitle only
                    local name = full_name:match("[Cc]hapter%s+%d+:%s*(.+)")
                             or  full_name:match(":%s*(.+)$")
                             or  full_name
                    table.insert(chapters, {
                        name = name,
                        path = "works/" .. work_id .. "/chapters/" .. ch_id,
                    })
                end
                pos2 = h3_e + 5
            end
            logger.dbg("AO3: chapters from inline headings:", #chapters)
        end
    end

    -- Method 3: single-chapter work — content is on the work page itself
    if #chapters == 0 then
        table.insert(chapters, { name = title, path = path })
        logger.dbg("AO3: single-chapter work, using work path")
    end

    return {
        name       = title,
        path       = path,
        cover      = nil,
        summary    = summary,
        author     = author,
        genres     = genres,
        status     = status,
        chapters   = chapters,
        totalPages = 1,
    }
end

function ext:parseChapter(path)
    local url  = adult_url(path)
    local html = http_get(url)
    if not html then return "<p>Error fetching chapter.</p>" end

    -- Login-restricted works redirect to a login page
    if html:match('id="login%-form"') or
       (html:match('Log [Ii]n') and not html:find('id="chapters"')) then
        return "<p>This work is restricted to registered users on AO3 and cannot be accessed without logging in.</p>"
    end

    -- div#chapters holds all chapter content
    local chapters_div = extract_div(html, '<div[^>]*id="chapters"')
    if not chapters_div then
        return "<p>Could not extract chapter content.</p>"
    end

    -- The first child div of #chapters is the chapter content wrapper
    local content = extract_div(chapters_div, '<div') or chapters_div

    -- Strip hrefs from all links — they don't work in epub
    content = content:gsub(' href="[^"]*"', '')

    -- Remove the landmark heading AO3 inserts ("Chapter Content", etc.)
    content = content:gsub('<h3[^>]*id="work"[^>]*>[^<]*</h3>', '')

    return content
end

return ext
