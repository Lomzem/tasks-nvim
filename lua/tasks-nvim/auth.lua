local Job = require("plenary.job")
local curl = require("plenary.curl")

local M = {}

-- Configuration (set by init.lua setup)
M.client_id = nil
M.client_secret = nil
M.redirect_uri = "http://127.0.0.1:8080/callback"
M.scopes = "https://www.googleapis.com/auth/tasks"

-- Token storage paths
local token_dir = nil
local token_file = nil

-- In-memory token cache
local tokens = nil

--- Initialize paths
local function init_paths()
  if token_dir then
    return
  end
  token_dir = vim.fn.stdpath("cache") .. "/tasks-nvim"
  token_file = token_dir .. "/tokens.json"
end

--- Ensure the token directory exists
local function ensure_token_dir()
  init_paths()
  if vim.fn.isdirectory(token_dir) == 0 then
    vim.fn.mkdir(token_dir, "p")
  end
end

--- Load tokens from disk
---@return boolean success
local function load_tokens()
  init_paths()

  local file = io.open(token_file, "r")
  if not file then
    tokens = nil
    return false
  end

  local content = file:read("*a")
  file:close()

  if content == "" then
    tokens = nil
    return false
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    tokens = nil
    return false
  end

  tokens = decoded
  return true
end

--- Save tokens to disk
---@return boolean success
local function save_tokens()
  ensure_token_dir()

  local content = vim.json.encode(tokens)
  local file = io.open(token_file, "w")
  if not file then
    vim.notify("tasks-nvim: Failed to write token file", vim.log.levels.ERROR)
    return false
  end

  file:write(content)
  file:close()
  return true
end

--- Build the OAuth authorization URL
---@return string url
local function build_auth_url()
  local params = {
    client_id = M.client_id,
    redirect_uri = M.redirect_uri,
    response_type = "code",
    scope = M.scopes,
    access_type = "offline",
    prompt = "consent", -- Force consent to always get refresh token
  }

  local query_parts = {}
  for k, v in pairs(params) do
    table.insert(query_parts, k .. "=" .. vim.uri_encode(v))
  end

  return "https://accounts.google.com/o/oauth2/v2/auth?" .. table.concat(query_parts, "&")
end

--- Exchange authorization code for tokens
---@param code string Authorization code from OAuth redirect
---@param callback function Called with (success, error_message)
local function exchange_code(code, callback)
  curl.post("https://oauth2.googleapis.com/token", {
    body = vim.uri_encode("client_id")
      .. "="
      .. vim.uri_encode(M.client_id)
      .. "&"
      .. vim.uri_encode("client_secret")
      .. "="
      .. vim.uri_encode(M.client_secret)
      .. "&"
      .. vim.uri_encode("code")
      .. "="
      .. vim.uri_encode(code)
      .. "&"
      .. vim.uri_encode("grant_type")
      .. "="
      .. vim.uri_encode("authorization_code")
      .. "&"
      .. vim.uri_encode("redirect_uri")
      .. "="
      .. vim.uri_encode(M.redirect_uri),
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
    },
    callback = function(response)
      vim.schedule(function()
        if response.status ~= 200 then
          callback(false, "Token exchange failed: " .. (response.body or "unknown error"))
          return
        end

        local ok, data = pcall(vim.json.decode, response.body)
        if not ok then
          callback(false, "Failed to parse token response")
          return
        end

        if data.error then
          callback(false, "OAuth error: " .. (data.error_description or data.error))
          return
        end

        tokens = {
          access_token = data.access_token,
          refresh_token = data.refresh_token,
          expires_at = os.time() + (data.expires_in or 3600) - 60, -- 60s buffer
        }

        if save_tokens() then
          callback(true, nil)
        else
          callback(false, "Failed to save tokens")
        end
      end)
    end,
  })
end

