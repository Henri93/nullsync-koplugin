--[[--
Reading Recap podcast for the null-space sync plugin.

Extracts, on the device, the exact passage the reader has read since the last
episode and sends it to the server's /podcast/ingest endpoint. The server turns
it into a spoken episode and keeps only the script and the audio; the passage
itself is used once and discarded. Nothing is ever uploaded unless the reader
turned the feature on, and only the text between two reading positions ever
leaves the device.

Works for both document families:
  * crengine (EPUB, FB2, HTML...): positions are xpointers, text comes from
    document:getTextFromXPointers(from, to)
  * page-based (PDF, DjVu, CBZ): positions are page numbers, text comes from
    document:getPageText(page) for each page in the range
--]]--

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local Podcast = {}

-- Server-side limits mirrored here so we never upload something that will be refused.
Podcast.MIN_CHARS = 400
Podcast.MAX_CHARS = 60000
-- Auto mode: send a passage once at least this much of the book was read since the last
-- send. The server groups the day's passages into one nightly episode per book (or makes an
-- episode right away if the reader chose that), so there is no interval gate by default.
Podcast.DEFAULT_MIN_PROGRESS = 0.005
Podcast.DEFAULT_MIN_INTERVAL_S = 0

local MARKER_KEY = "nullsync_podcast_marker"

-- Flatten whatever getPageText() returns (nested tables of {word=...} boxes, or
-- plain strings) into one string.
local function flattenPageText(node, out)
    if node == nil then return end
    if type(node) == "string" then
        table.insert(out, node)
        return
    end
    if type(node) ~= "table" then return end
    if node.word then
        table.insert(out, node.word)
        return
    end
    for _, child in ipairs(node) do
        flattenPageText(child, out)
    end
    -- A line ends: keep words from different lines separated.
    table.insert(out, "\n")
end

-- Where the reader is right now, in a form we can diff against later.
function Podcast.currentPosition(ui)
    if not ui or not ui.document then return nil end
    local position = { time = os.time() }
    if ui.document.info.has_pages then
        position.page = ui.paging and ui.paging:getLastProgress() or ui:getCurrentPage()
        position.percent = ui.paging and ui.paging:getLastPercent() or 0
    else
        position.xp = ui.document:getXPointer()
        position.percent = ui.rolling and ui.rolling:getLastPercent() or 0
    end
    return position
end

function Podcast.getMarker(ui)
    return ui and ui.doc_settings and ui.doc_settings:readSetting(MARKER_KEY) or nil
end

function Podcast.setMarker(ui, position)
    if ui and ui.doc_settings then
        ui.doc_settings:saveSetting(MARKER_KEY, position)
    end
end

-- The text between the saved marker and the current position. Returns the text
-- and the current position, or nil and a reason code.
function Podcast.extractSinceMarker(ui)
    local marker = Podcast.getMarker(ui)
    local now = Podcast.currentPosition(ui)
    if not marker or not now then return nil, "no_marker" end
    if (now.percent or 0) <= (marker.percent or 0) then return nil, "no_progress" end

    local text
    if ui.document.info.has_pages then
        local first = (marker.page or 0) + 1
        local last = now.page or first
        if last < first then return nil, "no_progress" end
        -- Never walk hundreds of pages; a day's reading is a few dozen at most.
        if last - first > 150 then first = last - 150 end
        local parts = {}
        for page = first, last do
            local ok, page_text = pcall(ui.document.getPageText, ui.document, page)
            if ok then flattenPageText(page_text, parts) end
        end
        text = table.concat(parts, " ")
    else
        if not marker.xp or not now.xp then return nil, "no_marker" end
        local ok, result = pcall(ui.document.getTextFromXPointers, ui.document, marker.xp, now.xp)
        if not ok then
            logger.warn("NullSync podcast: getTextFromXPointers failed:", result)
            return nil, "extract_failed"
        end
        text = result
    end

    if type(text) ~= "string" then return nil, "extract_failed" end
    text = util.trim(text:gsub("[ \t]+", " "))
    if #text > Podcast.MAX_CHARS then
        -- Keep the most recent reading.
        text = text:sub(-Podcast.MAX_CHARS)
    end
    if #text < Podcast.MIN_CHARS then return nil, "too_short" end
    return text, now
