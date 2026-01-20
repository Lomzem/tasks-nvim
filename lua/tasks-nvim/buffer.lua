local cache = require("tasks-nvim.cache")

local M = {}

-- Buffer state
local bufnr = nil
local augroup = nil

--- Get the task buffer number (or nil if not open)
---@return number|nil
function M.get_bufnr()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  bufnr = nil
  return nil
end

--- Format a single task as a buffer line
---@param id string Task ID
---@param task table Task data
---@return string line
local function format_task_line(id, task)
  local status_char = task.status == "completed" and "x" or " "
  local due_part = ""

  if task.due then
    -- Extract just the date part if it's a full ISO timestamp
    local date_str = task.due:match("^(%d%d%d%d%-%d%d%-%d%d)")
    if date_str then
      due_part = date_str .. " "
    end
  end

  return string.format("/%s - [%s] %s%s", id, status_char, due_part, task.title or "")
end

--- Parse a single buffer line into task data
---@param line string Buffer line
---@return string|nil id Task ID (or nil if line is invalid/empty)
---@return table|nil task Task data
function M.parse_line(line)
  -- Skip empty lines
  if not line or line:match("^%s*$") then
    return nil, nil
  end

  -- Pattern: /ID - [x] YYYY-MM-DD Title
  -- or: /ID - [x] Title (no date)
  -- The ID can be a Google ID (base64-ish) or new:N

  -- First, try to extract the ID
  local id, rest = line:match("^/([^%s]+)%s+(.*)$")

  if not id then
    -- Line without ID - this is a new task
    -- Try to parse: - [x] YYYY-MM-DD Title or - [x] Title
    rest = line
    id = nil
  end

  if not rest then
    return nil, nil
  end

  -- Parse the rest: - [x] YYYY-MM-DD Title or - [x] Title
  local status_char, date_str, title

  -- Try with date first
  status_char, date_str, title = rest:match("^%-%s*%[([%sx])%]%s+(%d%d%d%d%-%d%d%-%d%d)%s+(.*)$")

  if not status_char then
    -- Try without date
    status_char, title = rest:match("^%-%s*%[([%sx])%]%s+(.*)$")
    date_str = nil
  end

  if not status_char or not title then
    return nil, nil
  end

  local task = {
    title = title,
    status = status_char == "x" and "completed" or "needsAction",
    due = date_str,
  }

  return id, task
end

--- Render tasks to the buffer
---@param tasks table<string, table> Map of task ID to task data
function M.render(tasks)
  local buf = M.get_bufnr()
  if not buf then
    return
  end

  -- Sort tasks: incomplete first (by due date), then completed
  local sorted = {}
  for id, task in pairs(tasks) do
    table.insert(sorted, { id = id, task = task })
  end

  table.sort(sorted, function(a, b)
    -- Incomplete tasks come before completed
    local a_completed = a.task.status == "completed"
    local b_completed = b.task.status == "completed"

    if a_completed ~= b_completed then
      return not a_completed
    end

    -- Within same completion status, sort by due date (earliest first, nil last)
    local a_due = a.task.due
    local b_due = b.task.due

    if a_due and b_due then
      return a_due < b_due
    elseif a_due then
      return true
    elseif b_due then
      return false
    end

    -- Fall back to title
    return (a.task.title or "") < (b.task.title or "")
  end)

  -- Build lines
  local lines = {}
  for _, item in ipairs(sorted) do
    table.insert(lines, format_task_line(item.id, item.task))
  end

  -- Update buffer
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modified", false)
end

--- Parse all lines in the buffer and return task data
---@return table<string, table> parsed Map of ID to task data (ID is nil key for new tasks)
---@return table new_tasks List of tasks without IDs (new tasks)
function M.parse()
  local buf = M.get_bufnr()
  if not buf then
    return {}, {}
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local parsed = {}
  local new_tasks = {}

  for _, line in ipairs(lines) do
    local id, task = M.parse_line(line)
    if task then
      if id then
        parsed[id] = task
      else
        table.insert(new_tasks, task)
      end
    end
  end

  return parsed, new_tasks
end

--- Update a specific line in the buffer by task ID
---@param id string Task ID
---@param task table Task data
function M.update_line(id, task)
  local buf = M.get_bufnr()
  if not buf then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    local line_id = line:match("^/([^%s]+)")
    if line_id == id then
      local new_line = format_task_line(id, task)
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { new_line })
      return
    end
  end

  -- ID not found, append as new line
  local new_line = format_task_line(id, task)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { new_line })
end

--- Remove a line from the buffer by task ID
---@param id string Task ID
function M.remove_line(id)
  local buf = M.get_bufnr()
  if not buf then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    local line_id = line:match("^/([^%s]+)")
    if line_id == id then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, {})
      return
    end
  end
end

--- Setup buffer-local autocmds
---@param buf number Buffer number
---@param on_save function Callback when buffer is saved
local function setup_autocmds(buf, on_save)
  augroup = vim.api.nvim_create_augroup("TasksNvim", { clear = true })

  -- Handle buffer save
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = buf,
    callback = function()
      on_save()
      -- Mark buffer as not modified after save
      vim.api.nvim_buf_set_option(buf, "modified", false)
    end,
  })

  -- Handle yank to strip ID prefix
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = augroup,
    buffer = buf,
    callback = function()
      local event = vim.v.event
      if not event or not event.regcontents then
        return
      end

      -- Strip the /ID prefix from each yanked line
      local modified = false
      local new_contents = {}

      for _, line in ipairs(event.regcontents) do
        -- Remove /ID prefix if present
        local stripped = line:gsub("^/[^%s]+%s+", "")
        if stripped ~= line then
          modified = true
        end
        table.insert(new_contents, stripped)
      end

      if modified then
        -- Update the register with stripped content
        local regname = event.regname
        if regname == "" then
          regname = '"'
        end
        vim.fn.setreg(regname, new_contents, event.regtype)
      end
    end,
  })

  -- Cleanup on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    buffer = buf,
    callback = function()
      bufnr = nil
    end,
  })
end

--- Open the tasks buffer
---@param on_save function Callback when buffer is saved
---@return number buf Buffer number
function M.open(on_save)
  -- If buffer already exists and is valid, just switch to it
  local existing = M.get_bufnr()
  if existing then
    -- Find a window displaying this buffer, or open in current window
    local wins = vim.fn.win_findbuf(existing)
    if #wins > 0 then
      vim.api.nvim_set_current_win(wins[1])
    else
      vim.api.nvim_set_current_buf(existing)
    end
    return existing
  end

  -- Create new buffer
  bufnr = vim.api.nvim_create_buf(true, false)

  -- Set buffer options
  vim.api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")
  vim.api.nvim_buf_set_name(bufnr, "tasks://default")

  -- Set window options for concealment
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_option(0, "conceallevel", 3)
  vim.api.nvim_win_set_option(0, "concealcursor", "nvic")

  -- Apply syntax for concealment
  vim.cmd("syntax match tasksId /^\\/[^ ]* / conceal")

  -- Setup autocmds
  setup_autocmds(bufnr, on_save)

  return bufnr
end

--- Close the tasks buffer
function M.close()
  local buf = M.get_bufnr()
  if buf then
    vim.api.nvim_buf_delete(buf, { force = true })
    bufnr = nil
  end
end

--- Check if the buffer is currently modified
---@return boolean
function M.is_modified()
  local buf = M.get_bufnr()
  if not buf then
    return false
  end
  return vim.api.nvim_buf_get_option(buf, "modified")
end

return M
