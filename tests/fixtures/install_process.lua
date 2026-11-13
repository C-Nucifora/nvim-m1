-- Real curl consumes a local fixture; no network or executable fixture is used.
local root, shared, name, tool, held = unpack(arg)
vim.opt.runtimepath:prepend(root)
local install = require("nvim-m1.install")
install.bin_dir = function()
  return shared .. "/bin"
end
install.needs_resign = function()
  return false
end
install.versions[tool] = "fixture-" .. name
local payload = shared .. "/" .. name .. ".payload"
local system = vim.system
vim.system = function(cmd, opts, cb)
  assert(cmd[1]:match("curl"))
  cmd[#cmd] = vim.uri_from_fname(payload)
  return system(cmd, opts, cb)
end
install.attest_verify_async = function(path, _, cb)
  vim.fn.writefile(
    { path, table.concat(vim.fn.readfile(path), "\n") },
    shared .. "/" .. name .. ".verified"
  )
  local function finish()
    if held == "hold" and vim.fn.filereadable(shared .. "/release") ~= 1 then
      vim.defer_fn(finish, 10)
      return
    end
    cb(true)
  end
  finish()
end
local done
install.install_async({ tool }, function(ok)
  done = ok
end)
assert(
  vim.wait(15000, function()
    return done ~= nil
  end),
  "installer did not complete"
)
vim.fn.writefile({ tostring(done) }, shared .. "/" .. name .. ".result")
vim.cmd("qa!")
