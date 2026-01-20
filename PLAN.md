# tasks-nvim Plugin - Final Plan

## Summary

A Neovim plugin for managing Google Tasks via an oil.nvim-style buffer. Uses **Stale-While-Revalidate** for instant open/close with background sync.

**Key decisions:**
- Google IDs used directly in buffer (with `new:N` prefix for unsaved tasks)
- Last-Write-Wins conflict resolution per-task
- Soft-delete with 30-day purge (deleted tasks are hidden, not removed)
- Buffer updates immediately when background sync finds changes
- Custom checkbox rendering with extmarks (no external dependencies for UI)
- Errors via `vim.notify`

## Dependencies

- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - HTTP requests, async operations

---

## File Structure

```
lua/tasks-nvim/
├── init.lua           # setup(), user commands
├── auth.lua           # OAuth flow, token storage/refresh
├── api.lua            # Google Tasks API wrapper
├── buffer.lua         # Buffer rendering, parsing, autocmds, extmarks
├── cache.lua          # Task cache, file I/O
├── sync.lua           # SWR logic, conflict resolution
└── util.lua           # Date parsing helpers
```

---

## Module Specifications

### 1. `init.lua`

**Public API:**
```lua
M.setup(opts)  -- Store client_id, client_secret, purge_after_days (default 30)
M.open()       -- Open task buffer (:Tasks)
M.auth()       -- Start OAuth flow (:TasksAuth)
M.sync()       -- Force sync with remote (:TasksSync)
M.purge()      -- Purge hidden tasks older than threshold (:TasksPurge)
```

**Commands:**
- `:Tasks` → `M.open()`
- `:TasksAuth` → `M.auth()`
- `:TasksSync` → `M.sync()`
- `:TasksPurge` → `M.purge()`

---

### 2. `auth.lua`

**Functions:**
```lua
M.start_oauth()           -- Start OAuth flow (server + browser)
M.get_access_token()      -- Returns valid token (refreshes if needed)
M.is_authenticated()      -- Check if tokens exist and valid
```

**OAuth Flow:**
1. Start TCP server on `127.0.0.1:8080` via `vim.loop`
2. Open browser to Google consent URL via `plenary.job`
3. Capture `?code=` from redirect
4. Exchange code for tokens via `plenary.curl`
5. Save to `~/.cache/nvim/tasks-nvim/tokens.json`

**Token file:**
```json
{
  "access_token": "...",
  "refresh_token": "...",
  "expires_at": 1705600000
}
```

---

### 3. `api.lua`

**Functions:**
```lua
M.list_tasks(callback)              -- GET all tasks
M.create_task(task, callback)       -- POST new task
M.update_task(id, task, callback)   -- PATCH existing task
M.delete_task(id, callback)         -- DELETE task
```

All functions:
- Use `plenary.curl` with async callbacks
- Auto-refresh token via `auth.get_access_token()`
- Call `vim.notify` on errors

---

### 4. `buffer.lua`

**Functions:**
```lua
M.open()                    -- Create/open task buffer
M.render(tasks)             -- Render tasks to buffer
M.parse()                   -- Parse buffer → list of tasks
M.update_line(id, task)     -- Update specific line (for live sync)
M.get_bufnr()               -- Get task buffer number (or nil)
M.apply_extmarks()          -- Apply extmarks for rendering
```

**Buffer setup:**
- `buftype = "acwrite"` (allows custom save handling)
- `filetype = "tasks"` (custom filetype)
- Window options: `conceallevel = 3`, `concealcursor = "nvic"`

**Line format:**
```
/GOOGLE_ID_HERE - [x] 2024-01-18 Task title
/new:1 - [ ] New unsaved task (no date)
```

**Extmarks rendering:**
- `/ID - ` prefix is concealed
- `[x]` and `[ ]` are replaced with icons (󰱒 and 󰄱)
- Dates are highlighted with `Special` highlight group

User sees:
```
󰱒  2024-01-18 Task title
󰄱  New unsaved task
```