--- Refresh the access token using the refresh token
---@param callback function Called with (success, error_message)
local function refresh_access_token(callback)
  if not tokens or not tokens.refresh_token then
    callback(false, "No refresh token available")
    return
  end

  curl.post("https://oauth2.googleapis.com/token", {
    body = vim.uri_encode("client_id")
      .. "="
      .. vim.uri_encode(M.client_id)
      .. "&"
      .. vim.uri_encode("client_secret")
      .. "="
      .. vim.uri_encode(M.client_secret)
      .. "&"
      .. vim.uri_encode("refresh_token")
      .. "="
      .. vim.uri_encode(tokens.refresh_token)
      .. "&"
      .. vim.uri_encode("grant_type")
      .. "="
      .. vim.uri_encode("refresh_token"),
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
    },
    callback = function(response)
      vim.schedule(function()
        if response.status ~= 200 then
          callback(false, "Token refresh failed: " .. (response.body or "unknown error"))
          return
        end

        local ok, data = pcall(vim.json.decode, response.body)
        if not ok then
          callback(false, "Failed to parse refresh response")
          return
        end

        if data.error then
          callback(false, "OAuth error: " .. (data.error_description or data.error))
          return
        end

        tokens.access_token = data.access_token
        tokens.expires_at = os.time() + (data.expires_in or 3600) - 60

        -- Refresh token might be rotated
        if data.refresh_token then
          tokens.refresh_token = data.refresh_token
        end

        if save_tokens() then
          callback(true, nil)
        else
          callback(false, "Failed to save refreshed tokens")
        end
      end)
    end,
  })
end

--- Create a minimal HTTP server to capture the OAuth redirect
---@param callback function Called with (code) when authorization code is received
---@return userdata server The server handle
local function create_oauth_server(callback)
  local uv = vim.loop
  local server = uv.new_tcp()

  server:bind("127.0.0.1", 8080)

  server:listen(128, function(err)
    if err then
      vim.schedule(function()
        vim.notify("tasks-nvim: Failed to start OAuth server: " .. err, vim.log.levels.ERROR)
      end)
      return
    end

    local client = uv.new_tcp()
    server:accept(client)

    client:read_start(function(read_err, chunk)
      if read_err then
        client:close()
        server:close()
        return
      end

      if chunk then
        -- Parse the authorization code from the request
        local code = chunk:match("[?&]code=([^%s&]+)")

        -- Determine response based on whether we got a code
        local html_body, status_line
        if code then
          status_line = "HTTP/1.1 200 OK\r\n"
          html_body = [[
<!DOCTYPE html>
<html>
<head><title>Authorization Successful</title></head>
<body style="font-family: sans-serif; text-align: center; padding-top: 50px;">
  <h1>Authorization Successful!</h1>
  <p>You can close this window and return to Neovim.</p>
</body>
</html>
]]
        else
          -- Check for error
          local error_msg = chunk:match("[?&]error=([^%s&]+)")
          status_line = "HTTP/1.1 400 Bad Request\r\n"
          html_body = string.format(
            [[
<!DOCTYPE html>
<html>
<head><title>Authorization Failed</title></head>
<body style="font-family: sans-serif; text-align: center; padding-top: 50px;">
  <h1>Authorization Failed</h1>
  <p>Error: %s</p>
  <p>Please try again.</p>
</body>
</html>
]],
            error_msg or "Unknown error"
          )
        end

        local response = status_line
          .. "Content-Type: text/html\r\n"
          .. "Content-Length: "
          .. #html_body
          .. "\r\n"
          .. "Connection: close\r\n"
          .. "\r\n"
          .. html_body

        client:write(response, function()
          client:shutdown(function()
            client:close()
            server:close()

            if code then
              vim.schedule(function()
                callback(code)
              end)
            end
          end)
        end)
      end
    end)
  end)

  return server
end

