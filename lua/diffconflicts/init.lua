local M = {}

local config = {
  vcs = "git", -- "git" or "hg" (jj is auto-detected)
  commands = {
    diff_conflicts = "DiffConflicts",
    show_history = "DiffConflictsShowHistory",
    with_history = "DiffConflictsWithHistory",
  },
}

local function is_jj_repo()
  local buf_path = vim.api.nvim_buf_get_name(0)
  local start = buf_path ~= "" and vim.fn.fnamemodify(buf_path, ":p:h") or vim.uv.cwd()
  local found = vim.fs.find(".jj", { upward = true, path = start, type = "directory" })
  return found ~= nil and #found > 0
end

local function effective_vcs()
  if is_jj_repo() then
    return "jj"
  end
  return config.vcs
end

local function jj_get_marker_length(explicit)
  local marker_length = explicit
  if marker_length == nil or marker_length == 0 then
    marker_length = vim.g.jj_diffconflicts_marker_length
    if marker_length == nil or marker_length == "" then
      marker_length = 7
    end
  end
  marker_length = tonumber(marker_length)
  if marker_length == nil or marker_length < 1 then
    marker_length = 7
  end
  return marker_length
end

local function jj_get_patterns(marker_length)
  local marker = {
    top = string.rep("<", marker_length),
    bottom = string.rep(">", marker_length),
    diff = string.rep("%", marker_length),
    diff_cont = string.rep("\\", marker_length),
    snapshot = string.rep("+", marker_length),
  }

  return {
    top = "^" .. marker.top .. " .+$",
    bottom = "^" .. marker.bottom .. " .+$",
    -- double to escape `%` symbols
    diff = "^" .. marker.diff .. marker.diff .. " .+$",
    diff_cont = "^" .. marker.diff_cont .. " .+$",
    snapshot = "^" .. marker.snapshot .. " .+$",
  }
end

local function jj_err(msg)
  error(msg, 0)
end

local function jj_find_index(pattern, list)
  for i, x in ipairs(list) do
    if string.find(x, pattern) then
      return i
    end
  end
  jj_err(string.format("could not find element matching pattern %q", pattern))
end

local function jj_parse_diff(diff_lines)
  local new = {}
  for _, line in ipairs(diff_lines) do
    local symbol, rest = string.sub(line, 1, 1), string.sub(line, 2, -1)
    if symbol == "+" then
      table.insert(new, rest)
    elseif symbol == "-" then
      -- ignore removed lines in "new"
      local _ = rest
    elseif symbol == " " then
      table.insert(new, rest)
    else
      jj_err(string.format("unexpected diff line: %q", line))
    end
  end
  return { new = new }
end

local function jj_validate_conflict(patterns, lines)
  local num_diffs = 0
  local has_snapshot = false
  for _, l in ipairs(lines) do
    if string.find(l, patterns.diff) then
      num_diffs = num_diffs + 1
    elseif string.find(l, patterns.snapshot) then
      has_snapshot = true
    end
  end
  if num_diffs == 0 then
    jj_err("could not find diff section of conflict")
  end
  if num_diffs > 1 then
    jj_err(string.format("conflict has %d sides, at most 2 sides are supported", num_diffs + 1))
  end
  if not has_snapshot then
    jj_err("could not find snapshot section of conflict")
  end
end

local function jj_extract_conflicts(patterns, buffer_lines)
  local conflicts = {}
  local lnum = 1
  local max_lnum = #buffer_lines

  while lnum <= max_lnum do
    local line = buffer_lines[lnum]
    if string.find(line, patterns.top) then
      local conflict_top = lnum
      local bottom_found = false
      lnum = lnum + 1

      while lnum <= max_lnum and not bottom_found do
        line = buffer_lines[lnum]
        if not string.find(line, patterns.bottom) then
          lnum = lnum + 1
        else
          bottom_found = true
          local conflict_bottom = lnum
          local conflict_lines = vim.list_slice(buffer_lines, conflict_top + 1, conflict_bottom - 1)
          jj_validate_conflict(patterns, conflict_lines)
          table.insert(conflicts, {
            top = conflict_top,
            bottom = conflict_bottom,
            lines = conflict_lines,
          })
        end
      end

      if not bottom_found then
        jj_err(string.format("could not find bottom marker matching %q", buffer_lines[conflict_top]))
      end
    end
    lnum = lnum + 1
  end

  return conflicts
