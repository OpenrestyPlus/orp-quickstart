-- 四层 TCP/UDP 运行时 IP 策略。配置快照由 runtime.lua 在 HTTP worker 中
-- 写入共享字典；本模块只读取已验证的快照，因此控制面暂时不可用不会改变
-- 已经生效的访问控制规则。
local cjson = require "cjson"
local _M = {}
local cache = ngx.shared.runtime_configuration

local function current_snapshot()
  local encoded = cache and cache:get("content")
  if not encoded then return nil end
  local ok, decoded = pcall(cjson.decode, encoded)
  return ok and decoded or nil
end

local function ipv4_number(value)
  local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if not a or a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

local function ipv4_matches(ip, cidr)
  local address, bits = cidr:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
  address, bits = address or cidr, tonumber(bits) or 32
  if bits < 0 or bits > 32 then return false end
  local left, right = ipv4_number(ip), ipv4_number(address)
  if not left or not right then return false end
  if bits == 0 then return true end
  local divisor = 2 ^ (32 - bits)
  return math.floor(left / divisor) == math.floor(right / divisor)
end

local function ip_matches(ip, rules)
  if type(rules) ~= "table" then return false end
  for _, rule in ipairs(rules) do
    if type(rule) == "string" then
      if ip:find(":", 1, true) then
        -- IPv6 当前支持精确匹配；CIDR IPv6 可在后续引入专用地址库后扩展。
        if rule:lower() == ip:lower() then return true end
      elseif ipv4_matches(ip, rule) then
        return true
      end
    end
  end
  return false
end

local function current_server(content)
  local port = tonumber(ngx.var.server_port)
  local protocol = (ngx.var.protocol or ""):upper()
  for _, server in ipairs(content.streamServers or {}) do
    if tonumber(server.listenPort) == port and (protocol == "" or server.protocol == protocol) then
      return server
    end
  end
  return nil
end

function _M.enforce()
  local content = current_snapshot()
  if not content then return end -- 初始化或控制面不可用时沿用 fail-open 约定。
  local server = current_server(content)
  if not server or server.ipPolicyEnabled == false then return end
  local server_id = server.id
  local client_ip = ngx.var.remote_addr or ""
  local policies = {}
  for _, policy in ipairs(content.ipPolicies or {}) do
    if policy.scope == "STREAM" and tostring(policy.targetResourceId) == tostring(server_id) then
      policies[#policies + 1] = policy
    end
  end
  table.sort(policies, function(left, right)
    local lp, rp = tonumber(left.priority) or 0, tonumber(right.priority) or 0
    if lp ~= rp then return lp < rp end
    return tostring(left.id or "") < tostring(right.id or "")
  end)
  local blacklist_match, whitelist_configured, whitelist_match = false, false, false
  for _, policy in ipairs(policies) do
    if policy.enabled then
      local matches = ip_matches(client_ip, policy.ipRules)
      if policy.mode == "BLACKLIST" and matches then blacklist_match = true end
      if policy.mode == "WHITELIST" then whitelist_configured = true; if matches then whitelist_match = true end end
    end
  end
  if server.ipPolicyModeOrder == "WHITELIST_FIRST" and whitelist_match then return "allow" end
  if blacklist_match or (whitelist_configured and not whitelist_match) then
    ngx.log(ngx.WARN, "四层 IP 策略拒绝连接: client=", client_ip)
    return ngx.exit(ngx.ERROR)
  end
end

return _M
