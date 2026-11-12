local M = {}

--- Scrolls a window down until some screen lines fit below a line, without
--- scrolling the line itself out of view.
---@param win integer
---@param row integer The 0-based line.
---@param height integer The number of screen lines.
M.scroll_to_fit_below = function(win, row, height)
  local topline = vim.fn.line("w0", win)
  local overflow = vim.api.nvim_win_text_height(win, {
    start_row = topline - 1,
    end_row = row,
  }).all + height - vim.api.nvim_win_get_height(win)
  if overflow <= 0 then return end
  local hidden = vim.api.nvim_win_text_height(win, {
    start_row = topline - 1,
    max_height = overflow,
  }).end_row
  vim.api.nvim_win_call(
    win,
    function() vim.fn.winrestview({ topline = math.min(hidden + 2, row + 1) }) end
  )
end

return M
