--[[--
Null-space sync: pushes the vocabulary builder word list and the current
book's highlights/notes to the null-space sync server (the same server the
Progress sync / kosync plugin talks to, reusing its account settings).

Sync is one-way (device -> server) with replace semantics: the device is the
source of truth, so words or highlights deleted on the device disappear from
the server on the next sync. Background syncs only ever run when a network
connection is already up -- this plugin never turns on WiFi and never nags
while offline (e.g. traveling / airplane mode).
--]]--

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local md5 = require("ffi/sha2").md5
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")
local Podcast = require("podcast")

-- Block/total socket timeouts; payloads are small but Lambda cold starts are not.
local SYNC_TIMEOUTS = { 10, 30 }
-- Minimum seconds between background syncs (close + suspend often fire together)
local BACKGROUND_DEBOUNCE_S = 60

local VOCABULARY_DB = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"

-- Matches kosync's CHECKSUM_METHOD.FILENAME
local CHECKSUM_METHOD_FILENAME = 1

local NullSync = WidgetContainer:extend{
    name = "nullsync",
    settings = nil,
    last_push_timestamp = 0,
}

NullSync.default_settings = {
    auto_sync = true,
    sync_vocabulary = true,
    sync_annotations = true,
    -- Reading Recap podcast: upload the passage read since the last episode so the
    -- server can make a spoken episode. Off until the reader turns it on.
    podcast_enabled = false,
    podcast_min_progress = Podcast.DEFAULT_MIN_PROGRESS,
    podcast_min_interval_s = Podcast.DEFAULT_MIN_INTERVAL_S,
    -- Fingerprints of the last successfully pushed payloads, to skip no-op syncs
    vocab_fingerprint = nil,
    annotations_fingerprints = {}, -- keyed by document digest
}

function NullSync:init()
    self.settings = G_reader_settings:readSetting("nullsync", self.default_settings)
    self:registerEvents()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function NullSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("nullsync_sync_now",
        { category = "none", event = "NullSyncNow", title = _("Sync vocabulary and highlights"), general = true })
    Dispatcher:registerAction("nullsync_podcast_now",
        { category = "none", event = "NullSyncPodcastNow", title = _("Make a podcast episode from what I read"), general = true })
end

function NullSync:getKOSyncSettings()
    local kosync = G_reader_settings:readSetting("kosync")
    if kosync and kosync.custom_server and kosync.username and kosync.userkey then
        return kosync
    end
    return nil
end

-- Same document identity the kosync plugin pushes progress under, so the
-- server can associate highlights with the right book.
function NullSync:getDocumentDigest()
    if not self.ui or not self.ui.document then return nil end
    local kosync = G_reader_settings:readSetting("kosync") or {}
    if kosync.checksum_method == CHECKSUM_METHOD_FILENAME then
        local _dir, filename = util.splitFilePathName(self.ui.document.file)
        return filename and md5(filename) or nil
    end
    return self.ui.doc_settings:readSetting("partial_md5_checksum")
end

