----------------------
-- The tmp module.
-- Lugate is a lua module for building JSON-RPC 2.0 Gateway APIs just inside of your Nginx configuration file.
-- Lugate is meant to be used with [ngx\_http\_lua\_module](https://github.com/openresty/lua-nginx-module) together.
--
-- @classmod tmp
-- @author Ivan Zinovyev <vanyazin@gmail.com>
-- @license MIT

--- Request factory
local Request = require ".request"

--- HTTP Statuses
local HttpStatuses = require '.http_statuses'

--- The lua gateway class definition
local Lugate = {
  ERR_PARSE_ERROR = -32700, -- Error code for "Parse error" error
  ERR_INVALID_REQUEST = -32600, -- Error code for "Invalid request" error
  ERR_METHOD_NOT_FOUND = -32601, -- Error code for "Method not found" error
  ERR_INVALID_PARAMS = -32602, -- Error code for "Invalid params" error
  ERR_INTERNAL_ERROR = -32603, -- Error code for "Internal error" error
  ERR_SERVER_ERROR = -32000, -- Error code for "Server error" error
  ERR_INVALID_PROXY_CALL = -32098, -- Error code for "Invalid proxy call" error
  ERR_EMPTY_REQUEST = -32097, -- Error code for "Empty request" error
  VERSION = '0.6.1', -- Current version
  DBG_MSG = 'DBG %s>>%s<<', -- Template for error log
  REQ_PREF = 'REQ', -- Request prefix (used in log message)
  RESP_PREF = 'RESP', -- Response prefix (used in log message)
}

Lugate.HTTP_POST = 8

--- Create new Lugate instance
-- @param[type=table] config Table of configuration options
-- @return[type=table] The new instance of Lugate
function Lugate:new(config)
  config.hooks = config.hooks or {}
  config.hooks.pre = config.hooks.pre or function() end
  config.hooks.pre_request = config.hooks.pre_request or function() end
  config.hooks.post = config.hooks.post or function() end

  assert(type(config.ngx) == "table", "Parameter 'ngx' is required and should be a table!")
  assert(type(config.json) == "table", "Parameter 'json' is required and should be a table!")
  assert(type(config.hooks.pre) == "function", "Parameter 'pre' is required and should be a function!")
  assert(type(config.hooks.post) == "function", "Parameter 'post' is required and should be a function!")

  -- Define metatable
  local lugate = setmetatable({}, Lugate)
  self.__index = self

  -- Define services and configs

  lugate.hooks = config.hooks
  lugate.ngx = config.ngx
  lugate.json = config.json
  lugate.router = config.router
  lugate.logger = config.logger
  lugate.responses = {}
  lugate.context = {}
  lugate.request_groups = {}

  return lugate
end

--- Create new Lugate instance. Initialize ngx dependent properties
-- @param[type=table] config Table of configuration options
-- @return[type=table] The new instance of Lugate
function Lugate:init(config)
  -- Create new tmp instance
  local lugate = self:new(config)

  -- Check request method
  if 'POST' ~= lugate.ngx.req.get_method() then
    lugate.ngx.say(lugate:build_json_error(Lugate.ERR_INVALID_REQUEST, 'Only POST requests are allowed'))
    lugate.ngx.exit(lugate.ngx.HTTP_OK)
  end

  -- Build config
  lugate.ngx.req.read_body() -- explicitly read the req body

  if not lugate:is_not_empty() then
    lugate.ngx.say(lugate:build_json_error(Lugate.ERR_EMPTY_REQUEST))
    lugate.ngx.exit(lugate.ngx.HTTP_OK)
  end

  return lugate
end

--- Get a proper formated json error
-- @param[type=int] code Error code
-- @param[type=string] message Error message
-- @param[type=table] data Additional error data
-- @param[type=number] id Request id
-- @return[type=string]
function Lugate:build_json_error(code, message, data, id)
  local messages = {
    [Lugate.ERR_PARSE_ERROR] = 'Invalid JSON was received by the server. An error occurred on the server while parsing the JSON text.',
    [Lugate.ERR_INVALID_REQUEST] = 'The JSON sent is not a valid Request object.',
    [Lugate.ERR_METHOD_NOT_FOUND] = 'The method does not exist / is not available.',
    [Lugate.ERR_INVALID_PARAMS] = 'Invalid method parameter(s).',
    [Lugate.ERR_INTERNAL_ERROR] = 'Internal JSON-RPC error.',
    [Lugate.ERR_SERVER_ERROR] = 'Server error',
    [Lugate.ERR_EMPTY_REQUEST] = 'Empty request.',
  }
--  local code = messages[code] and code or Lugate.ERR_SERVER_ERROR
  local code = (messages[code] or HttpStatuses[code]) and code or Lugate.ERR_SERVER_ERROR
  local message = message or messages[code]
  local data = data and self.json.encode(data) or 'null'
  local id = id or 'null'

  return '{"jsonrpc":"2.0","error":{"code":' .. tostring(code) .. ',"message":"' .. message .. '","data":' .. data .. '},"id":' .. id .. '}'
end

--- Check if request is empty
-- @return[type=boolean]
function Lugate:is_not_empty()
  return self:get_body() ~= '' and true or false
end

--- Get ngx request body
-- @return[type=string]
function Lugate:get_body()
  if not self.body then
    self.body = self.ngx.req and self.ngx.req.get_body_data() or ''
  end

  return self.body
end

--- Parse raw body
-- @return[type=table]
function Lugate:get_data()
  if not self.data then
    self.data = {}
    if self:get_body() then
      local success, res = pcall(self.json.decode, self:get_body())
      self.data = success and res or {}
    end
  end

  return self.data
end

--- Check if request is a batch
-- @return[type=boolean]
function Lugate:is_batch()
  if not self.batch then
    local data = self:get_data()
    self.batch =  data and data[1] and ('table' == type(data[1])) and true or false
  end

  return self.batch
end

--- Get request collection
-- @return[type=table] The table of requests
function Lugate:get_requests()
  if not self.requests then
    self.requests = {}
    local data = self:get_data()
    if self:is_batch() then
      for _, rdata in ipairs(data) do
        table.insert(self.requests, Request:new(rdata, self.json))
      end
    else
      table.insert(self.requests, Request:new(data, self.json))
    end
  end

  return self.requests
end

--- Get request collection prepared for ngx.location.capture_multi call
-- @return[type=table] The table of requests
function Lugate:run()
  -- Execute 'pre' middleware
  if false == self.hooks.pre(self) then
    return ngx.exit(ngx.HTTP_OK)
  end

  -- Loop requests
  local map_requests = {}
  for _, request in ipairs(self:get_requests()) do
    self:attach_request(request, map_requests)
  end

  -- Send multi requst and get multi response
  if  next(map_requests) ~= nil then
    local ngx_requests = self:get_ngx_requests(map_requests)
    local responses = { self.ngx.location.capture_multi(ngx_requests) }
    for i, response in ipairs(responses) do
      self:handle_response(i, response)
    end
  end

  -- Execute 'post' middleware
  if false == self.hooks.post(self) then
    return ngx.exit(ngx.HTTP_OK)
  end

  return self.responses
end

--- Attach request to the pipeline
-- @param[type=number] i Requets key
-- @param[type=table] request Request object
-- @param[type=table] ngx_requests Table of nginx requests
-- @return[type=boolean]
function Lugate:attach_request(request, map_requests)
  self.logger:write_log(request:get_body(), Lugate.REQ_PREF)
  if not request:is_valid() then
    table.insert(self.responses, self:build_json_error(Lugate.ERR_INVALID_REQUEST, nil, request:get_body(), request:get_id()));
    return true
  end

  local pre_request_result = self.hooks.pre_request(self, request)
  if type(pre_request_result) == 'string' then
    table.insert(self.responses, pre_request_result)
    return true
  end

  local addr, err = self.router:get_address(request:get_route())
  if addr then
    map_requests[addr] = map_requests[addr] or {}
    table.insert(map_requests[addr], request)
  else
    table.insert(self.responses,  self:build_json_error(Lugate.ERR_SERVER_ERROR, err, request:get_body(), request:get_id()))
  end


  return true
end

---
function Lugate:get_ngx_requests(map_requests)
  local ngx_requests = {}
  self.request_groups = {}
  for addr,requests in pairs(map_requests) do
    table.insert(self.request_groups, {addr=addr, reqs=requests})
    table.insert(ngx_requests, self:get_ngx_request(addr, requests))
  end

  return ngx_requests;
end

--- Build a request in format acceptable by nginx
-- @param[type=table] uri request uri
-- @return[type=table] requests list of rpc requests
function Lugate:get_ngx_request(addr, requests)
  local rpc_requests = {}
  for _,request in ipairs(requests) do
    table.insert(rpc_requests, request:get_body())
  end

  local body = ''
  if #requests > 1 then
    body = '[' .. table.concat(rpc_requests, ",") .. ']'
  else
    body = rpc_requests[1]
  end
  return { addr, { method = 8, body = body } }
end

--- Handle every single response
-- @param[type=number] n Response number
-- @param[type=table] response Response object
-- @return[type=boolean]
function Lugate:handle_response(i, response)
  -- HTTP code <> 200
  if self.ngx.HTTP_OK ~= response.status then
    local response_msg = HttpStatuses[response.status] or 'Unknown error'
    local data = self.ngx.HTTP_INTERNAL_SERVER_ERROR == response.status and self:clean_response(response.body) or nil
    for _,request in ipairs(self.request_groups[i]['reqs']) do
      table.insert(self.responses,  self:build_json_error(response.status, response_msg, data, request:get_id()))
    end
  -- HTTP code == 200
  else
    local resp_body = self:clean_response(response)
    -- Quick way to find invalid responses
    local first_char = string.sub(resp_body, 1, 1);
    local last_char = string.sub(resp_body, -1);

    -- JSON check
    if ('' == resp_body) or ('{' ~= first_char and '[' ~= first_char) or ('}' ~= last_char and ']' ~= last_char) then
      for _, request in ipairs(self.request_groups[i]['reqs']) do
        table.insert(self.responses,  self:build_json_error(
                Lugate.ERR_SERVER_ERROR, 'Server error. Bad JSON-RPC response.', nil, request:get_id()
        ))
      end
    else
      table.insert(self.responses, self:trim_brackets(resp_body))
      -- Push to log
      self.logger:write_log(self:trim_brackets(resp_body), Lugate.RESP_PREF)
    end
  end

  return true
end

--- Clean response (trim)
function Lugate:clean_response(response)
  local response_body = response.body or response
  return response_body:match'^()%s*$' and '' or response_body:match'^%s*(.*%S)'
end

---
function Lugate:trim_brackets(str)
  local _, i1 = string.find(str,'^%[*')
  local i2 = string.find(str,'%]*$')
  return string.sub(str, i1 + 1, i2 - 1)
end

--- Get responses as a string
-- @return[type=string]
function Lugate:get_result()
  if false == self:is_batch() then
    return self.responses[1]
  end

  return '[' .. table.concat(self.responses, ",") .. ']'
end

--- Print all responses and exit
function Lugate:print_responses()
  ngx.say(self:get_result())

  ngx.exit(ngx.HTTP_OK)
end

return Lugate