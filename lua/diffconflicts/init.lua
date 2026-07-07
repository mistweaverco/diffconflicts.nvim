local M = {}

local config = {
  vcs = "git", -- "git" or "hg" (jj is auto-detected)
  commands = {
    diff_conflicts = "DiffConflicts",
    show_history = "DiffConflictsShowHistory",
    with_history = "DiffConflictsWithHistory",
  },
  qol = {
    advance_on_save = true,
    quit_on_done = true,
  },
  keymaps = {
    next_diff = "]g",
    prev_diff = "[g",
    accept = nil,
  },
}

local advance_augroup = vim.api.nvim_create_augroup("diffconflicts.nvim.advance", { clear = false })

-- Forward declarations: these are referenced from callbacks defined earlier in the file.
local detect_jj_marker_length_from_buffer
local buffer_looks_like_jj_conflict
local jj_run
local setup_diff_session

local function close_win_if_valid(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
end

local function delete_buf_if_valid(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function is_plugin_aux_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr) or ""
  local tail = vim.fn.fnamemodify(name, ":t")

  if tail == "RCONFL" or tail == "snapshot" or tail == "left" or tail == "base" or tail == "right" then
    return true
  end

  -- git/hg history view buffers
  if tail == "BASE" or tail == "LOCAL" or tail == "REMOTE" then
    return true
  end
  if tail:find("^~base%.$") or tail:find("^~local%.$") or tail:find("^~other%.$") then
    return true
  end

  return false
end

local function cleanup_plugin_aux_buffers(keep_buf)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= keep_buf and vim.api.nvim_buf_is_valid(b) and is_plugin_aux_buffer(b) then
      delete_buf_if_valid(b)
    end
  end
end

local function systemlist_trim(cmd)
  local out = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return vim.tbl_filter(function(s)
    return s and s ~= ""
  end, out)
end

local function repo_root_from_path(marker, path)
  if not path or path == "" then
    return nil
  end
  local start = vim.fn.fnamemodify(path, ":p:h")
  local found = vim.fs.find(marker, { upward = true, path = start })
  if not found or #found == 0 then
    return nil
  end
  -- `vim.fs.find()` may return the marker with a trailing slash (e.g. ".../.git/"),
  -- which makes `:p:h` return ".../.git". Normalize first so we always return the
  -- repository root directory (the parent of the marker).
  local marker_path = vim.fn.fnamemodify(found[1], ":p"):gsub("/+$", "")
  return vim.fn.fnamemodify(marker_path, ":h")
end

local function repo_root_for_vcs_and_path(vcs, current_abs_path)
  if vcs == "jj" then
    return repo_root_from_path(".jj", current_abs_path)
  end
  return repo_root_from_path(".git", current_abs_path)
end

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

local function conflicted_files_for_vcs(vcs)
  local current = vim.api.nvim_buf_get_name(0)
  local root = repo_root_for_vcs_and_path(vcs, current) or vim.uv.cwd() or ""
  local root_esc = vim.fn.shellescape(root)

  if vcs == "jj" then
    -- jj prints relative paths
    return systemlist_trim("jj -R " .. root_esc .. " resolve --list")
  end
  -- git/hg: for now, git-style "U" filter is used (hg mergetool use-case is separate)
  return systemlist_trim("git -C " .. root_esc .. " diff --name-only --diff-filter=U")
end

local function advance_to_next_conflicted_file_for_vcs(vcs, current_abs_path)
  local files = conflicted_files_for_vcs(vcs)
  if vim.tbl_isempty(files) then
    return false
  end

  local root = repo_root_for_vcs_and_path(vcs, current_abs_path)
  if not root then
    return false
  end

  local current_rel = nil
  if current_abs_path and current_abs_path ~= "" then
    local p = vim.fn.fnamemodify(current_abs_path, ":p")
    local r = vim.fn.fnamemodify(root, ":p")
    if p:sub(1, #r + 1) == r .. "/" then
      current_rel = p:sub(#r + 2)
    end
  end

  local next_rel = nil
  if current_rel then
    for i, f in ipairs(files) do
      if f == current_rel then
        next_rel = files[i + 1]
        break
      end
    end
  end
  next_rel = next_rel or files[1]

  local next_abs = vim.fn.fnamemodify(root .. "/" .. next_rel, ":p")
  if current_abs_path and vim.fn.fnamemodify(current_abs_path, ":p") == next_abs then
    return false
  end

  vim.cmd.edit(vim.fn.fnameescape(next_abs))

  -- Re-open the diff view for the new buffer.
  -- Use the configured command so we don't depend on local function order.
  vim.schedule(function()
    if config.commands and config.commands.diff_conflicts then
      pcall(function()
        vim.cmd(config.commands.diff_conflicts)
      end)
    else
      pcall(function()
        vim.cmd("DiffConflicts")
      end)
    end
  end)

  return true
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

  local left_buf = vim.api.nvim_get_current_buf()
  local left_win = vim.api.nvim_get_current_win()

  vim.cmd.vsplit({ mods = { split = "belowright" } })
  vim.cmd.enew()
  local right_win = vim.api.nvim_get_current_win()
  local right_buf = vim.api.nvim_get_current_buf()
  local right_side = jj_get_content_for_side("right_side", conflicts, vim.deepcopy(conflicted_content))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, right_side)
  vim.cmd.file("snapshot")
  vim.bo.filetype = original_filetype
  vim.cmd([[setlocal nomodifiable readonly buftype=nofile bufhidden=delete nobuflisted]])
  vim.cmd.diffthis()

  vim.cmd.wincmd("p")
  -- Ensure we are back on the original buffer/window.
  if vim.api.nvim_get_current_buf() ~= left_buf and vim.api.nvim_win_is_valid(left_win) then
    vim.api.nvim_set_current_win(left_win)
  end
  local left_side = jj_get_content_for_side("left_side", conflicts, vim.deepcopy(conflicted_content))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, left_side)
  vim.cmd.diffthis()

  vim.cmd.diffupdate()
  vim.fn.cursor(conflicts[1].top_line, 1)
  setup_diff_session(left_buf, right_buf, left_win, right_win)

  -- QoL: save-to-advance (and optionally quit when done).
  if config.qol and config.qol.advance_on_save then
    vim.api.nvim_clear_autocmds({ group = advance_augroup, buffer = left_buf })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = advance_augroup,
      buffer = left_buf,
      callback = function()
        close_win_if_valid(right_win)
        delete_buf_if_valid(right_buf)
        cleanup_plugin_aux_buffers(left_buf)

        -- If there are more conflicts, reopen diff view; otherwise optionally quit.
        local lines = vim.api.nvim_buf_get_lines(left_buf, 0, -1, false)
        if buffer_looks_like_jj_conflict(lines) then
          -- Re-run using inferred marker length so we always match the buffer.
          jj_run(false, detect_jj_marker_length_from_buffer(lines), nil)
          return
        end

        local current = vim.api.nvim_buf_get_name(left_buf)
        local advanced = advance_to_next_conflicted_file_for_vcs("jj", current)
        if advanced then
          return
        end

        if config.qol and config.qol.quit_on_done then
          -- If we were launched as a mergetool, leaving Neovim is the smoothest way
          -- to hand control back to the VCS tooling.
          pcall(function()
            vim.cmd("qa")
          end)
        end
      end,
    })
  end
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

