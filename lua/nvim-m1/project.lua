--- nvim-m1: edit Project.m1prj via the `m1-project` CLI (#85, #86).
---
--- The language server stays read-only; structured, validated mutations of the
--- project file (create channels, set permissions/unit/type, set call rate) are
--- delegated to the standalone `m1-project` binary — the same tool the VS Code
--- extension uses, so both editors behave identically.
local M = {}

--- Resolve the m1-project executable: explicit `project_path`, then $PATH, then
--- the bundled binary (installed by `:M1Install` / the lazy `build` hook).
---@param cfg NvimM1Config
---@return string? bin
function M.resolve_cmd(cfg)
  return require("nvim-m1.install").resolve("m1-project", cfg.project_path)
end

--- The nearest `Project.m1prj` above the current buffer (or cwd), or nil.
local function project_file()
  local cur = vim.api.nvim_buf_get_name(0)
  local start = (cur ~= "" and vim.fs.dirname(cur)) or vim.fn.getcwd()
  return vim.fs.find({ "Project.m1prj" }, { path = start, upward = true })[1]
end

--- Tell the running m1-lsp client(s) the project file changed so they reload it,
--- without a full restart. (The server reloads `.m1prj` on a watched-file change.)
local function notify_reload(prj)
  local name = require("nvim-m1.lsp").client_name
  local uri = vim.uri_from_fname(prj)
  for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
    client.notify("workspace/didChangeWatchedFiles", {
      changes = { { uri = uri, type = 2 } }, -- 2 = Changed
    })
  end
end

--- Run `m1-project <args>` against the project; on success, reload the LSP.
---@param cfg NvimM1Config
---@param args string[]
---@param ok_msg string
local function run(cfg, args, ok_msg)
  local bin = M.resolve_cmd(cfg)
  if not bin then
    vim.notify(
      "nvim-m1: m1-project not found (set opts.project_path or install it on $PATH)",
      vim.log.levels.ERROR
    )
    return
  end
  local prj = project_file()
  if not prj then
    vim.notify("nvim-m1: no Project.m1prj found above the buffer", vim.log.levels.ERROR)
    return
  end
  local cmd = { bin, args[1], "--project", prj }
  for i = 2, #args do
    table.insert(cmd, args[i])
  end
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("nvim-m1: m1-project failed: " .. out, vim.log.levels.ERROR)
    return
  end
  notify_reload(prj)
  vim.notify("nvim-m1: " .. ok_msg)
end

--- The execution rates (`On <N>Hz` clocks) the project defines, via `list-rates`.
---@param cfg NvimM1Config
---@return string[]
local function list_rates(cfg)
  local bin = M.resolve_cmd(cfg)
  local prj = project_file()
  if not bin or not prj then
    return {}
  end
  local out = vim.fn.system({ bin, "list-rates", "--project", prj })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return vim.split(vim.trim(out), "\n", { trimempty = true })
end

local SECURITY = { "Tune", "Calibration", "Master Calibration", "Resource" }
local TYPES = { "(none)", "f32", "f64", "u8", "u16", "u32", "s8", "s16", "s32", "bool" }

--- :M1CreateChannel — prompt for name/type/unit/security, then create-channel.
function M.create_channel(cfg)
  vim.ui.input({ prompt = "New channel (Root.Group.Name): " }, function(name)
    if not name or name == "" then
      return
    end
    vim.ui.select(TYPES, { prompt = "Storage type" }, function(ty)
      if not ty then
        return
      end
      vim.ui.input({ prompt = "Unit (optional): " }, function(unit)
        if unit == nil then
          return
        end
        vim.ui.select(
          { "(none)", unpack(SECURITY) },
          { prompt = "Security" },
          function(sec)
            if not sec then
              return
            end
            local args = { "create-channel", "--name", name }
            if ty ~= "(none)" then
              table.insert(args, "--type")
              table.insert(args, ty)
            end
            if unit ~= "" then
              table.insert(args, "--unit")
              table.insert(args, unit)
            end
            if sec ~= "(none)" then
              table.insert(args, "--security")
              table.insert(args, sec)
            end
            run(cfg, args, "created channel " .. name)
          end
        )
      end)
    end)
  end)
end

--- :M1SetSecurity — prompt for component + level, then set-security.
function M.set_security(cfg)
  vim.ui.input({ prompt = "Component (Root.…): " }, function(component)
    if not component or component == "" then
      return
    end
    vim.ui.select(SECURITY, { prompt = "Security" }, function(sec)
      if not sec then
        return
      end
      run(
        cfg,
        { "set-security", "--component", component, "--security", sec },
        component .. " security -> " .. sec
      )
    end)
  end)
end

--- :M1SetCallRate — prompt for script + rate (from the project's clocks).
function M.set_call_rate(cfg)
  vim.ui.input({ prompt = "Script (Root.…): " }, function(script)
    if not script or script == "" then
      return
    end
    local rates = list_rates(cfg)
    if #rates == 0 then
      rates = { "100Hz", "50Hz", "20Hz", "10Hz", "Startup" }
    end
    vim.ui.select(rates, { prompt = "Execution rate" }, function(pick)
      if not pick then
        return
      end
      local rate = pick:lower():match("startup") and "startup" or pick:gsub("Hz$", "")
      run(
        cfg,
        { "set-call-rate", "--script", script, "--rate", rate },
        script .. " call rate -> " .. pick
      )
    end)
  end)
end

return M
