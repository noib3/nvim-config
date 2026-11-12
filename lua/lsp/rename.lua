local buffer = require("utils.buffer")
local window = require("utils.window")

local M = {}

--- The namespace of the new name drawn over the occurrences of the renamed
--- symbol.
local preview_ns = vim.api.nvim_create_namespace("noib3/rename-preview")

--- The namespace of the virtual line under the float.
local line_ns = vim.api.nvim_create_namespace("noib3/rename-line")

---@class lsp.rename.Occurrence
---@field bufnr integer
---@field row integer The 0-based line.
---@field col integer The 0-based byte column.
---@field end_row integer The 0-based line.
---@field end_col integer The 0-based, exclusive byte column.

--- Requests the references to the symbol at the cursor of a window from the
--- language servers of its buffer, and calls back with the ones in loaded
--- buffers.
---@param win integer
---@param on_done fun(occurrences: lsp.rename.Occurrence[])
local fetch_occurrences = function(win, on_done)
  local bufnr = vim.api.nvim_win_get_buf(win)
  vim.lsp.buf_request_all(
    bufnr,
    "textDocument/references",
    function(client)
      return vim.tbl_extend(
        "force",
        vim.lsp.util.make_position_params(win, client.offset_encoding),
        { context = { includeDeclaration = true } }
      )
    end,
    function(results)
      ---@type lsp.rename.Occurrence[]
      local occurrences = {}
      ---@type table<string, true?>
      local seen = {}
      for client_id, response in pairs(results) do
        local client = vim.lsp.get_client_by_id(client_id)
        local locations = response.result
        if client and locations then
          local items = vim.lsp.util.locations_to_items(
            locations --[[@as lsp.Location[] ]],
            client.offset_encoding
          )
          for _, item in ipairs(items) do
            local lnum, col = assert(item.lnum), assert(item.col)
            local item_buf = vim.fn.bufnr(item.filename)
            local key = ("%s:%d:%d"):format(item.filename, lnum, col)
            if
              item_buf ~= -1
              and vim.api.nvim_buf_is_loaded(item_buf)
              and not seen[key]
            then
              seen[key] = true
              occurrences[#occurrences + 1] = {
                bufnr = item_buf,
                row = lnum - 1,
                col = col - 1,
                end_row = (item.end_lnum or lnum) - 1,
                end_col = (item.end_col or col) - 1,
              }
            end
          end
        end
      end
      on_done(occurrences)
    end
  )
end