end

-- Build the ingest payload for the current book.
function Podcast.payload(ui, digest, marker, now, text)
    local _dir, filename = util.splitFilePathName(ui.document.file)
    local props = ui.doc_props or {}
    return {
        document = digest,
        filename = filename,
        title = props.display_title or props.title or filename,
        author = props.authors,
        start_percent = marker.percent or 0,
        end_percent = now.percent or 0,
        text = text,
        device = G_reader_settings:readSetting("device_name") or "KOReader",
    }
end

-- Decide whether the automatic trigger should fire now.
function Podcast.autoDue(settings, marker, now)
    if not marker or not now then return false end
    local min_progress = settings.podcast_min_progress or Podcast.DEFAULT_MIN_PROGRESS
    local min_interval = settings.podcast_min_interval_s or Podcast.DEFAULT_MIN_INTERVAL_S
    if (now.percent or 0) - (marker.percent or 0) < min_progress then return false end
    if marker.time and os.time() - marker.time < min_interval then return false end
    return true
end

local REASONS = {
    no_marker = _("Open the book and read a little first; the next episode starts from here."),
    no_progress = _("Nothing new read since the last episode."),
    too_short = _("Not enough new reading for an episode yet."),
    extract_failed = _("Couldn't read the text of this book."),
}

-- Make an episode from everything read since the marker. `callAPI` is the
-- plugin's HTTP helper; `digest` the kosync document id.
-- interactive: show messages; auto: silent, respects thresholds.
function Podcast.makeEpisode(plugin, interactive)
    local ui = plugin.ui
    if not ui or not ui.document then return false end
    local settings = plugin.settings
    local marker = Podcast.getMarker(ui)
    local now = Podcast.currentPosition(ui)

    if not marker then
        -- First time we see this book: start counting from here.
        Podcast.setMarker(ui, now)
        if interactive then
            UIManager:show(InfoMessage:new{ text = REASONS.no_marker, timeout = 4 })
        end
        return false
    end
    if not interactive and not Podcast.autoDue(settings, marker, now) then
        return false
    end

    local text, result = Podcast.extractSinceMarker(ui)
    if not text then
        if interactive then
            UIManager:show(InfoMessage:new{ text = REASONS[result] or result, timeout = 4 })
        elseif result == "no_progress" then
            -- Reader went backwards; restart the window from here.
            Podcast.setMarker(ui, now)
        end
        return false
    end

    local digest = plugin:getDocumentDigest()
    if not digest then return false end
    local payload = Podcast.payload(ui, digest, marker, result, text)
    local ok, err, code = plugin:callAPI("/podcast/ingest", payload, "POST", { 200, 202 })
    if ok then
        Podcast.setMarker(ui, result)
        if interactive then
            UIManager:show(InfoMessage:new{
                text = T(_("Sent: %1 to %2 of the book. It becomes part of your next episode (nightly, or right away, depending on your podcast settings)."),
                    string.format("%d%%", math.floor((marker.percent or 0) * 100 + 0.5)),
                    string.format("%d%%", math.floor((result.percent or 0) * 100 + 0.5))),
                timeout = 5,
            })
        end
        return true
    end

    if interactive then
        local msg
        if code == 402 then
            msg = _("Your podcast subscription isn't active. Manage it at null-space.xyz/reader/podcast.")
        elseif code == 429 then
            msg = _("You've reached today's episode limit. The next reading session gets a fresh one tomorrow.")
        elseif code == 400 then
            msg = _("The server needs a bit more new reading before it can use this.")
        else
            msg = T(_("Couldn't send this episode (%1)."), code or err)
        end
        UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
    else
        logger.warn("NullSync podcast: ingest failed", code or err)
    end
    return false
end

-- Called when a book is opened: make sure a marker exists so the first episode
-- covers from this session onward, never the whole book.
function Podcast.onReaderReady(plugin)
    local ui = plugin.ui
    if not ui or not ui.document or not plugin.settings.podcast_enabled then return end
    if not Podcast.getMarker(ui) then
        Podcast.setMarker(ui, Podcast.currentPosition(ui))
    end
end

return Podcast
