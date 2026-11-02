-- Yed Explorer for Ultima Noctis 
-- Pour la Guilde ULTIMA NOCTIS par Belzemute 2026 
local ADDON = ...
local Y = CreateFrame("Frame")
local db, panel, holder, content, footer, blank
local entries, queue, pending = {}, {}, nil
local epoch, activeScan, auraScheduled = 0, false, false
local rows = {}
-- Les huiles des AUTRES joueurs sont inconnues sauf s'ils partagent
-- eux-memes leur statut avec la meme version de cet addon.
local OIL_PREFIX = "YEDX_OIL"
local peerOils = {}
local lastOilStatus, lastOilSent = nil, -100
local oilScheduled = false


local ENCHANT_SLOTS = {
    {1,"Casque"}, {3,"Epaules"}, {5,"Torse"}, {7,"Jambes"},
    {8,"Bottes"}, {11,"Anneau 1"}, {12,"Anneau 2"}, {16,"Arme"},
}
local ALL_GEAR = {1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17}
local SLOT_NAMES = {
    [1]="Casque", [2]="Cou", [3]="Epaules", [5]="Torse", [6]="Ceinture",
    [7]="Jambes", [8]="Bottes", [9]="Poignets", [10]="Gants",
    [11]="Anneau 1", [12]="Anneau 2", [13]="Bijou 1", [14]="Bijou 2",
    [15]="Dos", [16]="Arme", [17]="Main gauche",
}
-- Identifiants de flacons utiles ; detection complementaire par nom localise.
local FLASK_SPELLS = { [1235108]=true }
-- Midnight utilise notamment le buff « Repas nourrissant » (1232091),
-- et non uniquement « Bien nourri ». Ces IDs couvrent aussi des festins.
local FOOD_SPELLS = {
    [1232091]=true, -- Repas nourrissant (Midnight)
    [1232078]=true, -- Festin copieux de Midnight
    [1232087]=true, -- Festin de Midnight
    [1284617]=true, -- Champion's Bento
    [454188]=true,  -- Hearty Well Fed
    [19705]=true,   -- Well Fed (ancien)
}
local FOOD_NAMES = {
    "repas nourrissant", "bien nourri", "nourrissant",
    "well fed", "hearty well fed",
}
local function HasFoodName(name)
    if type(name)~="string" then return false end
    local n=string.lower(name)
    for _,term in ipairs(FOOD_NAMES) do
        if n:find(term,1,true) then return true end
    end
    return false
end
local function IsSecret(x)
    return type(issecretvalue)=="function" and issecretvalue(x)
end
local function Restricted()
    if InCombatLockdown() then return true end
    if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
        local ok, running = pcall(C_ChallengeMode.IsChallengeModeActive)
        if ok and running then return true end
    end
    if IsEncounterInProgress and IsEncounterInProgress() then return true end
    return false
end
local function Name(unit)
    local name = UnitName(unit)
    return name or unit
end
local function AddProblem(entry, category, detail)
    entry.problems[category] = detail
end
local function ReadConsumables(entry)
    if Restricted() or not C_UnitAuras or not C_UnitAuras.GetBuffDataByIndex then return false end
    local foundFood, foundFlask, inspected = false, false, false
    local ok, readable = pcall(function()
        for i=1,120 do
            local aura = C_UnitAuras.GetBuffDataByIndex(entry.unit, i)
            if not aura then inspected=true; break end
            if IsSecret(aura) or IsSecret(aura.name) or IsSecret(aura.spellId) then
                return false
            end
            local n = type(aura.name)=="string" and string.lower(aura.name) or ""
            local id = aura.spellId
            if FOOD_SPELLS[id] or HasFoodName(n) then foundFood=true end
            if FLASK_SPELLS[id] or n:find("flacon",1,true)
                or n:find("flask",1,true) or n:find("flasque",1,true) then
                foundFlask=true
            end
        end
        return true
    end)
    -- Un buff illisible ne signifie PAS qu'il est absent.
    if not ok or not readable or not inspected then return false end
    entry.problems.food = not foundFood and "Pas mangé" or nil
    entry.problems.flask = not foundFlask and "Pas de flacon" or nil
    return true