--- Renames the symbol under the cursor to the name typed in a float on a
--- virtual line below it. The float starts out with the old name, in Insert
--- mode at its end. Writing the float's buffer renames the symbol, while
--- `<Esc>` in Normal or Insert mode or closing the float cancels. The
--- symbol's occurrences in the visible windows are highlighted, and replaced
--- with the edited name.
M.rename = function()
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local line = vim.api.nvim_get_current_line()

  local start, finish = buffer.token_at(bufnr, row, cursor[2])
  if not start or not finish then
    return vim.notify("No symbol under the cursor", vim.log.levels.WARN)
  end
  local old_name = line:sub(start + 1, finish)

  local view = vim.fn.winsaveview()
  window.scroll_to_fit_below(win, row, 1)
  vim.api.nvim__ns_set(line_ns, { wins = { win } })
  vim.api.nvim_buf_set_extmark(bufnr, line_ns, row, 0, {
    virt_lines = { { { "", "CursorLine" } } },
  })

  -- The float covers the virtual line from the symbol's column on.
  local info = assert(vim.fn.getwininfo(win)[1])
  local symbol = vim.fn.screenpos(win, row + 1, start + 1)
  local line_end = vim.fn.screenpos(win, row + 1, math.max(#line, 1))
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].buftype = "acwrite"
  vim.bo[float_buf].bufhidden = "wipe"
  vim.b[float_buf].completion = false
  vim.api.nvim_buf_set_name(float_buf, ("rename://%d"):format(float_buf))
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, true, { old_name })
  vim.bo[float_buf].modified = false
  local float = vim.api.nvim_open_win(float_buf, true, {
    relative = "win",
    win = win,
    row = line_end.row - info.winrow + 1,
    col = symbol.curscol - info.wincol,
    width = math.max(info.wincol + info.width - symbol.curscol, 1),
    height = 1,
    style = "minimal",
    border = "none",
  })
  vim.wo[float].winhighlight = "NormalFloat:CursorLine"
  vim.wo[float].wrap = false

  ---@type lsp.rename.Occurrence[]
  local occurrences = {}
  --- The 'conceallevel' of the windows it was raised in, from before.
  ---@type table<integer, integer>
  local conceallevels = {}
  local closed = false

  local new_name = function()
    return vim.api.nvim_buf_get_lines(float_buf, 0, 1, true)[1]
  end

  local clear_preview = function()
    for _, occurrence in ipairs(occurrences) do
      if vim.api.nvim_buf_is_valid(occurrence.bufnr) then
        vim.api.nvim_buf_clear_namespace(occurrence.bufnr, preview_ns, 0, -1)
      end
    end
  end

  local draw_preview = function()
    clear_preview()
    local name = new_name()
    -- An empty or unchanged name keeps the occurrences, highlighted.
    local unchanged = name == "" or name == old_name
    for _, occurrence in ipairs(occurrences) do
      -- The occurrence may have been edited away since.
      pcall(
        vim.api.nvim_buf_set_extmark,
        occurrence.bufnr,
        preview_ns,
        occurrence.row,
        occurrence.col,
        {
          end_row = occurrence.end_row,
          end_col = occurrence.end_col,
          hl_group = unchanged and "Substitute" or nil,
          conceal = not unchanged and "" or nil,
          virt_text = not unchanged and { { name, "Substitute" } } or nil,
          virt_text_pos = not unchanged and "inline" or nil,
        }
      )
    end
  end

  --- Closes the float, then calls back once the window and view the float
  --- was opened from are restored.
  ---@param on_closed? fun()
  local close = function(on_closed)
    if closed then return end
    closed = true
    clear_preview()
    for conceal_win, level in pairs(conceallevels) do
      if vim.api.nvim_win_is_valid(conceal_win) then
        vim.wo[conceal_win][0].conceallevel = level
      end
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, line_ns, 0, -1)
    end
    -- Insert mode ends in the float before the cursor goes back, or ending
    -- it would move the restored cursor left.
    vim.cmd.stopinsert()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then
        if vim.api.nvim_get_current_win() == float then
          vim.api.nvim_set_current_win(win)
        end
        vim.api.nvim_win_call(win, function() vim.fn.winrestview(view) end)
      end
      if vim.api.nvim_win_is_valid(float) then
        vim.api.nvim_win_close(float, true)
      end
      if on_closed then on_closed() end
    end)
  end

  fetch_occurrences(win, function(found)
    if closed then return end
    occurrences = found
    ---@type table<integer, true?>
    local buffers = {}
    for _, occurrence in ipairs(occurrences) do
      buffers[occurrence.bufnr] = true
    end
    for _, tab_win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local level = vim.wo[tab_win][0].conceallevel
      if buffers[vim.api.nvim_win_get_buf(tab_win)] and level < 2 then
        conceallevels[tab_win] = level
        vim.wo[tab_win][0].conceallevel = 2
      end
    end
    draw_preview()
  end)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = float_buf,
    callback = draw_preview,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = float_buf,
    callback = function()
      local name = new_name()
      vim.bo[float_buf].modified = false
      close(function()
        if name ~= "" and name ~= old_name then vim.lsp.buf.rename(name) end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
    buffer = float_buf,
    callback = function() close() end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(float),
    once = true,
    callback = function() close() end,
  })
  vim.keymap.set({ "n", "i" }, "<Esc>", close, { buffer = float_buf })

  vim.cmd.startinsert({ bang = true })
end

return M
