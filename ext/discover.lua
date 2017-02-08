
-- 初始化全局变量
_DISCOVER_HOLD_MAX = os.getenv("DISCOVER_HOLD_MAX")==nil and 102400 or os.getenv("DISCOVER_HOLD_MAX")
_DISCOVER_AUTH_TOKEN = os.getenv("DISCOVER_AUTH_TOKEN")==nil and '' or os.getenv("DISCOVER_AUTH_TOKEN")
_DISCOVER_DATA_PATH = os.getenv("DISCOVER_DATA_PATH")==nil and '/tmp' or os.getenv("DISCOVER_DATA_PATH")
_DISCOVER_HOSTS = {}
local discover_hosts_str = os.getenv("DISCOVER_HOSTS")
if discover_hosts_str ~= nil then
	for discover_host in string.gmatch(discover_hosts_str, "([^,]+)") do
	    table.insert( _DISCOVER_HOSTS, discover_host )
	end
end
_DISCOVER_CASES = {}
local discover_cases_str = os.getenv("DISCOVER_CASES")
if discover_cases_str ~= nil then
	for discover_case in string.gmatch(discover_cases_str, "([^,]+)") do
	    table.insert( _DISCOVER_CASES, discover_case )
	end
end

-- 注册服务
function discover_register()
	local url_args = ngx.req.get_uri_args()
	local token = url_args["token"]
	local case = url_args["case"]
	local isSync = url_args["isSync"]

	if token==nil then
	    return ngx.say("usage: /__discover?token=xxx&case=xxx&host=xxx&weight=xxx")
	end

	if token~=_DISCOVER_AUTH_TOKEN then
	    return ngx.say("NO ACCESS")
	end

	-- 返回各节点处理的PV信息
	local getPvs = url_args["getPvs"]
	if getPvs~=nil then
		local pv_ids = ngx.shared._discover_pvs:get_keys( _DISCOVER_HOLD_MAX )
		local pvs = {}
		for _,pv_id in ipairs(pv_ids) do
			pvs[pv_id] = ngx.shared._discover_pvs:get(pv_id)
		end
	    return ngx.say( ngx.encode_args( pvs ) )
	end

	-- 返回保持会话的数据
	local getHolds = url_args["getHolds"]
	if getHolds~=nil then
		local hold_ids = ngx.shared._discover_holds:get_keys( _DISCOVER_HOLD_MAX )
		local holds = {}
		for _,hold_id in ipairs(hold_ids) do
			holds[hold_id] = ngx.shared._discover_holds:get(hold_id)
		end
	    return ngx.say( ngx.encode_args( holds ) )
	end

	if case==nil then
	    return ngx.say("NO case")
	end

	local getHosts = url_args["getHosts"]
	if getHosts~=nil then
		-- 获取主机列表
	    return ngx.say( ngx.shared._discover_global:get("hosts_"..case) )
	end

	local holdId = url_args["holdId"]
	local holdHost = url_args["holdHost"]
	if holdId~=nil then
		-- 同步主机绑定
		if holdHost==nil or holdHost=="" then
			ngx.shared._discover_holds:delete(case.."_"..holdId)
		else
			ngx.shared._discover_holds:set(case.."_"..holdId, holdHost, _discover_get_expires())
		end
	    return ngx.say( "OK" )
	end

	local host = url_args["host"]
	local weight = url_args["weight"]
	if host~=nil and weight~=nil then
		-- 注册/注销节点
		local hosts = _discover_load_hosts( case )
		local init_pv = 0
		local real_weight = nil
		if weight~="" and weight~="0" then
			local weight1,pv1
			for tmp_host, tmp_weight in pairs(hosts) do
				weight1 = tmp_weight
				pv1 = _discover_getPv(case,tmp_host)
				break
			end
			if weight1~=nil and pv1~=nil then
				init_pv = pv1 / weight1 * weight
			end
			real_weight = weight
		end

		ngx.shared._discover_pvs:set(case.."_"..host, init_pv, _discover_get_expires())
		hosts[host] = real_weight
		local hosts_str = _discover_save_hosts(case, hosts, true)
		ngx.log( ngx.WARN, "***	"..(isSync~=nil and "SYNC	" or "REGISTER	")..(real_weight~=nil and "ADD	" or "REMOVE	")..case.."	"..host.."	"..weight.."	FROM	"..ngx.var.remote_addr.."	["..hosts_str.."]" )

		if isSync==nil then
			-- 同步到其他服务器
			for _,discover_host in ipairs(_DISCOVER_HOSTS) do
				-- local result = _discover_curl( "http://"..discover_host.."/__discover?token=".._DISCOVER_AUTH_TOKEN.."&case="..case.."&host="..host.."&weight="..weight.."&isSync=1" )
				local result = _discover_http( discover_host, "/__discover?token=".._DISCOVER_AUTH_TOKEN.."&case="..case.."&host="..host.."&weight="..weight.."&isSync=1" )
				ngx.log( ngx.WARN, "***	DISTRIBUTE	"..(real_weight~=nil and "ADD	" or "REMOVE	")..case.."	"..host.."	"..weight.."	TO	"..discover_host.."	["..(result~=nil and result or "").."]" )
			end
		end

		return ngx.say( "OK" )
	end
	ngx.say( "NO ACCESS" )
