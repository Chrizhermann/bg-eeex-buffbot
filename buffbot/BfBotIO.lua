-- Recipient-plan interchange. Data only: imported files are never executed.
BfBot.PlanIO={directory='override/bfbot_plans',maxBytes=524288}
local I=BfBot.PlanIO
local function hex(s) return (s or ''):gsub('.',function(c) return string.format('%02X',c:byte()) end) end
local function unhex(s,limit)
    if #s%2~=0 or #s>limit*2 or s:find('[^%x]') then return nil end
    return (s:gsub('%x%x',function(c) return string.char(tonumber(c,16)) end))
end
local function valid(s,n) return type(s)=='string' and #s>0 and #s<=n and not s:find('%c') end
function I.Encode(preset)
    if type(preset)~='table' or not valid(preset.name,80) or type(preset.requests)~='table'
        or #preset.requests>BfBot.Plan.MAX_REQUESTS then return nil,'Invalid preset' end
    local mode=preset.orderMode or 'custom'
    if mode~='custom' and mode~='smart' and mode~='long' then return nil,'Invalid order mode' end
    local lines={'BUFFBOT-PARTY-PLAN\t2','N\t'..hex(preset.name),'M\t'..mode}
    for index,r in ipairs(preset.requests) do
        if not valid(r.group,100) or not valid(r.target,200)
            or r.source~=nil and not valid(r.source,200) or r.var~=nil and not valid(r.var,8) then return nil,'Invalid request' end
        local manual=r.manual or index
        if type(manual)~='number' or manual%1~=0 or manual<1 or manual>1000000 then return nil,'Invalid manual order' end
        lines[#lines+1]=table.concat({'R',hex(r.group),hex(r.target),hex(r.source),hex(r.var),r.on==0 and '0' or '1',manual},'\t')
    end
    return table.concat(lines,'\n')..'\n'
end
function I.Decode(data)
    if type(data)~='string' or #data>I.maxBytes or data:find('\0',1,true) then return nil,'Invalid plan file' end
    data=data:gsub('\r\n','\n')
    local lines={};for line in data:gmatch('([^\n]*)\n') do lines[#lines+1]=line end
    local version=lines[1] and lines[1]:match('^BUFFBOT%-PARTY%-PLAN\t([12])$')
    if data:sub(-1)~='\n' or not version or not lines[2] then return nil,'Unsupported plan format' end
    local name=lines[2]:match('^N\t(%x+)$');name=name and unhex(name,80)
    if not valid(name,80) then return nil,'Invalid preset name' end
    local mode=version=='2' and lines[3] and lines[3]:match('^M\t([a-z]+)$') or 'custom'
    if mode~='custom' and mode~='smart' and mode~='long' then return nil,'Invalid order mode' end
    if version=='2' and lines[3]~='M\t'..mode then return nil,'Invalid order mode' end
    local preset={name=name,requests={},orderMode=mode}
    for n=(version=='2' and 4 or 3),#lines do
        local g,t,s,v,on,manual
        if version=='2' then g,t,s,v,on,manual=lines[n]:match('^R\t(%x+)\t(%x+)\t(%x*)\t(%x*)\t([01])\t(%d+)$')
        else g,t,s,v,on=lines[n]:match('^R\t(%x+)\t(%x+)\t(%x*)\t(%x*)\t([01])$') end
        manual=tonumber(manual) or #preset.requests+1
        if manual<1 or manual>1000000 then return nil,'Invalid manual order' end
        if not g or #preset.requests>=BfBot.Plan.MAX_REQUESTS then return nil,'Invalid request list' end
        g,t,s,v=unhex(g,100),unhex(t,200),unhex(s,200),unhex(v,8)
        if not valid(g,100) or not valid(t,200) or s==nil or v==nil
            or s~='' and not valid(s,200) or v~='' and not valid(v,8) then return nil,'Invalid request' end
        preset.requests[#preset.requests+1]={group=g,target=t,source=s~='' and s or nil,var=v~='' and v or nil,on=tonumber(on),manual=manual}
    end
    return preset
end
function I.ValidFilename(name)
    return type(name)=='string' and #name<=160 and name:match('^[%w_-]+%.bbp$')~=nil
end
function I.Export(preset)
    if BfBot._noIO or not io or not os then return nil,'File access unavailable' end
    local data,why=I.Encode(preset);if not data then return nil,why end
    os.execute('mkdir "'..I.directory..'" 2>nul')
    local stem=preset.name:gsub('[^%w_-]',''):sub(1,60);if stem=='' then stem='Preset' end
    -- Never overwrite another export, even with duplicate or translated names.
    for n=1,10000 do
        local name=stem..'-'..n..'.bbp';local path=I.directory..'/'..name
        local old=io.open(path,'rb')
        if old then old:close() else
            local f,err=io.open(path,'wb');if not f then return nil,tostring(err) end
            local ok,writeErr=f:write(data);local closed,closeErr=f:close()
            if not ok or not closed then return nil,tostring(writeErr or closeErr) end
            return name
        end
    end
    return nil,'Too many exported plans'
end
function I.List()
    local result={};if BfBot._noIO or not io or not io.popen then return result end
    local pipe=io.popen('dir /b "override\\bfbot_plans\\*.bbp" 2>nul');if not pipe then return result end
    for name in pipe:lines() do
        if I.ValidFilename(name) and #result<1024 then result[#result+1]=name end
    end
    pipe:close();table.sort(result);return result
end
function I.Read(name)
    if BfBot._noIO or not io or not I.ValidFilename(name) then return nil,'Invalid plan filename' end
    local f,err=io.open(I.directory..'/'..name,'rb');if not f then return nil,tostring(err) end
    local data=f:read(I.maxBytes+1);f:close();return I.Decode(data)
end
function I.Insert(state,preset)
    -- Round-trip validation keeps file and UI callers on the same strict schema.
    local data,why=I.Encode(preset);if not data then return nil,why end
    local clean;clean,why=I.Decode(data);if not clean then return nil,why end
    for i=1,8 do
        if not state.presets[i] then state.presets[i]=clean;state.active=i;return i end
    end
    return nil,'Maximum eight presets'
end
