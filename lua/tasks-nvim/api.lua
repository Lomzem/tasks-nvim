local curl = require("plenary.curl")
local auth = require("tasks-nvim.auth")

local M = {}

local BASE_URL = "https://tasks.googleapis.com/tasks/v1"
local DEFAULT_TASKLIST = "@default"

--- Make an authenticated API request
---@param method string HTTP method (get, post, patch, delete)
---@param endpoint string API endpoint (relative to base URL)
---@param opts table|nil Request options (body, query, etc.)
---@param callback function Called with (success, data, error_message)
local function api_request(method, endpoint, opts, callback)
  opts = opts or {}

  auth.get_access_token(function(token, token_err)
    if not token then
      vim.schedule(function()
        vim.notify("tasks-nvim: " .. (token_err or "Not authenticated"), vim.log.levels.ERROR)
        callback(false, nil, token_err)
      end)
      return
    end

    local url = BASE_URL .. endpoint

    local request_opts = {
      headers = vim.tbl_extend("force", opts.headers or {}, {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"] = "application/json",
      }),
      callback = function(response)
        vim.schedule(function()
          if response.status >= 200 and response.status < 300 then
            local data = nil
            if response.body and response.body ~= "" then
              local ok, decoded = pcall(vim.json.decode, response.body)
              if ok then
                data = decoded
              end
            end
            callback(true, data, nil)
          else
            local error_msg = "HTTP " .. response.status
            if response.body then
              local ok, decoded = pcall(vim.json.decode, response.body)
              if ok and decoded.error then
                error_msg = decoded.error.message or error_msg
              end
            end
            vim.notify("tasks-nvim: API error: " .. error_msg, vim.log.levels.ERROR)
            callback(false, nil, error_msg)
          end
        end)
      end,
    }

    -- Add body if present
    if opts.body then
      request_opts.body = vim.json.encode(opts.body)
    end

    -- Add query parameters if present
    if opts.query then
      local query_parts = {}
      for k, v in pairs(opts.query) do
        table.insert(query_parts, vim.uri_encode(k) .. "=" .. vim.uri_encode(tostring(v)))
      end
      if #query_parts > 0 then
        url = url .. "?" .. table.concat(query_parts, "&")
      end
    end

    request_opts.url = url

    -- Call the appropriate curl method
    if method == "get" then
      curl.get(request_opts)
    elseif method == "post" then
      curl.post(request_opts)
    elseif method == "patch" then
      curl.patch(request_opts)
    elseif method == "delete" then
      curl.delete(request_opts)
    elseif method == "put" then
      curl.put(request_opts)
    end
  end)
end

--- List all tasks from the default task list
---@param callback function Called with (success, tasks, error_message)
function M.list_tasks(callback)
  -- Google Tasks API requires pagination for large lists
  local all_tasks = {}

  local function fetch_page(page_token)
    local query = {
      maxResults = 100,
      showCompleted = true,
      showHidden = false,
    }

    if page_token then
      query.pageToken = page_token
    end

    api_request("get", "/lists/" .. DEFAULT_TASKLIST .. "/tasks", { query = query }, function(success, data, err)
      if not success then
        callback(false, nil, err)
        return
      end

      if data and data.items then
        for _, task in ipairs(data.items) do
          table.insert(all_tasks, task)
        end
      end

      -- Check for more pages
      if data and data.nextPageToken then
        fetch_page(data.nextPageToken)
      else
        callback(true, all_tasks, nil)
      end
    end)
  end

  fetch_page(nil)
end

--- Create a new task
---@param task table Task data (title, due, status, etc.)
---@param parent_id string|nil Parent task ID (for creating subtasks)
---@param callback function Called with (success, created_task, error_message)
function M.create_task(task, parent_id, callback)
  local body = {
    title = task.title,
    status = task.status or "needsAction",
  }

  -- Google Tasks API expects due date in RFC 3339 format
  if task.due then
    -- If due is just a date string (YYYY-MM-DD), convert to RFC 3339
    if task.due:match("^%d%d%d%d%-%d%d%-%d%d$") then
      body.due = task.due .. "T00:00:00.000Z"
    else
      body.due = task.due
    end
  end

  local query = {}
  if parent_id then
    query.parent = parent_id
  end

  api_request("post", "/lists/" .. DEFAULT_TASKLIST .. "/tasks", { body = body, query = query }, callback)
end

--- Update an existing task
---@param id string Google Task ID
---@param task table Task data to update (title, due, status, etc.)
---@param callback function Called with (success, updated_task, error_message)
function M.update_task(id, task, callback)
  local body = {
    id = id,
    title = task.title,
    status = task.status,
  }

  -- Handle due date
  if task.due then
    if task.due:match("^%d%d%d%d%-%d%d%-%d%d$") then
      body.due = task.due .. "T00:00:00.000Z"
    else
      body.due = task.due
    end
  else
    -- Explicitly clear due date if nil
    body.due = vim.NIL
  end

  api_request("patch", "/lists/" .. DEFAULT_TASKLIST .. "/tasks/" .. id, { body = body }, callback)
end

--- Delete a task
---@param id string Google Task ID
---@param callback function Called with (success, nil, error_message)
function M.delete_task(id, callback)
  api_request("delete", "/lists/" .. DEFAULT_TASKLIST .. "/tasks/" .. id, {}, callback)
end

--- Get a single task by ID
---@param id string Google Task ID
---@param callback function Called with (success, task, error_message)
function M.get_task(id, callback)
  api_request("get", "/lists/" .. DEFAULT_TASKLIST .. "/tasks/" .. id, {}, callback)
end

--- Move a task (change its position and/or parent in the list)
---@param id string Google Task ID
---@param opts table Options: { parent = string|nil, previous = string|nil }
---@param callback function Called with (success, task, error_message)
function M.move_task(id, opts, callback)
  opts = opts or {}
  local query = {}

  if opts.parent then
    query.parent = opts.parent
  end

  if opts.previous then
    query.previous = opts.previous
  end

  api_request("post", "/lists/" .. DEFAULT_TASKLIST .. "/tasks/" .. id .. "/move", { query = query }, callback)
end

return M
