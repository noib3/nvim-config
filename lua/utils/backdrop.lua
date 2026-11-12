local M = {}

--- The blend of the backdrops, from 0 for opaque to 100 for transparent.
local blend = 60

--- Returns the layout of a float covering the editor.
---@return vim.api.keyset.win_config
local full_layout = function()
  return {
    relative = "editor",
    width = vim.o.columns,
    height = vim.o.lines,
    row = 0,
    col = 0,
  }
end

--- Opens a backdrop fading the editor under a float. The backdrop follows the
--- editor's size, and closes with the float.
---@param win integer The float.
M.open = function(win)
  vim.api.nvim_set_hl(0, "Backdrop", { bg = "#000000", default = true })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local backdrop = vim.api.nvim_open_win(
    buf,
    false,
    vim.tbl_extend("force", full_layout(), {
      style = "minimal",
      focusable = false,
      border = "none",
      zindex = (vim.api.nvim_win_get_config(win).zindex or 50) - 1,
    })
  )
  vim.wo[backdrop].winhighlight = "Normal:Backdrop"
  vim.wo[backdrop].winblend = blend

  local group =
    vim.api.nvim_create_augroup("noib3/backdrop-" .. win, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function() vim.api.nvim_win_set_config(backdrop, full_layout()) end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function()
      vim.api.nvim_del_augroup_by_id(group)
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(backdrop) then
          vim.api.nvim_win_close(backdrop, true)
        end
      end)
    end,
  })
end

return M
