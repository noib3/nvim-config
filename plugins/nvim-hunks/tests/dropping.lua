local h = require("nvim_hunks_tests")
local hunks = require("nvim_hunks")

h.setup(80, 24)

---@param lines string[]
---@return string
local text = function(lines) return table.concat(lines, "\n") .. "\n" end

--- Returns a changed file of a repo's working-copy commit.
---@param repo string
---@param path string
---@return nvim_hunks.File
local changed = function(repo, path)
  ---@type nvim_hunks.File?
  local found
  local done = false
  hunks.files({ repo }, function(files)
    for _, file in ipairs(files) do
      if file.path == path then found = file end
    end
    done = true
  end)
  h.wait(function() return done end, "the files are listed")
  return (assert(found, path .. " isn't changed"))
end

--- Returns a file's contents on disk, or nothing if it doesn't exist.
---@param repo string
---@param path string
---@return string?
local on_disk = function(repo, path)
  local file = io.open(vim.fs.joinpath(repo, path), "rb")
  if not file then return end
  local contents = file:read("*a")
  file:close()
  return contents
end

---@param repo string
---@param path string
---@param expected string?
local wait_on_disk = function(repo, path, expected)
  h.wait(
    function() return on_disk(repo, path) == expected end,
    ("%s is %s on disk"):format(path, vim.inspect(expected))
  )
end

test("dropping a hunk keeps the file's other hunks", function()
  local repo = h.repo(
    { ["g.txt"] = text({ "a", "b", "c", "d", "e", "f", "g" }) },
    { ["g.txt"] = text({ "A", "b", "c", "D", "e", "f", "G" }) }
  )
  local file = changed(repo, "g.txt")
  hunks.drop_many({}, {
    { file = file, hunks = { assert(file.hunks[1]), assert(file.hunks[3]) } },
  })
  wait_on_disk(repo, "g.txt", text({ "a", "b", "c", "D", "e", "f", "g" }))
  h.eq(
    h.file_at(repo, "@", "g.txt"),
    text({ "a", "b", "c", "D", "e", "f", "g" })
  )
end)

test("dropping a file's only hunk restores the file", function()
  local repo = h.repo(
    { ["kept.txt"] = text({ "kept" }) },
    { ["kept.txt"] = false, ["new.txt"] = text({ "new" }) }
  )
  local file = changed(repo, "new.txt")
  hunks.drop_many({}, { { file = file, hunks = { assert(file.hunks[1]) } } })
  wait_on_disk(repo, "new.txt", nil)
end)

test("dropping whole files undoes all of their changes", function()
  local repo = h.repo({
    ["modified.txt"] = text({ "a", "b" }),
    ["removed.txt"] = text({ "removed" }),
  }, {
    ["modified.txt"] = text({ "A", "b" }),
    ["added.txt"] = text({ "added" }),
  })
  hunks.drop_many({
    changed(repo, "modified.txt"),
    changed(repo, "removed.txt"),
    changed(repo, "added.txt"),
  }, {})
  -- jj updates the files on disk one after the other.
  wait_on_disk(repo, "added.txt", nil)
  wait_on_disk(repo, "modified.txt", text({ "a", "b" }))
  wait_on_disk(repo, "removed.txt", text({ "removed" }))
end)

test("hunks of several files and whole files drop together", function()
  local repo = h.repo({
    ["a.txt"] = text({ "a", "b", "c", "d" }),
    ["b.txt"] = text({ "a", "b" }),
    ["c.txt"] = text({ "a" }),
  }, {
    ["a.txt"] = text({ "A", "b", "c", "D" }),
    ["b.txt"] = text({ "A", "b" }),
    ["c.txt"] = text({ "C" }),
  })
  local a, b = changed(repo, "a.txt"), changed(repo, "b.txt")
  hunks.drop_many({ changed(repo, "c.txt") }, {
    { file = a, hunks = { assert(a.hunks[1]) } },
    { file = b, hunks = { assert(b.hunks[1]) } },
  })
  wait_on_disk(repo, "c.txt", text({ "a" }))
  wait_on_disk(repo, "a.txt", text({ "a", "b", "c", "D" }))
  wait_on_disk(repo, "b.txt", text({ "a", "b" }))
end)

test("a dropped hunk leaves the file's buffer", function()
  local repo = h.repo(
    { ["g.txt"] = text({ "a", "b", "c" }) },
    { ["g.txt"] = text({ "A", "b", "C" }) }
  )
  vim.cmd.edit(vim.fs.joinpath(repo, "g.txt"))
  local buf = vim.api.nvim_get_current_buf()
  local file = changed(repo, "g.txt")
  hunks.drop_many({}, { { file = file, hunks = { assert(file.hunks[1]) } } })
  h.wait(
    function()
      return vim.deep_equal(
        vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        { "a", "b", "C" }
      )
    end,
    "the buffer is reloaded"
  )
end)

test("a buffer with unsaved edits isn't dropped from", function()
  local repo = h.repo(
    { ["g.txt"] = text({ "a", "b" }) },
    { ["g.txt"] = text({ "A", "b" }) }
  )
  vim.cmd.edit(vim.fs.joinpath(repo, "g.txt"))
  local file = changed(repo, "g.txt")
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { "B" })
  hunks.drop_many({ file }, {})
  vim.wait(500)
  h.eq(on_disk(repo, "g.txt"), text({ "A", "b" }))
  vim.cmd("bwipeout!")
end)