end

-- 获取一个节点地址
function discover_fetch(case,hold_id,default_host)
	ngx.ctx.case = case
	ngx.ctx.hold_id = hold_id
	if case==nil then
		ngx.ctx.host = ""
	    return default_host~=nil and default_host or ""
	end

	local hosts = _discover_load_hosts( case )
	if hold_id~=nil then
		local host = ngx.shared._discover_holds:get(case.."_"..hold_id)
		if host~=nil and host~="" then
			_discover_plusPv(case, host, 1)
			ngx.ctx.host = host
			return host
		end
	end

	local min_score = nil
	local min_host = nil
	for host, weight in pairs(hosts) do
		local pv = _discover_getPv(case,host)
		local score = pv/weight
		if min_score==nil or score<min_score then
			min_score = score
			min_host = host
		end
	end

	if min_host==nil or min_host=="" then
	    min_host = default_host~=nil and default_host or ""
	end

	_discover_plusPv(case, min_host, 1)

	if hold_id~=nil then
		ngx.shared._discover_holds:set(case.."_"..hold_id, min_host, _discover_get_expires())
		-- 同步到其他服务器
		for _,discover_host in ipairs(_DISCOVER_HOSTS) do
			-- local result = _discover_curl( "http://"..discover_host.."/__discover?token=".._DISCOVER_AUTH_TOKEN.."&case="..case.."&holdId="..hold_id.."&holdHost="..min_host.."&isSync=1" )
			local result = _discover_http( discover_host, "/__discover?token=".._DISCOVER_AUTH_TOKEN.."&case="..case.."&holdId="..hold_id.."&holdHost="..min_host.."&isSync=1" )
			-- ngx.log( ngx.WARN, "***	DISTRIBUTE	HOLD	"..case.."	"..hold_id.."	"..min_host.."	TO	"..discover_host.."	["..(result~=nil and result or "").."]" )
		end
	end

	ngx.ctx.host = min_host
	return min_host
end

-- 判读请求是否正常
function discover_check_response()
	local case = ngx.ctx.case
	local host = ngx.ctx.host
	if case==nil or host==nil then
		return
	end

	local hold_id = ngx.ctx.hold_id
	local failed_key = "faileds_"..case.."_"..host
	local failed_times = ngx.shared._discover_global:get(failed_key)
-- ngx.log( ngx.WARN, "***	discover_check_response	"..case.."	"..host.."	["..failed_times.."]" )

	if failed_times~=nil and (ngx.status<502 or ngx.status>504) then
		ngx.shared._discover_global:delete(failed_key)
	end

	if ngx.status>501 and ngx.status<505 then
		if failed_times == nil then
			ngx.shared._discover_global:set(failed_key, failed_times)
			failed_times = 1
		else
			ngx.shared._discover_global:incr(failed_key, 1)
			failed_times = failed_times + 1
		end

		if hold_id ~= nil then
			ngx.shared._discover_holds:delete(case.."_"..hold_id)
			for _,discover_host in ipairs(_DISCOVER_HOSTS) do
				_discover_curl( "http://"..discover_host.."/__discover?token=".._DISCOVER_AUTH_TOKEN.."&case="..case.."&holdId="..hold_id.."&holdHost=&isSync=1&failedTimes="..failed_times )
			end
		end

		_discover_plusPv(case, host, failed_times*10)
		if failed_times >= 3 then
			-- 失败3次，注销节点
			local hosts = _discover_load_hosts( case )
			hosts[host] = nil
			local hosts_str = _discover_save_hosts(case, hosts, true)
			ngx.log( ngx.WARN, "***	INVALID	"..case.."	"..host.."	"..ngx.status.."	FROM	"..ngx.var.remote_addr.."	["..failed_times.."]" )
			-- 同步到其他服务器
			for _,discover_host in ipairs(_DISCOVER_HOSTS) do
				local result = _discover_curl( "http://"..discover_host.."/__discover?token=".._DISCOVER_AUTH_TOKEN.."&case="..case.."&host="..host.."&weight=0&isSync=1&failedTimes="..failed_times )
				-- local result = _discover_http( discover_host, "/__discover?token=".._DISCOVER_AUTH_TOKEN.."&case="..case.."&host="..host.."&weight=0&isSync=1&failedTimes="..failed_times )
				ngx.log( ngx.WARN, "***	DISTRIBUTE	INVALID	"..case.."	"..host.."	TO	"..discover_host.."	["..(result~=nil and result or "").."]" )
			end
		end

		-- TODO 想办法找其他节点处理请求，确保不会出现失败
	end
end

function _discover_getPv(case,host)
	local pv = ngx.shared._discover_pvs:get(case.."_"..host)
	return pv==nil and 0 or pv
end

