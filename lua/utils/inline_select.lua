local logos = require("utils.logos")

local M = {}

local ns = vim.api.nvim_create_namespace("noib3/inline-select")

--- The keys moving the selection to the next item, as `keytrans()` names them.
local next_keys =
  { ["j"] = true, ["<Down>"] = true, ["<C-N>"] = true, ["<Tab>"] = true }

--- The keys moving the selection to the previous item, as `keytrans()` names
--- them.
local prev_keys =
  { ["k"] = true, ["<Up>"] = true, ["<C-P>"] = true, ["<S-Tab>"] = true }

--- The keys picking no item, as `keytrans()` names them.
local cancel_keys = { ["<Esc>"] = true, ["<C-C>"] = true }

--- The chevron before the selected item.
local chevron = "▸ "

--- Returns the 0-based byte column at which the token on a position of a
--- buffer starts. The token is treesitter's leaf node there, or the keyword
--- there in a buffer without a parser. The column is the position's own one
--- if there's no such token, or if the token starts on an earlier line.
---@param bufnr integer
---@param row integer The 0-based line.
---@param col integer The 0-based byte column.
---@return integer
local token_start = function(bufnr, row, col)
  local parser = vim.treesitter.get_parser(bufnr, nil, { error = false })
  if parser then
    parser:parse({ row, row + 1 })
    local node = vim.treesitter.get_node({
      bufnr = bufnr,
      pos = { row, col },
      ignore_injections = false,
      include_anonymous = true,
    })
    if not node or node:child_count() > 0 then return col end
    local start_row, start_col = node:start()
    return start_row == row and start_col or col
  end

  local line = assert(vim.api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1])
  if vim.fn.match(vim.fn.strpart(line, col, 1, 1), [[\k]]) ~= 0 then
    return col
  end
  return vim.fn.match(line:sub(1, col), [[\k*$]])
end

--- Returns the name of the highlight group of a logo, defining the group with
--- the logo's color.
---@param name string
---@param color string
---@return string
local logo_hl = function(name, color)
  local group = "InlineSelectLogo_" .. name
  vim.api.nvim_set_hl(0, group, { fg = color, default = true })
  return group
end

--- Returns the chunks of a virtual line showing a text in a highlight group,
--- with the logos that have a brand color in that color.
---@param text string
---@param hl? string
---@return [string, (string|string[])?][]
local virt_line = function(text, hl)
  local chunks = {}
  local start = 1
  while true do
    ---@type integer?, integer, string
    local first, last, group
    for name, logo in pairs(logos) do
      if logo.color then
        local s = text:find(logo.icon, start, true)
        if s and (not first or s < first) then
          first, last = s, s + #logo.icon - 1
          group = logo_hl(name, logo.color)
        end
      end
    end
    if not first then break end
    if first > start then
      chunks[#chunks + 1] = { text:sub(start, first - 1), hl }
    end
    chunks[#chunks + 1] =
      { text:sub(first, last), hl and { hl, group } or group }
    start = last + 1
  end
  if start <= #text then chunks[#chunks + 1] = { text:sub(start), hl } end
  return chunks
end

---@class utils.InlineSelectOpts
---@field format_item? fun(item: any): string
---@field prefix? [string, string][] The virtual text chunks at the start of every line.

--- Picks one of some items from virtual lines below the cursor, with the
--- interface of `vim.ui.select`. The lines start with the `prefix` option's
--- chunks, followed by the items. Without a prefix, the items start at the
--- column of the token under the cursor. The first item starts out selected,
--- and the selected one is highlighted with `CursorLine` past the prefix and
--- has a chevron before it, highlighted with `InlineSelectChevron`. `j`,
--- `<Down>`, `<C-n>` and `<Tab>` select the next item, `k`, `<Up>`, `<C-p>`
--- and `<S-Tab>` the previous one, `<CR>` picks the selected item, and `<Esc>`
--- or `<C-c>` picks nothing. Any other key, `<Up>` on the first item and
--- `<Down>` on the last one pick nothing too, and then go through to the
--- buffer.
---@generic T
---@param items T[]
---@param opts utils.InlineSelectOpts
---@param on_choice fun(item?: T, idx?: integer)
M.select = function(items, opts, on_choice)
  if #items == 0 then return on_choice(nil, nil) end

  local format_item = opts.format_item or tostring
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local view = vim.fn.winsaveview()

  local chevron_width = vim.fn.strdisplaywidth(chevron)
  local prefix = opts.prefix or {}
  local indent = ""
  if not opts.prefix then
    local info = assert(vim.fn.getwininfo(win)[1])
    local col = token_start(bufnr, row, cursor[2])
    -- `curscol` skips the inline virtual text before the token, unlike `col`.
    local pos = vim.fn.screenpos(win, row + 1, col + 1)
    indent = (" "):rep(
      math.max(pos.curscol - info.wincol - info.textoff - chevron_width, 0)
    )
  end
  local no_chevron = (" "):rep(chevron_width)
  vim.api.nvim_set_hl(0, "InlineSelectChevron", {
    link = "Comment",
    default = true,
  })

  -- Scroll the window down if the lines would go past its bottom.
  local height = vim.api.nvim_win_text_height(win, {
    start_row = view.topline - 1,
    end_row = row,
  }).all + #items
  local overflow = height - vim.api.nvim_win_get_height(win)
  if overflow > 0 then
    local hidden = vim.api.nvim_win_text_height(win, {
      start_row = view.topline - 1,
      max_height = overflow,
    }).end_row
    vim.fn.winrestview({ topline = math.min(hidden + 2, row + 1) })
  end

  vim.api.nvim__ns_set(ns, { wins = { win } })

  local selected = 1
  local mark
  local ok, choice, passed_key = pcall(function()
    while true do
      local lines = {}
      for idx, item in ipairs(items) do
        local hl = idx == selected and "CursorLine" or nil
        local line = vim.list_extend({}, prefix)
        line[#line + 1] = { indent, hl }
        line[#line + 1] = hl and { chevron, { hl, "InlineSelectChevron" } }
          or { no_chevron }
        vim.list_extend(line, virt_line(format_item(item), hl))
        if hl then line[#line + 1] = { "", hl } end
        lines[idx] = line
      end
      mark = vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
        id = mark,
        virt_lines = lines,
      })
      vim.cmd.redraw()

      local char = vim.fn.getcharstr()
      local key = vim.fn.keytrans(char)
      if key == "<CR>" then
        return selected
      elseif cancel_keys[key] then
        return nil
      elseif
        next_keys[key] and not (key == "<Down>" and selected == #items)
      then
        selected = selected % #items + 1
      elseif prev_keys[key] and not (key == "<Up>" and selected == 1) then
        selected = (selected - 2) % #items + 1
      else
        return nil, char
      end
    end
  end)

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
  end
  vim.cmd.redraw()

  if not ok then
    -- `<C-c>` can interrupt `getcharstr()` instead of being returned by it.
    if not tostring(choice):find("Keyboard interrupt") then error(choice) end
    choice = nil
  end
  on_choice(choice and items[choice], choice)
  if passed_key then vim.api.nvim_feedkeys(passed_key, "t", false) end
end

return M
