local M = {}

-- Buffer state
local bufnr = nil
local augroup = nil
local extmark_ns = vim.api.nvim_create_namespace("tasks-nvim")

-- Checkbox icons
local ICON_UNCHECKED = "󰄱 "
local ICON_CHECKED = "󰱒 "

-- Configuration (set by init.lua during setup)
M.config = {
  keys = {
    toggle = "<CR>",
  },
}

--- Calculate the minimum column position (after the concealed prefix)
--- Format: /ID - [x] YYYY-MM-DD Title
--- The prefix /ID - [x] is concealed/rendered, user edits from date/title onwards
---@param line string The buffer line
---@return number min_col The 0-indexed column where editable content starts
local function get_editable_start_col(line)
  if not line then
    return 0
  end

  -- Match: /ID - [x] (with trailing space)
  local prefix = line:match("^(/[^%s]+ %- %[[x ]%] )")
  if prefix then
    return #prefix
  end

  -- Fallback: just /ID -
  local id_prefix = line:match("^(/[^%s]+ %- )")
  if id_prefix then
    return #id_prefix
  end

  return 0
end

--- Constrain cursor to editable portion of the line
local function constrain_cursor()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local min_col = get_editable_start_col(line)

  if cursor[2] < min_col then
    vim.api.nvim_win_set_cursor(0, { cursor[1], min_col })
  end
end

--- Set window options for concealment
---@param winid number|nil Window ID (defaults to current window)
local function set_win_options(winid)
  winid = winid or vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("conceallevel", 3, { scope = "local", win = winid })
  vim.api.nvim_set_option_value("concealcursor", "nvic", { scope = "local", win = winid })
end

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
--- Format: /ID - [x] YYYY-MM-DD Title  or  /ID - [ ] Title
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
--- Format: /ID - [x] YYYY-MM-DD Title  or  /ID - [ ] Title  or  plain text (new task)
---@param line string Buffer line
---@return string|nil id Task ID (or nil if line is invalid/empty or new task)
---@return table|nil task Task data
function M.parse_line(line)
  -- Skip empty lines
  if not line or line:match("^%s*$") then
    return nil, nil
  end

  -- Try to extract ID: /ID - ...
  local id, rest = line:match("^/([^%s]+) %- (.*)$")

  if not id then
    -- No ID prefix - treat as new task (plain text)
    local title = line:match("^%s*(.-)%s*$")
    if title and title ~= "" then
      return nil, {
        title = title,
        status = "needsAction",
        due = nil,
      }
    end
    return nil, nil
  end

  -- Parse checkbox: [x] or [ ]
  local status_char, after_checkbox = rest:match("^%[([%sx])%]%s+(.*)$")

  if not status_char then
    -- No valid checkbox, treat rest as title
    return id, {
      title = rest,
      status = "needsAction",
      due = nil,
    }
  end

  -- Parse date and title from after_checkbox
  local date_str, title = after_checkbox:match("^(%d%d%d%d%-%d%d%-%d%d)%s+(.*)$")
  if not date_str then
    -- No date, rest is title
    title = after_checkbox
  end

  if not title or title == "" then
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
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  -- Apply extmarks for rendering
  M.apply_extmarks()
end

