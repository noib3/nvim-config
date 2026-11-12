local h = require("nvim_threads_tests")
local threads = require("nvim_threads")

threads.register(h.participant("editor", { "Like this." }, {
  edits = {
    {
      path = "f.txt",
      old_text = "# two lines of",
      new_text = "# Two rewritten lines of",
    },
    { path = "f.txt", old_text = "seven", new_text = "SEVEN" },
  },
}))

h.setup(80, 40)

local root = h.repo({
  ["f.txt"] = h.text({
    "one",
    "# two lines of",
    "# a comment",
    "four",
    "five",
    "six",
    "seven",
  }),
}, {})

vim.keymap.set({ "n", "x" }, "<F2>", function() threads.create() end)

---@return nvim_threads.Thread
local only_thread = function()
  ---@type nvim_threads.Thread[]?
  local found
  threads.list(root, function(entries)
    found = vim.tbl_map(function(entry) return entry.thread end, entries)
  end)
  h.wait(function() return found ~= nil end, "the threads are listed")
  return assert(assert(found)[1])
end

---@param float_buf integer
---@param line integer
---@return lsp.Command[]
local code_actions = function(float_buf, line)
  local client =
    assert(vim.lsp.get_clients({ bufnr = float_buf, name = "nvim-threads" })[1])
  local response = client:request_sync("textDocument/codeAction", {
    textDocument = { uri = vim.uri.from_buf(float_buf) },
    range = {
      start = { line = line - 1, character = 0 },
      ["end"] = { line = line - 1, character = 0 },
    },
    context = { diagnostics = {} },
  }, 2000, float_buf)
  return vim.tbl_map(
    function(action) return action.command end,
    assert(response and response.result)
  )
end

---@param commands lsp.Command[]
---@return string[]
local titles = function(commands)
  return vim.tbl_map(function(command) return command.title end, commands)
end

---@param float_buf integer
---@param command lsp.Command
local execute = function(float_buf, command)
  local client =
    assert(vim.lsp.get_clients({ bufnr = float_buf, name = "nvim-threads" })[1])
  client:exec_cmd(command, { bufnr = float_buf })
end

---@param float_buf integer
---@param text string
---@return integer
local line_of = function(float_buf, text)
  local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
  local found = vim
    .iter(ipairs(lines))
    :find(function(_, line) return line == text end)
  assert(found, ("no line is %q in %s"):format(text, vim.inspect(lines)))
  return found
end

test(
  "each suggested edit is a diff, applied or rejected by a code action",
  function()
    local bufnr = h.open(root, "f.txt")
    vim.api.nvim_feedkeys(vim.keycode("2GVj<F2>"), "x", false)
    vim.cmd.stopinsert()
    h.type({ "@editor fix the comment" })
    h.eq(threads.submit(), true)
    h.leave()
    local thread = only_thread()
    h.wait(
      function() return #thread.comments == 2 end,
      "the participant replies"
    )
    h.eq(
      thread.anchor,
      { start_row = 1, start_col = 0, end_row = 2, end_col = 11 }
    )

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    h.eq(threads.step(1, "j"), true)
    h.eq(threads.activate(), true, "the thread expands")
    local float_buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
    local header = line_of(float_buf, "▾ ✎ Suggested edits to f.txt")
    h.eq(lines[header - 2], "Like this.")
    h.eq(lines[header - 1], "", "a blank row separates the edits from the text")
    h.eq(vim.list_slice(lines, header + 1, header + 14), {
      "▾ Edit at line 2",
      " 1 1    one",
      " 2    - # two lines of",
      "   2  + # Two rewritten lines of",
      " 3 3    # a comment",
      " 4 4    four",
      " 5 5    five",
      "▾ Edit at line 7",
      "      3 unchanged lines",
      " 4 4    four",
      " 5 5    five",
      " 6 6    six",
      " 7    - seven",
      "   7  + SEVEN",
    })
    h.eq(
      vim.startswith(lines[header + 15] or "", "───"),
      true,
      "a line separates the reply's field"
    )

    h.eq(code_actions(float_buf, 1), {}, "the title has no edits to resolve")
    h.eq(titles(code_actions(float_buf, header)), {
      "Apply the edits to f.txt",
      "Reject the edits to f.txt",
      "Review the edits in buffers that apply them when written",
    })
    local first_edit = header + 4
    h.eq(titles(code_actions(float_buf, first_edit)), {
      "Apply this edit",
      "Reject this edit",
    })
    vim.api.nvim_win_set_cursor(0, { first_edit, 0 })
    h.eq(threads.is_on_edit(), true)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    h.eq(threads.is_on_edit(), false)

    execute(float_buf, assert(code_actions(float_buf, first_edit)[1]))
    h.wait(
      function()
        return vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1]
          == "# Two rewritten lines of"
      end,
      "the first edit is applied"
    )
    h.eq(
      vim.api.nvim_buf_get_lines(bufnr, 6, 7, false),
      { "seven" },
      "only that edit is applied"
    )
    h.eq(vim.bo[bufnr].modified, false, "the file is saved")
    h.eq(
      assert(assert(assert(thread.comments[2]).edits)[1]).resolution,
      "applied"
    )
    h.eq(
      thread.anchor,
      { start_row = 1, start_col = 0, end_row = 2, end_col = 11 },
      "the anchor still starts on the rewritten line"
    )

    -- The applied edit collapses.
    line_of(float_buf, "▾ ✎ Suggested edits to f.txt · 1 applied")
    local applied = line_of(float_buf, "▸ Applied edit at line 2")
    h.eq(
      code_actions(float_buf, applied),
      {},
      "an applied edit can't be resolved again"
    )

    local second_edit = line_of(float_buf, " 7    - seven")
    execute(float_buf, assert(code_actions(float_buf, second_edit)[2]))
    h.wait(
      function()
        return (pcall(line_of, float_buf, "▸ Rejected edit at line 7"))
      end,
      "the second edit is rejected"
    )
    h.eq(vim.api.nvim_buf_get_lines(bufnr, 6, 7, false), { "seven" })
    line_of(
      float_buf,
      "▾ ✎ Suggested edits to f.txt · 1 applied · 1 rejected"
    )

    -- <CR> expands a resolved edit.
    vim.api.nvim_win_set_cursor(
      0,
      { line_of(float_buf, "▸ Applied edit at line 2"), 0 }
    )
    h.eq(threads.activate(), true)
    line_of(float_buf, "▾ Applied edit at line 2")
    line_of(float_buf, "   2  + # Two rewritten lines of")

    -- <CR> on a diff's line collapses its edit, with the cursor on its title.
    vim.api.nvim_win_set_cursor(
      0,
      { line_of(float_buf, "   2  + # Two rewritten lines of"), 0 }
    )
    h.eq(threads.activate(), true)
    local title = line_of(float_buf, "▸ Applied edit at line 2")
    h.eq(vim.api.nvim_win_get_cursor(0)[1], title)

    -- <CR> on the file's row collapses its edits.
    vim.api.nvim_win_set_cursor(0, {
      line_of(
        float_buf,
        "▾ ✎ Suggested edits to f.txt · 1 applied · 1 rejected"
      ),
      0,
    })
    h.eq(threads.activate(), true)
    line_of(
      float_buf,
      "▸ ✎ Suggested edits to f.txt · 1 applied · 1 rejected"
    )
    h.eq(pcall(line_of, float_buf, "▸ Applied edit at line 2"), false)
  end
)

