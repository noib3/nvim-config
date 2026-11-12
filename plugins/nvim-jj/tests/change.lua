local h = require("nvim_jj_tests")
local nvim_jj = require("nvim_jj")

h.setup()
-- The changed words of the hunks come from nvim-hunks' diff.
if vim.env.LIBVSCODE_DIFF then
  require("nvim_hunks.diff").load(vim.env.LIBVSCODE_DIFF)
end

---@param root string
---@param path string
---@param text string
local write = function(root, path, text)
  local full = vim.fs.joinpath(root, path)
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  local file = assert(io.open(full, "w"))
  file:write(text)
  file:close()
end

---@param from integer
---@param to integer
---@return string[]
local numbers = function(from, to)
  local lines = {}
  for number = from, to do
    lines[#lines + 1] = tostring(number)
  end
  return lines
end

--- Creates a repo whose `work` change modifies two places of a long file,
--- deletes a file, adds one and renames one, and opens its log.
---@return string root
---@return integer bufnr
local repo = function()
  local root = h.repo({ "base" })
  write(root, "long.txt", table.concat(numbers(1, 30), "\n") .. "\n")
  write(root, "gone.txt", "gone\n")
  write(root, "ren.txt", "moved\n")
  h.run(root, { "jj", "commit", "--quiet", "-m", "setup" })
  local long = numbers(1, 30)
  long[2], long[25] = "TWO", "25 and more"
  write(root, "long.txt", table.concat(long, "\n") .. "\n")
  os.remove(vim.fs.joinpath(root, "gone.txt"))
  os.rename(
    vim.fs.joinpath(root, "ren.txt"),
    vim.fs.joinpath(root, "renamed.txt")
  )
  write(root, "new.txt", "new\n")
  h.run(root, { "jj", "commit", "--quiet", "-m", "work" })
  return root, h.open(root)
end

--- Opens the view of the change on a subject's line, and waits until it's
--- drawn.
---@param bufnr integer
---@param subject string
---@param where "right"|"float"
---@return integer view
local open = function(bufnr, subject, where)
  h.messages = {}
  nvim_jj.open_change(bufnr, h.row(bufnr, subject), where)
  local view = vim.api.nvim_get_current_buf()
  assert(
    vim.startswith(vim.api.nvim_buf_get_name(view), "jj-change://"),
    "the change isn't viewed: " .. vim.inspect(h.messages)
  )
  h.wait(
    function() return vim.api.nvim_buf_line_count(view) > 2 end,
    "the change is drawn"
  )
  return view
end

---@param view integer
---@return string[]
local lines_of = function(view)
  return vim.api.nvim_buf_get_lines(view, 0, -1, false)
end

---@param view integer
---@param text string
---@return integer
local line_of = function(view, text)
  for line, other in ipairs(lines_of(view)) do
    if other == text then return line end
  end
  error(("no line is %q"):format(text), 2)
end

---@param keys string
local press = function(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

--- Returns the texts of the extmarks of the change views on a line.
---@param view integer
---@param line integer
---@return { inline: string, above: string[] }
local decorations = function(view, line)
  local namespace = vim.api.nvim_create_namespace("nvim-jj-change")
  local marks = vim.api.nvim_buf_get_extmarks(
    view,
    namespace,
    { line - 1, 0 },
    { line - 1, -1 },
    { details = true }
  )
  local result = { inline = "", above = {} }
  for _, mark in ipairs(marks) do
    local details = assert(mark[4])
    if details.virt_text_pos == "inline" then
      for _, chunk in ipairs(details.virt_text or {}) do
        result.inline = result.inline .. chunk[1]
      end
    end
    for _, virt_line in ipairs(details.virt_lines or {}) do
      local text = ""
      for _, chunk in ipairs(virt_line) do
        text = text .. chunk[1]
      end
      result.above[#result.above + 1] = vim.trim(text)
    end
  end
  return result
end

test(
  "the change is viewed in a centered float over a backdrop until it's quit",
  function()
    local _, bufnr = repo()
    local windows = #vim.api.nvim_tabpage_list_wins(0)

    local view = open(bufnr, "work", "float")
    h.eq(lines_of(view), {
      "work",
      "4 files changed: 1 added, 1 deleted, 1 modified, 1 renamed,",
      "gone.txt",
      "long.txt",
      "new.txt",
      "ren.txt → renamed.txt",
    })
    local config = vim.api.nvim_win_get_config(0)
    h.eq(config.relative, "editor")
    h.eq(config.width, math.floor(vim.o.columns * 0.8 + 0.5))
    h.eq(config.border, { "", "", "", " ", "", "", "", " " })
    h.eq(vim.wo.winhighlight, "NormalFloat:Normal,FloatBorder:Normal")
    local backdrops = vim.tbl_filter(
      function(win) return vim.wo[win].winhighlight == "Normal:JjBackdrop" end,
      vim.api.nvim_tabpage_list_wins(0)
    )
    h.eq(#backdrops, 1)
    h.eq(vim.api.nvim_win_get_config(assert(backdrops[1])).width, vim.o.columns)
    h.eq(#vim.api.nvim_tabpage_list_wins(0), windows + 2)

    press("q")
    h.wait(
      function() return #vim.api.nvim_tabpage_list_wins(0) == windows end,
      "the float and its backdrop are closed"
    )
    h.eq(vim.api.nvim_get_current_buf(), bufnr)
  end
)

test(
  "a file's hunks show their line numbers and the lines between them",
  function()
    local _, bufnr = repo()
    local view = open(bufnr, "work", "float")

    vim.api.nvim_win_set_cursor(0, { line_of(view, "long.txt"), 0 })
    press("<CR>")
    local lines = lines_of(view)
    local hunks = vim.list_slice(
      lines,
      line_of(view, "long.txt") + 1,
      line_of(view, "new.txt") - 1
    )
    h.eq(hunks, {
      "1",
      "2",
      "TWO",
      "3",
      "4",
      "5",
      "22",
      "23",
      "24",
      "25",
      "25 and more",
      "26",
      "27",
      "28",
    })
    ---@param text string
    local gutter = function(text)
      return (
        vim.trim(decorations(view, line_of(view, text)).inline):gsub("%s+", " ")
      )
    end
    h.eq(gutter("1"), "1 1")
    h.eq(gutter("2"), "2 -")
    h.eq(gutter("TWO"), "2 +")
    h.eq(decorations(view, line_of(view, "22")).above, { "16 unchanged lines" })

    -- The changed words are highlighted on top of the changed lines.
    local namespace = vim.api.nvim_create_namespace("nvim-jj-change")
    local row = line_of(view, "25 and more") - 1
    local marks = vim.api.nvim_buf_get_extmarks(
      view,
      namespace,
      { row, 0 },
      { row, -1 },
      { details = true }
    )
    local groups = vim.tbl_map(function(mark)
      local details = assert(mark[4])
      return details.hl_group or ""
    end, marks)
    h.eq(vim.list_contains(groups, "HunksAddText"), true, vim.inspect(groups))
    h.eq(vim.list_contains(groups, "HunksAdd"), true, vim.inspect(groups))

    -- The indent before the gutter keeps the text's background.
    local inline = vim.iter(marks):find(
      function(mark) return assert(mark[4]).virt_text_pos == "inline" end
    )
    local virt_text = assert(assert(assert(inline)[4]).virt_text)
    h.eq(virt_text[1], { "  ", "JjDiffIndent" })

    press("<CR>")
    h.eq(lines_of(view)[line_of(view, "long.txt") + 1], "new.txt")
    vim.cmd("quit!")
  end
)

test("]] and [[ move between the hunks of the expanded files", function()
  local _, bufnr = repo()
  local view = open(bufnr, "work", "float")
  for _, path in ipairs({ "gone.txt", "long.txt", "new.txt" }) do
    vim.api.nvim_win_set_cursor(0, { line_of(view, path), 0 })
    press("<CR>")
  end

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local visited = {}
  for _ = 1, 5 do
    press("]]")
    visited[#visited + 1] = vim.api.nvim_get_current_line()
  end
  h.eq(visited, { "gone", "1", "22", "new", "new" })
  press("[[")
  h.eq(vim.api.nvim_get_current_line(), "22")
  vim.cmd("quit!")
end)

test("writing the view describes the change", function()
  local root, bufnr = repo()
  local view = open(bufnr, "work", "float")

  vim.api.nvim_buf_set_lines(view, 0, 1, false, { "subject", "", "body" })
  vim.cmd.write()
  h.wait(function()
    local description =
      h.query(root, 'description(substring:"subject")', "description")
    return #description > 0
  end, "the change is described")
  h.eq(
    h.query(
      root,
      'description(substring:"subject")',
      'description.first_line() ++ "|" ++ description.lines().len()'
    ),
    { "subject|3" }
  )
  vim.cmd("quit!")
end)

test("the description's markdown is concealed away from the cursor", function()
  local _, bufnr = repo()
  local view = open(bufnr, "work", "right")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(view, 0, 1, false, { "work", "", "some `code`" })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd.redraw()

  local pos = vim.fn.screenpos(win, 3, 1)
  local chars = {}
  for offset = 0, vim.api.nvim_win_get_width(win) - 1 do
    chars[#chars + 1] = vim.fn.screenstring(pos.row, pos.col + offset)
  end
  h.eq(vim.trim(table.concat(chars)), "some code")
  vim.cmd("quit!")
end)

test("a change can be viewed in a split next to the log", function()
  local _, bufnr = repo()
  local log_win = vim.api.nvim_get_current_win()
  local windows = #vim.api.nvim_tabpage_list_wins(0)

  open(bufnr, "work", "right")
  local win = vim.api.nvim_get_current_win()
  h.eq(#vim.api.nvim_tabpage_list_wins(0), windows + 1)
  h.eq(
    vim.api.nvim_win_get_position(win)[2]
      > vim.api.nvim_win_get_position(log_win)[2],
    true
  )
  vim.cmd("quit!")
end)

test("the details follow a separator after the description", function()
  local _, bufnr = repo()
  local view = open(bufnr, "work", "float")
  local above = decorations(view, 2).above
  h.eq((assert(above[1]):gsub("─", "")), "")
  h.eq(assert(above[3]):match("^%d%d%d%d%-%d%d%-%d%d ") ~= nil, true, above[3])
  h.eq(above[4], "test <test@example.com>")
  vim.cmd("quit!")
end)

--- Returns the float showing a change's view, if there's one.
---@return integer?
local change_float = function()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if
      vim.fn.win_gettype(win) == "popup"
      and vim.startswith(name, "jj-change://")
    then
      return win
    end
  end
end

test("hovering a change shows its view in a float fitting it", function()
  local _, bufnr = repo()
  -- The hover fits in the space above or below the cursor in the log.
  vim.api.nvim_win_set_config(0, { height = vim.o.lines - 4 })
  vim.api.nvim_win_set_cursor(0, { h.row(bufnr, "work"), 0 })
  local log_win = vim.api.nvim_get_current_win()
  h.messages = {}
  vim.lsp.buf.hover({ silent = true })
  h.wait(
    function() return change_float() ~= nil end,
    "the view is shown in the hover"
  )
  local win = assert(change_float())
  local view = vim.api.nvim_win_get_buf(win)
  h.eq(vim.api.nvim_get_current_win(), log_win)
  h.eq(lines_of(view)[1], "work")
  h.eq(
    vim.api.nvim_win_get_config(win).border,
    { "", "", "", " ", "", "", "", " " }
  )
  h.eq(
    vim.api.nvim_win_get_height(win),
    vim.api.nvim_win_text_height(win, {}).all
  )
  -- The totals follow the summary.
  local summary =
    "4 files changed: 1 added, 1 deleted, 1 modified, 1 renamed, +3 -3"
  h.eq(vim.api.nvim_win_get_width(win) >= #summary, true)

  -- Hovering again focuses the view, which stays open, and hovering in it
  -- goes back to the log.
  vim.lsp.buf.hover({ silent = true })
  h.wait(
    function() return vim.api.nvim_get_current_win() == win end,
    "the hover is focused"
  )
  vim.wait(50)
  h.eq(vim.api.nvim_win_is_valid(win), true)
  h.wait(
    function() return #vim.lsp.get_clients({ bufnr = view }) > 0 end,
    "the view's language server is attached"
  )
  vim.lsp.buf.hover({ silent = true })
  h.wait(
    function() return vim.api.nvim_get_current_win() == log_win end,
    "the log is focused again"
  )
  h.eq(h.messages, {})

  -- Moving in the log closes it.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
  h.wait(
    function() return not vim.api.nvim_win_is_valid(win) end,
    "the hover is closed"
  )
  h.eq(vim.api.nvim_buf_is_valid(view), false)
end)

test("writing an immutable change's view is an error", function()
  local root = h.repo({ "one" }, 1)
  local bufnr = h.open(root)
  local view = open(bufnr, "one", "float")

  h.messages = {}
  vim.api.nvim_buf_set_lines(view, 0, 1, false, { "uno" })
  vim.cmd.write()
  h.eq(#h.messages, 1)
  h.eq(
    assert(h.messages[1]):match("^error: %S+ one is immutable: ") ~= nil,
    true,
    h.messages[1]
  )
  h.eq(vim.bo[view].modified, true)
  vim.cmd("quit!")
end)

test("the changes viewed next to the log close with it", function()
  local _, bufnr = repo()
  local log_win = vim.api.nvim_get_current_win()
  local view = open(bufnr, "work", "right")
  local view_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(log_win)
  nvim_jj.toggle()
  h.wait(
    function() return not vim.api.nvim_win_is_valid(view_win) end,
    "the view is closed"
  )
  h.eq(vim.api.nvim_buf_is_valid(view), false)
end)