end

local function jj_parse_conflict(patterns, raw_conflict)
  local lines = raw_conflict.lines
  local raw_diff = nil
  local snapshot = nil

  local section_header = lines[1]
  if string.find(section_header, patterns.diff) then
    local diff_start = 2
    if lines[2] and string.find(lines[2], patterns.diff_cont) then
      diff_start = 3
    end
    local i = jj_find_index(patterns.snapshot, lines)
    raw_diff = vim.list_slice(lines, diff_start, i - 1)
    snapshot = vim.list_slice(lines, i + 1, #lines)
  elseif string.find(section_header, patterns.snapshot) then
    local i = jj_find_index(patterns.diff, lines)
    local diff_start = i + 1
    if lines[i + 1] and string.find(lines[i + 1], patterns.diff_cont) then
      diff_start = i + 2
    end
    snapshot = vim.list_slice(lines, 2, i - 1)
    raw_diff = vim.list_slice(lines, diff_start, #lines)
  else
    jj_err("unexpected start for conflict: " .. section_header)
  end

  local diff = jj_parse_diff(raw_diff)

  return {
    left_side = diff.new,
    right_side = snapshot,
    top_line = raw_conflict.top,
    bottom_line = raw_conflict.bottom,
  }
end

local function jj_get_content_for_side(side, conflicts, conflicted_content)
  for _, conflict in ipairs(conflicts) do
    local span = conflict.bottom_line - conflict.top_line + 1
    local content_lines = vim.deepcopy(conflict[side])
    local padding_lines = vim.fn["repeat"]({ vim.NIL }, span - #content_lines)
    vim.list_extend(content_lines, padding_lines)

    for i, line in ipairs(content_lines) do
      conflicted_content[i + conflict.top_line - 1] = line
    end
  end
  return vim.tbl_filter(function(x)
    return x ~= vim.NIL
  end, conflicted_content)
end

local function jj_setup_diff_splits(conflicts)
  local conflicted_content = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local original_filetype = vim.bo.filetype

  vim.cmd.vsplit({ mods = { split = "belowright" } })
  vim.cmd.enew()
  local right_side = jj_get_content_for_side("right_side", conflicts, vim.deepcopy(conflicted_content))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, right_side)
  vim.cmd.file("snapshot")
  vim.bo.filetype = original_filetype
  vim.cmd([[setlocal nomodifiable readonly buftype=nofile bufhidden=delete nobuflisted]])
  vim.cmd.diffthis()

  vim.cmd.wincmd("p")
  local left_side = jj_get_content_for_side("left_side", conflicts, vim.deepcopy(conflicted_content))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, left_side)
  vim.cmd.diffthis()

  vim.cmd.diffupdate()
  vim.fn.cursor(conflicts[1].top_line, 1)
end

local function jj_setup_history_view(base_path, left_path, right_path)
  local function load_path(path, name)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.cmd.file(name)
    vim.cmd([[setlocal statusline=%t]])
    vim.cmd([[setlocal nomodifiable readonly]])
    vim.cmd.diffthis()
  end

  vim.cmd.tabnew()
  vim.cmd.vsplit()
  vim.cmd.vsplit()
  vim.cmd.wincmd("h")
  vim.cmd.wincmd("h")

  load_path(left_path, "left")
  vim.cmd.wincmd("l")
  load_path(base_path, "base")
  vim.cmd.wincmd("l")
  load_path(right_path, "right")
  vim.cmd.wincmd("h")
end

local function jj_paths_from_args(fargs)
  local args = fargs or {}
  if #args >= 4 then
    return args[2], args[3], args[4]
  end

  local argv = vim.fn.argv()
  if #argv >= 4 then
    return argv[2], argv[3], argv[4]
  end

  return nil, nil, nil
end

local function jj_ensure_output_buffer(fargs)
  local output = (fargs and fargs[1]) or vim.fn.argv()[1]
  if output and output ~= "" then
    local current = vim.api.nvim_buf_get_name(0)
    if current == "" or vim.fn.fnamemodify(current, ":p") ~= vim.fn.fnamemodify(output, ":p") then
      vim.cmd.edit(vim.fn.fnameescape(output))
    end
  end
end

local function jj_run(show_history, marker_length, fargs)
  jj_ensure_output_buffer(fargs)

  local patterns = jj_get_patterns(jj_get_marker_length(marker_length))
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)

  local ok, raw_conflicts = pcall(jj_extract_conflicts, patterns, lines)
  if not ok then
    vim.notify("diffconflicts.nvim (jj): extract conflicts: " .. raw_conflicts, vim.log.levels.ERROR)
    return
  end
  if vim.tbl_isempty(raw_conflicts) then
    vim.notify("diffconflicts.nvim (jj): no conflicts found in buffer", vim.log.levels.WARN)
    return
  end

  local conflicts = {}
  for _, raw_conflict in ipairs(raw_conflicts) do
    local ok2, conflict = pcall(jj_parse_conflict, patterns, raw_conflict)
    if not ok2 then
      vim.notify("diffconflicts.nvim (jj): parse conflict: " .. conflict, vim.log.levels.ERROR)
      return
    end
    table.insert(conflicts, conflict)
  end

  if show_history then
    local base_path, left_path, right_path = jj_paths_from_args(fargs)
    if base_path and left_path and right_path then
      local ok3, err = pcall(jj_setup_history_view, base_path, left_path, right_path)
      if not ok3 then
        vim.notify("diffconflicts.nvim (jj): setup history view: " .. err, vim.log.levels.ERROR)
      else
        vim.cmd.tabnext(1)
      end
    else
      vim.notify("diffconflicts.nvim (jj): missing $base/$left/$right args; history view disabled", vim.log.levels.WARN)
    end
  end

  jj_setup_diff_splits(conflicts)
  vim.cmd.redraw()
