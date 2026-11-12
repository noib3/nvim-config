local M = {}

---@class BufferSaveOptions
---@field bufnr? integer Buffer number to save (defaults to current buffer)

local check_modified_augroup_id = vim.api.nvim_create_augroup(
  "noib3/check_if_buffer_was_modified_since_formatting_request",
  { clear = true }
)

---Save a buffer, optionally formatting it via LSP first.
---@param opts? BufferSaveOptions
M.save = function(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

  local save_buf = function()
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent write") end)
  end

  -- Find first LSP client that supports formatting.
  local formatting_client

  local clients = vim.lsp.get_clients({
    bufnr = bufnr,
  })

  for _, client in ipairs(clients) do
    if client:supports_method("textDocument/formatting") then
      formatting_client = client
      break
    end
  end

  -- If there's no formatter available, just save.
  if not formatting_client then
    save_buf()
    return
  end

  local buffer_was_modified = false

  vim.api.nvim_create_autocmd(
    { "TextChanged", "TextChangedI", "TextChangedP" },
    {
      group = check_modified_augroup_id,
      buffer = bufnr,
      callback = function() buffer_was_modified = true end,
      once = true,
    }
  )

  local offset_encoding = formatting_client.offset_encoding

  -- Request formatting.
  local did_send_request = formatting_client:request(
    "textDocument/formatting",
    vim.api.nvim_buf_call(bufnr, vim.lsp.util.make_formatting_params),
    function(_, result, _)
      -- Server was too slow.
      if buffer_was_modified then return end

      if result then
        vim.lsp.util.apply_text_edits(result, bufnr, offset_encoding)
      end

      save_buf()
    end,
    bufnr
  )

  if not did_send_request then save_buf() end
end

--- Returns the 0-based byte columns at which the token on a position of a
--- buffer starts and ends, the end being exclusive. Returns nothing if there's
--- no such token, or if it spans several lines.
---@param bufnr integer
---@param row integer The 0-based line.
---@param col integer The 0-based byte column.
---@return integer? start
---@return integer? finish
M.token_at = function(bufnr, row, col)
  local parser = vim.treesitter.get_parser(bufnr, nil, { error = false })
  if parser then
    parser:parse({ row, row + 1 })
    local node = vim.treesitter.get_node({
      bufnr = bufnr,
      pos = { row, col },
      ignore_injections = false,
      include_anonymous = true,
    })
    if not node or node:child_count() > 0 then return end
    local start_row, start_col, end_row, end_col = node:range()
    if start_row ~= row or end_row ~= row then return end
    return start_col, end_col
  end

  local line = assert(vim.api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1])
  local match = vim.fn.matchstrpos(line, [[\k*\%]] .. col + 1 .. [[c\k\+]])
  if match[2] == -1 then return end
  return match[2], match[3]
end

return M
