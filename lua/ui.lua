local fzf_select = require("fzf-lua.providers.ui_select").ui_select
local inline_select = require("utils.inline_select")
local jj = require("nvim_jj")
local logos = require("utils.logos")

--- Returns a text with the logos that have a brand color in that color, as ANSI
--- escape codes.
---@param text string
---@return string
local color_logos = function(text)
  for _, logo in pairs(logos) do
    if logo.color then
      local rgb = assert(tonumber(logo.color:sub(2), 16))
      local escape = ("\27[38;2;%d;%d;%dm"):format(
        math.floor(rgb / 0x10000) % 0x100,
        math.floor(rgb / 0x100) % 0x100,
        rgb % 0x100
      )
      text = text:gsub(vim.pesc(logo.icon), escape .. logo.icon .. "\27[0m")
    end
  end
  return text
end

--- Picks a code action from virtual lines below the cursor. In a jj log, the
--- actions start after the graph.
---@param items any[]
---@param opts table
---@param on_choice fun(item?: any, idx?: integer)
local select_code_action = function(items, opts, on_choice)
  local prefix =
    jj.graph_below(vim.api.nvim_get_current_buf(), vim.fn.line("."))
  inline_select.select(
    items,
    vim.tbl_extend("force", opts, { prefix = prefix }),
    on_choice
  )
end

---@diagnostic disable-next-line: duplicate-set-field
vim.ui.select = function(items, opts, on_choice)
  opts = opts or {}
  if opts.kind == "codeaction" then
    return select_code_action(items, opts, on_choice)
  end
  local format_item = opts.format_item or tostring
  fzf_select(
    items,
    vim.tbl_extend("force", opts, {
      format_item = function(item) return color_logos(format_item(item)) end,
    }),
    on_choice
  )
end