jj_run = function(show_history, marker_length, fargs)
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

detect_jj_marker_length_from_buffer = function(lines)
  -- jj conflict markers look like:
  --   <<<<<<< <description>
  --   %%%%%%% <description>
  --   +++++++ <description>
  --   >>>>>>> <description>
  --
  -- The marker length is configurable; infer it from the first "<<<<<<<" line.
  for _, line in ipairs(lines) do
    local run = line:match("^(<+)%s.+$")
    if run then
      return #run
    end
  end
  return nil
end

buffer_looks_like_jj_conflict = function(lines)
  local has_top = false
  local has_diff = false
  local has_snapshot = false
  local has_bottom = false

  for _, line in ipairs(lines) do
    if not has_top and line:match("^<+%s.+$") then
      has_top = true
    elseif not has_diff and line:match("^%%+%%+%s.+$") then
      -- "%%%%%%%" in Lua patterns needs escaping; this matches 2+ '%' chars then space.
      has_diff = true
    elseif not has_snapshot and line:match("^%+%+%s.+$") then
      -- "+++++++" (2+ '+' chars then space)
      has_snapshot = true
    elseif not has_bottom and line:match("^>+%s.+$") then
      has_bottom = true
    end
  end

  return has_top and has_bottom and (has_diff or has_snapshot)
