local M = {}

--- Parse a date string in YYYY-MM-DD format to a timestamp
---@param str string Date string like "2024-01-18"
---@return number|nil timestamp Unix timestamp, or nil if invalid
function M.parse_date(str)
  if not str or str == "" then
    return nil
  end

  local year, month, day = str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not year then
    return nil
  end

  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = 0,
    min = 0,
    sec = 0,
  })
end

--- Format a timestamp to YYYY-MM-DD string
---@param ts number Unix timestamp
---@return string Date string like "2024-01-18"
function M.format_date(ts)
  return os.date("%Y-%m-%d", ts)
end

--- Parse an ISO 8601 datetime string to a timestamp
--- Handles Google's format: "2024-01-15T10:30:00.000Z"
---@param str string ISO 8601 datetime string
---@return number|nil timestamp Unix timestamp, or nil if invalid
function M.parse_iso8601(str)
  if not str or str == "" then
    return nil
  end

  -- Pattern: YYYY-MM-DDTHH:MM:SS (with optional .milliseconds and Z)
  local year, month, day, hour, min, sec =
    str:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")

  if not year then
    -- Try date-only format (Google sometimes uses this for due dates)
    year, month, day = str:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not year then
      return nil
    end
    hour, min, sec = 0, 0, 0
  end

  -- Convert to timestamp (treating as UTC)
  -- os.time assumes local time, so we need to adjust
  local local_ts = os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })

  -- Get the UTC offset and adjust
  local utc_offset = os.difftime(local_ts, os.time(os.date("!*t", local_ts)))
  return local_ts - utc_offset
end

--- Convert a timestamp to ISO 8601 datetime string (UTC)
---@param ts number Unix timestamp
---@return string ISO 8601 datetime string like "2024-01-15T10:30:00.000Z"
function M.to_iso8601(ts)
  return os.date("!%Y-%m-%dT%H:%M:%S.000Z", ts)
end

--- Get the current time as an ISO 8601 datetime string (UTC)
---@return string ISO 8601 datetime string
function M.now_iso8601()
  return M.to_iso8601(os.time())
end

--- Get the current time as a Unix timestamp
---@return number Unix timestamp
function M.now()
  return os.time()
end

--- Check if a timestamp is older than a given number of days
---@param ts number Unix timestamp to check
---@param days number Number of days
---@return boolean True if ts is more than `days` days ago
function M.is_older_than_days(ts, days)
  local threshold = os.time() - (days * 24 * 60 * 60)
  return ts < threshold
end

return M
