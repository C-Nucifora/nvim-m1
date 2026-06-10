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
--- Exposed on `M` so other modules (e.g. init.lua's config scaffolder) share the
--- one project-root discovery rule instead of re-implementing it inline.
---@return string?
function M.project_file()
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
  local prj = M.project_file()
  if not prj then
    vim.notify("nvim-m1: no Project.m1prj found above the buffer", vim.log.levels.ERROR)
    return
  end
  -- `m1-project <subcommand> --project <prj> <rest…>`: keep the subcommand
  -- (args[1]) first, then splice the project flag, then the remaining args.
  local cmd = vim.list_extend({ bin, args[1], "--project", prj }, args, 2)
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
  local prj = M.project_file()
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

--- Prompt for a component path unless the caller (e.g. the telescope-m1
--- components picker) already knows it.
---@param component? string
---@param cb fun(component: string)
local function with_component(component, cb)
  if component and component ~= "" then
    cb(component)
    return
  end
  vim.ui.input({ prompt = "Component (Root.…): " }, function(c)
    if c and c ~= "" then
      cb(c)
    end
  end)
end

--- The project's execution-rate clocks (public for telescope-m1's rates picker).
---@param cfg NvimM1Config
---@return string[]
function M.rates(cfg)
  return list_rates(cfg)
end

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

--- :M1SetSecurity — prompt for component (unless given) + level.
---@param component? string  Pre-selected component (telescope action).
function M.set_security(cfg, component)
  with_component(component, function(comp)
    vim.ui.select(SECURITY, { prompt = "Security" }, function(sec)
      if not sec then
        return
      end
      run(
        cfg,
        { "set-security", "--component", comp, "--security", sec },
        comp .. " security -> " .. sec
      )
    end)
  end)
end

