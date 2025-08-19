local M = {}

local config = {
  vcs = "git", -- Default VCS to use
  commands = {
    diff_conflicts = "DiffConflicts",
    show_history = "DiffConflictsShowHistory",
    with_history = "DiffConflictsWithHistory",
  },
}

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

---Sets up the plugin with user configuration.
---@param opts table Configuration options.
---@field vcs string The version control system to use ("git" or "hg").
---@field commands table A table of command names to override.
---@field commands.diff_conflicts string|nil Name for the diff conflicts command.
---@field commands.show_history string|nil Name for the show history command.
---@field commands.with_history string|nil Name for the command to show history and diff conflicts.
function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", config, opts)

  if config.commands.diff_conflicts then
    vim.api.nvim_create_user_command(config.commands.diff_conflicts, check_then_diff, {})
  end
  if config.commands.show_history then
    vim.api.nvim_create_user_command(config.commands.show_history, check_then_show_history, {})
  end
  if config.commands.with_history then
    vim.api.nvim_create_user_command(config.commands.with_history, M.show_with_history, {})
  end
end

return M
