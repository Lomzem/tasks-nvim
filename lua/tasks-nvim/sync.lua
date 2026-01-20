local api = require("tasks-nvim.api")
local cache = require("tasks-nvim.cache")
local buffer = require("tasks-nvim.buffer")
local util = require("tasks-nvim.util")

local M = {}

-- Configuration
M.purge_after_days = 30

--- Convert a Google API task to our internal format
---@param google_task table Task from Google API
---@return table task Internal task format
local function google_to_internal(google_task)
  local due = nil
  if google_task.due then
    -- Extract just the date part
    due = google_task.due:match("^(%d%d%d%d%-%d%d%-%d%d)")
  end

  return {
    title = google_task.title or "",
    status = google_task.status or "needsAction",
    due = due,
    updated = google_task.updated,
    hidden = false,
    hidden_at = nil,
    local_modified = nil,
    parent = google_task.parent, -- Capture parent task ID from API
    parent_modified = nil,
  }
end

--- Fetch tasks from remote and merge into cache
---@param callback function|nil Called with (success, error_message) when done
function M.fetch_and_merge(callback)
  callback = callback or function() end

  api.list_tasks(function(success, remote_tasks, err)
    if not success then
      callback(false, err)
      return
    end

    remote_tasks = remote_tasks or {}
    local changed = false

    -- Build a set of remote task IDs for detecting deletions
    local remote_ids = {}
    for _, remote_task in ipairs(remote_tasks) do
      remote_ids[remote_task.id] = true
    end

    -- Process each remote task
    for _, remote_task in ipairs(remote_tasks) do
      local id = remote_task.id
      local local_task = cache.get_task(id)
      local remote_internal = google_to_internal(remote_task)

      if not local_task then
        -- New task from remote, add to cache
        cache.set_task(id, remote_internal)
        changed = true
      elseif local_task.hidden then
        -- We soft-deleted it locally - DO NOT restore it
        -- The deletion is in progress or will be retried on purge
        -- Only restore if remote was updated AFTER we hid it (meaning someone else edited it)
        if local_task.hidden_at and remote_task.updated then
          local hidden_ts = util.parse_iso8601(local_task.hidden_at)
          local remote_ts = util.parse_iso8601(remote_task.updated)

          -- Only restore if remote update is significantly after hidden_at (> 5 seconds)
          -- This prevents race conditions where we just hid it but haven't deleted yet
          if hidden_ts and remote_ts and (remote_ts - hidden_ts) > 5 then
            -- Remote was meaningfully updated after we hid it, restore
            remote_internal.hidden = false
            remote_internal.hidden_at = nil
            cache.set_task(id, remote_internal)
            changed = true
          end
          -- else: keep hidden, our delete is in progress
        end
      elseif local_task.local_modified then
        -- We have local changes, check timestamps for conflict resolution
        local local_ts = util.parse_iso8601(local_task.local_modified)
        local remote_ts = util.parse_iso8601(remote_task.updated)

        if local_ts and remote_ts and remote_ts > local_ts then
          -- Remote is newer, overwrite local
          cache.set_task(id, remote_internal)
          changed = true
        end
        -- else: local is newer, keep local (will push on next save)
      else
        -- No conflict, accept remote if different
        if
          local_task.title ~= remote_internal.title
          or local_task.status ~= remote_internal.status
          or local_task.due ~= remote_internal.due
          or local_task.parent ~= remote_internal.parent
        then
          cache.set_task(id, remote_internal)
          changed = true
        end
      end
    end

    -- Update last synced timestamp
    cache.set_last_synced()
    cache.save()

    -- Update buffer if open and changes were made
    if changed and buffer.get_bufnr() then
      vim.schedule(function()
        buffer.render(cache.get_tasks())
      end)
    end

    callback(true, nil)
  end)
end

--- Get all tasks that have pending parent changes
---@return table<string, table> Map of task ID to task data
local function get_pending_parent_changes()
  local result = {}
  for id, task in pairs(cache.get_all_tasks()) do
    if task.parent_modified and not cache.is_new_id(id) then
      result[id] = task
    end
  end
  return result
end