--- :M1SetType — prompt for component (unless given) + storage type (#46).
---@param component? string
function M.set_type(cfg, component)
  with_component(component, function(comp)
    local types = vim.list_slice(TYPES, 2) -- no "(none)": set-type needs a value
    vim.ui.select(types, { prompt = "Storage type" }, function(ty)
      if not ty then
        return
      end
      run(
        cfg,
        { "set-type", "--component", comp, "--type", ty },
        comp .. " type -> " .. ty
      )
    end)
  end)
end

--- :M1SetUnit — prompt for component (unless given) + display unit (#46).
---@param component? string
function M.set_unit(cfg, component)
  with_component(component, function(comp)
    vim.ui.input({ prompt = "Unit (e.g. rpm, kPa): " }, function(unit)
      if not unit or unit == "" then
        return
      end
      run(
        cfg,
        { "set-unit", "--component", comp, "--unit", unit },
        comp .. " unit -> " .. unit
      )
    end)
  end)
end

--- All component paths via `list-components --json`. Shared by the pickers in
--- the delete/rename commands; telescope-m1's components picker remains the
--- richer entry point and can preselect via the `component` arguments below.
---@param cfg NvimM1Config
---@return string[]
local function component_paths(cfg)
  local bin = M.resolve_cmd(cfg)
  local prj = M.project_file()
  if not bin or not prj then
    return {}
  end
  local out = vim.fn.system({ bin, "list-components", "--project", prj, "--json" })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  local paths = {}
  for _, entry in ipairs(decoded) do
    if type(entry) == "table" and entry.path then
      table.insert(paths, entry.path)
    end
  end
  return paths
end

--- Pick a component: the caller's preselection (telescope), else a
--- vim.ui.select over the project's components, else free-text input.
---@param cfg NvimM1Config
---@param component? string
---@param prompt string
---@param cb fun(component: string)
local function pick_component(cfg, component, prompt, cb)
  if component and component ~= "" then
    cb(component)
    return
  end
  local paths = component_paths(cfg)
  if #paths == 0 then
    with_component(nil, cb)
    return
  end
  vim.ui.select(paths, { prompt = prompt }, function(c)
    if c then
      cb(c)
    end
  end)
end

--- :M1CreateGroup — prompt for the fully-qualified name, then create-group (#51).
function M.create_group(cfg)
  vim.ui.input({ prompt = "New group (Root.Parent.Name): " }, function(name)
    if not name or name == "" then
      return
    end
    run(cfg, { "create-group", "--name", name }, "created group " .. name)
  end)
end

--- :M1DeleteComponent — pick, confirm (destructive), then delete-component (#51).
---@param component? string  Pre-selected component (telescope action).
function M.delete_component(cfg, component)
  pick_component(cfg, component, "Delete component", function(comp)
    local choice = vim.fn.confirm(
      "Delete " .. comp .. " from the project?",
      "&Delete\n&Subtree too\n&Cancel",
      3,
      "Warning"
    )
    if choice ~= 1 and choice ~= 2 then
      return
    end
    local args = { "delete-component", "--name", comp }
    if choice == 2 then
      table.insert(args, "--recursive")
    end
    run(cfg, args, "deleted " .. comp)
  end)
end

--- :M1RenameComponent — pick, prompt the new single-segment name, then
--- rename-component; echoes the CLI's backing-script-filename guidance (#51).
---@param component? string
function M.rename_component(cfg, component)
  pick_component(cfg, component, "Rename component", function(comp)
    local leaf = comp:match("([^.]+)$") or comp
    vim.ui.input(
      { prompt = "New name (single segment): ", default = leaf },
      function(new_name)
        if not new_name or new_name == "" or new_name:find("%.") then
          return
        end
        local bin = M.resolve_cmd(cfg)
        local prj = M.project_file()
        if not bin or not prj then
          vim.notify(
            "nvim-m1: m1-project or Project.m1prj not found",
            vim.log.levels.ERROR
          )
          return
        end
        -- vim.system rather than run(): rename's backing-script-filename
        -- warnings arrive on stderr and must reach the user.
        local res = vim
          .system({
            bin,
            "rename-component",
            "--project",
            prj,
            "--name",
            comp,
            "--new-name",
            new_name,
          })
          :wait()
        if res.code ~= 0 then
          vim.notify(
            "nvim-m1: rename failed: " .. (res.stderr or res.stdout or ""),
            vim.log.levels.ERROR
          )
          return
        end
        notify_reload(prj)
        local warn = vim.trim(res.stderr or "")
        if warn ~= "" then
          vim.notify(
            "nvim-m1: renamed " .. comp .. " -> " .. new_name .. "\n" .. warn,
            vim.log.levels.WARN
          )
        else
          vim.notify("nvim-m1: renamed " .. comp .. " -> " .. new_name)
        end
      end
    )
  end)
end

--- :M1ValidateProject — run `m1-project validate` and load the findings into
--- the quickfix list (ERROR -> E, WARN -> W); opens it when non-empty (#51).
function M.validate(cfg)
  local bin = M.resolve_cmd(cfg)
  local prj = M.project_file()
  if not bin then
    vim.notify("nvim-m1: m1-project not found", vim.log.levels.ERROR)
    return
  end
  if not prj then
    vim.notify("nvim-m1: no Project.m1prj found above the buffer", vim.log.levels.ERROR)
    return
  end
  -- validate exits 1 on error-level findings; the report is still on stdout.
  local res = vim.system({ bin, "validate", "--project", prj }):wait()
  local out = res.stdout or ""
  if out == "" and res.code ~= 0 then
    vim.notify("nvim-m1: validate failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
    return
  end
  local items = {}
  local summary = "done"
  for _, line in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local level, rest = line:match("^(ERROR) (.+)$")
    if not level then
      level, rest = line:match("^(WARN) (.+)$")
    end
    if level then
      table.insert(items, {
        filename = prj,
        lnum = 1,
        col = 1,
        type = level == "ERROR" and "E" or "W",
        text = rest,
      })
    else
      summary = line
    end
  end
  vim.fn.setqflist({}, " ", { title = "m1-project validate", items = items })
  if #items > 0 then
    vim.cmd.copen()
    vim.notify("nvim-m1: project validation: " .. summary, vim.log.levels.WARN)
  else
    vim.notify("nvim-m1: project validation: " .. summary)
  end
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
