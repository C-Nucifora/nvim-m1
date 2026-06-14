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
--- Public so telescope-m1.nvim's call_rates picker can reuse it instead of
--- duplicating the notification shape (telescope-m1.nvim#19).
---@param prj string  Path to the Project.m1prj that changed.
function M.notify_reload(prj)
  local name = require("nvim-m1.lsp").client_name
  local uri = vim.uri_from_fname(prj)
  for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
    -- Colon (method) form: `client.notify` (dot form) is deprecated in Neovim
    -- 0.12 and a hard error in 0.13 (#87). Older 0.10/0.11 clients still expose
    -- `:notify`, so this is backwards-compatible.
    client:notify("workspace/didChangeWatchedFiles", {
      changes = { { uri = uri, type = 2 } }, -- 2 = Changed
    })
  end
end

--- Per-project mutation serialization. `m1-project` does a read-modify-write of
--- Project.m1prj, so two subprocesses racing on one file lose edits (last writer
--- wins). The old synchronous `vim.fn.system` prevented that for free; the async
--- `vim.system` migration (#68) reintroduced it. Chain each project file's
--- mutations through a per-file queue so only one runs at a time, and surface
--- completion so callers (and the test suite) can await it instead of sleeping
--- (#71).
---@class M1MutationQueue
---@field running boolean
---@field pending table[]  Queued jobs: { cmd, ok_msg, on_done?, on_success? }
local queues = {} ---@type table<string, M1MutationQueue>

--- Whether every pending project mutation (or those for `prj`, if given) has
--- finished. Callers and tests poll this via `vim.wait` to await completion
--- deterministically — the "queue handle" the async runner exposes.
---@param prj? string
---@return boolean
function M.is_idle(prj)
  local function idle(q)
    return not q or (not q.running and #q.pending == 0)
  end
  if prj then
    return idle(queues[prj])
  end
  for _, q in pairs(queues) do
    if not idle(q) then
      return false
    end
  end
  return true
end

--- Start the next queued mutation for `prj` unless one is already running. The
--- completion handler re-enters the main thread (vim.schedule) before touching
--- the LSP, notifying, or starting the next job, then drains the queue in order.
---@param prj string
local function drain(prj)
  local q = queues[prj]
  if not q or q.running or #q.pending == 0 then
    return
  end
  q.running = true
  local job = table.remove(q.pending, 1)
  vim.system(job.cmd, { text = true }, function(res)
    vim.schedule(function()
      local ok = res.code == 0
      if ok then
        M.notify_reload(prj)
        if job.on_success then
          job.on_success(res)
        elseif job.ok_msg then
          vim.notify("nvim-m1: " .. job.ok_msg)
        end
      else
        vim.notify(
          "nvim-m1: m1-project failed: " .. (res.stderr or res.stdout or ""),
          vim.log.levels.ERROR
        )
      end
      q.running = false
      if job.on_done then
        job.on_done(ok, ok and nil or (res.stderr or res.stdout or ""))
      end
      drain(prj) -- next queued mutation for this project, in submission order
    end)
  end)
end

--- Run `m1-project <args>` against the project; on success, reload the LSP.
--- Async (vim.system, 0.10+) so the subprocess never freezes the editor (#68),
--- serialized per project file so concurrent edits can't clobber each other, and
--- reporting completion through `opts.on_done` (#71).
---@param cfg NvimM1Config
---@param args string[]
---@param ok_msg? string  Success toast; omit when `opts.on_success` handles it.
---@param opts? { on_done?: fun(ok: boolean, err: string?), on_success?: fun(res: table) }
local function run(cfg, args, ok_msg, opts)
  opts = opts or {}
  local bin = M.resolve_cmd(cfg)
  if not bin then
    vim.notify(
      "nvim-m1: m1-project not found (set opts.project_path or install it on $PATH)",
      vim.log.levels.ERROR
    )
    if opts.on_done then
      opts.on_done(false, "m1-project not found")
    end
    return
  end
  local prj = M.project_file()
  if not prj then
    vim.notify("nvim-m1: no Project.m1prj found above the buffer", vim.log.levels.ERROR)
    if opts.on_done then
      opts.on_done(false, "no Project.m1prj")
    end
    return
  end
  -- `m1-project <subcommand> --project <prj> <rest…>`: keep the subcommand
  -- (args[1]) first, then splice the project flag, then the remaining args.
  local cmd = vim.list_extend({ bin, args[1], "--project", prj }, args, 2)
  local q = queues[prj]
  if not q then
    q = { running = false, pending = {} }
    queues[prj] = q
  end
  table.insert(
    q.pending,
    { cmd = cmd, ok_msg = ok_msg, on_done = opts.on_done, on_success = opts.on_success }
  )
  drain(prj)
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
  -- :wait() pumps the event loop (vs vim.fn.system's hard block) and the
  -- timeout turns a hung subprocess into a clean empty result, not a freeze
  -- (#68). The caller needs the rates synchronously to build the picker.
  local ok, res = pcall(function()
    return vim
      .system({ bin, "list-rates", "--project", prj }, { text = true })
      :wait(5000)
  end)
  if not ok or res.code ~= 0 then
    return {}
  end
  return vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
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

--- Run the shared name -> storage type -> unit -> security prompt cascade and
--- arg-assembly for the typed-component creators (create-channel,
--- create-parameter), which differ only in the subcommand verb, the first
--- prompt label, and the success-toast noun. Keeping this in one place means a
--- fix to the cascade (a new flag, a cancel edge case) lands in both verbs at
--- once instead of needing to be mirrored by hand.
---@param cfg NvimM1Config
---@param opts { verb: string, name_prompt: string, success_label_prefix: string }
local function create_typed_component(cfg, opts)
  vim.ui.input({ prompt = opts.name_prompt }, function(name)
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
            local args = { opts.verb, "--name", name }
            if ty ~= "(none)" then
              vim.list_extend(args, { "--type", ty })
            end
            if unit ~= "" then
              vim.list_extend(args, { "--unit", unit })
            end
            if sec ~= "(none)" then
              vim.list_extend(args, { "--security", sec })
            end
            run(cfg, args, opts.success_label_prefix .. name)
          end
        )
      end)
    end)
  end)
end

--- :M1CreateChannel — prompt for name/type/unit/security, then create-channel.
function M.create_channel(cfg)
  create_typed_component(cfg, {
    verb = "create-channel",
    name_prompt = "New channel (Root.Group.Name): ",
    success_label_prefix = "created channel ",
  })
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

--- Every component entry from `list-components --json` (path/classname/type/
--- unit/security/call_rate/…), decoded. Shared by `component_paths` (the
--- delete/rename pickers, which need only the paths) and `security_matrix`
--- (which needs path + security). Centralising the spawn + parse keeps the argv
--- and the #68 degrade-on-hang behaviour in one place.
---@param cfg NvimM1Config
---@return table[]  Decoded entries; empty on any failure (missing binary, hung
---                 subprocess, non-zero exit, or unparseable output).
local function component_entries(cfg)
  local bin = M.resolve_cmd(cfg)
  local prj = M.project_file()
  if not bin or not prj then
    return {}
  end
  -- :wait() pumps the loop instead of hard-blocking, and the timeout degrades a
  -- hung subprocess to an empty list rather than freezing the editor (#68).
  -- Callers need these synchronously (to populate vim.ui.select / the matrix).
  local ran, res = pcall(function()
    return vim
      .system({ bin, "list-components", "--project", prj, "--json" }, { text = true })
      :wait(5000)
  end)
  if not ran or res.code ~= 0 then
    return {}
  end
  local out = res.stdout or ""
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  local entries = {}
  for _, entry in ipairs(decoded) do
    if type(entry) == "table" and entry.path then
      table.insert(entries, entry)
    end
  end
  return entries
end

--- All component paths via `list-components --json`. Shared by the pickers in
--- the delete/rename commands; telescope-m1's components picker remains the
--- richer entry point and can preselect via the `component` arguments below.
---@param cfg NvimM1Config
---@return string[]
local function component_paths(cfg)
  local paths = {}
  for _, entry in ipairs(component_entries(cfg)) do
    table.insert(paths, entry.path)
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

--- :M1CreateConstant — prompt name + literal value, then create-constant (#76).
--- m1-project's create-constant takes only a name and value (no type/unit/
--- security knobs), so we prompt for just those two.
---@param cfg NvimM1Config
---@param on_done? fun(ok: boolean, err: string?)
function M.create_constant(cfg, on_done)
  vim.ui.input({ prompt = "Constant name (Root.…): " }, function(name)
    if not name or name == "" then
      return
    end
    vim.ui.input({ prompt = "Value: " }, function(value)
      if not value or value == "" then
        return
      end
      run(
        cfg,
        { "create-constant", "--name", name, "--value", value },
        "created constant " .. name,
        { on_done = on_done }
      )
    end)
  end)
end

--- :M1CreateTable — prompt name + 1–3 axis source channels, then create-table
--- (#76). X is required; Y makes it 2-axis and Z makes it 3-axis, both optional
--- (a blank source stops adding axes). Axis sources are picked from the project's
--- components (falling back to free text), the same source telescope-m1 consumes.
---@param cfg NvimM1Config
---@param on_done? fun(ok: boolean, err: string?)
function M.create_table(cfg, on_done)
  vim.ui.input({ prompt = "Table name (Root.…): " }, function(name)
    if not name or name == "" then
      return
    end
    pick_component(cfg, nil, "X-axis source channel", function(axis_x)
      local args = { "create-table", "--name", name, "--axis-x", axis_x }
      vim.ui.input({ prompt = "Y-axis source (blank = 1-axis): " }, function(axis_y)
        if axis_y and axis_y ~= "" then
          vim.list_extend(args, { "--axis-y", axis_y })
          vim.ui.input({ prompt = "Z-axis source (blank = 2-axis): " }, function(axis_z)
            if axis_z and axis_z ~= "" then
              vim.list_extend(args, { "--axis-z", axis_z })
            end
            run(cfg, args, "created table " .. name, { on_done = on_done })
          end)
        else
          run(cfg, args, "created table " .. name, { on_done = on_done })
        end
      end)
    end)
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
        -- Goes through the same per-project queue as every other mutation so a
        -- rename can't race a queued create/delete on the file. rename's
        -- backing-script-filename guidance arrives on stderr even on success, so
        -- surface it via on_success rather than the default ok-toast.
        run(cfg, { "rename-component", "--name", comp, "--new-name", new_name }, nil, {
          on_success = function(res)
            local warn = vim.trim(res.stderr or "")
            if warn ~= "" then
              vim.notify(
                "nvim-m1: renamed " .. comp .. " -> " .. new_name .. "\n" .. warn,
                vim.log.levels.WARN
              )
            else
              vim.notify("nvim-m1: renamed " .. comp .. " -> " .. new_name)
            end
          end,
        })
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
  -- :wait(timeout) pumps the loop instead of hard-blocking, and degrades a hung
  -- subprocess to a clean error rather than freezing the editor's UI thread
  -- indefinitely (#68, #91 — this call site was missed by #68). validate exits 1
  -- on error-level findings; the report is still on stdout.
  local ran, res = pcall(function()
    return vim.system({ bin, "validate", "--project", prj }, { text = true }):wait(5000)
  end)
  if not ran then
    vim.notify("nvim-m1: validate timed out or failed to run", vim.log.levels.ERROR)
    return
  end
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
      local rate = pick:lower():match("startup") and "startup"
        or pick:gsub("[Hh]z$", "")
      run(
        cfg,
        { "set-call-rate", "--script", script, "--rate", rate },
        script .. " call rate -> " .. pick
      )
    end)
  end)
end

--- Programmatic set-call-rate (telescope-m1.nvim delegates here, #26 there):
--- the same serialized per-project mutation queue, error reporting, and LSP
--- reload notification as :M1SetCallRate, but without UI prompts — for
--- callers that already know the script and rate.
---@param cfg table  Plugin config (e.g. `require("nvim-m1").config`).
---@param script string  Dotted script path (`Root.…`).
---@param rate string|number  `"100"`, `"100Hz"`, or `"startup"` (any case).
---@param opts? { label?: string, on_done?: fun(ok: boolean, err?: string) }
function M.set_call_rate_for(cfg, script, rate, opts)
  opts = opts or {}
  local raw = tostring(rate)
  local norm = raw:lower():match("startup") and "startup" or raw:gsub("[Hh]z$", "")
  run(
    cfg,
    { "set-call-rate", "--script", script, "--rate", norm },
    opts.label or (script .. " call rate -> " .. raw),
    { on_done = opts.on_done }
  )
end

--- :M1CreateParameter — prompt for name + type + unit + security (#61).
function M.create_parameter(cfg)
  create_typed_component(cfg, {
    verb = "create-parameter",
    name_prompt = "Parameter name (Root.…): ",
    success_label_prefix = "created parameter ",
  })
end

--- :M1CreateFunction / :M1CreateScheduledFunction — prompt for the name (#61).
---@param scheduled boolean
local function create_function(cfg, scheduled)
  local verb = scheduled and "create-scheduled-function" or "create-function"
  vim.ui.input({ prompt = "Function name (Root.…): " }, function(name)
    if not name or name == "" then
      return
    end
    run(
      cfg,
      { verb, "--name", name },
      "created " .. (scheduled and "scheduled " or "") .. "function " .. name
    )
  end)
end

function M.create_function(cfg)
  create_function(cfg, false)
end

function M.create_scheduled_function(cfg)
  create_function(cfg, true)
end

--- :M1SetQuantity — prompt for component (unless given) + physical quantity (#61).
---@param component? string
function M.set_quantity(cfg, component)
  with_component(component, function(comp)
    vim.ui.input({ prompt = "Quantity (e.g. Angular Speed): " }, function(qty)
      if not qty or qty == "" then
        return
      end
      run(
        cfg,
        { "set-quantity", "--component", comp, "--quantity", qty },
        comp .. " quantity -> " .. qty
      )
    end)
  end)
end

--- :M1SetValidation — MinMax bounds or None; the in-editor remedy for T043 (#61).
---@param component? string
function M.set_validation(cfg, component)
  with_component(component, function(comp)
    vim.ui.select({ "MinMax", "None" }, { prompt = "Validation" }, function(ty)
      if not ty then
        return
      end
      if ty == "None" then
        run(
          cfg,
          { "set-validation", "--component", comp, "--type", "None" },
          comp .. " validation cleared"
        )
        return
      end
      vim.ui.input({ prompt = "Min: " }, function(min)
        if not min or min == "" then
          return
        end
        vim.ui.input({ prompt = "Max: " }, function(max)
          if not max or max == "" then
            return
          end
          run(
            cfg,
            { "set-validation", "--component", comp, "--min", min, "--max", max },
            comp .. " validation -> [" .. min .. ", " .. max .. "]"
          )
        end)
      end)
    end)
  end)
end

--- :M1SetFormat — display format string (#61).
---@param component? string
function M.set_format(cfg, component)
  with_component(component, function(comp)
    vim.ui.input({ prompt = "Format (e.g. %.1f): " }, function(fmt)
      if not fmt or fmt == "" then
        return
      end
      run(
        cfg,
        { "set-format", "--component", comp, "--format", fmt },
        comp .. " format -> " .. fmt
      )
    end)
  end)
end

--- :M1SetDps — display decimal places (#61).
---@param component? string
function M.set_dps(cfg, component)
  with_component(component, function(comp)
    vim.ui.input({ prompt = "Decimal places: " }, function(dps)
      if not dps or dps == "" then
        return
      end
      run(
        cfg,
        { "set-dps", "--component", comp, "--dps", dps },
        comp .. " dps -> " .. dps
      )
    end)
  end)
end

--- :M1SetDisplayRange — display min/max (#61).
---@param component? string
function M.set_display_range(cfg, component)
  with_component(component, function(comp)
    vim.ui.input({ prompt = "Display min: " }, function(min)
      if not min or min == "" then
        return
      end
      vim.ui.input({ prompt = "Display max: " }, function(max)
        if not max or max == "" then
          return
        end
        run(
          cfg,
          { "set-display-range", "--component", comp, "--min", min, "--max", max },
          comp .. " display range -> [" .. min .. ", " .. max .. "]"
        )
      end)
    end)
  end)
end

--- :M1AddTag / :M1RemoveTag — the in-editor remedy for the T092 tags audit (#61).
---@param component? string
function M.add_tag(cfg, component)
  with_component(component, function(comp)
    vim.ui.input({ prompt = "Tag (e.g. System/Type tag name): " }, function(tag)
      if not tag or tag == "" then
        return
      end
      run(
        cfg,
        { "add-tag", "--component", comp, "--tag", tag },
        comp .. " +tag " .. tag
      )
    end)
  end)
end

---@param component? string
function M.remove_tag(cfg, component)
  with_component(component, function(comp)
    vim.ui.input({ prompt = "Tag to remove: " }, function(tag)
      if not tag or tag == "" then
        return
      end
      run(
        cfg,
        { "remove-tag", "--component", comp, "--tag", tag },
        comp .. " -tag " .. tag
      )
    end)
  end)
end

--- The access levels, in audit order — mirrors m1-vscode's security-matrix.ts
--- LEVELS so the Neovim and VS Code matrices read identically.
local LEVELS = { "Tune", "Calibration", "Master Calibration", "Resource" }

--- :M1SecurityMatrix — render every secured channel/parameter as a
--- Component × access-level grid, grouped by top-level subsystem, into a
--- read-only scratch buffer (#102). Parity with m1-vscode's
--- `m1.showSecurityMatrix` (vscode #78) — the pre-competition audit view of
--- which calibrateable items are exposed at which security level.
---
--- Built from the same `list-components --json` payload the VS Code view
--- consumes; only path + security are needed (the rest of the entry is ignored).
--- The server stays read-only: this writes nothing, just a scratch buffer.
---@param cfg NvimM1Config
function M.security_matrix(cfg)
  if not M.resolve_cmd(cfg) then
    vim.notify(
      "nvim-m1: m1-project not found (set opts.project_path or install it on $PATH)",
      vim.log.levels.ERROR
    )
    return
  end
  if not M.project_file() then
    vim.notify("nvim-m1: no Project.m1prj found above the buffer", vim.log.levels.ERROR)
    return
  end

  -- JSON null decodes to vim.NIL, so treat both nil and vim.NIL as "unsecured".
  local secured = {}
  for _, entry in ipairs(component_entries(cfg)) do
    local sec = entry.security
    if sec ~= nil and sec ~= vim.NIL and type(sec) == "string" and sec ~= "" then
      table.insert(secured, { path = entry.path, security = sec })
    end
  end

  if #secured == 0 then
    vim.notify("nvim-m1: no secured components in this project")
    return
  end

  -- Group by the path's 2nd segment (Root.<Subsystem>.…), mirroring
  -- security-matrix.ts; a 2-segment path (Root.X) has no subsystem.
  local groups, order = {}, {}
  for _, c in ipairs(secured) do
    local seg = vim.split(c.path, ".", { plain = true })
    local group = #seg > 2 and seg[2] or "(top level)"
    if not groups[group] then
      groups[group] = {}
      table.insert(order, group)
    end
    table.insert(groups[group], c)
  end
  table.sort(order)

  -- Column widths: the path column fits the longest path; each level column
  -- fits its header. A centred "X" marks the component's level.
  local path_w = #"Component"
  for _, c in ipairs(secured) do
    path_w = math.max(path_w, #c.path)
  end
  local function pad(s, w)
    return s .. string.rep(" ", math.max(0, w - #s))
  end
  local function centre(s, w)
    local left = math.floor((w - #s) / 2)
    return string.rep(" ", math.max(0, left))
      .. s
      .. string.rep(" ", math.max(0, w - #s - left))
  end

  local function row(path_cell, cells)
    local parts = { pad(path_cell, path_w) }
    for i, level in ipairs(LEVELS) do
      table.insert(parts, centre(cells[i] or "", #level))
    end
    return table.concat(parts, " | ")
  end

  local lines = {
    ("Security matrix — %d secured component(s)"):format(#secured),
    "",
    row("Component", LEVELS),
  }
  -- A separator that lines up with the header columns.
  local sep_cells = {}
  for _, level in ipairs(LEVELS) do
    sep_cells[#sep_cells + 1] = string.rep("-", #level)
  end
  table.insert(lines, row(string.rep("-", path_w), sep_cells))

  for _, group in ipairs(order) do
    table.insert(lines, "")
    table.insert(lines, group .. ":")
    table.sort(groups[group], function(a, b)
      return a.path < b.path
    end)
    for _, c in ipairs(groups[group]) do
      local cells = {}
      for i, level in ipairs(LEVELS) do
        cells[i] = (c.security == level) and "X" or ""
      end
      table.insert(lines, row(c.path, cells))
    end
  end

  -- Render into a read-only scratch buffer (#102): nofile/wipe/non-modifiable,
  -- so the audit view never writes to disk and the server stays read-only.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "M1 Security Matrix")
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_set_current_buf(buf)
end

return M