function NullSync:callAPI(path, body_table, method, ok_codes)
    local kosync = self:getKOSyncSettings()
    if not kosync then
        return false, "not_configured"
    end

    local body = rapidjson.encode(body_table)
    local sink = {}
    socketutil:set_timeout(SYNC_TIMEOUTS[1], SYNC_TIMEOUTS[2])
    local request = {
        url = kosync.custom_server:gsub("/+$", "") .. path,
        method = method or "PUT",
        headers = {
            ["x-auth-user"] = kosync.username,
            ["x-auth-key"] = kosync.userkey,
            ["content-type"] = "application/json",
            ["accept"] = "application/json",
            ["content-length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    }
    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if resp_headers == nil then
        logger.dbg("NullSync: network error", status or code)
        return false, "network_error"
    end
    local accepted = false
    for _i, ok_code in ipairs(ok_codes or { 200 }) do
        if code == ok_code then accepted = true end
    end
    if not accepted then
        logger.warn("NullSync:", path, "failed with HTTP", code, table.concat(sink))
        return false, "http_error", code
    end
    return true
end

-- Read the whole vocabulary builder DB. Returns a payload table, or nil.
function NullSync:getVocabularyPayload()
    if lfs.attributes(VOCABULARY_DB, "mode") ~= "file" then
        return nil
    end

    local conn = SQ3.open(VOCABULARY_DB, "ro")
    local ok, results, nrows = pcall(conn.exec, conn, [[
        SELECT word, title.name AS book_title, create_time, review_time, due_time,
               review_count, streak_count, prev_context, next_context, highlight
        FROM vocabulary LEFT JOIN title ON title.id = vocabulary.title_id
        ORDER BY create_time;]])
    conn:close()
    if not ok then
        logger.warn("NullSync: failed to read vocabulary DB:", results)
        return nil
    end

    local words = {}
    nrows = tonumber(nrows) or 0
    if results then
        for i = 1, nrows do
            table.insert(words, {
                word = results.word[i],
                book_title = results.book_title[i],
                create_time = results.create_time[i] and tonumber(results.create_time[i]) or nil,
                review_time = results.review_time[i] and tonumber(results.review_time[i]) or nil,
                due_time = results.due_time[i] and tonumber(results.due_time[i]) or nil,
                review_count = results.review_count[i] and tonumber(results.review_count[i]) or 0,
                streak_count = results.streak_count[i] and tonumber(results.streak_count[i]) or 0,
                prev_context = results.prev_context[i],
                next_context = results.next_context[i],
                highlight = results.highlight[i],
            })
        end
    end
    -- Empty vocab must encode as [] (not {}) for the server to accept it
    setmetatable(words, { __jsontype = "array" })
    return { words = words }
end

-- pos0/pos1 are xpointer strings for EPUBs but tables for page-based formats;
-- the server stores strings, and this keeps the identity stable either way.
local function posToString(pos)
    if pos == nil or type(pos) == "string" then
        return pos
    end
    return rapidjson.encode(pos)
end

-- Collect the current book's highlights/notes. Returns a payload table, or nil.
function NullSync:getAnnotationsPayload()
    if not self.ui or not self.ui.document then return nil end
    local annotations = self.ui.annotation and self.ui.annotation.annotations
    if not annotations then return nil end

    local digest = self:getDocumentDigest()
    if not digest then return nil end

    local items = {}
    for _idx, a in ipairs(annotations) do
        -- Entries with a drawer are highlights (with or without a note);
        -- entries without one are plain page bookmarks, which we skip.
        if a.drawer then
            table.insert(items, {
                text = a.text,
                note = a.note,
                chapter = a.chapter,
                color = a.color,
                drawer = a.drawer,
                datetime = a.datetime,
                pageno = type(a.pageno) == "number" and a.pageno or nil,
                pos0 = posToString(a.pos0),
                pos1 = posToString(a.pos1),
            })
        end
    end
    setmetatable(items, { __jsontype = "array" })

    local _dir, filename = util.splitFilePathName(self.ui.document.file)
    local doc_props = self.ui.doc_props or {}
    return {
        document = digest,
        filename = filename,
        title = doc_props.display_title or doc_props.title,
        author = doc_props.authors,
        annotations = items,
    }
end

-- Push vocabulary + current book's annotations.
-- interactive: triggered from menu/gesture; shows result messages and skips
-- the debounce/fingerprint shortcuts. Background calls are entirely silent
-- and only run when a connection is already up.
function NullSync:sync(interactive)
    if not self:getKOSyncSettings() then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Null-space sync uses the Progress sync account. Please set the custom sync server and log in under Progress sync first."),
                timeout = 5,
            })
        end
        return
    end

    -- Never attempt (or nag about) a connection in the background: when
    -- offline (e.g. airplane mode), skip silently. isConnected is a cheap,
    -- purely local check.
    if not NetworkMgr:isConnected() then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("Not connected to a network, cannot sync."),
                timeout = 3,
            })
        else
            logger.dbg("NullSync: no active network connection, skipping background sync")
        end
        return
    end

    local now = os.time()
    if not interactive and now - self.last_push_timestamp < BACKGROUND_DEBOUNCE_S then
        logger.dbg("NullSync: debounced, last background sync was", now - self.last_push_timestamp, "s ago")
        return
    end
    self.last_push_timestamp = now

    local summary = {}
    local errors = {}

    if self.settings.sync_annotations then
        local payload = self:getAnnotationsPayload()
        if payload then
            local fingerprint = md5(rapidjson.encode(payload.annotations))
            if interactive or self.settings.annotations_fingerprints[payload.document] ~= fingerprint then
                local ok, err, code = self:callAPI("/syncs/annotations", payload)
                if ok then
                    self.settings.annotations_fingerprints[payload.document] = fingerprint
                    table.insert(summary, T(_("%1 highlights"), #payload.annotations))
                else
                    table.insert(errors, T(_("highlights (%1)"), code or err))
                end
            else
                logger.dbg("NullSync: annotations unchanged, skipping")
            end
        end
    end

    if self.settings.sync_vocabulary then
        local payload = self:getVocabularyPayload()
        if payload then
            local fingerprint = md5(rapidjson.encode(payload.words))
            if interactive or self.settings.vocab_fingerprint ~= fingerprint then
                local ok, err, code = self:callAPI("/syncs/vocabulary", payload)
                if ok then
                    self.settings.vocab_fingerprint = fingerprint
                    table.insert(summary, T(_("%1 words"), #payload.words))
                else
                    table.insert(errors, T(_("vocabulary (%1)"), code or err))
                end
            else
                logger.dbg("NullSync: vocabulary unchanged, skipping")
            end
        end
    end

    if #errors > 0 then
        logger.warn("NullSync: sync failed for", table.concat(errors, ", "))
        if interactive then
            UIManager:show(InfoMessage:new{
                text = T(_("Sync failed for %1."), table.concat(errors, ", ")),
                timeout = 3,
            })
        end
    elseif interactive then
        UIManager:show(InfoMessage:new{
            text = #summary > 0 and T(_("Synced %1."), table.concat(summary, ", "))
                or _("Nothing to sync."),
            timeout = 3,
        })
    end
end

function NullSync:onNullSyncNow()
    self:sync(true)
    return true
end

function NullSync:onNullSyncPodcastNow()
    self:podcast(true)
    return true
end

function NullSync:onReaderReady()
    Podcast.onReaderReady(self)
end

-- Background podcast trigger: silent, only when online, only when due.
function NullSync:podcast(interactive)
    if not self.settings.podcast_enabled and not interactive then return end
    if not self:getKOSyncSettings() then
        if interactive then
            UIManager:show(InfoMessage:new{
                text = _("The podcast uses your Progress sync account. Set the custom sync server and log in under Progress sync first."),
                timeout = 5,
            })
        end
        return
    end
    if not NetworkMgr:isConnected() then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Not connected to a network."), timeout = 3 })
        end
        return
    end
    Podcast.makeEpisode(self, interactive)
end

function NullSync:_onCloseDocument()
    logger.dbg("NullSync: onCloseDocument")
    -- The document is still open here, so the passage can still be extracted.
    self:podcast(false)
    self:sync(false)
end

function NullSync:_onSuspend()
    logger.dbg("NullSync: onSuspend")
    self:podcast(false)
    self:sync(false)
end

function NullSync:_onNetworkConnected()
    logger.dbg("NullSync: onNetworkConnected")
    -- Let kosync's progress pull/push go first
    self.network_sync_task = self.network_sync_task or function()
        self:sync(false)
    end
    UIManager:scheduleIn(3, self.network_sync_task)
end

function NullSync:registerEvents()
    if self.settings.auto_sync then
        self.onCloseDocument = self._onCloseDocument
        self.onSuspend = self._onSuspend
        self.onNetworkConnected = self._onNetworkConnected
    else
        self.onCloseDocument = nil
        self.onSuspend = nil
        self.onNetworkConnected = nil
    end
end

function NullSync:onCloseWidget()
    if self.network_sync_task then
        UIManager:unschedule(self.network_sync_task)
    end
end

function NullSync:addToMainMenu(menu_items)
    menu_items.nullsync = {
        text = _("Null-space sync"),
        -- Third-party plugins aren't in KOReader's menu order tables; without a
        -- sorting hint this lands in the first top-level menu prefixed "NEW: ".
        -- "tools" puts it alongside Progress sync in both reader and file browser.
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync vocabulary and highlights now"),
                keep_menu_open = true,
                enabled_func = function()
                    return self:getKOSyncSettings() ~= nil
                        and (self.settings.sync_vocabulary or self.settings.sync_annotations)
                end,
                callback = function()
                    self:sync(true)
                end,
                separator = true,
            },
            {
                text = _("Sync automatically"),
                help_text = _([[Sync when closing a book, on suspend, and when a network connection comes up. Never attempts to enable WiFi: syncs are silently skipped while offline and caught up once you're connected again.]]),
                checked_func = function() return self.settings.auto_sync end,
                callback = function()
                    self.settings.auto_sync = not self.settings.auto_sync
                    self:registerEvents()
                end,
            },
            {
                text = _("Include vocabulary builder words"),
                checked_func = function() return self.settings.sync_vocabulary end,
                callback = function()
                    self.settings.sync_vocabulary = not self.settings.sync_vocabulary
                end,
            },
            {
                text = _("Include highlights and notes"),
                checked_func = function() return self.settings.sync_annotations end,
                callback = function()
                    self.settings.sync_annotations = not self.settings.sync_annotations
                end,
                separator = true,
            },
            {
                text = _("Reading Recap podcast"),
                sub_item_table = {
                    {
                        text = _("Make episodes automatically"),
                        help_text = _([[When you close a book or the device sleeps, the passage you read since the last episode is sent to your sync server, which turns it into a spoken episode for your private podcast feed. Only the text you actually read is sent, and the server keeps the episode, not the book. Needs a Reading Recap subscription at null-space.xyz/reader/podcast.]]),
                        checked_func = function() return self.settings.podcast_enabled end,
                        callback = function()
                            self.settings.podcast_enabled = not self.settings.podcast_enabled
                            if self.settings.podcast_enabled then
                                Podcast.onReaderReady(self)
                            end
                        end,
                    },
                    {
                        text = _("Make an episode from what I've read now"),
                        keep_menu_open = true,
                        enabled_func = function()
                            return self.ui and self.ui.document ~= nil and self:getKOSyncSettings() ~= nil
                        end,
                        callback = function()
                            self:podcast(true)
                        end,
                    },
                    {
                        text = _("Start the next episode from here"),
                        help_text = _("Forget what was read before this point; the next episode covers only what you read from now on."),
                        keep_menu_open = true,
                        enabled_func = function() return self.ui and self.ui.document ~= nil end,
                        callback = function()
                            Podcast.setMarker(self.ui, Podcast.currentPosition(self.ui))
                            UIManager:show(InfoMessage:new{ text = _("The next episode starts here."), timeout = 3 })
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Minimum new reading for an automatic episode: %1%"),
                                math.floor((self.settings.podcast_min_progress or Podcast.DEFAULT_MIN_PROGRESS) * 100 + 0.5))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            UIManager:show(SpinWidget:new{
                                value = math.floor((self.settings.podcast_min_progress or Podcast.DEFAULT_MIN_PROGRESS) * 100 + 0.5),
                                value_min = 1, value_max = 25, value_step = 1, value_hold_step = 5,
                                unit = "%",
                                title_text = _("Minimum new reading"),
                                callback = function(spin)
                                    self.settings.podcast_min_progress = spin.value / 100
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    },
                },
            },
        },
    }
end

return NullSync