**Autocmds:**
- `BufWriteCmd` → Parse buffer, queue sync, mark as saved
- `TextYankPost` → Strip `/ID - ` prefix from yanked text
- `TextChanged` / `InsertLeave` → Reapply extmarks

**Parsing logic:**
```lua
-- Pattern: /^\/([^\s]+) - \[([ x])\] (?:(\d{4}-\d{2}-\d{2}) )?(.+)$/
-- Groups: id, status, due (optional), title
```

---

### 5. `cache.lua`

**Functions:**
```lua
M.load()                    -- Load cache from disk
M.save()                    -- Save cache to disk
M.get_tasks()               -- Get all non-hidden tasks
M.get_task(id)              -- Get task by ID
M.set_task(id, task)        -- Update/create task
M.mark_hidden(id)           -- Mark task as hidden
M.allocate_new_id()         -- Returns "new:N", increments counter
M.rename_id(old, new)       -- Rename ID (after sync assigns real ID)
M.get_pending_changes()     -- Tasks with local_modified set
```

**Cache file (`~/.cache/nvim/tasks-nvim/tasks.json`):**
```json
{
  "last_synced": "2024-01-15T10:30:00.000Z",
  "next_new_id": 3,
  "tasks": {
    "GOOGLE_ID": {
      "title": "Task title",
      "status": "needsAction",
      "due": "2024-01-18",
      "updated": "2024-01-15T10:30:00.000Z",
      "hidden": false,
      "hidden_at": null,
      "local_modified": null
    }
  }
}
```

---

### 6. `sync.lua`

**Functions:**
```lua
M.fetch_and_merge(callback)    -- Fetch remote, merge into cache
M.push_changes(callback)       -- Push local changes to remote
M.purge_old_hidden()           -- Delete hidden tasks > 30 days
```

**SWR flow (on `:Tasks`):**
1. `cache.load()` → immediate
2. `buffer.render(cache.get_tasks())` → immediate
3. `sync.fetch_and_merge()` → async
4. On merge complete: `buffer.render()` to update

**Merge logic (Last-Write-Wins):**
```lua
for each remote_task:
  local_task = cache.get_task(remote_task.id)
  
  if not local_task then
    cache.set_task(remote_task.id, remote_task)  -- new from remote
  elseif local_task.hidden then
    if remote_task.updated > local_task.hidden_at then
      local_task.hidden = false  -- restore, remote updated after hide
    end
  elseif local_task.local_modified then
    if remote_task.updated > local_task.local_modified then
      cache.set_task(remote_task.id, remote_task)  -- remote wins
    end
    -- else: local wins, will push on next save
  else
    cache.set_task(remote_task.id, remote_task)  -- no conflict
  end
```

**On buffer save:**
1. `buffer.parse()` → get current buffer state
2. Diff against cache:
   - New IDs → `cache.allocate_new_id()`, mark `local_modified`
   - Changed tasks → update cache, mark `local_modified`
   - Missing IDs → `cache.mark_hidden(id)`
3. `sync.push_changes()` → async POST/PATCH to API
4. On success: clear `local_modified`, rename `new:N` → real ID

---

### 7. `util.lua`

**Functions:**
```lua
M.parse_date(str)           -- "2024-01-18" → timestamp
M.format_date(ts)           -- timestamp → "2024-01-18"
M.parse_iso8601(str)        -- Google's format → timestamp
M.to_iso8601(ts)            -- timestamp → ISO string
M.now_iso8601()             -- current time as ISO string
```

---

## Implementation Order

| Phase | Module | Description |
|-------|--------|-------------|
| 1 | `util.lua` | Date parsing helpers |
| 2 | `cache.lua` | File I/O, task storage |
| 3 | `auth.lua` | OAuth flow, token management |
| 4 | `api.lua` | Google Tasks API wrapper |
| 5 | `buffer.lua` | Rendering, parsing, autocmds |
| 6 | `sync.lua` | SWR, merge, push logic |
| 7 | `init.lua` | Wire everything together |
