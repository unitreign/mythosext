# Locked Chapters

Some sites put chapters behind coins, a subscription, or a login. Extensions can flag these so Mythos handles them correctly instead of showing a blank or broken chapter.

## The locked field

Add `locked = true` to any chapter you detect as inaccessible:

```lua
table.insert(chapters, {
    name   = "Chapter 50",
    path   = "/novel/slug/chapter-50",
    locked = true,
})
```

Leave `locked` out entirely (don't set it to `false`) for normal chapters. It keeps the table small and Mythos treats absent as unlocked.

## What Mythos does with it

- Locked chapters show as dimmed in the chapter list and can't be selected for reading
- If a selection going into export happens to include locked chapters, the export screen shows a warning with a count
- The export still runs, but locked chapters produce blank pages in the epub

## Detecting locked chapters

Sites mark locked content in different ways. Look at the HTML of the chapter list page and pick whichever pattern fits:

**Lock icon in the HTML:**
```lua
local is_locked = inner:match('<i[^>]*class="[^"]*fa%-lock[^"]*"') ~= nil
```

**CSS class on the list item or link:**
```lua
local is_locked = li_open:match('class="[^"]*locked[^"]*"') ~= nil
              or  li_open:match('class="[^"]*premium[^"]*"') ~= nil
```

**Data attribute:**
```lua
local is_locked = a_tag:match('data%-locked="1"') ~= nil
```

**Coin or price label:**
```lua
local is_locked = inner:match('%d+%s*coins?') ~= nil
```

Combine them with `or` if the site uses more than one marker. Then pass the result into the chapter table:

```lua
table.insert(chapters, {
    name   = title,
    path   = path,
    locked = is_locked or nil,
})
```

## Handling a locked response in parseChapter

If a user tries to export a locked chapter, the request will usually come back as a login redirect or error page. You can catch this and return something readable instead of an empty or broken page:

```lua
function ext:parseChapter(path)
    local html = http_get(BASE .. path)
    if not html then return "<p>Could not fetch chapter.</p>" end

    if html:match('class="[^"]*login%-required[^"]*"')
    or html:match("you need to be logged in")
    or html:match("subscribe to read") then
        return "<p>This chapter requires a subscription to access.</p>"
    end

    -- normal extraction continues here
end
```

The exact strings to match depend on the site. Check what the locked page actually contains and match against that.
