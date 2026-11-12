local utils = require("utils")

local is_text_file = function(path)
  local output = vim.fn.systemlist({ "file", "-Lb", "--mime-type", path })
  if vim.v.shell_error ~= 0 or not output or not output[1] then return false end
  local mime = output[1]
  return vim.startswith(mime, "text/")
    or mime == "application/csv"
    or mime == "application/javascript"
    or mime == "application/json"
    or mime == "application/x-pem-file"
    or mime == "inode/x-empty"
end

local open = function(path)
  local is_macos = vim.fn.has("macunix") == 1 or vim.fn.has("mac") == 1
  local opener = is_macos and "open" or "xdg-open"
  vim.fn.jobstart({ opener, path }, { detach = true })
end

--- The border of lf's float, an empty column on each side.
local padding = { "", "", "", " ", "", "", "", " " }

--- Returns the layout of a float centered on the editor, taking 80% of its
--- width and height inside its padding.
---@return vim.api.keyset.win_config
local layout = function()
  local width = utils.math.round(vim.o.columns * 0.8)
  local height = utils.math.round(vim.o.lines * 0.8)
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2) - 1,
  }
end

--- Opens lf on the current buffer's file, in a float centered on the editor
--- over a backdrop. Once lf quits, the text files selected in it are edited
--- in the window it was opened from, and the other files are opened with
--- the system's default apps.
local open_lf = function()
  local origin = vim.api.nvim_get_current_win()
  local name = vim.api.nvim_buf_get_name(0)
  local selection_path = vim.fn.tempname()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(
    buf,
    true,
    -- The backdrop goes over incline's floats, which are at the default 50.
    vim.tbl_extend("force", layout(), { border = padding, zindex = 60 })
  )
  vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:Normal"
  utils.backdrop.open(win)

  local group =
    vim.api.nvim_create_augroup("noib3/lf-" .. win, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function() vim.api.nvim_win_set_config(win, layout()) end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function() vim.api.nvim_del_augroup_by_id(group) end,
  })

  local cmd = { "lf", "-selection-path", selection_path }
  if vim.uv.fs_stat(name) then cmd[#cmd + 1] = name end
  vim.fn.jobstart(cmd, {
    term = true,
    on_exit = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end

      -- lf only writes the selection if files were selected.
      local selected_paths = utils.fs.read_file(selection_path)
      os.remove(selection_path)
      if not selected_paths then return end
      -- TODO:
      -- * if text file is currently focused, skip it;
      -- * if text file is first one, open it in current window;
      -- * if text file is not first one, add it to the qf list;
      for path in utils.lua.iter_lines(selected_paths) do
        if vim.fn.isdirectory(path) == 1 then goto continue end
        if is_text_file(path) then
          if vim.api.nvim_win_is_valid(origin) then
            vim.api.nvim_win_call(
              origin,
              function() vim.cmd.edit(vim.fn.fnameescape(path)) end
            )
          end
        else
          open(path)
        end
        ::continue::
      end
    end,
  })
end

vim.keymap.set("n", "ll", open_lf, { silent = true })