end

local function get_diff_session(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local session = vim.b[bufnr].diffconflicts_session
  local role = vim.b[bufnr].diffconflicts_role
  if not session or not role then
    return nil, nil
  end
  if not vim.api.nvim_buf_is_valid(session.left_buf) or not vim.api.nvim_buf_is_valid(session.right_buf) then
    return nil, nil
  end
  return session, role
end

function M.next_diff()
  local session = get_diff_session()
  if not session then
    vim.notify("diffconflicts.nvim: not in a diff conflicts session", vim.log.levels.WARN)
    return
  end
  local before = vim.fn.line(".")
  vim.cmd.normal({ args = { "]c" }, bang = true })
  if vim.fn.line(".") == before then
    vim.notify("diffconflicts.nvim: no next diff", vim.log.levels.INFO)
  end
end

function M.prev_diff()
  local session = get_diff_session()
  if not session then
    vim.notify("diffconflicts.nvim: not in a diff conflicts session", vim.log.levels.WARN)
    return
  end
  local before = vim.fn.line(".")
  vim.cmd.normal({ args = { "[c" }, bang = true })
  if vim.fn.line(".") == before then
    vim.notify("diffconflicts.nvim: no previous diff", vim.log.levels.INFO)
  end
end

function M.accept()
  local session, role = get_diff_session()
  if not session then
    vim.notify("diffconflicts.nvim: not in a diff conflicts session", vim.log.levels.WARN)
    return
  end
  if role == "left" then
    vim.cmd.diffget()
  else
    vim.cmd.diffput()
  end
end

local function register_diff_keymaps(left_buf, right_buf)
  if config.keymaps == false then
    return
  end

  local keymaps = config.keymaps or {}

  local function set_map(buf, key, fn, desc)
    if key and key ~= false then
      vim.keymap.set("n", key, fn, { buffer = buf, desc = desc, silent = true })
    end
  end

  for _, buf in ipairs({ left_buf, right_buf }) do
    if keymaps.next_diff ~= nil and keymaps.next_diff ~= false then
      set_map(buf, keymaps.next_diff, M.next_diff, "Next diff hunk")
    end
    if keymaps.prev_diff ~= nil and keymaps.prev_diff ~= false then
      set_map(buf, keymaps.prev_diff, M.prev_diff, "Previous diff hunk")
    end
    if keymaps.accept ~= nil and keymaps.accept ~= false then
      set_map(buf, keymaps.accept, M.accept, "Accept diff hunk from right")
    end
  end
end

setup_diff_session = function(left_buf, right_buf, left_win, right_win)
  local session = {
    left_buf = left_buf,
    right_buf = right_buf,
    left_win = left_win,
    right_win = right_win,
  }
  vim.b[left_buf].diffconflicts_session = session
  vim.b[left_buf].diffconflicts_role = "left"
  vim.b[right_buf].diffconflicts_session = session
  vim.b[right_buf].diffconflicts_role = "right"
  register_diff_keymaps(left_buf, right_buf)
end

local function diff_confl()
  if effective_vcs() == "jj" then
    jj_run(false, nil, nil)
    return
  end

  -- If we were invoked on a jj-style conflict buffer outside of a jj repo
  -- (e.g. `jj resolve` temp paths), fall back to jj parsing anyway.
  do
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if buffer_looks_like_jj_conflict(lines) then
      jj_run(false, detect_jj_marker_length_from_buffer(lines), nil)
      return
    end
  end

  local orig_buf = vim.api.nvim_get_current_buf()
  local orig_ft = vim.bo.filetype
  local left_win = vim.api.nvim_get_current_win()

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
  local right_win = vim.api.nvim_get_current_win()
  local right_buf = vim.api.nvim_get_current_buf()
  vim.cmd('silent execute "read #" .. ' .. orig_buf)
  vim.api.nvim_buf_set_lines(0, 0, 1, false, {}) -- Delete the first line
  vim.cmd("silent file RCONFL")
  vim.bo.filetype = orig_ft
  vim.cmd("diffthis")

  vim.cmd("silent! g/^<<<<<<< /,/^=======\\r\\?$/d")
  vim.cmd("silent! g/^>>>>>>> /d")

  vim.bo.modifiable = false
  vim.bo.readonly = true
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "delete"
  vim.bo.buflisted = false

  -- Set up the left-hand side.
  vim.cmd("wincmd p")
  vim.cmd("diffthis")

  if conflict_style:lower() == "diff3" or conflict_style:lower() == "zdiff3" then
    vim.cmd("silent! g/^||||||| \\?/,/^>>>>>>> /d")
  else
    vim.cmd("silent! g/^=======\\r\\?$/,/^>>>>>>> /d")
  end
  vim.cmd("silent! g/^<<<<<<< /d")

  vim.cmd("diffupdate")
  setup_diff_session(orig_buf, right_buf, left_win, right_win)

  -- QoL: save-to-advance (and optionally quit when done).
  if config.qol and config.qol.advance_on_save then
    vim.api.nvim_clear_autocmds({ group = advance_augroup, buffer = orig_buf })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = advance_augroup,
      buffer = orig_buf,
      callback = function()
        close_win_if_valid(right_win)
        delete_buf_if_valid(right_buf)
        cleanup_plugin_aux_buffers(orig_buf)
        if vim.api.nvim_win_is_valid(left_win) then
          pcall(vim.api.nvim_set_current_win, left_win)
        end

        if has_conflicts() then
          diff_confl()
          return
        end

        local current = vim.api.nvim_buf_get_name(orig_buf)
        local advanced = advance_to_next_conflicted_file_for_vcs("git", current)
        if advanced then
          return
        end

        if config.qol and config.qol.quit_on_done then
          pcall(function()
            vim.cmd("qa")
          end)
        end
      end,
    })
  end
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

  local function load_history_buf(bufnr, name)
    vim.cmd("buffer " .. tostring(bufnr))
    -- Avoid swapfile issues and keep these buffers read-only.
    -- (Some environments disallow writing swap/shada to default locations.)
    vim.cmd("setlocal noswapfile")
    vim.cmd("silent! file " .. name)
    vim.cmd([[setlocal statusline=%t]])
    vim.bo.modifiable = false
    vim.bo.readonly = true
    vim.cmd("diffthis")
  end

  local bufs = vim.g.diffconflicts_history_bufs
  if type(bufs) ~= "table" or not (bufs.base and bufs["local"] and bufs.remote) then
    vim.cmd("echohl WarningMsg")
    vim.cmd([[echon "Missing BASE/LOCAL/REMOTE buffers. Was Neovim invoked by a Git mergetool?"]])
    vim.cmd("echohl None")
    return
  end

  load_history_buf(bufs["local"], "LOCAL")
  vim.bo.modifiable = false
  vim.bo.readonly = true

  vim.cmd("wincmd l")
  load_history_buf(bufs.base, "BASE")

  vim.cmd("wincmd l")
  load_history_buf(bufs.remote, "REMOTE")

  vim.cmd("wincmd h")
