local bwUtils=require('bwUtils')

function getFeederHandleToTrigger(feedersData)
    local errString=nil
    local feederName=getDistributionValue(feederDistribution)
    local feederHandle=feedersData[feederName]
    local partToDrop=nil
    if feederHandle then
        return feederHandle
    end
    errString="Warning: feeder '"..feederName.."' was not found and won't be triggered."
    return -1,errString
end

getDistributionValue=function(distribution)
    -- Distribution string could be:
    -- {} --> returns nil
    -- {{}} --> returns nil
    -- a,a,b,c --> returns a,b, or c
    -- {{2,a},{1,b},{1,c}} --> returns a,b, or c
    if #distribution>0 then
        if (type(distribution[1])~='table') or (#distribution[1]>0) then
            if (type(distribution[1])=='table') and (#distribution[1]==2) then
                local cnt=0
                for i=1,#distribution,1 do
                   cnt=cnt+distribution[i][1] 
                end
                local p=simGetFloatParameter(sim_floatparam_rand)*cnt
                cnt=0
                for i=1,#distribution,1 do
                    if cnt+distribution[i][1]>=p then
                        return distribution[i][2]
                    end
                    cnt=cnt+distribution[i][1] 
                end
            else
                local cnt=#distribution
                local p=1+math.floor(simGetFloatParameter(sim_floatparam_rand)*cnt-0.0001)
                return distribution[p]
            end
        end
    end
end

getSensorState=function()
    if sensorHandle>=0 then
        local data=simReadCustomDataBlock(sensorHandle,'XYZ_BINARYSENSOR_INFO')
        data=simUnpackTable(data)
        return data['detectionState']
    end
    return 0
end

getConveyorDistanceTrigger=function()
    if conveyorHandle>=0 then
        local data=simReadCustomDataBlock(conveyorHandle,'CONVEYOR_CONF')
        if data then
            data=simUnpackTable(data)
            local d=data['encoderDistance']
            if d then
                if not lastConveyorDistance then
                    lastConveyorDistance=d
                end
                if math.abs(lastConveyorDistance-d)>conveyorTriggerDist then
                    lastConveyorDistance=d
                    return true
                end
            end
        end
    end
    return false
end

wasMultiFeederTriggered=function()
    local data=simUnpackTable(simReadCustomDataBlock(model,'XYZ_MULTIFEEDERTRIGGER_INFO'))
    local val=data['multiFeederTriggerCnt']
    if val and val~=multiFeederTriggerLastState then
        multiFeederTriggerLastState=val
        return true
    end
    return false
end

if (sim_call_type==sim_childscriptcall_initialization) then
    REF_SENSOR=1 -- index of referenced sensor object handle
    REF_CONVEYOR=2 -- index of referenced conveyor object handle
    model=simGetObjectAssociatedWithScript(sim_handle_self)
    local data=simReadCustomDataBlock(model,'XYZ_MULTIFEEDERTRIGGER_INFO')
    data=simUnpackTable(data)
    sensorHandle=bwUtils.getReferencedObjectHandle(model,REF_SENSOR)
    conveyorHandle=bwUtils.getReferencedObjectHandle(model,REF_CONVEYOR)
    conveyorTriggerDist=data['conveyorDist']
    mode=0 -- 0=frequency, 1=sensor, 2=user, 3=conveyor, 4=multi-feeder
    local tmp=simBoolAnd32(data['bitCoded'],4+8+16)
    if tmp==4 then mode=1 end
    if tmp==8 then mode=2 end
    if tmp==12 then mode=3 end
    if tmp==16 then mode=4 end
    sensorLastState=0
    multiFeederTriggerLastState=0

    local feeders=bwUtils.getAllPossibleTriggerableFeeders(model)
    feedersData={}
    if feeders then
        for i=1,#feeders,1 do
            feedersData[feeders[i][1]]=feeders[i][2]
        end
    end
    counter=0
end

if (sim_call_type==sim_childscriptcall_actuation) then
    local t=simGetSimulationTime()
    local dt=simGetSimulationTimeStep()

    local data=simReadCustomDataBlock(model,'XYZ_MULTIFEEDERTRIGGER_INFO')
    data=simUnpackTable(data)
    local triggerFrequency=data['frequency']
    local feederAlgo=data['algorithm']
    if simBoolAnd32(data['bitCoded'],2)>0 then
        -- The feeder is enabled
        feederDistribution='{'..data['feederDistribution']..'}'
        local f=loadstring("return "..feederDistribution)
        feederDistribution=f()

        if true then --feederAlgo then
            local sensorState=getSensorState()
            local feederToTrigger=-1
            local errStr=nil
            local t=simGetSimulationTime()
            if mode==0 then
                -- Frequency triggered
                if not lastTriggerTime then
                    lastTriggerTime=t-9999
                end
                if t-lastTriggerTime>(1/triggerFrequency) then
                    lastTriggerTime=t
                    feederToTrigger,errStr=getFeederHandleToTrigger(feedersData)
                end
            end
            if mode==1 then
                -- Sensor triggered
                if sensorState~=sensorLastState then
                    feederToTrigger,errStr=getFeederHandleToTrigger(feedersData)
                end
            end
            if mode==3 and getConveyorDistanceTrigger() then
                -- Conveyor belt distance triggered
                feederToTrigger,errStr=getFeederHandleToTrigger(feedersData)
            end
            if mode==2 then
                -- User triggered
                local algo=assert(loadstring(feederAlgo))
                if algo() then
                    feederToTrigger,errStr=getFeederHandleToTrigger(feedersData)
                end
            end
            if mode==4 then
                -- Multi-feeder triggered
                if wasMultiFeederTriggered() then
                    feederToTrigger,errStr=getFeederHandleToTrigger(feedersData)
                end
            end
            if errStr then
                simAddStatusbarMessage('\n'..errStr..'\n')
            end
            sensorLastState=sensorState
            if feederToTrigger and feederToTrigger>=0 then
                counter=counter+1
                if simIsHandleValid(feederToTrigger)>0 then
                    local data=simReadCustomDataBlock(feederToTrigger,'XYZ_FEEDER_INFO')
                    if data then
                        data=simUnpackTable(data)
                        if simBoolAnd32(data['bitCoded'],4+8+16)==16 then
                            data['multiFeederTriggerCnt']=data['multiFeederTriggerCnt']+1
                            simWriteCustomDataBlock(feederToTrigger,'XYZ_FEEDER_INFO',simPackTable(data))
                        end
                    else
                        data=simReadCustomDataBlock(feederToTrigger,'XYZ_MULTIFEEDERTRIGGER_INFO')
                        if data then
                            data=simUnpackTable(data)
                            if simBoolAnd32(data['bitCoded'],4+8+16)==16 then
                                data['multiFeederTriggerCnt']=data['multiFeederTriggerCnt']+1
                                simWriteCustomDataBlock(feederToTrigger,'XYZ_MULTIFEEDERTRIGGER_INFO',simPackTable(data))
                            end
                        end
                    end
                end
            end
        end
    end

end 