function _discover_plusPv(case,host,value)
	-- PV+1
	if ngx.shared._discover_pvs:incr(case.."_"..host, value) == nil then
		ngx.shared._discover_pvs:set(case.."_"..host, value, _discover_get_expires())
	end
end


function _discover_load_hosts(case)
	local str = ngx.shared._discover_global:get("hosts_"..case)
	if str==nil then
		return {}
	end
	local hosts = ngx.decode_args( str )
	if hosts==nil then
		return {}
	end
    return hosts
end

-- 保存数据
function _discover_save_hosts(case,hosts,file)
	if hosts==nil then
		return
	end
	local str = ngx.encode_args( hosts )
	if str==nil then
		return
	end

	-- 保存到共享内存
	ngx.shared._discover_global:set( "hosts_"..case, str )

	if file~=nil and file~=false then
		-- 保存到文件
		local f,err = io.open( _DISCOVER_DATA_PATH.."/"..case, "w+" )
		if f~=nil then
			f:write( str )
			f:close()
		else
			ngx.log( ngx.ERR, "save file discover."..case.." failed, "..err)
		end
	end

	return str
end

function _discover_get_expires()
	-- TODO 计算到第二天凌晨4:00的秒数，并确定GC是否自动
	-- TODO 或考虑跑 crontab 定时清除
	return 3600
end

-- 用tcp实现一个最简单的http客户端
function _discover_http(hostname,path)
	if hostname==nil or path==nil then
		return nil
	end
  	local result = nil
	local pos = hostname:find(":")
	local host = pos~=nil and hostname:sub(1,pos-1) or hostname
	local port = pos~=nil and hostname:sub(pos+1) or 80
	local sock = ngx.socket.tcp()
    sock:settimeout(100)
    local ok, err = sock:connect(host, port)
    if ok then
		local bytes, err = sock:send("GET "..path.." HTTP/1.0\r\nHost:"..hostname.."\r\n\r\n")
	    if bytes~=nil then
			repeat
		        local data, err = sock:receive()
		        if data ~= nil then
		        	result = data
		        end
			until( data==nil or err~=nil )
	    end
	    sock:close()
    end
    return result
end

-- 调用curl
function _discover_curl(url)
	if url==nil then
		return nil
	end
	local fp = io.popen("curl --connect-timeout 0.1 '"..url.."' 2>/dev/null")
	local result = fp:read("*all")
	fp:close()
	if result ~= nil then
		result = result:gsub( "%s+$", "" )
	end
	if result ~= nil and result~="" and result~="nil" and result:find("<")==nil then
		return result
	end
    return nil
end

-- 初始化
local is_inited = ngx.shared._discover_global:get("__inited")
if is_inited==nil then
	ngx.shared._discover_global:set("__inited",1)

	-- 启动时初始化Hosts数据
	for _,discover_case in ipairs(_DISCOVER_CASES) do
		-- 优先从其他nginx节点取配置
		local str = ngx.shared._discover_global:get("host_"..discover_case)
		if str == nil then
			for _,discover_host in ipairs(_DISCOVER_HOSTS) do
				str = _discover_curl( "http://"..discover_host.."/__discover?token=".._DISCOVER_AUTH_TOKEN.."&case="..discover_case.."&getHosts=1" )
				if str ~= nil then
					_discover_save_hosts( discover_case, ngx.decode_args( str ) )
					ngx.log( ngx.WARN, "***	INIT HOSTS	"..discover_case.."	FROM HOST	"..discover_host.."	["..str.."]" )
					break
				end
			end
		end

		if str == nil then
			-- 没有其他nginx节点时从本地文件获取
			local f = io.open( _DISCOVER_DATA_PATH.."/"..discover_case, "r" )
			if f ~= nil then
				local result = f:read( "*all" )
				f:close()
				if result ~= nil and result~="" then
					str = result
					_discover_save_hosts( discover_case, ngx.decode_args( str ) )
					ngx.log( ngx.WARN, "***	INIT HOSTS	"..discover_case.."	FROM FILE	".._DISCOVER_DATA_PATH.."/"..discover_case.."	["..str.."]" )
				end
			end
		end

		if str == nil then
			-- 确实没有内容
			_discover_save_hosts( discover_case, {} )
			ngx.log( ngx.WARN, "***	INIT HOSTS	"..discover_case.."	EMPTY" )
		end
	end

	-- 初始化Holds数据
	for _,discover_host in ipairs(_DISCOVER_HOSTS) do
		str = _discover_curl( "http://"..discover_host.."/__discover?token=".._DISCOVER_AUTH_TOKEN.."&getHolds=1" )
		if str ~= nil then
			local holds = ngx.decode_args(str)
			local hold_expires = _discover_get_expires()
			local hold_num = 0
			for case_hold_id, hold_host in pairs(holds) do
				ngx.shared._discover_holds:set(case_hold_id, hold_host, hold_expires)
				hold_num = hold_num+1
			end
			ngx.log( ngx.WARN, "***	INIT HOLDS	FROM HOST	"..discover_host.."	["..hold_num.."]" )
			break
		end
	end

end
