-- Explicit, read-only snapshot adapter for a later controlled native session.
-- Merely loading this file installs no listener, starts no cast and writes no file.
-- Caller supplies a load-generation token. A fixed token cannot detect reloads.
local M={}
local function number(n)
    return type(n)=='number' and n==math.floor(n) and math.abs(n)<=9007199254740991
end
local function requireNumber(n,label)
    assert(number(n),'Invalid native '..label);return n
end
function M.Capture(epoch)
    if type(epoch)~='string' or epoch=='' or #epoch>200 then return nil,'Load-generation token required' end
    local out={epoch=epoch,complete=false,actors={},errors={},tick=0}
    local ok,why=pcall(function()
        assert(type(EEex_Sprite_GetInPortrait)=='function','Party reader unavailable')
        assert(type(EEex_Utility_IterateCPtrList)=='function','Effect iterator unavailable')
        assert(type(EEex_UDToPtr)=='function','Effect token reader unavailable')
        local chitin=rawget(_G,'EEex_EngineGlobal_CBaldurChitin')
            or (rawget(_G,'EngineGlobals') and EngineGlobals.g_pBaldurChitin)
        assert(chitin,'Game clock unavailable')
        out.tick=requireNumber(chitin.m_pObjectGame.m_worldTime.m_gameTime,'game clock')
        assert(out.tick>=0,'Negative game clock')
        local count=0
        for slot=0,5 do
            -- Never save sprites/effects in the exported snapshot. All native
            -- references remain local to this synchronous read on the game thread.
            local sprite=EEex_Sprite_GetInPortrait(slot)
            if sprite then
                local actor={id=requireNumber(sprite.m_id,'actor ID'),slot=slot,effects={}}
                -- Raw observed action ID; it is not decoded into a cast-start,
                -- release, aura-ready or successful-delivery event here.
                actor.actionId=requireNumber(sprite.m_curAction.m_actionID,'current action')
                assert(BfBot and type(BfBot._GetName)=='function','Name reader unavailable')
                actor.name=BfBot._GetName(sprite)
                assert(type(actor.name)=='string' and #actor.name>0 and #actor.name<=200,'Invalid actor name')
                out.actors[#out.actors+1]=actor
                EEex_Utility_IterateCPtrList(sprite.m_timedEffectList,function(e)
                    count=count+1;assert(count<=4096,'Effect snapshot limit exceeded')
                    local ptr=requireNumber(EEex_UDToPtr(e),'effect token');assert(ptr>0,'Null effect token')
                    local res=e.m_sourceRes:get()
                    -- Keep unnamed administrative effects in the baseline too.
                    -- Empty source names cannot match a nonempty cast resource.
                    assert(type(res)=='string' and #res<=8,'Invalid source resource')
                    local resource=e.m_res:get()
                    assert(type(resource)=='string' and #resource<=8,'Invalid effect resource')
                    actor.effects[#actor.effects+1]={token=string.format('%.0f',ptr),
                        sourceRes=res,resource=resource,
                        sourceId=requireNumber(e.m_sourceId,'effect source'),
                        opcode=requireNumber(e.m_effectId,'effect opcode'),
                        timing=requireNumber(e.m_durationType,'effect timing'),
                        rawDuration=requireNumber(e.m_duration,'raw effect duration'),
                        param1=requireNumber(e.m_effectAmount,'effect amount'),
                        param2=requireNumber(e.m_dWFlags,'effect flags'),
                        sourceType=requireNumber(e.m_sourceType,'effect source type')}
                end)
            end
        end
        assert(requireNumber(chitin.m_pObjectGame.m_worldTime.m_gameTime,'game clock')==out.tick,
            'Game clock changed during snapshot')
    end)
    if ok then out.complete=true else out.errors[1]=tostring(why) end
    return out
end
return M