end

local function has_conflicts()
  local conflict_count = 0
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:find("^<<<<<<< ") then
      conflict_count = conflict_count + 1
    end
  end
  return conflict_count > 0
end

local function diff_confl()
  if effective_vcs() == "jj" then
    jj_run(false, nil, nil)
    return
  end

  local orig_buf = vim.api.nvim_get_current_buf()
  local orig_ft = vim.bo.filetype

  local conflict_style
  if config.vcs == "git" then
    local result = vim.fn.system("git config --get merge.conflictStyle")
    conflict_style = result:gsub("%s$", "")
  else
    conflict_style = "diff"
  end

  -- Set up the right-hand side.
  vim.cmd("rightb vsplit")
  vim.cmd("enew")
  vim.cmd('silent execute "read #" .. ' .. orig_buf)
  vim.api.nvim_buf_set_lines(0, 0, 1, false, {}) -- Delete the first line
  vim.cmd("silent file RCONFL")
  vim.bo.filetype = orig_ft
  vim.cmd("diffthis")

  vim.cmd("silent g/^<<<<<<< /,/^=======\\r\\?$/d")
  vim.cmd("silent g/^>>>>>>> /d")

  vim.bo.modifiable = false
  vim.bo.readonly = true
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "delete"
  vim.bo.buflisted = false

  -- Set up the left-hand side.
  vim.cmd("wincmd p")
  vim.cmd("diffthis")

  if conflict_style:lower() == "diff3" or conflict_style:lower() == "zdiff3" then
    vim.cmd("silent g/^||||||| \\?/,/^>>>>>>> /d")
  else
    vim.cmd("silent g/^=======\\r\\?$/,/^>>>>>>> /d")
  end
  vim.cmd("silent g/^<<<<<<< /d")

  vim.cmd("diffupdate")
end

local function show_history()
  -- NOTE: `show_history()` is only used for git/hg history view. For jj, the
  -- history view requires paths from args, so it is handled in the command
  -- wrapper below.

  vim.cmd("tabnew")
  vim.cmd("vsplit")
  vim.cmd("vsplit")
  vim.cmd("wincmd h")
  vim.cmd("wincmd h")

  local base_buf, local_buf, remote_buf
  if config.vcs == "hg" then
    base_buf = "~base."
    local_buf = "~local."
    remote_buf = "~other."
  else
    base_buf = "BASE"
    local_buf = "LOCAL"
    remote_buf = "REMOTE"
  end

  vim.cmd("buffer " .. local_buf)
  vim.cmd("file LOCAL")
  vim.bo.modifiable = false
  vim.bo.readonly = true
  vim.cmd("diffthis")

  vim.cmd("wincmd l")
  vim.cmd("buffer " .. base_buf)
  vim.cmd("file BASE")
  vim.bo.modifiable = false
  vim.bo.readonly = true
  vim.cmd("diffthis")

  vim.cmd("wincmd l")
  vim.cmd("buffer " .. remote_buf)
  vim.cmd("file REMOTE")
  vim.bo.modifiable = false
  vim.bo.readonly = true
  vim.cmd("diffthis")

  vim.cmd("wincmd h")
