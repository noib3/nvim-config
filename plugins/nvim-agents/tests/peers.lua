local h = require("nvim_agents_tests")
local peers = require("nvim_agents.peers")

test("an answer split across reads is decoded whole", function()
  local address = vim.fs.joinpath(h.tmpdir(), "nvim.1.0")
  local answer = vim.mpack.encode({ 1, 1, vim.NIL, { "split", "answer" } })
  local middle = math.floor(#answer / 2)

  -- A peer that writes its answer in two halves, the second one later.
  local server = assert(vim.uv.new_pipe(false))
  assert(server:bind(address))
  local timer = assert(vim.uv.new_timer())
  server:listen(1, function()
    local client = assert(vim.uv.new_pipe(false))
    server:accept(client)
    client:read_start(function(_, data)
      if not data then return end
      client:write(answer:sub(1, middle))
      timer:start(50, 0, function() client:write(answer:sub(middle + 1)) end)
    end)
  end)

  ---@type table<string, any>?
  local results
  peers.ask_all(
    { address },
    "return nil",
    {},
    1000,
    function(answers) results = answers end
  )
  h.wait(function() return results ~= nil end, "the peer answered")
  timer:close()
  server:close()
  h.eq(assert(results)[address], { "split", "answer" })
end)