end

-- API Midnight 12.1 : enchantement temporaire sur NOS armes.
-- Aucun parametre "unit" : impossible de lire directement celui d'autrui.
local function WeaponIsOffhandWeapon()
    local link = GetInventoryItemLink("player",17)
    if not link or IsSecret(link) or not GetItemInfoInstant then return false end
    local ok, _, _, _, equipLoc = pcall(GetItemInfoInstant,link)
    if not ok or IsSecret(equipLoc) then return false end
    return equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONOFFHAND"
end
local function ReadTempEnchant(slot)
    if C_PaperDollInfo and C_PaperDollInfo.GetTemporaryEnchantmentInfo then
        local ok, result = pcall(C_PaperDollInfo.GetTemporaryEnchantmentInfo,slot)
        if not ok or IsSecret(result) then return nil end
        return result ~= nil
    end
    -- Compatibilite avec les clients ou l'ancien nom reste disponible.
    if GetWeaponEnchantInfo then
        local ok, main, _, _, _, offhand = pcall(GetWeaponEnchantInfo)
        if not ok or IsSecret(main) or IsSecret(offhand) then return nil end
        if slot == 16 then return not not main end
        if slot == 17 then return not not offhand end
    end
    return nil
end
-- Retour : "Y" = equipe ; "N" = manque ; nil = impossible a verifier.
local function OwnOilStatus()
    if Restricted() then return nil end
    local link = GetInventoryItemLink("player",16)
    if not link or IsSecret(link) then return nil end
    local main = ReadTempEnchant(16)
    if main == nil then return nil end
    if not main then return "N" end
    if WeaponIsOffhandWeapon() then
        local off = ReadTempEnchant(17)
        if off == nil then return nil end
        if not off then return "N" end
    end
    return "Y"
end
local function ApplyOilStatus(entry,status)
    if status == "N" then
        entry.problems.oil = "Huile / pierre d'arme manquante"
    elseif status == "Y" then
        entry.problems.oil = nil
    end
end
local function FullUnitName(unit)
    if GetUnitName then
        local n=GetUnitName(unit,true)
        if type(n)=="string" and not IsSecret(n) and n~="" then return n end
    end
    return Name(unit)
end
local function SameMember(sender, entry)
    if type(sender)~="string" or IsSecret(sender) then return false end
    local a=sender:lower():gsub("%s+","")
    local b=(entry.fullName or entry.name):lower():gsub("%s+","")
    if a==b then return true end
    local ra=a:match("^[^-]+")
    local rb=b:match("^[^-]+")
    -- Tolere un realm absent, mais pas deux realms contradictoires.
    return ra==rb and (not a:find("-",1,true) or not b:find("-",1,true))
end
local function OilChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end
local function SendOilMessage(message)
    local channel=OilChannel()
    if Restricted() or not channel or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    pcall(C_ChatInfo.SendAddonMessage,OIL_PREFIX,message,channel)
end
local function ShareOwnOil(force)
    if Restricted() or not OilChannel() then return end
    local status=OwnOilStatus()
    if not status then return end
    local now=(GetTime and GetTime()) or 0
    if status==lastOilStatus and now-lastOilSent<(force and 1 or 8) then return end
    lastOilStatus,lastOilSent=status,now
    SendOilMessage("O:"..status)
end
local function CheckPeerCache(entry)
    if UnitIsUnit(entry.unit,"player") then return end
    local now=(GetTime and GetTime()) or 0
    for sender,record in pairs(peerOils) do
        if now-record.time < 90 and SameMember(sender,entry) then
            ApplyOilStatus(entry,record.status)
            return
        end
    end
end

