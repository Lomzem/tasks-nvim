local util = require("tasks-nvim.util")

local M = {}

-- In-memory cache state
local cache = {
  last_synced = nil,
  next_new_id = 1,
  tasks = {},
}

-- Cache file path
local cache_dir = nil
local cache_file = nil

--- Initialize cache paths
local function init_paths()
  if cache_dir then
    return
  end
  cache_dir = vim.fn.stdpath("cache") .. "/tasks-nvim"
  cache_file = cache_dir .. "/tasks.json"
end

--- Ensure the cache directory exists
local function ensure_cache_dir()
  init_paths()
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end
end

--- Load cache from disk
---@return boolean success True if cache was loaded successfully
function M.load()
  init_paths()

  local file = io.open(cache_file, "r")
  if not file then
    -- No cache file yet, start fresh
    cache = {
      last_synced = nil,
      next_new_id = 1,
      tasks = {},
    }
    return true
  end

  local content = file:read("*a")
  file:close()

  if content == "" then
    cache = {
      last_synced = nil,
      next_new_id = 1,
      tasks = {},
    }
    return true
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    vim.notify("tasks-nvim: Failed to parse cache file", vim.log.levels.ERROR)
    return false
  end

  cache = {
    last_synced = decoded.last_synced,
    next_new_id = decoded.next_new_id or 1,
    tasks = decoded.tasks or {},
  }

  return true
end

--- Save cache to disk
---@return boolean success True if cache was saved successfully
function M.save()
  ensure_cache_dir()

  local content = vim.json.encode(cache)
  local file = io.open(cache_file, "w")
  if not file then
    vim.notify("tasks-nvim: Failed to write cache file", vim.log.levels.ERROR)
    return false
  end

  file:write(content)
  file:close()
  return true
end

--- Get all non-hidden tasks
---@return table<string, table> Map of task ID to task data
function M.get_tasks()
  local result = {}
  for id, task in pairs(cache.tasks) do
    if not task.hidden then
      result[id] = task
    end
  end
  return result
end

--- Get all tasks including hidden ones
---@return table<string, table> Map of task ID to task data
function M.get_all_tasks()
  return cache.tasks
end

--- Get a task by ID
---@param id string Task ID (Google ID or new:N)
---@return table|nil task Task data, or nil if not found
function M.get_task(id)
  return cache.tasks[id]
end

--- Set/update a task
---@param id string Task ID
---@param task table Task data
function M.set_task(id, task)
  cache.tasks[id] = task
end

--- Delete a task from cache entirely
---@param id string Task ID
function M.delete_task(id)
  cache.tasks[id] = nil
end

--- Mark a task as hidden (soft delete)
---@param id string Task ID
function M.mark_hidden(id)
  local task = cache.tasks[id]
  if task then
    task.hidden = true
    task.hidden_at = util.now_iso8601()
  end
end

--- Allocate a new temporary ID for unsaved tasks
---@return string id New ID in format "new:N"
function M.allocate_new_id()
  local id = "new:" .. cache.next_new_id
  cache.next_new_id = cache.next_new_id + 1
  return id
end

--- Rename a task ID (used after syncing new tasks to get real Google ID)
---@param old_id string Old ID (typically "new:N")
---@param new_id string New ID (Google ID)
function M.rename_id(old_id, new_id)
  local task = cache.tasks[old_id]
  if task then
    cache.tasks[new_id] = task
    cache.tasks[old_id] = nil

    -- Update parent references in child tasks
    for _, child_task in pairs(cache.tasks) do
      if child_task.parent == old_id then
        child_task.parent = new_id
      end
    end
  end
end

--- Get all tasks that have pending local changes
---@return table<string, table> Map of task ID to task data
function M.get_pending_changes()
  local result = {}
  for id, task in pairs(cache.tasks) do
    if task.local_modified then
      result[id] = task
    end
  end
  return result
end

--- Clear the local_modified flag for a task
---@param id string Task ID
function M.clear_modified(id)
  local task = cache.tasks[id]
  if task then
    task.local_modified = nil
  end
end

--- Update the last synced timestamp
function M.set_last_synced()
  cache.last_synced = util.now_iso8601()
end

--- Get the last synced timestamp
---@return string|nil ISO 8601 timestamp
function M.get_last_synced()
  return cache.last_synced
end

--- Check if a task ID is a temporary new ID
---@param id string Task ID
---@return boolean True if this is a new:N ID
function M.is_new_id(id)
  return id:match("^new:%d+$") ~= nil
end

--- Get all hidden tasks
---@return table<string, table> Map of task ID to task data
function M.get_hidden_tasks()
  local result = {}
  for id, task in pairs(cache.tasks) do
    if task.hidden then
      result[id] = task
    end
  end
  return result
end

--- Get all children of a parent task
---@param parent_id string Parent task ID
---@return table<string, table> Map of child task ID to task data
function M.get_children(parent_id)
  local result = {}
  for id, task in pairs(cache.tasks) do
    if task.parent == parent_id and not task.hidden then
      result[id] = task
    end
  end
  return result
end

--- Check if a task has children
---@param id string Task ID
---@return boolean True if the task has at least one child
function M.has_children(id)
  for _, task in pairs(cache.tasks) do
    if task.parent == id and not task.hidden then
      return true
    end
  end
  return false
end

--- Get all root tasks (tasks with no parent)
---@return table<string, table> Map of task ID to task data
function M.get_root_tasks()
  local result = {}
  for id, task in pairs(cache.tasks) do
    if not task.parent and not task.hidden then
      result[id] = task
    end
  end
  return result
end

--- Clear the parent_modified flag for a task
---@param id string Task ID
function M.clear_parent_modified(id)
  local task = cache.tasks[id]
  if task then
    task.parent_modified = nil
  end
end

return M