--- Apply extmarks to render the buffer nicely
--- - Conceals /ID - prefix
--- - Renders checkbox icons over [ ] and [x]
--- - Highlights dates
function M.apply_extmarks()
  local buf = M.get_bufnr()
  if not buf then
    return
  end

  -- Clear existing extmarks
  vim.api.nvim_buf_clear_namespace(buf, extmark_ns, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    local row = i - 1 -- 0-indexed

    -- Find the prefix pattern: /ID - [x] or /ID - [ ]
    local prefix_end = line:find("%] ")
    if prefix_end then
      -- Conceal /ID - (everything before the checkbox)
      local checkbox_start = line:find("%[")
      if checkbox_start and checkbox_start > 1 then
        vim.api.nvim_buf_set_extmark(buf, extmark_ns, row, 0, {
          end_col = checkbox_start - 1,
          conceal = "",
        })
      end

      -- Render checkbox icon over [x] or [ ]
      local is_checked = line:match("%[x%]")
      local icon = is_checked and ICON_CHECKED or ICON_UNCHECKED
      local hl = is_checked and "DiagnosticOk" or "DiagnosticInfo"

      -- The checkbox is 3 chars: [ ] or [x]
      -- We overlay it with our icon
      if checkbox_start then
        vim.api.nvim_buf_set_extmark(buf, extmark_ns, row, checkbox_start - 1, {
          end_col = checkbox_start + 2, -- covers [x]
          conceal = "",
        })
        vim.api.nvim_buf_set_extmark(buf, extmark_ns, row, checkbox_start - 1, {
          virt_text = { { icon, hl } },
          virt_text_pos = "inline",
        })
      end
    end

    -- Find and highlight dates: YYYY-MM-DD
    local date_start, date_end = line:find("%d%d%d%d%-%d%d%-%d%d")
    if date_start then
      vim.api.nvim_buf_set_extmark(buf, extmark_ns, row, date_start - 1, {
        end_col = date_end,
        hl_group = "Special",
      })
    end
  end
end

--- Parse all lines in the buffer and return task data
---@return table<string, table> parsed Map of ID to task data
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
    -- Extract ID: /ID - ...
    local line_id = line:match("^/([^%s]+) %-")
    if line_id == id then
      local new_line = format_task_line(id, task)
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { new_line })
      M.apply_extmarks()
      return
    end
  end

  -- ID not found, append as new line
  local new_line = format_task_line(id, task)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { new_line })
  M.apply_extmarks()
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
    -- Extract ID: /ID - ...
    local line_id = line:match("^/([^%s]+) %-")
    if line_id == id then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, {})
      return
    end
  end
end

--- Toggle the completion status of the task on the current line
function M.toggle_completion()
  local buf = M.get_bufnr()
  if not buf then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()

  -- Toggle [ ] <-> [x]
  local new_line
  if line:match("%[%s%]") then
    new_line = line:gsub("%[%s%]", "[x]", 1)
  elseif line:match("%[x%]") then
    new_line = line:gsub("%[x%]", "[ ]", 1)
  else
    return -- Not a valid task line
  end

  vim.api.nvim_buf_set_lines(buf, cursor[1] - 1, cursor[1], false, { new_line })
  vim.bo[buf].modified = true
  M.apply_extmarks()
end

--- Setup buffer-local keymaps
---@param buf number Buffer number
local function setup_keymaps(buf)
  -- Toggle completion (configurable, can be disabled with false)
  local toggle_key = M.config.keys and M.config.keys.toggle
  if toggle_key then
    vim.keymap.set("n", toggle_key, function()
      M.toggle_completion()
    end, { buffer = buf, desc = "Toggle task completion" })
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
      vim.bo[buf].modified = false
    end,
  })

  -- Handle yank to strip ID prefix from lines
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = augroup,
    buffer = buf,
    callback = function()
      local event = vim.v.event
      if not event or not event.regcontents then
        return
      end

      -- Strip the /ID - prefix from each yanked line
      local modified = false
      local new_contents = {}

      for _, line in ipairs(event.regcontents) do
        -- Remove /ID - prefix if present
        local stripped = line:gsub("^/[^%s]+ %- ", "")
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

  -- Constrain cursor to editable area
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = buf,
    callback = constrain_cursor,
  })

  -- Also constrain on InsertEnter with schedule to handle cursor bounce-back
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    buffer = buf,
    callback = function()
      vim.schedule(constrain_cursor)
    end,
  })

  -- Reapply extmarks when leaving insert mode
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        M.apply_extmarks()
      end)
    end,
  })

  -- Reapply extmarks after text changes (handles paste, undo, etc.)
  vim.api.nvim_create_autocmd("TextChanged", {
    group = augroup,
    buffer = buf,
    callback = function()
      M.apply_extmarks()
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

  -- Ensure window options are set when entering buffer
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = buf,
    callback = function()
      set_win_options()
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
    -- Ensure window options are set
    set_win_options()
    return existing
  end

  -- Create new buffer
  bufnr = vim.api.nvim_create_buf(true, false)

  -- Set buffer options
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "tasks"

  vim.api.nvim_buf_set_name(bufnr, "tasks://default")

  -- Switch to buffer first
  vim.api.nvim_set_current_buf(bufnr)

  -- Set window options
  set_win_options()

  -- Setup autocmds
  setup_autocmds(bufnr, on_save)

  -- Setup keymaps
  setup_keymaps(bufnr)

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
  return vim.bo[buf].modified
end

return M