--- Push local changes to remote
---@param callback function|nil Called with (success, error_message) when done
function M.push_changes(callback)
  callback = callback or function() end

  local pending = cache.get_pending_changes()
  local pending_parent = get_pending_parent_changes()

  local pending_count = 0
  for _ in pairs(pending) do
    pending_count = pending_count + 1
  end
  for _ in pairs(pending_parent) do
    pending_count = pending_count + 1
  end

  if pending_count == 0 then
    callback(true, nil)
    return
  end

  local completed = 0
  local errors = {}

  local function check_done()
    if completed >= pending_count then
      cache.save()

      if #errors > 0 then
        callback(false, table.concat(errors, "; "))
      else
        callback(true, nil)
      end
    end
  end

  -- Process content changes (create/update)
  for id, task in pairs(pending) do
    if cache.is_new_id(id) then
      -- Create new task (with optional parent)
      -- If parent is also a new:N ID, skip parent for now - will be set via move_task later
      local parent_id = task.parent
      if parent_id and cache.is_new_id(parent_id) then
        parent_id = nil
        -- Mark that we need to set parent later
        task.parent_modified = util.now_iso8601()
      end
      api.create_task(task, parent_id, function(success, created_task, err)
        if success and created_task then
          -- Rename from new:N to real Google ID
          cache.rename_id(id, created_task.id)

          -- Update task with server response
          local updated_task = cache.get_task(created_task.id)
          if updated_task then
            updated_task.updated = created_task.updated
            updated_task.local_modified = nil
            -- Parent was set during creation, so clear parent_modified if set
            updated_task.parent_modified = nil
          end

          -- Update buffer if open
          if buffer.get_bufnr() then
            vim.schedule(function()
              buffer.remove_line(id)
              buffer.update_line(created_task.id, updated_task)
            end)
          end
        else
          table.insert(errors, "Failed to create task: " .. (err or "unknown"))
        end

        completed = completed + 1
        check_done()
      end)
    else
      -- Update existing task
      api.update_task(id, task, function(success, updated_task, err)
        if success then
          cache.clear_modified(id)

          -- Update task with server response
          local cached_task = cache.get_task(id)
          if cached_task and updated_task then
            cached_task.updated = updated_task.updated
          end
        else
          table.insert(errors, "Failed to update task: " .. (err or "unknown"))
        end

        completed = completed + 1
        check_done()
      end)
    end
  end

  -- Process parent changes (move tasks)
  for id, task in pairs(pending_parent) do
    -- Skip if this task was also in pending (already handled above as new task)
    if not pending[id] then
      api.move_task(id, { parent = task.parent }, function(success, _, err)
        if success then
          cache.clear_parent_modified(id)
        else
          table.insert(errors, "Failed to move task: " .. (err or "unknown"))
        end

        completed = completed + 1
        check_done()
      end)
    else
      -- Task was in both pending and pending_parent, decrement count since we're skipping
      completed = completed + 1
      check_done()
    end
  end
end