end

local function check_then_show_history()
  if effective_vcs() == "jj" then
    vim.cmd("echohl WarningMsg")
    vim.cmd([[echon "For jj history view, use :DiffConflictsWithHistory (e.g. from jj resolve)."]])
    vim.cmd("echohl None")
    return 1
  end

  -- If we were seeded with explicit history buffers (e.g. from mergetool args),
  -- trust that and skip discovery.
  do
    local bufs = vim.g.diffconflicts_history_bufs
    if type(bufs) == "table" and bufs.base and bufs["local"] and bufs.remote then
      show_history()
      return 0
    end
  end

  local function maybe_generate_git_stage_history_buffers()
    -- When the user runs :DiffConflictsWithHistory manually (not via git mergetool),
    -- there are no temp files. But Git *does* expose the conflict stages:
    --   :1 = BASE, :2 = LOCAL (ours), :3 = REMOTE (theirs)
    if effective_vcs() ~= "git" then
      return false
    end

    local merged_abs = vim.api.nvim_buf_get_name(0)
    if not merged_abs or merged_abs == "" then
      return false
    end

    local root = repo_root_for_vcs_and_path("git", merged_abs)
    if not root or root == "" then
      return false
    end

    local merged_p = vim.fn.fnamemodify(merged_abs, ":p")
    local root_p = vim.fn.fnamemodify(root, ":p")
    -- `:p` on directories often includes a trailing slash; normalize so prefix
    -- comparisons and relative slicing work reliably.
    root_p = root_p:gsub("/+$", "")
    if merged_p:sub(1, #root_p + 1) ~= root_p .. "/" then
      return false
    end
    local rel = merged_p:sub(#root_p + 2)

    local function git_show_stage(stage)
      -- Use -C to ensure correct repo, and --no-pager to avoid pager surprises.
      local spec = ":" .. stage .. ":" .. rel
      local cmd = "git -C " .. vim.fn.shellescape(root_p) .. " --no-pager show " .. vim.fn.shellescape(spec)
      local out = vim.fn.systemlist(cmd)
      if vim.v.shell_error ~= 0 then
        return nil
      end
      return out
    end

    local base_lines = git_show_stage("1")
    local local_lines = git_show_stage("2")
    local remote_lines = git_show_stage("3")
    if not (base_lines and local_lines and remote_lines) then
      return false
    end

    local original_ft = vim.bo.filetype

    local function make_stage_buf(lines, name)
      local b = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true
      vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
      vim.api.nvim_buf_set_name(b, name)
      -- Ensure these are ephemeral, read-only buffers.
      vim.bo[b].modifiable = false
      vim.bo[b].readonly = true
      vim.bo[b].buftype = "nofile"
      vim.bo[b].bufhidden = "delete"
      vim.bo[b].swapfile = false
      vim.bo[b].filetype = original_ft
      return b
    end

    vim.g.diffconflicts_history_bufs = {
      base = make_stage_buf(base_lines, "BASE"),
      ["local"] = make_stage_buf(local_lines, "LOCAL"),
      remote = make_stage_buf(remote_lines, "REMOTE"),
    }
    return true
  end

  local function tail(name)
    return vim.fn.fnamemodify(name or "", ":t")
  end

  local function current_dir()
    local cur = vim.api.nvim_buf_get_name(0)
    if cur and cur ~= "" then
      return vim.fn.fnamemodify(cur, ":p:h")
    end
    return vim.uv.cwd()
  end

  local function match_git_role(t, role)
    local tu = (t or ""):upper()
    local ru = (role or ""):upper()

    if tu == ru then
      return true
    end

    -- Treat the role as a token delimited by common filename separators.
    -- Note: Lua's `%w` includes `_`, so we avoid frontier patterns and use an explicit delimiter set.
    -- Matches:
    --   poem_BASE_11614.txt, poem.BASE.11614, poem-BASE-11614, BASE.poem, poem.BASE
    -- Avoids:
    --   REBASE (no delimiter before BASE)
    local delim = "[%._%-_]"

    if tu:match("^" .. ru .. delim) then
      return true
    end
    if tu:match("(" .. delim .. ")" .. ru .. "$") then
      return true
    end
    if tu:match("(" .. delim .. ")" .. ru .. "(" .. delim .. ")") then
      return true
    end
    return false
  end

  local function match_hg_role(t, role)
    if role == "BASE" then
      return t:find("^~base%.$") ~= nil
    end
    if role == "LOCAL" then
      return t:find("^~local%.$") ~= nil
    end
    if role == "REMOTE" then
      return t:find("^~other%.$") ~= nil
    end
    return false
  end

  local function try_open_history_files_from_disk()
    -- If the buffers aren't present (common when the user runs :DiffConflictsWithHistory
    -- outside of a mergetool-invoked session), attempt to locate sibling files on disk.
    local dir = current_dir()
    if not dir or dir == "" then
      return
    end

    local cur_name = vim.api.nvim_buf_get_name(0)
    local cur_tail = tail(cur_name)
    local cur_stem = vim.fn.fnamemodify(cur_tail, ":r")
    local cur_ext = vim.fn.fnamemodify(cur_tail, ":e")

    local function glob_first(pattern)
      local matches = vim.fn.globpath(dir, pattern, false, true) or {}
      return matches[1]
    end

    local function best_match(paths, role)
      for _, p in ipairs(paths) do
        local t = tail(p)
        if config.vcs == "hg" then
          if match_hg_role(t, role) or match_hg_role(p, role) then
            return p
          end
        else
          if match_git_role(t, role) or match_git_role(p, role) then
            return p
          end
        end
      end
      return nil
    end

    -- Prefer files that share the same stem as the current file (e.g. poem_BASE_123.txt).
    -- This matches the `_utils` benchmark repo layout and avoids accidentally picking
    -- unrelated BASE/LOCAL/REMOTE files in the same directory.
    local base_p, local_p, remote_p
    if config.vcs ~= "hg" and cur_stem and cur_stem ~= "" then
      local suffix = (cur_ext and cur_ext ~= "") and ("." .. cur_ext) or ""
      base_p = glob_first(cur_stem .. "_BASE_*" .. suffix) or glob_first(cur_stem .. ".*BASE*")
      local_p = glob_first(cur_stem .. "_LOCAL_*" .. suffix) or glob_first(cur_stem .. ".*LOCAL*")
      remote_p = glob_first(cur_stem .. "_REMOTE_*" .. suffix) or glob_first(cur_stem .. ".*REMOTE*")
    end

    -- Fallback: scan all files in the directory.
    if not (base_p and local_p and remote_p) then
      local paths = vim.fn.globpath(dir, "*", false, true) or {}
      base_p = base_p or best_match(paths, "BASE")
      local_p = local_p or best_match(paths, "LOCAL")
      remote_p = remote_p or best_match(paths, "REMOTE")
    end

    -- Open any we found; ignore errors.
    for _, p in ipairs({ local_p, base_p, remote_p }) do
      if p and p ~= "" then
        pcall(vim.cmd.edit, vim.fn.fnameescape(p))
      end
    end
  end

  local function find_history_bufs()
    local found = { base = nil, ["local"] = nil, remote = nil }
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name and name ~= "" then
          local t = tail(name)
          local full = name
          if config.vcs == "hg" then
            if not found.base and (match_hg_role(t, "BASE") or match_hg_role(full, "BASE")) then
              found.base = bufnr
            elseif not found["local"] and (match_hg_role(t, "LOCAL") or match_hg_role(full, "LOCAL")) then
              found["local"] = bufnr
            elseif not found.remote and (match_hg_role(t, "REMOTE") or match_hg_role(full, "REMOTE")) then
              found.remote = bufnr
            end
          else
            if not found.base and (match_git_role(t, "BASE") or match_git_role(full, "BASE")) then
              found.base = bufnr
            elseif not found["local"] and (match_git_role(t, "LOCAL") or match_git_role(full, "LOCAL")) then
              found["local"] = bufnr
            elseif not found.remote and (match_git_role(t, "REMOTE") or match_git_role(full, "REMOTE")) then
              found.remote = bufnr
            end
          end
        end
      end
    end
    return found
  end

  local found = find_history_bufs()
  if not (found.base and found["local"] and found.remote) then
    -- Prefer generating from git conflict stages when invoked manually.
    if maybe_generate_git_stage_history_buffers() then
      show_history()
      return 0
    end
    try_open_history_files_from_disk()
    found = find_history_bufs()
  end

  if not (found.base and found["local"] and found.remote) then
    vim.cmd("echohl WarningMsg")
    vim.cmd([[echon "Missing one or more of BASE, LOCAL, REMOTE. Was Neovim invoked by a Git mergetool?"]])
    vim.cmd("echohl None")
    return 1
  else
    vim.g.diffconflicts_history_bufs = found
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

  -- Support git/hg mergetool invocation:
  --   :DiffConflicts $MERGED [$BASE $LOCAL $REMOTE]
  -- If a target path is provided, ensure it is the active buffer first.
  do
    local args = (opts and opts.fargs) or {}
    local merged = args[1]
    if not merged or merged == "" then
      -- When invoked via: nvim -c DiffConflicts "$MERGED" ...
      -- the file paths are available via argv(), not fargs.
      local argv = vim.fn.argv() or {}
      merged = argv[1]
    end
    if not merged or merged == "" then
      -- Some mergetool configurations don't pass file args to Neovim; fall back
      -- to standard Git mergetool environment variables.
      merged = vim.fn.getenv("MERGED")
    end
    if merged and merged ~= "" then
      local cur = vim.api.nvim_buf_get_name(0)
      local merged_abs = vim.fn.fnamemodify(merged, ":p")
      local cur_abs = cur ~= "" and vim.fn.fnamemodify(cur, ":p") or ""
      if cur_abs == "" or cur_abs ~= merged_abs then
        pcall(vim.cmd.edit, vim.fn.fnameescape(merged))
      end
    end
  end

  check_then_diff()
end

local function seed_history_bufs_from_args(opts)
  local args = (opts and opts.fargs) or {}
  local merged_path, base_path, local_path, remote_path

  if #args >= 4 then
    merged_path, base_path, local_path, remote_path = args[1], args[2], args[3], args[4]
  else
    -- When invoked via: nvim -c DiffConflictsWithHistory "$MERGED" "$BASE" "$LOCAL" "$REMOTE"
    -- the file paths are available via argv(), not fargs.
    local argv = vim.fn.argv() or {}
    if #argv >= 4 then
      merged_path, base_path, local_path, remote_path = argv[1], argv[2], argv[3], argv[4]
    else
      -- Some mergetool configurations don't pass file args to Neovim; fall back
      -- to standard Git mergetool environment variables.
      merged_path = vim.fn.getenv("MERGED")
      base_path = vim.fn.getenv("BASE")
      local_path = vim.fn.getenv("LOCAL")
      remote_path = vim.fn.getenv("REMOTE")

      if
        not (base_path and base_path ~= "" and local_path and local_path ~= "" and remote_path and remote_path ~= "")
      then
        return false
      end
    end
  end

  local function resolve_path(p, base_dir)
    -- `vim.fn.getenv()` can return vim.NIL (userdata) when unset.
    if type(p) ~= "string" then
      return nil
    end
    if p == "" then
      return nil
    end

    local function is_readable(path)
      return path and path ~= "" and vim.fn.filereadable(path) == 1
    end

    -- First try as-is (absolute) or relative to current cwd.
    local abs = vim.fn.fnamemodify(p, ":p")
    if is_readable(abs) then
      return abs
    end

    -- If that fails, resolve relative paths against the merged file's directory (more reliable).
    if base_dir and base_dir ~= "" then
      local cleaned = p:gsub("^%./", "")
      local candidate = vim.fn.fnamemodify(base_dir .. "/" .. cleaned, ":p")
      if is_readable(candidate) then
        return candidate
      end
    end

    -- Give up and return the best-effort absolute path (will create an empty buffer if missing).
    return abs
  end

  local function ensure_buf_for_path(p, base_dir)
    local abs = resolve_path(p, base_dir)
    if not abs or abs == "" then
      return nil
    end

    local existing = vim.fn.bufnr(abs, false)
    if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
      pcall(vim.fn.bufload, existing)
      return existing
    end

    -- Fallback: actually edit the file to force a real buffer with a name
    -- (some environments behave oddly with bufadd/bufload for non-current buffers).
    local cur_win = vim.api.nvim_get_current_win()
    local cur_buf = vim.api.nvim_get_current_buf()
    local ok = pcall(vim.cmd.edit, vim.fn.fnameescape(abs))
    local b = ok and vim.api.nvim_get_current_buf() or nil
    if cur_win and vim.api.nvim_win_is_valid(cur_win) then
      pcall(vim.api.nvim_set_current_win, cur_win)
    end
    if cur_buf and vim.api.nvim_buf_is_valid(cur_buf) then
      pcall(vim.api.nvim_set_current_buf, cur_buf)
    end
    return (b and vim.api.nvim_buf_is_valid(b)) and b or nil
  end

  local base_dir = nil
  if merged_path and merged_path ~= "" then
    local merged_abs = resolve_path(merged_path, nil)
    if merged_abs then
      base_dir = vim.fn.fnamemodify(merged_abs, ":p:h")
    end
  end
  if not base_dir or base_dir == "" then
    local cur = vim.api.nvim_buf_get_name(0)
    base_dir = cur ~= "" and vim.fn.fnamemodify(cur, ":p:h") or vim.uv.cwd()
  end

  local bufs = {
    base = ensure_buf_for_path(base_path, base_dir),
    ["local"] = ensure_buf_for_path(local_path, base_dir),
    remote = ensure_buf_for_path(remote_path, base_dir),
  }

  if bufs.base and bufs["local"] and bufs.remote then
    vim.g.diffconflicts_history_bufs = bufs
    return true
  end
  return false
end

local function command_show_history(opts)
  if effective_vcs() == "jj" then
    vim.cmd("echohl WarningMsg")
    vim.cmd([[echon "For jj history view, use :DiffConflictsWithHistory (e.g. from jj resolve)."]])
    vim.cmd("echohl None")
    return
  end
  -- Allow wrappers to call show-history directly with mergetool args.
  seed_history_bufs_from_args(opts)
  check_then_show_history()
end

local function command_with_history(opts)
  if effective_vcs() == "jj" then
    -- Support jj resolve invocation:
    --   :DiffConflictsWithHistory $output $base $left $right
    jj_run(true, nil, opts.fargs)
    return
  end

  -- Support git/hg mergetool invocation:
  --   :DiffConflictsWithHistory $MERGED $BASE $LOCAL $REMOTE
  -- If args are present, seed the history buffers directly so we don't rely on
  -- buffer discovery heuristics.
  seed_history_bufs_from_args(opts)

  M.show_with_history()
end

---@class DiffConflictsConfig
---@field vcs string|nil The version control system to use ("git" or "hg").
---@field commands table|nil A table of command names to override.
---@field commands.diff_conflicts string|nil Name for the diff conflicts command.
---@field commands.show_history string|nil Name for the show history command.
---@field commands.with_history string|nil Name for the command to show history and diff conflicts.
---@field commands.jj_diff_conflicts string|nil Name for the Jujutsu diff conflicts command.
---@field keymaps table|boolean|nil Keymaps for diff navigation and accept actions.
---@field keymaps.next_diff string|boolean|nil Keymap for next diff hunk (default: "]g").
---@field keymaps.prev_diff string|boolean|nil Keymap for previous diff hunk (default: "[g").
---@field keymaps.accept string|boolean|nil Keymap to accept the right-pane change into the left pane.

---Sets up the plugin with user configuration.
---@param opts DiffConflictsConfig|nil Configuration options.
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
