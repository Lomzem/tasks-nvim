local M = {}

-- Module references (lazy loaded)
local auth = nil
local buffer = nil
local cache = nil
local sync = nil

-- Configuration with defaults
M.config = {
  client_id = nil,
  client_secret = nil,
  purge_after_days = 30,
  -- Keybindings (set to false to disable)
  keys = {
    toggle = "<CR>", -- Toggle task completion
  },
}

--- Setup the plugin with configuration
---@param opts table Configuration options
---  - client_id: string (required) Google OAuth client ID
---  - client_secret: string (required) Google OAuth client secret
---  - purge_after_days: number (optional) Days before hidden tasks are purged (default: 30)
---  - keys: table (optional) Keybinding configuration
---    - toggle: string|false (optional) Key to toggle completion (default: "<CR>", false to disable)
function M.setup(opts)
  opts = opts or {}

  -- Validate required options
  if not opts.client_id then
    vim.notify("tasks-nvim: client_id is required in setup()", vim.log.levels.ERROR)
    return
  end

  if not opts.client_secret then
    vim.notify("tasks-nvim: client_secret is required in setup()", vim.log.levels.ERROR)
    return
  end

  -- Merge user config with defaults
  M.config = vim.tbl_deep_extend("force", M.config, opts)

  -- Load modules
  auth = require("tasks-nvim.auth")
  sync = require("tasks-nvim.sync")
  buffer = require("tasks-nvim.buffer")

  -- Configure auth module
  auth.client_id = M.config.client_id
  auth.client_secret = M.config.client_secret

  -- Configure sync module
  sync.purge_after_days = M.config.purge_after_days

  -- Configure buffer module
  buffer.config = {
    keys = M.config.keys,
  }

  -- Create user commands
  vim.api.nvim_create_user_command("Tasks", function()
    M.open()
  end, { desc = "Open Google Tasks buffer" })

  vim.api.nvim_create_user_command("TasksAuth", function()
    M.auth()
  end, { desc = "Authenticate with Google Tasks" })

  vim.api.nvim_create_user_command("TasksSync", function()
    M.sync()
  end, { desc = "Force sync with Google Tasks" })

  vim.api.nvim_create_user_command("TasksPurge", function()
    M.purge()
  end, { desc = "Purge old hidden tasks" })
end

--- Open the tasks buffer
function M.open()
  -- Lazy load modules
  auth = auth or require("tasks-nvim.auth")
  buffer = buffer or require("tasks-nvim.buffer")
  cache = cache or require("tasks-nvim.cache")
  sync = sync or require("tasks-nvim.sync")

  -- Check authentication
  if not auth.is_authenticated() then
    vim.notify("tasks-nvim: Not authenticated. Run :TasksAuth first.", vim.log.levels.WARN)
    return
  end

  -- Load cache from disk (instant)
  cache.load()

  -- Open buffer with save handler
  buffer.open(function()
    sync.on_buffer_save()
  end)

  -- Render cached tasks immediately (SWR: stale)
  local tasks = cache.get_tasks()
  buffer.render(tasks)

  -- Fetch remote tasks asynchronously (SWR: revalidate)
  sync.fetch_and_merge(function(success, err)
    if not success then
      vim.notify("tasks-nvim: Failed to fetch tasks: " .. (err or "unknown"), vim.log.levels.WARN)
    end
  end)
end

--- Start the OAuth authentication flow
function M.auth()
  auth = auth or require("tasks-nvim.auth")
  auth.start_oauth()
end

--- Force sync with remote
function M.sync()
  auth = auth or require("tasks-nvim.auth")
  sync = sync or require("tasks-nvim.sync")

  if not auth.is_authenticated() then
    vim.notify("tasks-nvim: Not authenticated. Run :TasksAuth first.", vim.log.levels.WARN)
    return
  end

  sync.force_sync()
end

--- Purge old hidden tasks
function M.purge()
  auth = auth or require("tasks-nvim.auth")
  cache = cache or require("tasks-nvim.cache")
  sync = sync or require("tasks-nvim.sync")

  if not auth.is_authenticated() then
    vim.notify("tasks-nvim: Not authenticated. Run :TasksAuth first.", vim.log.levels.WARN)
    return
  end

  -- Load cache if not already loaded
  cache.load()

  sync.purge_old_hidden()
end

return M