local function ItemFields(link)
    if type(link)~="string" or IsSecret(link) then return end
    local payload = link:match("item:([%d:%-]+)")
    if not payload then return end
    local result, count = {}, 0
    for field in (payload .. ":"):gmatch("([^:]*):") do
        count=count+1
        result[count]=tonumber(field) or 0
        if count==6 then break end
    end
    if count < 6 then return end
    return result
end
local function SocketCount(link)
    if not C_Item or not C_Item.GetItemNumSockets then return nil end
    local success, amount = pcall(C_Item.GetItemNumSockets, link)
    if not success or IsSecret(amount) or type(amount)~="number" then return nil end
    return amount
end
local function ScanGear(entry)
    local unit = entry.unit
    local ench, gem = {}, {}
    for _, slot in ipairs(ENCHANT_SLOTS) do
        local link = GetInventoryItemLink(unit,slot[1])
        local fields = ItemFields(link)
        if fields and fields[2]==0 then ench[#ench+1]=slot[2] end
    end
    -- La main gauche n'exige un enchantement que si elle porte une arme.
    local left = GetInventoryItemLink(unit,17)
    if left and GetItemInfoInstant then
        local _, _, _, equipLoc = GetItemInfoInstant(left)
        if equipLoc=="INVTYPE_WEAPON" or equipLoc=="INVTYPE_WEAPONOFFHAND" then
            local fields=ItemFields(left)
            if fields and fields[2]==0 then ench[#ench+1]="Arme secondaire" end
        end
    end
    for _, slot in ipairs(ALL_GEAR) do
        local link=GetInventoryItemLink(unit,slot)
        local fields=ItemFields(link)
        if fields then
            local sockets=SocketCount(link)
            -- Les 4 emplacements de gemmes sont dans le lien d'objet.
            -- Ne jamais deduire qu'une chasse existe si l'API ne l'indique pas.
            if sockets and sockets > 0 then
                local limit=math.min(4,sockets)
                for i=1,limit do
                    if (fields[i+2] or 0)==0 then
                        gem[#gem+1]=SLOT_NAMES[slot] or ("Emplacement "..slot)
                    end
                end
            end
        end
    end
    if #ench>0 then AddProblem(entry,"enchant","Enchantement manquant : "..table.concat(ench,", ")) end
    if #gem>0 then AddProblem(entry,"gem","Gemme manquante : "..table.concat(gem,", ")) end
    entry.gearChecked=true
end
local function BuildLines()
    local output={}
    for _, entry in ipairs(entries) do
        for _,category in ipairs({"food","flask","oil","enchant","gem"}) do
            local detail=entry.problems[category]
            if detail then output[#output+1]={name=entry.name,detail=detail,class=entry.class} end
        end
    end
    return output
end
local function MakeLabel(parent, size)
    local t=parent:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    t:SetFont(STANDARD_TEXT_FONT,size,"")
    t:SetJustifyH("LEFT")
    return t
end
local function MakeButton(parent, label, width, x, callback)
    local b=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate")
    b:SetSize(width,20)
    b:SetPoint("TOPRIGHT",x,-7)
    b:SetText(label)
    b:SetScript("OnClick",callback)
    return b
end
local function BuildPanel()
    panel=CreateFrame("Frame","YedXploreurFrame",UIParent,"BackdropTemplate")
    panel:SetSize(408,90)
    panel:SetPoint("CENTER",UIParent,"CENTER",db.x or 0,db.y or 80)
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart",function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop",function(self)
        self:StopMovingOrSizing()
        local x,y=self:GetCenter()
        local cx,cy=UIParent:GetCenter()
        db.x=math.floor(x-cx+0.5)
        db.y=math.floor(y-cy+0.5)
    end)
    panel:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
    panel:SetBackdropColor(0.065,0.083,0.12,0.96)
    panel:SetBackdropBorderColor(0.24,0.33,0.45,1)

    local title=MakeLabel(panel,13)
    title:SetPoint("TOPLEFT",11,-11)
    title:SetText("|cff70c8ffYed Explorer for Ultima Noctis|r")
    MakeButton(panel,"X",23,-7,function() panel:Hide();db.visible=false end)
    MakeButton(panel,"R",23,-35,function() Y:Scan(true) end)

    holder=CreateFrame("ScrollFrame",nil,panel)
    holder:SetPoint("TOPLEFT",10,-37)
    holder:SetWidth(387)
    holder:EnableMouseWheel(true)
    content=CreateFrame("Frame",nil,holder)
    content:SetWidth(385)
    content:SetHeight(20)
    holder:SetScrollChild(content)
    holder:SetScript("OnMouseWheel",function(self,delta)
        local maximum=math.max(0,content:GetHeight()-self:GetHeight())
        self:SetVerticalScroll(math.max(0,math.min(maximum,self:GetVerticalScroll()-delta*22)))
    end)
    blank=MakeLabel(content,11)
    blank:SetPoint("TOPLEFT",4,-3)
    blank:SetTextColor(.50,.77,.57)

    footer=MakeLabel(panel,10)
    footer:SetPoint("BOTTOMLEFT",12,9)
    footer:SetWidth(267)
    footer:SetTextColor(.57,.65,.72)

    local copyright = MakeLabel(panel,8)
    copyright:SetPoint("BOTTOMRIGHT",-10,9)
    copyright:SetWidth(119)
    copyright:SetJustifyH("RIGHT")
    copyright:SetTextColor(.43,.49,.56)
    copyright:SetText("© 2026 Belzemute")
    panel:Hide()
end
function Y:Draw()
    if not panel or not panel:IsShown() then return end
    local lines=BuildLines()
    local count=#lines
    local visible=math.max(1,math.min(12,count))
    local height=visible*20
    panel:SetHeight(62+height)
    holder:SetHeight(height)
    content:SetHeight(math.max(height,count*20))
    blank:SetText(count==0 and (activeScan and "Inspection en cours..." or "Aucun manque confirme") or "")
    for i,record in ipairs(lines) do
        local row=rows[i]
        if not row then
            row=MakeLabel(content,11)
            row:SetPoint("TOPLEFT",4,-(i-1)*20)
            row:SetWidth(376)
            row:SetHeight(19)
            rows[i]=row
        end
        local c=RAID_CLASS_COLORS and RAID_CLASS_COLORS[record.class]
        local r,g,b=1,1,1
        if c then r,g,b=c.r,c.g,c.b end
        row:SetText(string.format("|cff%02x%02x%02x%s|r  -  |cffff7777%s|r",
            math.floor(r*255),math.floor(g*255),math.floor(b*255),record.name,record.detail))
        row:Show()
    end
    for i=count+1,#rows do rows[i]:Hide() end
    if Restricted() then
        footer:SetText("Etat fige : combat ou cle MM+ active")
    elseif activeScan then
        footer:SetText(count.." manque(s) confirme(s) - inspection en cours")
    else
        footer:SetText(count.." manque(s) confirme(s) - R pour actualiser")
    end
end
local function RefreshBuffs()
    if Restricted() then return end
    for _,entry in ipairs(entries) do
        if UnitExists(entry.unit) and UnitGUID(entry.unit)==entry.guid then
            ReadConsumables(entry)
        end
    end
    Y:Draw()
end
local function NextInspect(version)
    if version~=epoch or Restricted() or pending then return end
    local e=table.remove(queue,1)
    if not e then activeScan=false;Y:Draw();return end
    if not UnitExists(e.unit) or UnitGUID(e.unit)~=e.guid or not CanInspect(e.unit) then
        C_Timer.After(.10,function() NextInspect(version) end)
        return
    end
    pending=e
    local ok=pcall(NotifyInspect,e.unit)
    if not ok then pending=nil;C_Timer.After(.2,function() NextInspect(version) end);return end
    C_Timer.After(4,function()
        if version~=epoch then return end
        if pending==e then
            pending=nil
            if ClearInspectPlayer then ClearInspectPlayer() end
            C_Timer.After(1.8,function() NextInspect(version) end)
        end
    end)
end
function Y:Scan(requestPeerStatus)
    if Restricted() then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff70c8ffYed-xploreur :|r scan impossible en combat ou pendant une cle MM+ active.") end
        Y:Draw()
        return
    end
    epoch=epoch+1
    local version=epoch
    if pending and ClearInspectPlayer then ClearInspectPlayer() end
    pending=nil
    entries,queue={},{}
    activeScan=true
    local units={}
    if IsInRaid() then
        for i=1,GetNumGroupMembers() do units[#units+1]="raid"..i end
    elseif IsInGroup() then
        units={"player"}
        for i=1,GetNumSubgroupMembers() do units[#units+1]="party"..i end
    else units={"player"} end
    for _,unit in ipairs(units) do
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local guid=UnitGUID(unit)
            if guid and not IsSecret(guid) then
                local _,class=UnitClass(unit)
                local e={unit=unit,guid=guid,name=Name(unit),fullName=FullUnitName(unit),class=class,problems={}}
                ReadConsumables(e)
                entries[#entries+1]=e
                if UnitIsUnit(unit,"player") then
                    ScanGear(e)
                    ApplyOilStatus(e,OwnOilStatus())
                else
                    CheckPeerCache(e)
                    queue[#queue+1]=e
                end
            end
        end
    end
    self:Draw()
    NextInspect(version)
    -- Un seul signal par joueur. Les reponses a la demande de statut
    -- sont espacees pour respecter la limitation des messages Blizzard.
    ShareOwnOil()
    if requestPeerStatus ~= false and IsInGroup() and not Restricted() then SendOilMessage("Q") end
end
local function DebugAuras()
    if Restricted() then
        print("|cff70c8ffYed-xploreur :|r buffs illisibles en combat ou en clé MM+ active.")
        return
    end
    if not C_UnitAuras or not C_UnitAuras.GetBuffDataByIndex then
        print("|cff70c8ffYed-xploreur :|r API des buffs indisponible.")
        return
    end
    print("|cff70c8ffYed-xploreur :|r Liste des buffs actifs (nom / ID) :")
    local seen = 0
    local ok = pcall(function()
        for i=1,120 do
            local aura=C_UnitAuras.GetBuffDataByIndex("player",i)
            if not aura then break end
            if IsSecret(aura) or IsSecret(aura.name) or IsSecret(aura.spellId) then
                print("Buffs protégés par le jeu.")
                break
            end
            seen=seen+1
            print(tostring(aura.name).." / "..tostring(aura.spellId or "?"))
        end
    end)
    if not ok then print("Impossible de lire les buffs actuellement.") end
    if seen==0 and ok then print("Aucun buff lisible.") end
end
local function ScheduleOilRefresh()
    if oilScheduled or Restricted() then return end
    oilScheduled=true
    C_Timer.After(.6,function()
        oilScheduled=false
        local status=OwnOilStatus()
        if panel and panel:IsShown() then
            for _,entry in ipairs(entries) do
                if UnitIsUnit(entry.unit,"player") then ApplyOilStatus(entry,status) end
            end
            Y:Draw()
        end
        ShareOwnOil()
    end)
end
local function ScheduleBuffRefresh()
    if auraScheduled or Restricted() then return end
    auraScheduled=true
    C_Timer.After(1,function()
        auraScheduled=false
        if panel and panel:IsShown() then RefreshBuffs() end
    end)
end

SLASH_YEDXPLOREUR1="/yed"
SLASH_YEDXPLOREUR2="/yedx"
SlashCmdList.YEDXPLOREUR=function(msg)
    local cmd=type(msg)=="string" and msg:lower():match("^%s*(%S+)") or ""
    if cmd=="reset" then
        db.x,db.y=0,80
        panel:ClearAllPoints()
        panel:SetPoint("CENTER",UIParent,"CENTER",0,80)
        panel:Show();db.visible=true;Y:Scan()
    elseif cmd=="arme" or cmd=="oil" then
        local status=OwnOilStatus()
        print("|cff70c8ffYed Explorer for Ultima Noctis :|r arme temporaire : " ..
            (status=="Y" and "OK" or status=="N" and "MANQUANTE" or "NON VERIFIABLE"))
    elseif cmd=="auras" or cmd=="buffs" or cmd=="debug" then
        DebugAuras()
    elseif cmd=="scan" or cmd=="actualiser" then
        panel:Show();db.visible=true;Y:Scan()
    elseif cmd=="off" or cmd=="hide" then
        panel:Hide();db.visible=false
    else
        if panel:IsShown() then panel:Hide();db.visible=false
        else panel:Show();db.visible=true;Y:Scan() end
    end
end
Y:RegisterEvent("ADDON_LOADED")
Y:RegisterEvent("READY_CHECK")
Y:RegisterEvent("GROUP_ROSTER_UPDATE")
Y:RegisterEvent("INSPECT_READY")
Y:RegisterEvent("PLAYER_REGEN_DISABLED")
Y:RegisterEvent("PLAYER_REGEN_ENABLED")
Y:RegisterEvent("UNIT_AURA")
Y:RegisterEvent("UNIT_INVENTORY_CHANGED")
Y:RegisterEvent("CHAT_MSG_ADDON")
Y:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
Y:SetScript("OnEvent",function(self,event,...)
    if event=="ADDON_LOADED" then
        if ...~=ADDON then return end
        if type(YedXploreurDB)~="table" then YedXploreurDB={} end
        db=YedXploreurDB
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            pcall(C_ChatInfo.RegisterAddonMessagePrefix,OIL_PREFIX)
        end
        BuildPanel()
        -- La fenetre reste cachee tant que le joueur ne l'ouvre pas.
    elseif event=="INSPECT_READY" then
        local guid=...
        if not pending or Restricted() or guid~=pending.guid then return end
        local e=pending
        pending=nil
        if UnitExists(e.unit) and UnitGUID(e.unit)==guid then ScanGear(e) end
        if ClearInspectPlayer then ClearInspectPlayer() end
        Y:Draw()
        local version=epoch
        C_Timer.After(1.8,function() NextInspect(version) end)
    elseif event=="READY_CHECK" then
        if not Restricted() then panel:Show();db.visible=true;self:Scan(false) end
    elseif event=="GROUP_ROSTER_UPDATE" then
        if panel and panel:IsShown() and not Restricted() then self:Scan(false) end
        ShareOwnOil()
    elseif event=="PLAYER_REGEN_DISABLED" then
        epoch=epoch+1
        pending=nil
        activeScan=false
        self:Draw()
    elseif event=="PLAYER_REGEN_ENABLED" then
        if panel and panel:IsShown() and not Restricted() then self:Scan() end
    elseif event=="UNIT_AURA" then
        if panel and panel:IsShown() and not Restricted() then ScheduleBuffRefresh() end
    elseif event=="UNIT_INVENTORY_CHANGED" then
        local unit=...
        if unit=="player" then ScheduleOilRefresh() end
    elseif event=="CHAT_MSG_ADDON" then
        local prefix,msg,channel,sender=...
        if prefix~=OIL_PREFIX or Restricted() then return end
        if msg=="Q" then
            -- Repond une fois, pas une fois par demandeur.
            ShareOwnOil(true)
        elseif msg=="O:N" or msg=="O:Y" then
            local matched=false
            for _,entry in ipairs(entries) do
                if not UnitIsUnit(entry.unit,"player") and SameMember(sender,entry) then
                    ApplyOilStatus(entry,msg:sub(3))
                    matched=true
                end
            end
            if matched then
                peerOils[sender]={status=msg:sub(3),time=(GetTime and GetTime()) or 0}
                self:Draw()
            end
        end
    elseif event=="ADDON_RESTRICTION_STATE_CHANGED" then
        if panel and panel:IsShown() and not Restricted() then ScheduleBuffRefresh();ScheduleOilRefresh() end
    end
end)
