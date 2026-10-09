local _M = {}

local function allowed_path(path)
  return type(path) == "string" and path:sub(1, 15) == "/var/log/nginx/" and not path:find("..", 1, true) and not path:find("%z")
end

function _M.read()
  local args = ngx.req.get_uri_args()
  local path = args.path
  if not allowed_path(path) then
    ngx.status = ngx.HTTP_BAD_REQUEST
    ngx.say(require("cjson").encode({ error = "日志路径必须位于 /var/log/nginx/ 下" }))
    return
  end
  local limit = math.min(math.max(tonumber(args.lines) or 200, 1), 1000)
  local file = io.open(path, "r")
  if not file then
    ngx.status = ngx.HTTP_NOT_FOUND
    ngx.say(require("cjson").encode({ error = "日志文件不存在或当前实例没有权限读取", path = path, lines = {} }))
    return
  end
  local all = {}
  for line in file:lines() do
    all[#all + 1] = line
    if #all > limit then table.remove(all, 1) end
  end
  file:close()
  ngx.header.content_type = "application/json; charset=utf-8"
  ngx.say(require("cjson").encode({ path = path, lines = all, generatedAt = ngx.now() }))
end

return _M