--- Open the authorization URL in the default browser
---@param url string The URL to open
local function open_browser(url)
  local cmd, args

  if vim.fn.has("mac") == 1 then
    cmd = "open"
    args = { url }
  elseif vim.fn.has("wsl") == 1 then
    cmd = "wslview"
    args = { url }
  elseif vim.fn.executable("xdg-open") == 1 then
    cmd = "xdg-open"
    args = { url }
  elseif vim.fn.executable("wslview") == 1 then
    cmd = "wslview"
    args = { url }
  else
    vim.notify("tasks-nvim: Could not find a way to open browser. Please open this URL manually:\n" .. url, vim.log.levels.WARN)
    return
  end

  Job:new({
    command = cmd,
    args = args,
    on_exit = function(_, return_val)
      if return_val ~= 0 then
        vim.schedule(function()
          vim.notify("tasks-nvim: Failed to open browser. Please open this URL manually:\n" .. url, vim.log.levels.WARN)
        end)
      end
    end,
  }):start()
end

--- Start the OAuth authentication flow
function M.start_oauth()
  if not M.client_id or not M.client_secret then
    vim.notify("tasks-nvim: client_id and client_secret must be configured in setup()", vim.log.levels.ERROR)
    return
  end

  vim.notify("tasks-nvim: Starting authentication...", vim.log.levels.INFO)

  -- Start the local server to capture the redirect
  create_oauth_server(function(code)
    vim.notify("tasks-nvim: Received authorization code, exchanging for tokens...", vim.log.levels.INFO)

    exchange_code(code, function(success, err)
      if success then
        vim.notify("tasks-nvim: Authentication successful!", vim.log.levels.INFO)
      else
        vim.notify("tasks-nvim: Authentication failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
      end
    end)
  end)

  -- Open the browser to the authorization URL
  local auth_url = build_auth_url()
  open_browser(auth_url)
end

--- Check if the user is authenticated (has valid tokens)
---@return boolean
function M.is_authenticated()
  if not tokens then
    load_tokens()
  end
  return tokens ~= nil and tokens.access_token ~= nil
end

--- Get a valid access token, refreshing if necessary
--- This is async and calls the callback with the token
---@param callback function Called with (token, error_message)
function M.get_access_token(callback)
  if not tokens then
    load_tokens()
  end

  if not tokens or not tokens.access_token then
    callback(nil, "Not authenticated. Run :TasksAuth first.")
    return
  end

  -- Check if token is expired or about to expire
  if tokens.expires_at and os.time() >= tokens.expires_at then
    refresh_access_token(function(success, err)
      if success then
        callback(tokens.access_token, nil)
      else
        callback(nil, err)
      end
    end)
  else
    callback(tokens.access_token, nil)
  end
end

--- Get access token synchronously (blocks briefly, use sparingly)
--- Returns nil if not authenticated or if refresh fails
---@return string|nil token
function M.get_access_token_sync()
  if not tokens then
    load_tokens()
  end

  if not tokens or not tokens.access_token then
    return nil
  end

  -- If token is still valid, return it
  if not tokens.expires_at or os.time() < tokens.expires_at then
    return tokens.access_token
  end

  -- Token expired, need to refresh synchronously
  -- This is a blocking operation, use sparingly
  local result = curl.post("https://oauth2.googleapis.com/token", {
    body = vim.uri_encode("client_id")
      .. "="
      .. vim.uri_encode(M.client_id)
      .. "&"
      .. vim.uri_encode("client_secret")
      .. "="
      .. vim.uri_encode(M.client_secret)
      .. "&"
      .. vim.uri_encode("refresh_token")
      .. "="
      .. vim.uri_encode(tokens.refresh_token)
      .. "&"
      .. vim.uri_encode("grant_type")
      .. "="
      .. vim.uri_encode("refresh_token"),
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
    },
  })

  if result.status ~= 200 then
    return nil
  end

  local ok, data = pcall(vim.json.decode, result.body)
  if not ok or data.error then
    return nil
  end

  tokens.access_token = data.access_token
  tokens.expires_at = os.time() + (data.expires_in or 3600) - 60
  if data.refresh_token then
    tokens.refresh_token = data.refresh_token
  end

  save_tokens()
  return tokens.access_token
end

return M