test(
  "the float follows its thread up when an edit deletes lines above it",
  function()
    threads.register(h.participant("trimmer", { "Drop them." }, {
      edits = {
        { path = "g.txt", old_text = "two\nthree\n", new_text = "" },
      },
    }))
    local trimmed_root = h.repo({
      ["g.txt"] = h.text({ "one", "two", "three", "four", "five" }),
    }, {})
    -- The previous test leaves the cursor in a float.
    h.leave()
    local bufnr = h.open(trimmed_root, "g.txt")
    vim.api.nvim_feedkeys(vim.keycode("4G<F2>"), "x", false)
    vim.cmd.stopinsert()
    h.type({ "@trimmer drop two and three" })
    h.eq(threads.submit(), true)
    h.leave()

    ---@type nvim_threads.Thread?
    local thread
    threads.list(
      trimmed_root,
      function(entries) thread = assert(entries[1]).thread end
    )
    h.wait(
      function() return thread ~= nil and #thread.comments == 2 end,
      "the participant replies"
    )

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    h.eq(threads.step(1, "j"), true)
    h.eq(threads.activate(), true, "the thread expands")
    local float_win = vim.api.nvim_get_current_win()
    local float_buf = vim.api.nvim_get_current_buf()
    local header = line_of(float_buf, "▾ ✎ Suggested edits to g.txt")
    execute(float_buf, assert(code_actions(float_buf, header)[1]))
    h.wait(
      function() return vim.api.nvim_buf_line_count(bufnr) == 3 end,
      "the edit is applied"
    )

    local shown = require("nvim_threads.float").get(float_win)
    h.eq(shown ~= nil, true, "the float stays open")
    ---@cast shown -nil
    h.eq(shown.row, 1, "the float follows the line its thread is on")
    h.eq(
      vim.api.nvim_win_get_config(float_win).row,
      vim.fn.screenpos(shown.source_win, 2, 1).row,
      "the float starts right below that line"
    )
  end
)

test("an edit without old text creates its file", function()
  threads.register(h.participant("creator", { "Add it." }, {
    edits = { { path = "new.txt", new_text = "first\nsecond\n" } },
  }))
  local created_root = h.repo({
    ["h.txt"] = h.text({ "one", "two" }),
  }, {})
  -- The previous test leaves the cursor in a float.
  h.leave()
  h.open(created_root, "h.txt")
  vim.api.nvim_feedkeys(vim.keycode("1G<F2>"), "x", false)
  vim.cmd.stopinsert()
  h.type({ "@creator add new.txt" })
  h.eq(threads.submit(), true)
  h.leave()

  ---@type nvim_threads.Thread?
  local thread
  threads.list(
    created_root,
    function(entries) thread = assert(entries[1]).thread end
  )
  h.wait(
    function() return thread ~= nil and #thread.comments == 2 end,
    "the participant replies"
  )

  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  h.eq(threads.step(1, "j"), true)
  h.eq(threads.activate(), true, "the thread expands")
  local float_buf = vim.api.nvim_get_current_buf()
  local header = line_of(float_buf, "▾ ✎ Suggested edits to new.txt")
  local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
  h.eq(vim.list_slice(lines, header + 1, header + 3), {
    "▾ New file",
    "   1  + first",
    "   2  + second",
  })

  local path = vim.fs.joinpath(created_root, "new.txt")
  h.write(path, "already here\n")
  h.eq(titles(code_actions(float_buf, header))[1], "Apply the edits to new.txt")
  execute(float_buf, assert(code_actions(float_buf, header)[1]))
  vim.wait(100)
  h.eq(h.read(path), "already here\n", "an existing file isn't overwritten")

  os.remove(path)
  execute(float_buf, assert(code_actions(float_buf, header)[1]))
  h.wait(
    function() return h.read(path) == "first\nsecond\n" end,
    "the file is created"
  )
  line_of(float_buf, "▸ Created file")
end)
