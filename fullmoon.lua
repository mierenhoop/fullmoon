--
-- ultra-light webframework for Redbean web server (https://redbean.dev/)
-- Copyright 2021 Paul Kulchenko
-- 

--[[-- support functions --]]--

local _VERSION = "0.10"
local _NAME = "fullmoon"
if not setfenv then -- Lua 5.2+; this assumes f is a function
  -- based on http://lua-users.org/lists/lua-l/2010-06/msg00314.html
  -- and https://leafo.net/guides/setfenv-in-lua52-and-above.html
  local function findenv(f)
    local idx = 1
    repeat
      local name, value = debug.getupvalue(f, idx)
      if name == '_ENV' then return idx, value end
      idx = idx + 1
    until not name
  end
  getfenv = function (f) return(select(2, findenv(f)) or _G) end
  setfenv = function (f, t)
    local level = findenv(f)
    if level then debug.upvaluejoin(f, level, function() return t end, 1) end
    return f
  end
end

local function argerror(cond, narg, extramsg)
  local name = debug.getinfo(2, "n").name or "?"
  local msg = ("bad argument #%d to %s%s"):format(narg, name, extramsg and " "..extramsg or  "")
  if not cond then error(msg, 3) end
  return cond, msg
end
local function logFormat(fmt, ...)
  return "(fm) "..(select('#', ...) == 0 and fmt or (fmt or ""):format(...))
end
local function getRBVersion()
  local v = GetRedbeanVersion()
  local major = math.floor(v / 2^16)
  return ("%d.%d"):format(major, math.floor((v / 2^16 - major) * 2^8))
end

-- request headers based on https://datatracker.ietf.org/doc/html/rfc7231#section-5
local headers = {}
(function(s) for h in s:gmatch("[%w%-]+") do headers[h:gsub("-","")] = h end end)([[
  Cache-Control Host Max-Forwards Proxy-Authorization User-Agent
  Accept Accept-Charset Accept-Encoding Accept-Language
  If-Match If-None-Match If-Modified-Since If-Unmodified-Since If-Range
]])
local setmap = {["%d"] = "0-9", ["%w"] = "a-zA-Z0-9", ["\\d"] = "0-9", ["\\w"] = "a-zA-Z0-9"}
local default500 = [[<!doctype html><title>{%& status %} {%& reason %}</title>
<h1>{%& status %} {%& reason %}</h1>
{% if message then %}<pre>{%& message %}</pre>{% end %}]]

--[[-- route path generation --]]--

local routes = {}
local function makePath(name, params)
  argerror(type(name) == "string", 1, "(string expected)")
  params = params or {}
  -- name can be the name or the route itself (even not registered)
  local pos = routes[name]
  local route = pos and routes[pos].route or name
  -- replace :foo with provided parameters
  route = route:gsub(":(%w+)([^(*:]*)", function(param, rest)
      return (params[param] or ":"..param)..rest:gsub("^%b[]","")
    end)
  -- replace splat with provided parameter, if any
  -- more than one splat is not expected, since it's already checked
  route = route:gsub("*", function() return params.splat or "*" end)
  -- remove all optional groups
  local function findopt(route)
    return route:gsub("(%b())", function(optroute)
        optroute = optroute:sub(2, -2)
        local s = optroute:find("[:*]")
        if s then
          local p = optroute:find("%b()")
          if not p or s < p then return "" end
        end
        return findopt(optroute)
      end)
  end
  route = findopt(route)
  local param = route:match(":(%w+)")
  argerror(not param, 2, "(missing required parameter "..(param or "?")..")")
  argerror(not route:find("*", 1, true), 2, "(missing required splat parameter)")
  return route
end

local ref = {} -- some unique key value
-- request functions (`request.write()`)
local reqenv = { write = Write, escapeHtml = EscapeHtml, makePath = makePath }
-- request properties (`request.authority`)
local reqapi = { authority = function()
    local url = ParseUrl(GetUrl())
    return EncodeUrl({scheme = url.scheme, host = url.host, port = url.port})
  end, }
local envmt = {__index = function(t, key)
    local val = reqenv[key] or rawget(t, ref) and t[ref][key] or _G[key]
    if not val and type(key) == "string" then
      local func = reqapi[key] or _G["Get"..key:sub(1,1):upper()..key:sub(2)]
      -- map a property (like `.host`) to a function call (`.GetHost()`)
      if type(func) == "function" then val = func() else val = func end
      t[key] = val
    end
    return val
  end}
local req
local function getRequest() return req end

local function serveResponse(status, headers, body)
  -- since headers is optional, handle the case when headers are not present
  if type(headers) == "string" and body == nil then
    body, headers = headers, nil
  end
  argerror(type(status) == "number", 1, "(number expected)")
  argerror(not headers or type(headers) == "table", 2, "(table expected)")
  argerror(not body or type(body) == "string", 3, "(string expected)")
  return function()
    SetStatus(status)
    if headers then
      -- make sure that the metatable gets transferred as well
      local r = getRequest()
      r.headers = setmetatable(headers, getmetatable(r.headers))
    end
    if body then Write(body) end
    return true
  end
end

--[[-- template engine --]]--

local function addlocals(params)
  local i = 1
  while true do
    local name, value = debug.getlocal(3, i)
    if not name then break end
    if string.sub(name, 1, 1) ~= '(' then
      params[name] = value
    end
    i = i + 1
  end
  return params
end

local templates = {}
local function render(name, opt)
  argerror(type(name) == "string", 1, "(string expected)")
  argerror(templates[name], 1, "(unknown template name)")
  -- add local variables from the current environment
  local params = addlocals(getfenv(templates[name])[ref] or {})
  -- add explicitly passed parameters
  for k, v in pairs(type(opt) == "table" and opt or {}) do params[k] = v end
  -- set the calculated parameters to the current template
  getfenv(templates[name])[ref] = params
  Log(kLogInfo, logFormat("render template '%s'", name))
  -- return template results or an empty string to indicate completion
  -- this is useful when the template does direct write to the output buffer
  return templates[name](opt) or ""
end

local function parseTemplate(tmpl)
  local EOT = "\0"
  local function writer(s) return #s > 0 and ("write(%q)"):format(s) or "" end
  local tupd = (tmpl.."{%"..EOT.."%}"):gsub("(.-){%%([=&]*)%s*(.-)%s*%%}", function(htm, pref, val)
      return writer(htm)
      ..(val ~= EOT -- this is not the suffix
        and (pref == "" -- this is a code fragment
          and val.." "
          or ("write(%s(%s or ''))"):format(pref == "&" and "escapeHtml" or "", val))
        or "")
    end)
  return tupd
end

local function addTemplate(name, code, opt)
  argerror(type(name) == "string", 1, "(string expected)")
  argerror(type(code) == "string" or type(code) == "function", 2, "(string or function expected)")
  Log(kLogVerbose, logFormat("add template '%s'", name))
  local env = setmetatable({include = render, [ref] = opt}, envmt)
  templates[name] = setfenv(type(code) == "function" and code or assert((loadstring or load)(parseTemplate(code), code)), env)
end

--[[-- routing engine --]]--

local function route2regex(route)
  -- foo/bar, foo/*, foo/:bar, foo/:bar[%d], foo(/:bar(/:more))(.:ext)
  local params = {}
  local regex, subnum = string.gsub(route, "%)", "%1?") -- update optional groups from () to ()?
    :gsub("%.", "\\.") -- escape dots (.)
    :gsub(":(%w+)", function(param) table.insert(params, param); return "([^/]+)" end)
    :gsub("(%b[])(%+%))(%b[])", "%3%2") -- handle custom sets
    :gsub("%b[]", function(s) return s:gsub("[%%\\][wd]", setmap) end)
    :gsub("%*", "(.*)") -- add splat
  argerror(subnum <= 1, 1, "more than one splat ('*') found")
  if subnum > 0 then table.insert(params, "splat") end
  -- mark optional captures, as they are going to be returned during match
  subnum = 1
  local s, e, capture = 0
  while true do
    s, e, capture = regex:find("%b()([?]?)", s+1)
    if not s then break end
    if capture > "" then table.insert(params, subnum, false) end
    subnum = subnum + 1
  end
  return "^"..regex.."$", params
end

local function addRoute(opts, handler)
  local ot = type(opts)
  local route
  if ot == "string" then
    route, opts = opts, nil
  elseif ot == "table" then
    route = table.remove(opts, 1)
  else
    argerror(false, 1, "(string or table expected)")
  end
  argerror(type(route) == "string", 1, "(route string expected)")
  argerror(not opts or opts[1] == nil, 1, "(only one route expected)")
  -- as the handler is optional, allow it to be skipped
  local ht = type(handler)
  argerror(ht == "function" or ht == "string" or ht == "nil", 2, "(function or string expected)")
  local pos = routes[route] or #routes+1
  local regex, params = route2regex(route)
  Log(kLogVerbose, logFormat("add route '%s'", route))
  if ht == "string" then
    -- if `handler` is a string, then turn it into a handler
    local newroute = handler
    handler = function(r) return RoutePath(r.makePath(newroute, r.params)) end
  end
  if ot == "table" then
    if opts.name then routes[opts.name] = pos end
    -- remap filters to hash if presented as an (array) table
    for k, v in pairs(opts) do
      if type(v) == "table" then
        -- {"POST", "PUT"} => {"POST", "PUT", PUT = true, POST = true}
        for i = 1, #v do v[v[i]] = true end
        if v.regex then v.regex = re.compile(v.regex) or argerror(false, 3, "(valid regex expected)") end
      elseif headers[k] then
        opts[k] = {pattern = "%f[%w]"..v.."%f[%W]"}
      end
    end
  end
  routes[pos] = {route = route, handler = handler, options = opts, comp = re.compile(regex), params = params}
  routes[route] = pos
end

local function matchAttribute(value, cond)
  if type(cond) ~= "table" then
    -- compare with the value, but if condition is a function, then return its result
    return value == nil or value == cond or type(cond) == "function" and cond(value)
  end
  if value == nil or cond[value] then return true end
  if cond.regex then return cond.regex:search(value) ~= nil end
  if cond.pattern then return value:match(cond.pattern) ~= nil end
  return false
end

local function matchRoute(path, req)
  assert(type(req) == "table", "bad argument #2 to match (table expected)")
  Log(kLogVerbose, logFormat("match %d route(s) against '%s'", #routes, path))
  for _, route in ipairs(routes) do
    -- skip static routes that are only used for path generation
    if type(route.handler) == "function" then
      local res = {route.comp:search(path)}
      local matched = table.remove(res, 1)
      Log(matched and kLogInfo or kLogVerbose, logFormat("route '%s' %smatched",
          route.route, matched and "" or "not "))
      if matched then -- path matched
        for ind, val in ipairs(route.params) do
          if val and res[ind] then req.params[val] = res[ind] > "" and res[ind] or false end
        end
        -- check if there are any additional options to filter by
        local opts = route.options
        local otherwise
        matched = true
        if opts and next(opts) then
          for filter, cond in pairs(opts) do
            local header = headers[filter]
            -- check "dashed" headers, params, properties (method, port, host, etc.), and then headers again
            local value = (header and req.headers[header]
              or req.params[filter] or req[filter] or req.headers[filter])
            -- condition can be a value (to compare with) or a table/hash with multiple values
            if not matchAttribute(value, cond) then
              otherwise = type(cond) == "table" and cond.otherwise or opts.otherwise
              matched = false
              Log(kLogInfo, logFormat("route '%s' filter '%s' not matched value '%s'%s",
                  route.route, filter, value, tonumber(otherwise) and " and returned "..otherwise or ""))
              break
            end
          end
        end
        if matched then
          local res = route.handler(req)
          if res then return res end
        else
          if otherwise then
            if type(otherwise) == "function" then
              return otherwise()
            else
              return serveResponse(otherwise)
            end
          end
        end
      end
    end
  end
end

--[[-- core engine --]]--

local function error2tmpl(status, reason, message)
  if not reason then reason = GetHttpReason(status) end
  SetStatus(status, reason) -- set status, but allow template handlers to overwrite it
  local ok, res = pcall(render, tostring(status),
    {status = status, reason = reason, message = message})
  return ok and res or ServeError(status, reason) or true
end
-- call the handler and handle any Lua error by returning Server Error
local function hcall(func, ...)
  local ok, res = xpcall(func, debug.traceback, ...)
  if ok then return res end
  local err = res:gsub("\n[^\n]*in function 'xpcall'\n", "\n")
  Log(kLogError, logFormat("Lua error: %s", err))
  return error2tmpl(500, nil, IsLoopbackIp(GetRemoteAddr()) and err or nil)
end

local function handleRequest()
  req = setmetatable({
      params = setmetatable({}, {__index = function(_, k) return GetParam(k) end}),
      headers = setmetatable({}, {__index = function(_, k) return GetHeader(k) end}),
    }, envmt)
  -- find a match and handle any Lua errors in handlers
  local res = hcall(matchRoute, GetPath(), req)
  local tres = type(res)
  if res == true then
    -- do nothing, as this request was already handled
  elseif not res then
    -- this request wasn't handled, so report 404
    return error2tmpl(404) -- use 404 template if available
  elseif tres == "function" then
    hcall(res) -- execute the (deferred) function and handle any errors
  elseif tres == "string" and #res > 0 then
    Write(res) -- output content as is
  end
  -- also output any headers that have been specified
  for name, value in pairs(req.headers or {}) do SetHeader(name, value) end
end

local tests -- forward declaration
local function run(opt)
  opt = opt or {}
  if opt.tests and tests then tests(); os.exit() end
  ProgramBrand(("%s/%s %s/%s"):format("redbean", getRBVersion(), _NAME, _VERSION))
  for key, v in pairs(opt) do
    if key == "headers" and type(v) == "table" then
      for h, val in pairs(v) do ProgramHeader(h, val) end
    else
      local func = _G["Program"..key:sub(1,1):upper()..key:sub(2)]
      argerror(type(func) == "function", 1, ("(unknown option '%s' with value '%s')"):format(key, v))
      func(v)
    end
  end
  OnHttpRequest = handleRequest -- assign Redbean handler to execute on each request
end

local function checkpath(path) return type(path) == "string" and path or GetPath() end
local fm = setmetatable({ VERSION = _VERSION, NAME = _NAME, COPYRIGHT = "Paul Kulchenko",
  addTemplate = addTemplate, render = render,
  addRoute = addRoute, makePath = makePath,
  getAsset = LoadAsset, run = run,
  -- serve index.lua or index.html if available; continue if not
  -- this handles being served as the route handler (with request passed)
  -- or as a method called from a route handler (with an optional path passed)
  serveIndex = function(path) return function() return ServeIndex(checkpath(path)) end end,
  -- return existing static/other assets if available
  serveDefault = function() return RoutePath() end,
  serveError = function(status, reason) return function() return error2tmpl(status, reason) end end,
  serveContent = function(tmpl, params) return function() return render(tmpl, params) end end,
  serveRedirect = function(loc, status) return function() return ServeRedirect(status or 307, loc) end end,
  serveAsset = function(path) return function() return ServeAsset(checkpath(path)) end end,
  serveResponse = serveResponse,
}, {__index =
  function(t, key)
    local method = key:match("^[A-Z][A-Z][A-Z]+$")
    if method then return(function(route) return {route, method = method} end) end
    -- handle serve204 and similar calls
    local serveStatus = key:match("^serve(%d%d%d)$")
    if serveStatus then return t.serveResponse(tonumber(serveStatus)) end
    -- handle logVerbose and other log calls
    local kVal = _G[key:gsub("^l(og%w*)$", function(name) return "kL"..name end)]
    if kVal then
      t[key] = function(...) return Log(kVal, logFormat(...)) end
      return t[key]
    end
    return _G[key:sub(1,1):upper()..key:sub(2)] -- return upper camel case version if exists
  end})

--[[-- various tests --]]--

tests = function()
  local isRedbean = ProgramBrand ~= nil
  if not isRedbean then
    Write = io.write
    re = {compile = function(exp) return {search = function(self, path)
          local res = {path:match(exp)}
          if #res > 0 then table.insert(res, 1, path) end
          return (unpack or table.unpack)(res)
        end}
      end}
    Log = function(_, ...) print("#", ...) end
    reqenv.escapeHtml = function(s) return (string.gsub(s, "&", "&amp;"):gsub('"', "&quot;"):gsub("<","&lt;"):gsub(">","&gt;")) end
  end

  -- provide methods not available outside of Redbean or outside of request handling
  SetStatus = function() end
  ServeError = function() end
  IsLoopbackIp = function() return true end
  GetRemoteAddr = function() end
  GetHttpReason = function(status) return tostring(status).." reason" end

  -- suppress default logging during tests
  if SetLogLevel then SetLogLevel(kLogWarn) end

  local out = ""
  reqenv.write = function(s) out = out..s end
  local num, success = 0, 0
  local section = ""
  local function outformat(s) return type(s) == "string" and ("%q"):format(s):gsub("\n","n") or tostring(s) end
  local function is(result, expected, message)
    local ok = result == expected
    num = num + 1
    success = success + (ok and 1 or 0)
    local msg = ("%s %d%s\t%s%s"):format((ok and "ok" or "not ok"),
      num, ((num == success or not ok) and "" or " -"..(num-success)), -- show number of total and failed tests
      (section > "" and section.." " or ""), message or ""
    )
    if not ok then
      msg = msg .. ("\n\treceived: %s\n\texpected: %s"):format(outformat(result), outformat(expected))
    end
    print(msg)
    out = ""
  end

  --[[-- template engine tests --]]--

  section = "(template)"
  local tmpl1 = "tmpl1"
  fm.addTemplate(tmpl1, "Hello, World!")
  fm.render(tmpl1)
  is(out, "Hello, World!", "text rendering")

  fm.addTemplate(tmpl1, "Hello, {%& title %}!")
  fm.render(tmpl1, {title = "World"})
  is(out, "Hello, World!", "text with parameter")

  fm.render(tmpl1, {title = "World&"})
  is(out, "Hello, World&amp;!", "text with encoded parameter")

  fm.addTemplate(tmpl1, "Hello, {% for i, v in ipairs({3,2,1}) do %}-{%= v %}{% end %}")
  fm.render(tmpl1)
  is(out, "Hello, -3-2-1", "Lua code")

  local tmpl2 = "tmpl2"
  fm.addTemplate(tmpl2, [[{a: "{%= title %}"}]])
  fm.render(tmpl2)
  is(out, '{a: ""}', "JSON with empty local value")

  do
    fm.addTemplate(tmpl2, [[{a: "{%= title %}"}]], {title = "set when adding template"})
    fm.render(tmpl2)
    is(out, '{a: "set when adding template"}', "JSON with value set when adding template")

    local title = "local value" -- do not remove; to provide a value for the template
    fm.render(tmpl2)
    is(out, '{a: "local value"}', "JSON with local value")

    fm.render(tmpl2, {title = "set from render"})
    is(out, '{a: "set from render"}', "JSON with a passed value set at rendering")

    fm.addTemplate(tmpl2, [[{% local title = "set from template" %}{a: "{%= title %}"}]])
    fm.render(tmpl2)
    is(out, '{a: "set from template"}', "JSON with value set from template")

    fm.addTemplate(tmpl2, [[{a: "{%= title %}"}]], {title = "set when adding"})
    fm.render(tmpl2)
    is(out, '{a: "local value"}', "JSON with local value overwriting the one set when adding template")
  end

  fm.addTemplate(tmpl1, "Hello, {% include('tmpl2') %}")
  fm.render(tmpl1)
  is(out, [[Hello, {a: "local value"}]], "`include` other template with a local value")

  fm.addTemplate(tmpl1, [[Hello, {% include('tmpl2', {title = "value"}) %}]])
  fm.render(tmpl1)
  is(out, [[Hello, {a: "value"}]], "`include` other template with passed value set at rendering")

  fm.addTemplate(tmpl1, [[Hello, {% local title = "another value"; include('tmpl2') %}]])
  fm.render(tmpl1)
  is(out, [[Hello, {a: "another value"}]], "`include` other template with value set from template")

  fm.addTemplate(tmpl1, "Hello, World!\n{% main() %}")
  local _, err = pcall(render, tmpl1)
  is(err ~= nil, true, "report Lua error in template")
  is(err:match('string "Hello, World!'), 'string "Hello, World!', "error references original template code")
  is(err:match(':2: '), ':2: ', "error references expected line number")

  fm.addTemplate(tmpl1, "Hello, {% main() %}World!", {main = function() end})
  fm.render(tmpl1)
  is(out, [[Hello, World!]], "used function can be passed when adding template")

  fm.addTemplate(tmpl2, [[{% local function main() %}<h1>Title</h1>{% end %}{% include "tmpl1" %}]])
  fm.render(tmpl2)
  is(out, [[Hello, <h1>Title</h1>World!]], "function can be overwritten with template fragments in extended template")

  fm.addTemplate(tmpl2, [[{% local function main() write"<h1>Title</h1>" end %}{% include "tmpl1" %}]])
  fm.render(tmpl2)
  is(out, [[Hello, <h1>Title</h1>World!]], "function can be overwritten with direct write in extended template")

  --[[-- routing engine tests --]]--

  section = "(routing)"
  is(route2regex("/foo/bar"), "^/foo/bar$", "simple route")
  is(route2regex("/foo/:bar"), "^/foo/([^/]+)$", "route with a named parameter")
  is(route2regex("/foo(/:bar)"), "^/foo(/([^/]+))?$", "route with a named optional parameter")
  is(route2regex("/foo/:bar[\\d]"), "^/foo/([0-9]+)$", "route with a named parameter and a customer set (posix syntax)")
  is(route2regex("/foo/:bar[%d]"), "^/foo/([0-9]+)$", "route with a named parameter and a customer set (Lua syntax)")
  is(route2regex("/foo(/:bar(/:more))"), "^/foo(/([^/]+)(/([^/]+))?)?$", "route with two named optional parameters")
  is(route2regex("/foo(/:bar)/*.zip"), "^/foo(/([^/]+))?/(.*)\\.zip$", "route with an optional parameter and a splat")
  local _, params = route2regex("foo(/:bar)/*.zip")
  is(params[1], false, "'foo(/:bar)/*.zip' - parameter 1 is optional")
  is(params[2], "bar", "'foo(/:bar)/*.zip' - parameter 2 is 'bar'")
  is(params[3], "splat", "'foo(/:bar)/*.zip' - parameter 3 is 'splat'")

  local handler = function() end
  fm.addRoute("/foo/bar", handler)
  local index = routes["/foo/bar"]
  is(routes[index].handler, handler, "assign handler to a regular route")
  fm.addRoute("/foo/bar")
  is(routes["/foo/bar"], index, "route with the same name is reassigned")
  is(routes[routes["/foo/bar"]].handler, nil, "assign no handler to a static route")

  local route = "/foo(/:bar(/:more[%d]))(.:ext)/*.zip"
  fm.addRoute(route, function(r)
      is(r.params.bar, "some", "[1/4] default optional parameter matches")
      is(r.params.more, "123", "[2/4] customer set matches")
      is(r.params.ext, "myext", "[3/4] optional extension matches")
      is(r.params.splat, "mo/re", "[4/4] splat matches path separators")
    end)
  matchRoute("/foo/some/123.myext/mo/re.zip", {params = {}})
  fm.addRoute(route, function(r)
      is(r.params.bar, "some.myext", "[1/4] default optional parameter matches dots")
      is(not r.params.more, true, "[2/4] missing optional parameter gets `false` value")
      is(not r.params.ext, true, "[3/4] missing optional parameter gets `false` value")
      is(r.params.splat, "more", "[4/4] splat matches")
    end)
  matchRoute("/foo/some.myext/more.zip", {params = {}})
  if isRedbean then
    local called = false
    fm.addRoute(route, function() called = true end)
    matchRoute("/foo/some.myext/more", {params = {}})
    is(called, false, "non-matching route handler is not called")
  end

  is(headers.CacheControl, "Cache-Control", "Cache-Control header is mapped")
  is(headers.IfRange, "If-Range", "If-Range header is mapped")
  is(headers.Host, "Host", "Host header is mapped")

  section = "(matchAttr)"

  is(matchAttribute("GET", "GET"), true, "attribute matches based on simple value")
  is(matchAttribute("GET", {GET = true}), true, "attribute matches based on simple value in a table")
  is(matchAttribute("GET", {}), false, "non-existing attribute doesn't match")
  is(matchAttribute(nil, "GET"), true, "`nil` value matches a simple value")
  is(matchAttribute(nil, {GET = true}), true, "`nil` value matches a value in a table")
  is(matchAttribute("GET", {GET = true, POST = true}), true, "attribute matches based on simple value in a table (among other values)")
  is(matchAttribute("text/html; charset=utf-8", {regex = re.compile("text/")}), true, "attribute matches based on regex")
  is(matchAttribute("text/html; charset=utf-8", {pattern = "%f[%w]text/html%f[%W]"}), true, "attribute matches based on Lua pattern")
  is(matchAttribute("GET", "POST"), false, "attribute doesn't match another simple value")
  is(matchAttribute("GET", {POST = true}), false, "attribute doesn't match if not present in a table")
  is(matchAttribute("text/html; charset=utf-8", {regex = re.compile("text/plain")}), false, "attribute doesn't match another regex")
  is(matchAttribute("GET", function() return true end), true, "attribute matches with a function that return `true`")
  is(matchAttribute("GET", function() return false end), false, "attribute doesn't match with a function that return `false`")

  fm.addRoute({"acceptencoding", AcceptEncoding = "gzip"})
  is(routes[routes.acceptencoding].options.AcceptEncoding.pattern, "%f[%w]gzip%f[%W]", "known header generates pattern-based match")

  local groute = fm.GET"route"
  is(type(groute), "table", "GET method returns attribute table")
  is(groute.method, "GET", "GET method sets method")
  is(groute[1], "route", "GET method sets route")

  --[[-- makePath tests --]]--

  section = "(makePath)"
  route = "/foo(/:bar(/:more[%d]))(.:ext)/*.zip"
  -- allow static parameters to skip the handler
  fm.addRoute({route, name = "foobar"})

  _, err = pcall(fm.makePath, route)
  is(err:match("missing required splat"), "missing required splat", "required splat is checked")
  _, err = pcall(fm.makePath, "foo/:bar")
  is(err:match("missing required parameter bar"), "missing required parameter bar", "required parameter is checked")
  is(fm.makePath(route, {splat = "name"}), "/foo/name.zip", "required splat is filled in")
  is(fm.makePath("foobar", {splat = "name"}), makePath(route, {splat = "name"}),
    "`makePath` by name and route produce same results")
  is(fm.makePath(route, {splat = "name", more = "foo"}), "/foo/name.zip",
    "missing optional parameter inside another missing parameter is removed")
  is(fm.makePath(route, {splat = "name", bar = "some"}), "/foo/some/name.zip", "single optional parameter is filled in")
  is(fm.makePath(route, {splat = "name", bar = "some", more = 12, ext = "json"}), "/foo/some/12.json/name.zip",
    "multiple optional parameters are filled in")
  is(fm.makePath("/foo/:bar", {bar = "more"}), "/foo/more", "unregistered route is handled")
  is(fm.makePath("/foo(/*.zip)"), "/foo", "optional splat is not required")
  is(fm.makePath("/foo(/*.zip)", {splat = "more"}), "/foo/more.zip", "optional splat is filled in")
  is(fm.makePath("/foo"), "/foo", "relative route generates absolute path")
  is(fm.makePath("/foo"), "/foo", "absolute route generates absolute path")

  is(fm.makePath("http://some.website.com/:foo?param=:bar", {foo = "some", bar = 123}),
    "http://some.website.com/some?param=123", "external/static path")

  -- test using makePath from a template
  fm.addTemplate(tmpl1, "Hello, {%= makePath('foobar', {splat = 'name'}) %}")
  fm.render(tmpl1)
  is(out, [[Hello, /foo/name.zip]], "`makePath` inside template")

  --[[-- serve* tests --]]--

  local status
  SetStatus = function(s) status = s end
  local url = "/status"
  GetPath = function() return url end

  section = "(serveError)"
  fm.addRoute("/status", fm.serveError(403, "Access forbidden"))
  fm.addTemplate("403", "Server Error: {%& reason %}")
  local error403 = routes[routes["/status"]].handler()
  is(out, "Server Error: Access forbidden", "serveError used as a route handler")
  is(error403, "", "serveError finds registered template")

  fm.addRoute("/status", fm.serveError(405))
  handleRequest()
  is(status, 405, "direct serveError(405) sets expected status")

  fm.addRoute("/status", function() return fm.serveError(402) end)
  handleRequest()
  is(status, 402, "handler calling serveError(402) sets expected status")

  section = "(serveResponse)"
  fm.addRoute("/status", fm.serve401)
  handleRequest()
  is(status, 401, "direct serve401 sets expected status")

  GetParam = function(key) return ({foo=123, bar=456})[key] end
  GetHeader = function() end
  GetMethod = function() return "GET" end

  fm.addRoute({"/status", method = {"SOME", otherwise = 404}}, fm.serve402)
  handleRequest()
  is(status, 404, "not matched attribute triggers configured otherwise processing")

  fm.addRoute({"/status", method = {"SOME", otherwise = fm.serveResponse(405)}}, fm.serve402)
  handleRequest()
  is(status, 405, "not matched attribute triggers dynamic otherwise processing")

  section = "(serveContent)"
  fm.addTemplate(tmpl1, "Hello, {%& title %}!")
  fm.addRoute("content", fm.serveContent(tmpl1, {title = "World"}))
  routes[routes["content"]].handler()
  is(out, "Hello, World!", "serveContent used as a route handler")

  section = "(params)"
  url = "/params/789"

  fm.addTemplate(tmpl1, "{%= foo %}-{%= bar %}")
  fm.addRoute("/params/:bar", function(r)
      return fm.render(tmpl1, {foo = r.params.foo, bar = r.params.bar})
    end)
  handleRequest()
  is(out, "123-789", "route parameter takes precedence over URL parameter with the same name")

  --[[-- redbean tests --]]--

  if isRedbean then
    section = "(log)"
    is(type(fm.logVerbose), "function", "logVerbose is a (dynamic) method")
    is(type(fm.logInfo), "function", "logInfo is a (dynamic) method")

    section = "(redbean)"
    is(type(fm.fetch), "function", "fetch function is available")
    is(type(fm.isLoopbackIp), "function", "isLoopbackIp function is available")
  end

  --[[-- run tests --]]--

  section = "(run)"
  local brand, port, header, value
  GetRedbeanVersion = function() return 0x010000 end
  ProgramBrand = function(b) brand = b end
  ProgramPort = function(p) port = p end
  ProgramHeader = function(h,v) header, value = h, v end
  run({port = 8081, headers = {foo = "bar"}})
  is(brand:match("redbean/[.%d]+"), "redbean/1.0", "brand captured server version")
  is(port, 8081, "port is set when passed")
  is(header..":"..value, "foo:bar", "default headers set when passed")
end

-- run tests if launched as a script
if not pcall(debug.getlocal, 4, 1) then run{tests = true} end

fm.addTemplate("500", default500) -- register default 500 status template

-- return library if called with `require`
return fm