end

local function check_then_show_history()
  if effective_vcs() == "jj" then
    vim.cmd("echohl WarningMsg")
    vim.cmd([[echon "For jj history view, use :DiffConflictsWithHistory (e.g. from jj resolve)."]])
    vim.cmd("echohl None")
    return 1
  end

  local file_check
  if config.vcs == "hg" then
    file_check = function(name)
      return name:find("~base.$") or name:find("~local.$") or name:find("~other.$")
    end
  else
    file_check = function(name)
      return name:find("BASE$") or name:find("LOCAL$") or name:find("REMOTE$")
    end
  end

  local existing_buffers = vim.tbl_filter(function(bufnr)
    return vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_buf_get_name(bufnr) ~= ""
      and file_check(vim.api.nvim_buf_get_name(bufnr))
  end, vim.api.nvim_list_bufs())

  if #existing_buffers < 3 then
    vim.cmd("echohl WarningMsg")
    vim.cmd([[echon "Missing one or more of BASE, LOCAL, REMOTE. Was Neovim invoked by a Git mergetool?"]])
    vim.cmd("echohl None")
    return 1
  else
    show_history()
    return 0
  end
end

local function check_then_diff()
  if effective_vcs() == "jj" then
    jj_run(false, nil, nil)
    return
  end

  if has_conflicts() then
    vim.cmd("redraw")
    vim.cmd("echohl WarningMsg")
    vim.cmd([[echon "Resolve conflicts leftward then save. Use :cq to abort."]])
    vim.cmd("echohl None")
    diff_confl()
  else
    vim.cmd('echohl WarningMsg | echo "No conflict markers found." | echohl None')
  end
end

M.show = check_then_show_history
M.show_history = check_then_show_history
M.show_with_history = function()
  check_then_show_history()
  vim.cmd("1tabn")
  check_then_diff()
end

local function command_diff_conflicts(opts)
  if effective_vcs() == "jj" then
    -- Support jj resolve invocation:
    --   :DiffConflicts $output
    jj_run(false, nil, opts.fargs)
    return
  end
  check_then_diff()
end

local function command_show_history(_opts)
  if effective_vcs() == "jj" then
    vim.cmd("echohl WarningMsg")
    vim.cmd([[echon "For jj history view, use :DiffConflictsWithHistory (e.g. from jj resolve)."]])
    vim.cmd("echohl None")
    return
  end
  check_then_show_history()
end

local function command_with_history(opts)
  if effective_vcs() == "jj" then
    -- Support jj resolve invocation:
    --   :DiffConflictsWithHistory $output $base $left $right
    jj_run(true, nil, opts.fargs)
    return
  end
  M.show_with_history()
end

---Sets up the plugin with user configuration.
---@param opts table Configuration options.
---@field vcs string The version control system to use ("git" or "hg").
---@field commands table A table of command names to override.
---@field commands.diff_conflicts string|nil Name for the diff conflicts command.
---@field commands.show_history string|nil Name for the show history command.
---@field commands.with_history string|nil Name for the command to show history and diff conflicts.
---@field commands.jj_diff_conflicts string|nil Name for the Jujutsu diff conflicts command.
function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", config, opts)

  if config.commands.diff_conflicts then
    vim.api.nvim_create_user_command(
      config.commands.diff_conflicts,
      command_diff_conflicts,
      { bang = false, nargs = "*", complete = "file" }
    )
  end
  if config.commands.show_history then
    vim.api.nvim_create_user_command(config.commands.show_history, command_show_history, { bang = false, nargs = "*" })
  end
  if config.commands.with_history then
    vim.api.nvim_create_user_command(
      config.commands.with_history,
      command_with_history,
      { bang = false, nargs = "*", complete = "file" }
    )
  end
end

return M