--- Handle buffer save: parse changes, update cache, push to remote
function M.on_buffer_save()
  local parsed, new_tasks = buffer.parse()

  -- IMPORTANT: Take a snapshot of current cache IDs before modifying
  -- We need this because cache.get_all_tasks() returns a reference
  local existing_ids = {}
  for id, _ in pairs(cache.get_all_tasks()) do
    existing_ids[id] = true
  end

  -- Track which cached IDs are still in the buffer
  local seen_ids = {}

  -- Track tasks to delete
  local to_delete = {}

  -- Process existing tasks (those with IDs)
  for id, buffer_task in pairs(parsed) do
    seen_ids[id] = true

    local cached_task = cache.get_task(id)

    if not cached_task then
      -- ID exists in buffer but not cache - might be pasted from elsewhere
      -- Treat as new task (strip the ID)
      table.insert(new_tasks, buffer_task)
    else
      -- Check if task was modified (including parent)
      local content_changed = cached_task.title ~= buffer_task.title
        or cached_task.status ~= buffer_task.status
        or cached_task.due ~= buffer_task.due

      local parent_changed = cached_task.parent ~= buffer_task.parent

      if content_changed then
        -- Update cache with changes
        cached_task.title = buffer_task.title
        cached_task.status = buffer_task.status
        cached_task.due = buffer_task.due
        cached_task.local_modified = util.now_iso8601()
      end

      if parent_changed then
        -- Warn if trying to indent a task that has children (would create > 1 level nesting)
        if buffer_task.parent and cache.has_children(id) then
          vim.notify(
            "tasks-nvim: Cannot indent task with children (only 1 level of nesting supported)",
            vim.log.levels.WARN
          )
          -- Don't update parent, keep it as root
        else
          -- Update parent and mark parent_modified
          cached_task.parent = buffer_task.parent
          cached_task.parent_modified = util.now_iso8601()
        end
      end
    end
  end

  -- Process new tasks (those without IDs)
  for _, task in ipairs(new_tasks) do
    local new_id = cache.allocate_new_id()
    cache.set_task(new_id, {
      title = task.title,
      status = task.status,
      due = task.due,
      updated = nil,
      hidden = false,
      hidden_at = nil,
      local_modified = util.now_iso8601(),
      parent = task.parent,
      parent_modified = nil,
    })
  end

  -- Find tasks to delete (not in buffer anymore)
  -- Only check IDs that existed BEFORE we added new tasks
  for id, _ in pairs(existing_ids) do
    local task = cache.get_task(id)
    if task and not task.hidden and not seen_ids[id] then
      -- Task was deleted from buffer
      -- Promote orphaned children to root level
      local children = cache.get_children(id)
      for child_id, child_task in pairs(children) do
        child_task.parent = nil
        child_task.parent_modified = util.now_iso8601()
      end

      if cache.is_new_id(id) then
        -- New task that was never synced, just remove from cache
        cache.delete_task(id)
      else
        -- Mark as hidden and queue for deletion
        cache.mark_hidden(id)
        table.insert(to_delete, id)
      end
    end
  end

  -- Save cache
  cache.save()

  -- Re-render buffer with new IDs for new tasks
  buffer.render(cache.get_tasks())

  -- Push changes to remote (async)
  M.push_changes(function(success, err)
    if not success then
      vim.notify("tasks-nvim: Failed to sync some changes: " .. (err or "unknown"), vim.log.levels.WARN)
    end
  end)

  -- Delete tasks from remote (async)
  for _, id in ipairs(to_delete) do
    api.delete_task(id, function(success, _, err)
      if success then
        -- Successfully deleted from remote, remove from cache entirely
        cache.delete_task(id)
        cache.save()
      else
        vim.notify("tasks-nvim: Failed to delete task: " .. (err or "unknown"), vim.log.levels.WARN)
        -- Keep it hidden in cache, will retry on next purge
      end
    end)
  end
end

--- Purge hidden tasks older than the threshold
---@param callback function|nil Called with (purged_count) when done
function M.purge_old_hidden(callback)
  callback = callback or function() end

  local hidden = cache.get_hidden_tasks()
  local to_purge = {}

  for id, task in pairs(hidden) do
    if task.hidden_at then
      local hidden_ts = util.parse_iso8601(task.hidden_at)
      if hidden_ts and util.is_older_than_days(hidden_ts, M.purge_after_days) then
        table.insert(to_purge, id)
      end
    end
  end

  if #to_purge == 0 then
    vim.notify("tasks-nvim: No tasks to purge", vim.log.levels.INFO)
    callback(0)
    return
  end

  local completed = 0
  local purged = 0

  local function check_done()
    if completed >= #to_purge then
      cache.save()
      vim.notify("tasks-nvim: Purged " .. purged .. " hidden task(s)", vim.log.levels.INFO)
      callback(purged)
    end
  end

  for _, id in ipairs(to_purge) do
    if cache.is_new_id(id) then
      -- New task that was never synced, just delete from cache
      cache.delete_task(id)
      purged = purged + 1
      completed = completed + 1
      check_done()
    else
      -- Delete from remote
      api.delete_task(id, function(success, _, err)
        if success then
          cache.delete_task(id)
          purged = purged + 1
        else
          vim.notify("tasks-nvim: Failed to delete task " .. id .. ": " .. (err or "unknown"), vim.log.levels.WARN)
        end

        completed = completed + 1
        check_done()
      end)
    end
  end
end

--- Force a full sync (fetch + push)
---@param callback function|nil Called when done
function M.force_sync(callback)
  callback = callback or function() end

  vim.notify("tasks-nvim: Syncing...", vim.log.levels.INFO)

  -- First push any pending changes
  M.push_changes(function(push_success, push_err)
    if not push_success then
      vim.notify("tasks-nvim: Push failed: " .. (push_err or "unknown"), vim.log.levels.WARN)
    end

    -- Then fetch remote changes
    M.fetch_and_merge(function(fetch_success, fetch_err)
      if fetch_success then
        vim.notify("tasks-nvim: Sync complete", vim.log.levels.INFO)
      else
        vim.notify("tasks-nvim: Fetch failed: " .. (fetch_err or "unknown"), vim.log.levels.ERROR)
      end

      callback()
    end)
  end)
end

return M
