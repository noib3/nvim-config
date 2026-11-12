local Format = require("trouble.format")
local Item = require("trouble.item")
local hunks = require("nvim_hunks")

local M = {}

--- The user event refreshing the lists of hunks once a listing is ready.
local listed_event = "NvimHunksTroubleListed"

---@class nvim_hunks.trouble.Entry
---@field file nvim_hunks.File
---@field hunk? nvim_hunks.Hunk Unset on the row of the file itself.

--- Returns the `+added -deleted` segments of a set of hunks.
---@param hunk_list nvim_hunks.Hunk[]
---@return trouble.Format[]
local counts = function(hunk_list)
  local added, deleted = 0, 0
  for _, hunk in ipairs(hunk_list) do
    added = added + hunk.new_count
    deleted = deleted + hunk.old_count
  end

  local segments = {}
  if added > 0 then
    segments[#segments + 1] = { text = " +" .. added, hl = "HunksAddedCount" }
  end
  if deleted > 0 then
    segments[#segments + 1] =
      { text = " -" .. deleted, hl = "HunksDeletedCount" }
  end
  return segments
end

--- Returns the 1-based line a hunk starts at in the buffer, or the line its
--- deleted lines follow.
---@param hunk nvim_hunks.Hunk
---@return integer
local first_line = function(hunk) return math.max(hunk.new_start, 1) end

--- The addition of files, with its letter and the highlight of its number.
local added_status = { "added", "A", "HunksAddedFiles" }

--- The changes to files in the order they're summarized, with their letters
--- and the highlights of their numbers.
local statuses = {
  added_status,
  { "removed", "D", "HunksDeletedFiles" },
  { "modified", "M", "HunksModifiedFiles" },
  { "renamed", "R", "HunksRenamedFiles" },
  { "copied", "C", "HunksRenamedFiles" },
}

--- Returns the segments summarizing a set of files, like `1A, 2M, +20 -4`:
--- how many were added, deleted, modified, renamed and copied, and the lines
--- added and deleted.
---@param files nvim_hunks.File[]
---@return trouble.Format[]
local summary = function(files)
  ---@type table<string, integer?>
  local counts_by_status = {}
  local all = {}
  for _, file in ipairs(files) do
    counts_by_status[file.status] = (counts_by_status[file.status] or 0) + 1
    vim.list_extend(all, file.hunks)
  end

  local segments = {}
  for _, status in ipairs(statuses) do
    local count = counts_by_status[status[1]]
    if count then
      if #segments > 0 then segments[#segments + 1] = { text = ", " } end
      segments[#segments + 1] = { text = count .. status[2], hl = status[3] }
    end
  end

  local lines = counts(all)
  if #lines > 0 then
    -- The counts of lines start with a space.
    if #segments == 0 then lines[1].text = lines[1].text:sub(2) end
    if #segments > 0 then segments[#segments + 1] = { text = "," } end
    vim.list_extend(segments, lines)
  end
  return segments
end

---@class nvim_hunks.trouble.Segment
---@field text string
---@field hl? string|string[]

--- The captures of the highlights query that aren't highlights.
local unhighlighted_captures = { conceal = true, nospell = true, spell = true }

--- Returns the segments of a subject shortened to a width, with its inline
--- markdown highlighted and concealed like Neovim's highlights query does.
---@param subject string
---@param max_width integer
---@return nvim_hunks.trouble.Segment[]
local subject_segments = function(subject, max_width)
  -- The concealed bytes, the texts shown instead from their first bytes on,
  -- and the highlights of each byte.
  ---@type table<integer, true?>, table<integer, string?>, table<integer, string[]?>
  local hidden, replacements, highlights = {}, {}, {}
  local ok, parser =
    pcall(vim.treesitter.get_string_parser, subject, "markdown_inline")
  local query = ok and vim.treesitter.query.get("markdown_inline", "highlights")
  if ok and query then
    local root = parser:parse()[1]:root()
    for id, node, metadata in query:iter_captures(root, subject) do
      local name = assert(query.captures[id])
      local range = vim.treesitter.get_range(node, subject, metadata[id])
      local start, finish = range[3], range[6]
      local conceal = metadata.conceal or (metadata[id] or {}).conceal
      local hl_group = not name:match("^_")
        and not unhighlighted_captures[name]
        and ("@%s.markdown_inline"):format(name)
      for byte = start + 1, finish do
        if type(conceal) == "string" then hidden[byte] = true end
        if hl_group then
          local groups = highlights[byte] or {}
          groups[#groups + 1] = hl_group
          highlights[byte] = groups
        end
      end
      if type(conceal) == "string" and conceal ~= "" then
        replacements[start + 1] = conceal
      end
    end
  end

  ---@param byte integer
  ---@return string
  local key_of = function(byte) return table.concat(highlights[byte] or {}, ",") end

  ---@type nvim_hunks.trouble.Segment[]
  local segments = {}
  local byte = 1
  while byte <= #subject do
    if hidden[byte] then
      local replacement = replacements[byte]
      if replacement then
        segments[#segments + 1] = { text = replacement, hl = highlights[byte] }
      end
      byte = byte + 1
    else
      local first, key = byte, key_of(byte)
      while byte <= #subject and not hidden[byte] and key_of(byte) == key do
        byte = byte + 1
      end
      segments[#segments + 1] = {
        text = subject:sub(first, byte - 1),
        hl = highlights[first],
      }
    end
  end

  ---@type nvim_hunks.trouble.Segment[]
  local shortened, width = {}, 0
  for _, segment in ipairs(segments) do
    local segment_width = vim.api.nvim_strwidth(segment.text)
    if width + segment_width > max_width then
      local kept = math.max(max_width - width - 1, 0)
      shortened[#shortened + 1] = {
        text = vim.fn.strcharpart(segment.text, 0, kept) .. "…",
        hl = segment.hl,
      }
      return shortened
    end
    width = width + segment_width
    shortened[#shortened + 1] = segment
  end
  return shortened
end

--- The files of the last listing.
---@type nvim_hunks.File[]
local listed = {}

--- The working-copy commit of the listed workspace, if only one is listed.
---@type nvim_hunks.Revision?
local working_copy

--- The floats showing the recap of each open list of hunks at its top-right
--- corner, keyed by the list's window.
---@type table<integer, integer>
local recaps = {}

local recap_namespace = vim.api.nvim_create_namespace("nvim-hunks-recap")

--- Returns the lines of the recap of the listed files, each as its segments:
--- the working-copy commit's subject, shortened to the given width, its IDs
--- and bookmarks, and the counts of changed files and lines.
---@param max_width integer
---@return nvim_hunks.trouble.Segment[][]
local recap_lines = function(max_width)
  local lines = {}

  if working_copy then
    local subject = working_copy.description
    lines[#lines + 1] = subject ~= "" and subject_segments(subject, max_width)
      or { { text = "(no description set)", hl = "Comment" } }

    local change_id, commit_id = working_copy.change_id, working_copy.commit_id
    local ids = {
      { text = change_id.prefix, hl = "HunksChangeId" },
      { text = change_id.rest .. " ", hl = "HunksChangeIdRest" },
      { text = commit_id.prefix .. commit_id.rest, hl = "HunksChangeIdRest" },
    }
    for _, bookmark in ipairs(working_copy.bookmarks) do
      ids[#ids + 1] = { text = " " }
      ids[#ids + 1] = { text = bookmark, hl = "HunksBookmark" }
    end
    lines[#lines + 1] = ids
  end

  if #listed > 0 then lines[#lines + 1] = summary(listed) end

  return lines
end

--- Draws the recap of the listed files at the top-right corner of a list of
--- hunks, with each of its lines aligned to the right and a column of padding
--- on each side.
---@param list_win integer
local draw_recap = function(list_win)
  local list_width = vim.api.nvim_win_get_width(list_win)
  local lines = recap_lines(math.max(math.floor(list_width / 2), 10))
  local recap = recaps[list_win]
  if #lines == 0 then
    if recap and vim.api.nvim_win_is_valid(recap) then
      vim.api.nvim_win_close(recap, true)
    end
    recaps[list_win] = nil
    return
  end

  local widths, width = {}, 0
  for idx, segments in ipairs(lines) do
    widths[idx] = 0
    for _, segment in ipairs(segments) do
      widths[idx] = widths[idx] + vim.api.nvim_strwidth(segment.text)
    end
    width = math.max(width, widths[idx])
  end
  width = math.max(math.min(width, list_width - 2), 1)

  local buf = recap
      and vim.api.nvim_win_is_valid(recap)
      and vim.api.nvim_win_get_buf(recap)
    or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local texts, marks = {}, {}
  for idx, segments in ipairs(lines) do
    local text = (" "):rep(math.max(width - widths[idx], 0))
    for _, segment in ipairs(segments) do
      if segment.hl then
        marks[#marks + 1] =
          { idx - 1, #text, #text + #segment.text, segment.hl }
      end
      text = text .. segment.text
    end
    texts[idx] = text
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
  vim.api.nvim_buf_clear_namespace(buf, recap_namespace, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, recap_namespace, mark[1], mark[2], {
      end_col = mark[3],
      hl_group = mark[4],
    })
  end

  ---@type vim.api.keyset.win_config
  local config = {
    relative = "win",
    win = list_win,
    anchor = "NE",
    row = 0,
    col = list_width,
    width = width,
    height = #lines,
    focusable = false,
    style = "minimal",
    border = { "", "", "", " ", "", "", "", " " },
  }
  if recap and vim.api.nvim_win_is_valid(recap) then
    vim.api.nvim_win_set_config(recap, config)
  else
    config.noautocmd = true
    recap = vim.api.nvim_open_win(buf, false, config)
    vim.wo[recap].winhighlight =
      "Normal:HunksRecap,NormalFloat:HunksRecap,FloatBorder:HunksRecap"
    recaps[list_win] = recap
  end
end

--- Returns the window of a list of hunks, if it's open.
---@param view trouble.View
---@return integer?
local list_win = function(view)
  local win = view.win.win --[[@as integer?]]
  return win and vim.api.nvim_win_is_valid(win) and win or nil
end

--- Returns whether a window shows a list of hunks. A window keeps trouble's
--- variable when trouble jumps from the list it showed to a file in it.
---@param win integer
---@return boolean
local is_list = function(win)
  local trouble = vim.w[win].trouble
  return trouble ~= nil
    and trouble.mode == "hunks"
    and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "trouble"
end

--- Returns the rows a list of hunks shows, from the top.
---@param view trouble.View
---@return trouble.Render.Location[]
local rows_of = function(view)
  local rows = {}
  local win = list_win(view)
  if not win then return rows end
  for row = 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) do
    rows[row] = view:at({ row, 0 })
  end
  return rows
end

--- Draws the recaps of the open lists of hunks.
local draw_recaps = function()
  for _, open in ipairs(require("trouble.view").get({ mode = "hunks" })) do
    local win = list_win(open.view)
    if win then draw_recap(win) end
  end
end

M.config = {
  formatters = {
    hunks_row = function(ctx)
      ---@type nvim_hunks.trouble.Entry
      local entry = ctx.item.item
      local file, hunk = entry.file, entry.hunk

      if hunk then
        local first = first_line(hunk)
        local last = first + hunk.new_count - 1
        local range = last > first and ("L%d-%d"):format(first, last)
          or ("L%d"):format(first)
        return vim.list_extend({ { text = range } }, counts({ hunk }))
      end

      local segments = { Format.formatters.file_icon(ctx), { text = " " } }
      if file.status == "renamed" then
        segments[#segments + 1] = { text = assert(file.old_path) .. " → " }
      end
      segments[#segments + 1] = {
        text = file.path,
        hl = file.status == "added" and "HunksAddedCount"
          or file.status == "removed" and "HunksDeletedCount"
          or "TroubleFilename",
      }
      vim.list_extend(segments, counts(file.hunks))

      local tag = file.binary and "binary"
        or file.status == "removed" and "deleted"
        or file.status == "copied" and "copied"
        or nil
      if tag then
        segments[#segments + 1] =
          { text = (" (%s)"):format(tag), hl = "Comment" }
      end
      return segments
    end,
  },
  modes = {
    hunks = {
      desc = "Hunks of the working-copy change",
      source = "hunks",
      events = {
        {
          event = "User",
          pattern = {
            "NvimHunksChanged",
            "NvimHunksFilesChanged",
            listed_event,
          },
        },
      },
      groups = {},
      sort = {},
      format = "{hunks_row}",
      -- A listing can take longer than trouble waits for it, so the list
      -- says itself when there's nothing to list.
      warn_no_results = false,
      -- The list follows the cursor itself, except while it opens.
      follow = false,
      -- The preview covers the main window, but not the floats on it with
      -- the default z-index, like incline.nvim's.
      preview = { zindex = 49 },
    },
  },
}

--- Returns the row of a file, or of one of its hunks nested under the
--- file's row.
---@param file nvim_hunks.File
---@param hunk? nvim_hunks.Hunk
---@param parent? trouble.Item The row of the file.
---@return trouble.Item
local new_item = function(file, hunk, parent)
  local filename = vim.fs.joinpath(file.root, file.path)
  -- A file's row is at its first hunk, which its preview shows.
  local shown = hunk or file.hunks[1]
  local line = shown and first_line(shown) or 1
  local last = hunk and math.max(line + hunk.new_count - 1, line) or line

  local bufnr = file.status == "removed" and hunks.deleted_buffer(file)
    or vim.fn.bufnr(filename)
  local buf = bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) and bufnr or nil

  return Item.new({
    id = hunk and ("%s:%d:%d"):format(filename, hunk.old_start, hunk.new_start)
      or filename,
    buf = buf,
    filename = filename,
    pos = { line, 0 },
    end_pos = { last, 0 },
    -- A file's row covers the whole file, and its hunks' rows come after it.
    range = not hunk and {
      pos = { 1, 0 },
      end_pos = { math.max(#file.lines, 1), 0 },
    } or nil,
    item = { file = file, hunk = hunk },
    parent = parent,
    source = "hunks",
  })
end

--- The roots of the jj workspaces listed while the list is open: the one
--- containing the working directory it was opened in.
---@type string[]?
local roots

--- The folded rows of the lists of hunks, keyed by node ID, which stay folded
--- when a list is closed and opened again. The IDs of the files' rows are
--- their paths.
---@type table<string, true>
local folds = {}

--- The IDs of the rows of the files listed since Neovim started, whose rows
--- keep their folds when the list opens again.
---@type table<string, true?>
local known_files = {}

--- Returns the row of the hunk containing a buffer's line, or else the row
--- of the buffer's file, if it's listed.
---@param items trouble.Item[]
---@param buf integer
---@param line integer The 1-based line.
---@return trouble.Item?
local row_at = function(items, buf, line)
  local name = vim.api.nvim_buf_get_name(buf)
  ---@type trouble.Item?
  local found
  for _, item in ipairs(items) do
    local range = item.range
      or { pos = item.pos, end_pos = item.end_pos or item.pos }
    if
      (item.buf == buf or item.filename == name)
      and line >= range.pos[1]
      and line <= range.end_pos[1]
    then
      found = item
    end
  end
  return found
end

--- The ids of the rows of the files listed since the list was opened.
---@type table<string, true>
local listed_files = {}

--- The longest a list of hunks takes to show its rows after getting them.
local open_timeout_ms = 2000

--- Calls back with the open list of hunks once it shows one of the given
--- items, and is focused if asked to.
---@param items table<trouble.Item, true>
---@param focused boolean
---@param on_shown fun(view: trouble.View)
local when_shown = function(items, focused, on_shown)
  local timer = assert(vim.uv.new_timer())
  local deadline = vim.uv.now() + open_timeout_ms
  timer:start(
    10,
    10,
    vim.schedule_wrap(function()
      if timer:is_closing() then return end
      local done = vim.uv.now() > deadline
      for _, open in ipairs(require("trouble.view").get({ mode = "hunks" })) do
        local view = open.view
        local win = list_win(view)
        local is_ready = win
          and (not focused or win == vim.api.nvim_get_current_win())
        if is_ready and not done then
          for _, location in pairs(rows_of(view)) do
            if location.item and items[location.item] then
              done = true
              on_shown(view)
              break
            end
          end
        end
      end
      if done then timer:close() end
    end)
  )
end

--- The lists of hunks whose previews are turned off while their cursors are
--- moved, with the `auto_preview` options to restore.
---@type table<trouble.View, boolean>
local previews_off = setmetatable({}, { __mode = "k" })

--- Calls a function that moves the cursor of a focused list of hunks,
--- without previewing the item it moves to. The preview is turned back on
--- once the move is reported, after trouble's own handler skipped it, or
--- right away if the cursor didn't move.
---@param view trouble.View
---@param move fun()
local without_preview = function(view, move)
  local win = list_win(view)
  if not win then return move() end

  local cursor = vim.api.nvim_win_get_cursor(win)
  if previews_off[view] == nil then
    previews_off[view] = view.opts.auto_preview
  end
  view.opts.auto_preview = false
  move()

  local restore = function()
    if previews_off[view] == nil then return end
    view.opts.auto_preview = previews_off[view]
    previews_off[view] = nil
  end
  local moved = vim.api.nvim_win_is_valid(win)
    and win == vim.api.nvim_get_current_win()
    and not vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
  if not moved then return restore() end
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = vim.api.nvim_win_get_buf(win),
    once = true,
    callback = restore,
  })
end

--- Moves the cursor of a list of hunks to an item's row.
---@param view trouble.View
---@param target trouble.Item
local move_cursor_to = function(view, target)
  local win = list_win(view)
  if not win then return end
  for row, location in ipairs(rows_of(view)) do
    if location.item == target then
      return vim.api.nvim_win_set_cursor(win, { row, 0 })
    end
  end
end

--- Collapses the rows of the files that are new to the list, or of all files
--- whose folds aren't known when the list is opening, and expands the row of
--- the given file.
---@param view trouble.View
---@param new_files table<trouble.Item, true>
---@param is_opening boolean
---@param expanded? nvim_hunks.File
local collapse_files = function(view, new_files, is_opening, expanded)
  for _, location in pairs(rows_of(view)) do
    local item, node = location.item, location.node
    local is_file = item and node and not item.item.hunk and not node:is_leaf()
    if item and node and is_file then
      if item.item.file == expanded then
        view.renderer:fold(node, { action = "open" })
      elseif (is_opening or new_files[item]) and not known_files[item.id] then
        view.renderer:fold(node, { action = "close" })
      end
      known_files[item.id] = true
    end
  end
  -- A view's own `render` is throttled, and the rows are needed right away.
  require("trouble.view").render(view)
end

--- Calls a function once the window of a list of hunks is created, before
--- it's drawn.
---@param view trouble.View
---@param on_mounted fun()
local when_mounted = function(view, on_mounted)
  local opts = view.win.opts
  local on_mount = opts.on_mount
  opts.on_mount = function(win)
    opts.on_mount = on_mount
    if on_mount then on_mount(win) end
    on_mounted()
  end
end

---@class nvim_hunks.trouble.Listing
---@field items trouble.Item[]
---@field new_files table<trouble.Item, true> The rows of the files new to the list.

--- The rows the lists of hunks show while the next listing runs.
---@type trouble.Item[]
local shown_items = {}

--- The listing done since the lists of hunks were last refreshed.
---@type nvim_hunks.trouble.Listing?
local ready

--- Whether a listing is running, and whether another one is due once it's
--- done.
local is_listing, is_listing_due = false, false

--- The number of times the list was closed, which discards the listings that
--- were running then.
local generation = 0

---@class nvim_hunks.trouble.Opening
---@field main? trouble.Main The window the list is opened from.
---@field view? trouble.View
--- The callback of the refresh opening the list, which gets the first listing.
---@field cb? fun(items: trouble.Item[])

--- The list that's opening, until it shows its first listing.
---@type nvim_hunks.trouble.Opening?
local opening

--- Forgets the listings, and stops showing all diffs.
local reset = function()
  roots = nil
  listed_files = {}
  listed = {}
  working_copy = nil
  shown_items = {}
  ready = nil
  is_listing, is_listing_due = false, false
  opening = nil
  generation = generation + 1
  if hunks.is_showing_all() then hunks.show_all(false) end
end

--- Turns the changed files into the rows of the list.
---@param files nvim_hunks.File[]
---@return nvim_hunks.trouble.Listing
local listing_of = function(files)
  local items = {}
  ---@type table<trouble.Item, true>
  local new_files = {}
  for _, file in ipairs(files) do
    local file_item = new_item(file)
    items[#items + 1] = file_item
    if not listed_files[file_item.id] then
      listed_files[file_item.id] = true
      new_files[file_item] = true
    end
    if file.status == "modified" or file.status == "renamed" then
      for _, hunk in ipairs(file.hunks) do
        items[#items + 1] = new_item(file, hunk, file_item)
      end
    end
  end
  return { items = items, new_files = new_files }
end

--- Gives a listing to trouble, then places the cursor of a list that's
--- opening and collapses the rows of new files.
---@param listing nvim_hunks.trouble.Listing
---@param cb fun(items: trouble.Item[])
local show = function(listing, cb)
  shown_items = listing.items
  cb(listing.items)

  local opened = opening
  opening = nil
  local main = opened and opened.main
  ---@type trouble.Item?
  local target
  if main then
    local line = main.cursor[1] --[[@as integer]]
    target = row_at(listing.items, main.buf --[[@as integer]], line)
  end
  ---@type table<trouble.Item, true>
  local batch = {}
  for _, item in ipairs(listing.items) do
    batch[item] = true
  end
  when_shown(batch, opened ~= nil, function(view)
    local win = list_win(view)
    if win then draw_recap(win) end
    if not opened then return collapse_files(view, listing.new_files, false) end
    -- Only placing the cursor moves it to another item.
    without_preview(view, function()
      collapse_files(view, listing.new_files, true, target and target.item.file)
      -- Without a row under the main window's cursor, trouble's `restore`
      -- option puts the cursor back on the row it was last on.
      if target then move_cursor_to(view, target) end
    end)
  end)
end

--- Lists the changed files in the background. The first listing goes to the
--- list that's opening, and the others refresh the lists when they're done.
local list = function()
  is_listing = true
  local listed_generation = generation
  local listed_roots = assert(roots)
  ---@type fun()
  local run
  run = function()
    hunks.files(listed_roots, function(files)
      if generation ~= listed_generation then return end
      if #listed_roots == 1 then
        hunks.working_copy(listed_roots[1], function(revision)
          if generation ~= listed_generation then return end
          working_copy = revision
          draw_recaps()
        end)
      else
        working_copy = nil
      end
      listed = files
      local listing = listing_of(files)
      local opened = opening
      local view = opened and opened.view
      local opening_cb = opened and opened.cb
      if opening_cb and #listing.items == 0 then
        opening_cb(listing.items)
        vim.notify(
          "No results for **hunks**",
          vim.log.levels.WARN,
          { title = "Trouble" }
        )
        return reset()
      elseif
        opening_cb
        and opened
        and view
        and not view.first_update:is_pending()
      then
        -- trouble stops waiting for the first listing after a timeout, so the
        -- list opens again with the listing ready.
        ready = listing
        opened.cb = nil
        view:open()
        -- Like `trouble.open()`, the list is focused unless told otherwise.
        if
          view.opts.focus --[[@as boolean?]]
          ~= false
        then
          view:wait(function() view.win:focus() end)
        end
      elseif opening_cb then
        show(listing, opening_cb)
      else
        ready = listing
        vim.api.nvim_exec_autocmds("User", { pattern = listed_event })
      end

      -- The listing requested while this one ran starts after it's shown.
      if is_listing_due then
        is_listing_due = false
        run()
        return
      end
      is_listing = false
    end)
  end
  run()
end

--- Lists every changed file, with the hunks of the modified and renamed ones
--- nested under it, collapsed. A list that's opening starts on the hunk or
--- file under the cursor of the window it's opened from, with only that file
--- expanded. The listed workspaces are the ones around the list's `cwd`
--- option, or else the current working directory when it opens. With the
--- `center` option, the window it's opened from has its cursor line centered.
---
--- The list opens with its first listing. Afterwards it shows the rows of the
--- previous listing while the next one runs in the background.
---@param cb fun(items: trouble.Item[])
---@param ctx { main?: trouble.Main, opts: { cwd?: string, center?: boolean } }
M.get = function(cb, ctx)
  -- The lists that didn't open, like the ones without changes, keep
  -- refreshing on the lists' events.
  local views = require("trouble.view").get({ mode = "hunks" })
  if #views == 0 and not opening and not ready then return cb({}) end
  for _, open in ipairs(views) do
    open.view.renderer._folded = folds
  end

  if roots == nil then
    local root = hunks.workspace(ctx.opts.cwd)
    if not root then
      vim.notify(
        "Not in a jj workspace",
        vim.log.levels.ERROR,
        { title = "nvim-hunks" }
      )
      return cb({})
    end
    roots = { root }
    hunks.show_all(true)

    ---@type trouble.View?
    local view
    for _, open in ipairs(require("trouble.view").get({ mode = "hunks" })) do
      if not list_win(open.view) then view = open.view end
    end
    opening = { main = ctx.main, view = view }

    local main_win = ctx.main and ctx.main.win --[[@as integer?]]
    if view and ctx.opts.center and main_win then
      when_mounted(view, function()
        if not vim.api.nvim_win_is_valid(main_win) then return end
        vim.api.nvim_win_call(
          main_win,
          function() vim.cmd.normal({ "zz", bang = true }) end
        )
      end)
    end
  end

  if ready then
    local listing = ready
    ready = nil
    return show(listing, cb)
  end

  -- An opening list shows up with its first listing, or else with trouble's
  -- message that there's nothing to list.
  if opening and not opening.cb then
    opening.cb = cb
  else
    cb(shown_items)
  end
  if is_listing then
    is_listing_due = true
  else
    list()
  end
end

--- Draws the hunks on a preview, laid out for the preview's window, and
--- removes trouble's highlights of the item, which cover the hunk's colors.
---@param item trouble.Item
---@param ctx { win: integer, buf: integer }
M.preview = function(item, ctx)
  vim.wo[ctx.win].cursorline = false
  vim.api.nvim_buf_clear_namespace(
    ctx.buf,
    require("trouble.view.render").ns,
    0,
    -1
  )
  ---@type nvim_hunks.File?
  local file = item.item.file
  if file and file.status ~= "removed" and not hunks.is_shown(ctx.buf) then
    -- The preview of a file that isn't loaded is a scratch buffer, whose lines
    -- trouble splits from the file's text with an extra empty line after the
    -- last newline.
    if ctx.buf ~= vim.fn.bufnr(item.filename) then
      vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, file.lines)
    end
    hunks.render_file(ctx.buf, file, ctx.win)
  else
    -- trouble shows the buffer without the autocommands redrawing it for
    -- the preview's window.
    hunks.redraw(ctx.buf, ctx.win)
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(ctx.win),
      once = true,
      desc = "Redraws the previewed buffer for the windows still showing it",
      callback = vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(ctx.buf) then hunks.redraw(ctx.buf) end
      end),
    })
  end
end

--- Returns the changes of rows of a list of hunks: the whole files of file
--- rows, and the hunks of hunk rows, except the ones of those files.
---@param nodes trouble.Node[]
---@return nvim_hunks.File[] files
---@return nvim_hunks.HunkSelection[] selections
local changes_of = function(nodes)
  ---@type nvim_hunks.File[], table<nvim_hunks.File, true?>
  local files, whole = {}, {}
  ---@param file nvim_hunks.File
  local add_file = function(file)
    if whole[file] then return end
    whole[file] = true
    files[#files + 1] = file
  end

  ---@type nvim_hunks.HunkSelection[], table<nvim_hunks.File, nvim_hunks.HunkSelection?>
  local selections, by_file = {}, {}
  for _, node in ipairs(nodes) do
    ---@type nvim_hunks.trouble.Entry?
    local entry = node.item and node.item.item --[[@as nvim_hunks.trouble.Entry?]]
    if entry and entry.file and entry.hunk then
      local selection = by_file[entry.file]
      if not selection then
        selection = { file = entry.file, hunks = {} }
        by_file[entry.file] = selection
        selections[#selections + 1] = selection
      end
      table.insert(selection.hunks, entry.hunk)
    elseif entry and entry.file then
      add_file(entry.file)
    end
  end

  selections = vim.tbl_filter(
    function(selection) return not whole[selection.file] end,
    selections
  )
  return files, selections
end

--- Moves the changes of rows of a list of hunks into another revision: the
--- whole files of file rows, and the hunks of hunk rows, except the ones of
--- files moved whole.
---@param nodes trouble.Node[]
---@param into string
M.move = function(nodes, into)
  local files, selections = changes_of(nodes)
  if #files == 0 and #selections == 0 then return end
  hunks.move_many(files, selections, into)
end

--- Drops the changes of rows of a list of hunks from the working-copy commit:
--- the whole files of file rows, and the hunks of hunk rows, except the ones
--- of files dropped whole.
---@param nodes trouble.Node[]
M.drop = function(nodes)
  local files, selections = changes_of(nodes)
  if #files == 0 and #selections == 0 then return end
  hunks.drop_many(files, selections)
end

local list_namespace = vim.api.nvim_create_namespace("nvim-hunks-list")

--- The lists of hunks being drawn, keyed by their windows.
---@type table<integer, trouble.View?>
local drawn_lists = {}

-- The rows of added files have no hunks to fold, so their chevrons' cells
-- show the files' letter in the recap instead.
vim.api.nvim_set_decoration_provider(list_namespace, {
  on_win = function(_, win)
    drawn_lists[win] = nil
    local trouble = vim.w[win].trouble
    if not (trouble and trouble.mode == "hunks") then return false end
    for _, open in ipairs(require("trouble.view").get({ mode = "hunks" })) do
      if list_win(open.view) == win then drawn_lists[win] = open.view end
    end
    return drawn_lists[win] ~= nil
  end,
  on_line = function(_, win, bufnr, row)
    local view = drawn_lists[win]
    local item = view and view.renderer:at(row + 1).item
    local entry = item and item.item --[[@as nvim_hunks.trouble.Entry?]]
    if not entry or entry.hunk or entry.file.status ~= "added" then return end
    vim.api.nvim_buf_set_extmark(bufnr, list_namespace, row, 1, {
      virt_text = { { added_status[2], added_status[3] } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      ephemeral = true,
    })
  end,
})

local group =
  vim.api.nvim_create_augroup("nvim-hunks-trouble", { clear = true })

vim.api.nvim_create_autocmd("WinResized", {
  group = group,
  desc = "Keeps the recaps at the top-right corners of the lists of hunks",
  callback = function()
    for _, win in ipairs(vim.v.event.windows or {}) do
      if recaps[win] and vim.api.nvim_win_is_valid(win) then draw_recap(win) end
    end
  end,
})

vim.api.nvim_create_autocmd("CursorMoved", {
  group = group,
  desc = "Moves the cursors of the lists of hunks to the row under the cursor",
  callback = function(ev)
    local win = vim.api.nvim_get_current_win()
    if
      opening
      or vim.bo[ev.buf].filetype == "trouble"
      or vim.w[win].trouble_preview
    then
      return
    end
    local found =
      row_at(shown_items, ev.buf, vim.api.nvim_win_get_cursor(win)[1])
    if not found then return end

    -- Moving the cursor of a list that isn't focused doesn't preview the row
    -- under it. A collapsed file's row stands for the rows of its hunks.
    for _, open in ipairs(require("trouble.view").get({ mode = "hunks" })) do
      local list = list_win(open.view)
      ---@type integer?, integer?
      local row, file_row
      for idx, location in ipairs(list and rows_of(open.view) or {}) do
        if location.item == found then row = idx end
        if found.parent and location.item == found.parent then
          file_row = idx
        end
      end
      row = row or file_row
      if list and row then vim.api.nvim_win_set_cursor(list, { row, 0 }) end
    end
  end,
})

vim.api.nvim_create_autocmd({ "WinClosed", "BufWinEnter" }, {
  group = group,
  desc = "Moves the recaps to the windows of the lists of hunks, and stops showing all diffs once none is open",
  -- The closed window is still valid while WinClosed runs, and trouble would
  -- refresh the list in it.
  callback = vim.schedule_wrap(function()
    for list_win, recap in pairs(recaps) do
      if not vim.api.nvim_win_is_valid(list_win) or not is_list(list_win) then
        if vim.api.nvim_win_is_valid(recap) then
          vim.api.nvim_win_close(recap, true)
        end
        recaps[list_win] = nil
      end
    end
    -- trouble opens a list again in a new window after jumping to an item in
    -- its window.
    for _, open in ipairs(require("trouble.view").get({ mode = "hunks" })) do
      local win = list_win(open.view)
      if win and not recaps[win] then draw_recap(win) end
    end

    -- A list that's opening has no window until its first listing.
    if not roots or opening then return end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if is_list(win) then return end
    end
    reset()
  end),
})

return M
