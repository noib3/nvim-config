local layout = require("utils.layout")

-- trouble's module is a metatable that forwards to `trouble.api`, which EmmyLua
-- can't see through.
local trouble = require("trouble")

vim.keymap.set(
  "n",
  "<D-t>",
  ---@diagnostic disable-next-line: undefined-field
  function() trouble.toggle({ focus = true, mode = "errors_and_warnings" }) end
)

vim.keymap.set(
  "n",
  "<D-x>",
  ---@diagnostic disable-next-line: undefined-field
  function() trouble.toggle({ focus = true, mode = "call_sites" }) end
)

vim.keymap.set("n", "<D-d>", function()
  -- The list runs in other windows' contexts, which don't see the buffer-local
  -- working directories of terminals.
  ---@diagnostic disable-next-line: undefined-field
  trouble.toggle({ focus = true, mode = "hunks", cwd = vim.fn.getcwd() })
end)

vim.keymap.set("n", "<D-k>", function()
  ---@diagnostic disable-next-line: undefined-field
  trouble.toggle({
    focus = true,
    mode = "threads_waiting_on_me",
    cwd = vim.fn.getcwd(),
  })
end)

-- trouble previews and jumps to items in a "main" window, which it never picks
-- among terminals. Without one, it'd use the list's own window. This falls
-- back to the first window that isn't a float or a trouble window.
local Main = require("trouble.view.main")
---@diagnostic disable-next-line: access-invisible
local find_main = Main._find
---@diagnostic disable-next-line: duplicate-set-field
Main._find = function()
  ---@diagnostic disable-next-line: access-invisible
  local main = find_main() --[[@as trouble.Main?]]
  if main then return main end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local is_float = vim.fn.win_gettype(win) == "popup"
    ---@diagnostic disable-next-line: access-invisible
    if not is_float and not vim.w[win].trouble then return Main._info(win) end
  end
end

-- Without a main window, trouble jumps to an item in the list's own window and
-- opens the list again in a new one. The old window keeps the list's variable,
-- which makes trouble and the list's plugins take it for a list.
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = vim.api.nvim_create_augroup(
    "noib3/trouble-windows",
    { clear = true }
  ),
  desc = "Forgets that a window showed a trouble list once it shows another buffer",
  callback = function(ev)
    local win = vim.api.nvim_get_current_win()
    if vim.w[win].trouble and vim.bo[ev.buf].filetype ~= "trouble" then
      vim.w[win].trouble = nil
    end
  end,
})

---@param into string
---@return trouble.Action
local move_to = function(into)
  return {
    action = function(view)
      require("trouble.sources.hunks").move(view:selection(), into)
    end,
    desc = ("Move the selected hunks or files to `%s`"):format(into),
    -- Trouble hands the modes to `vim.keymap.set`, which takes a list.
    mode = { "n", "x" } --[[@as string]],
  }
end

---@param view trouble.View
local drop = function(view)
  require("trouble.sources.hunks").drop(view:selection())
end

-- Rows with nested rows, like files with hunks, fold instead of jumping.
---@type trouble.Action
local fold_or_jump = {
  action = function(view, ctx)
    local node = ctx.node
    if node and not node:is_leaf() then
      view:fold(node)
    elseif ctx.item then
      view:jump(ctx.item)
    end
  end,
  desc = "Show or hide the nested rows, or else jump to the item",
}

--- Returns the root of the innermost jj or Git repo containing the path.
---@param path string
---@return string?
local repo_root = function(path) return vim.fs.root(path, { { ".jj", ".git" } }) end

---@diagnostic disable-next-line: undefined-field
trouble.setup({
  formatters = {
    -- The file's path relative to the root of its jj or Git repo, or else its
    -- full path with the home directory as `~`.
    repo_path = function(ctx)
      local filename = ctx.item.filename
      local root = repo_root(filename)
      return {
        text = root and vim.fs.relpath(root, filename)
          or vim.fn.fnamemodify(filename, ":~"),
        hl = "TroubleFilename",
      }
    end,
  },
  icons = {
    indent = {
      fold_open = "▾ ",
      fold_closed = "▸ ",
    },
  },
  modes = {
    call_sites = {
      mode = "lsp_references",
      win = {
        type = "split",
        size = {
          height = layout.split_height,
        },
      },
    },
    hunks = {
      center = true,
      keys = {
        ["<cr>"] = fold_or_jump,
        ["+"] = move_to("@+"),
        ["-"] = move_to("@-"),
        ["dd"] = {
          action = drop,
          desc = "Drop the hunk or file from the working-copy change",
        },
        ["d"] = {
          action = drop,
          desc = "Drop the selected hunks or files from the working-copy change",
          mode = "x",
        },
      },
      win = {
        type = "split",
        size = {
          height = layout.split_height,
        },
      },
    },
    errors_and_warnings = {
      max_items = false,
      mode = "diagnostics",
      source = "repo_diagnostics",
      groups = {
        { "filename", format = "{file_icon} {repo_path} {count}" },
      },
      filter = function(items)
        return vim.tbl_filter(
          function(item) return item.severity <= vim.diagnostic.severity.WARN end,
          items
        )
      end,
      win = {
        type = "split",
        size = {
          height = layout.split_height,
        },
      },
    },
  },
})

-- The diagnostics of the files of the current buffer's repo, or of that file
-- alone outside a repo.
require("trouble.sources").register("repo_diagnostics", {
  get = function(cb, ctx)
    local buf = ctx.main.buf --[[@as integer]]
    local win = ctx.main.win --[[@as integer]]
    local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    local is_file = file ~= "" and vim.bo[buf].buftype == ""
    local root = repo_root(is_file and file or vim.fn.getcwd(win))
    ---@type table<string, string|false>
    local roots = {}
    local get_diagnostics = require("trouble.sources").get("diagnostics") --[[@as trouble.Source.get]]
    get_diagnostics(function(items)
      cb(vim.tbl_filter(function(item)
        if not root then return item.filename == file end
        local filename = item.filename
        if roots[filename] == nil then
          roots[filename] = repo_root(filename) or false
        end
        return roots[filename] == root
      end, items))
    end, ctx)
  end,
})
