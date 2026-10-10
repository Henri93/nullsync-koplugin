-- Minimal KOReader stand-ins so podcast.lua can run under plain Lua.
local stubs = {
  ["ui/widget/infomessage"] = { new = function(_, t) return t end },
  ["ui/uimanager"] = { show = function(_, w) _G.LAST_MSG = w.text end },
  ["logger"] = { warn = function() end, dbg = function() end },
  ["util"] = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
               splitFilePathName = function(p) return p:match("^(.*)/([^/]+)$") end },
  ["ffi/util"] = { template = function(fmt, ...) local a={...}; local i=0; return (fmt:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end)) end },
  ["gettext"] = function(s) return s end,
}
local real_require = require
require = function(name) return stubs[name] or real_require(name) end
package.path = os.getenv("PLUGIN_DIR") .. "/?.lua;" .. package.path
_G.G_reader_settings = { readSetting = function(_, k) return nil end }
local Podcast = require("podcast")

-- Fake EPUB document: positions are integers encoded as xpointers.
local words = {}
for i = 1, 600 do words[i] = "word" .. i end
local text_all = table.concat(words, " ")
local settings_store = {}
local ui = {
  document = { info = { has_pages = false }, file = "/books/Dune.epub",
    getXPointer = function() return "xp:" .. _G.CUR end,
    getTextFromXPointers = function(_, a, b)
      local i, j = tonumber(a:match("%d+")), tonumber(b:match("%d+"))
      return table.concat(words, " ", i, j)
    end },
  rolling = { getLastPercent = function() return _G.CUR / 600 end },
  doc_settings = { readSetting = function(_, k) return settings_store[k] end,
                   saveSetting = function(_, k, v) settings_store[k] = v end },
  doc_props = { display_title = "Dune", authors = "Frank Herbert" },
}
_G.CUR = 10
Podcast.setMarker(ui, Podcast.currentPosition(ui))
assert(Podcast.getMarker(ui).xp == "xp:10")
_G.CUR = 12
local t, why = Podcast.extractSinceMarker(ui); assert(t == nil and why == "too_short", why)
_G.CUR = 300
local text, now = Podcast.extractSinceMarker(ui)
assert(text and #text > 400 and text:find("word11") and text:find("word300") and not text:find("word301 "), "extraction window")
local marker = Podcast.getMarker(ui)
assert(Podcast.autoDue({podcast_min_progress = 0.02, podcast_min_interval_s = 0}, marker, now) == true)
assert(Podcast.autoDue({podcast_min_progress = 0.9, podcast_min_interval_s = 0}, marker, now) == false)
assert(Podcast.autoDue({podcast_min_progress = 0.02, podcast_min_interval_s = 999999}, marker, now) == false, "interval gate")
local payload = Podcast.payload(ui, "digest123", marker, now, text)
assert(payload.title == "Dune" and payload.author == "Frank Herbert" and payload.document == "digest123" and payload.filename == "Dune.epub")
assert(math.abs(payload.start_percent - 10/600) < 1e-9 and math.abs(payload.end_percent - 0.5) < 1e-9)

-- Backwards reading: no progress
_G.CUR = 5
local t2, why2 = Podcast.extractSinceMarker(ui); assert(t2 == nil and why2 == "no_progress")

-- Fake PDF: pages of nested word boxes
local pdf_ui = {
  document = { info = { has_pages = true }, file = "/books/paper.pdf",
    getPageText = function(_, p) local line = {}; for i=1,60 do line[i] = { word = "p"..p.."w"..i } end; return { line } end },
  paging = { getLastProgress = function() return _G.PAGE end, getLastPercent = function() return _G.PAGE / 100 end },
  doc_settings = { readSetting = function(_, k) return settings_store["pdf"..k] end, saveSetting = function(_, k, v) settings_store["pdf"..k] = v end },
  doc_props = {},
}
_G.PAGE = 3; Podcast.setMarker(pdf_ui, Podcast.currentPosition(pdf_ui))
_G.PAGE = 7
local ptext = Podcast.extractSinceMarker(pdf_ui)
assert(ptext and ptext:find("p4w1") and ptext:find("p7w60") and not ptext:find("p3w1"), "pdf page window")

-- makeEpisode: full flow with a fake plugin
local sent
local plugin = { ui = ui, settings = { podcast_enabled = true, podcast_min_progress = 0.02, podcast_min_interval_s = 0 },
  getDocumentDigest = function() return "digest123" end,
  callAPI = function(_, path, body, method, ok) sent = { path = path, body = body, method = method }; return true end }
_G.CUR = 300
assert(Podcast.makeEpisode(plugin, true) == true)
assert(sent.path == "/podcast/ingest" and sent.method == "POST" and #sent.body.text > 400 and sent.body.text:find("word11"))
assert(Podcast.getMarker(ui).xp == "xp:300", "marker advanced after success")
assert(_G.LAST_MSG:find("Sent:"), _G.LAST_MSG)
-- 402 from the server gives a subscription message
plugin.callAPI = function() return false, "http_error", 402 end
_G.CUR = 500
assert(Podcast.makeEpisode(plugin, true) == false and _G.LAST_MSG:find("subscription"), _G.LAST_MSG)
assert(Podcast.getMarker(ui).xp == "xp:300", "marker unchanged after failure")
print("podcast.lua harness: all assertions passed")
