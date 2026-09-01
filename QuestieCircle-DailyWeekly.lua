local ADDON = ...

-- Adds WoW Circle's custom repeatable quests to Questie's database.
-- Nothing inside Questie is edited: entries are handed over through the public
-- registry QuestieCompat.RegisterCorrection, which Questie drains inside
-- QuestieCorrections:Initialize() right before it compiles the database.

if not QuestieLoader or not QuestieCompat then return end

local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
local l10n      = QuestieLoader:ImportModule("l10n")

-- ===========================================================================
--  СПИСОК КВЕСТОВ - добавлять сюда
-- ===========================================================================
--   kind        "daily" | "weekly"
--   name        точное название квеста (как в игре)
--   level       уровень квеста, показывается в трекере как [80]
--   startedBy   npcID того, кто ВЫДАЁТ квест              (необязательно)
--   finishedBy  npcID того, кто ПРИНИМАЕТ                 (по умолчанию = startedBy)
--   objective   текст цели квеста, например "Побеждено рейдовых боссов (ур. 80)"
--               Без него Questie считает, что делать нечего, и рисует жёлтый
--               знак вопроса "сдать". Сам текст и прогресс (0/1) берутся из
--               живого журнала, здесь он нужен только чтобы цель вообще была.
--               Поддерживается одна цель на квест.
--   npc         { name = "Имя", level = 80, zone = areaID, coords = {x, y} }
--               нужно только чтобы Questie рисовал иконку на карте
--
--   npcID и координаты снимаются так (взять NPC в цель, стоя рядом):
--   /run SetMapToCurrentZone() local g=UnitGUID("target") print(UnitName("target"), g and tonumber(g:sub(6,12),16), GetCurrentMapAreaID())
-- ===========================================================================

local QUESTS = {
    -- ---------------------------------------------------- еженедельные (7) --
    [50016] = { kind = "weekly", name = "Испытание подземелий",              level = 80,
                objective = "Пройдено подземелий через систему поиска группы" },
    [50017] = { kind = "weekly", name = "Испытание рейда",                   level = 80,
                objective = "Побеждено финальных боссов рейдовых подземелий (ур. 80)" },
    [50018] = { kind = "weekly", name = "Испытание полей боя",               level = 80,
                objective = "Побед на полях боя" },
    [50019] = { kind = "weekly", name = "Испытание полей боя: урон",         level = 80,
                objective = "Нанесено урона на полях боя" },
    [50020] = { kind = "weekly", name = "Испытание полей боя: исцеление",    level = 80,
                objective = "Исцелено здоровья союзников на полях боя" },
    [50021] = { kind = "weekly", name = "Испытание арены: 2х2 / 3х3",        level = 80,
                objective = "Побед на арене в форматах 2 на 2 или 3 на 3" },
    [50022] = { kind = "weekly", name = "Испытание арены: 1х1 / 3х3 соло",   level = 80,
                objective = "Побед в соло-боях на арене" },

    -- -------------------------------------------------------- ежедневные (4) --
    [50023] = { kind = "daily",  name = "Ежедневное испытание подземелий",   level = 80,
                objective = "Пройдено подземелий через систему поиска группы" },
    [50024] = { kind = "daily",  name = "Ежедневное испытание полей боя",    level = 80,
                objective = "Завершено сражений на полях боя" },
    [50025] = { kind = "daily",  name = "Ежедневное испытание арены",        level = 80,
                objective = "Побед на арене любого формата" },
    [50026] = { kind = "daily",  name = "Ежедневное испытание рейда",        level = 80,
                objective = "Побеждено рейдовых боссов (ур. 80)" },
}

-- Виртуальные записи только для строки-напоминания в трекере. Таких квестов на
-- сервере нет, они никогда не попадут в журнал - это просто "вешалка", чтобы
-- Questie было что нарисовать, когда напоминать не о чем конкретном.
-- ID взяты заведомо свободные, вне диапазона серверных 50016-50026.
local REMINDERS = {
    daily  = { id = 50900, name = "Ежедневное испытание", level = 80 },
    weekly = { id = 50901, name = "Еженедельное испытание", level = 80 },
}

-- ===========================================================================

-- Shared with Tracker.lua
QuestieCircleQuests = QuestieCircleQuests or {}
QuestieCircleQuests.QUESTS = QUESTS
QuestieCircleQuests.REMINDERS = REMINDERS

-- Галочка в настройках Questie (вкладка Tracker). SavedVariables на момент
-- выполнения этого файла ещё не загружены, но обе функции ниже вызываются
-- позже - из корректировок и из трекера, - когда флаг уже доступен.
function QuestieCircleQuests.IsEnabled()
    return not (QuestieCircleQuestsDB and QuestieCircleQuestsDB.disabled)
end

-- Negative zoneOrSort means "category". TrackerUtils:GetCategoryNameByID looks
-- the name up in l10n.questCategoryLookup, and l10n() falls back to the key
-- itself when there is no translation - so this text is what the tracker header
-- shows. It goes through format(), so keep it free of '%'.
local CATEGORY = {
    daily  = -910,
    weekly = -911,
}

l10n.questCategoryLookup[CATEGORY.daily]  = "WoW Circle - ежедневные"
l10n.questCategoryLookup[CATEGORY.weekly] = "WoW Circle - еженедельные"

QuestieCircleQuests.CATEGORY = CATEGORY

local QUEST_FLAG = {          -- QuestieDB.IsDailyQuest / IsWeeklyQuest read these
    daily  = 4096,
    weekly = 32768,
}

local SPECIAL_FLAG_REPEATABLE = 1   -- without it Questie hides the quest forever
                                    -- after the first turn-in

-- --------------------------------------------------------------- quest data --
QuestieCompat.RegisterCorrection("questData", function()
    if not QuestieCircleQuests.IsEnabled() then return {} end

    local k = QuestieDB.questKeys
    local out = {}

    for id, q in pairs(QUESTS) do
        local kind = QUEST_FLAG[q.kind] and q.kind or "daily"
        local entry = {
            [k.name]            = q.name,
            [k.requiredLevel]   = q.reqLevel or q.level or 1,
            [k.questLevel]      = q.level or -1,
            [k.requiredRaces]   = 0,        -- 0 = обе фракции
            [k.requiredClasses] = 0,
            [k.zoneOrSort]      = CATEGORY[kind],
            [k.questFlags]      = QUEST_FLAG[kind],
            [k.specialFlags]    = SPECIAL_FLAG_REPEATABLE,
        }
        if q.startedBy then
            entry[k.startedBy]  = { { q.startedBy } }
            entry[k.finishedBy] = { { q.finishedBy or q.startedBy } }
        end
        if q.objective then
            -- triggerEnd becomes an ObjectiveData entry of type "event": it needs
            -- no creature or object id, so nothing bogus ends up on the map, but
            -- Questie now has the objective slot it refuses to work without.
            -- Empty coordinate table = no icons to draw.
            entry[k.triggerEnd] = { q.objective, {} }
        end
        out[id] = entry
    end

    for kind, reminder in pairs(REMINDERS) do
        out[reminder.id] = {
            [k.name]            = reminder.name,
            [k.requiredLevel]   = reminder.level or 1,
            [k.questLevel]      = reminder.level or -1,
            [k.requiredRaces]   = 0,
            [k.requiredClasses] = 0,
            [k.zoneOrSort]      = CATEGORY[kind],
            [k.questFlags]      = QUEST_FLAG[kind],
            [k.specialFlags]    = SPECIAL_FLAG_REPEATABLE,
        }
    end

    return out
end)

-- ----------------------------------------------------------------- npc data --
QuestieCompat.RegisterCorrection("npcData", function()
    if not QuestieCircleQuests.IsEnabled() then return {} end

    local k = QuestieDB.npcKeys
    local out = {}

    -- Collect quests per NPC first: one NPC can hand out several of them.
    local starts, ends, info = {}, {}, {}
    for id, q in pairs(QUESTS) do
        if q.startedBy then
            starts[q.startedBy] = starts[q.startedBy] or {}
            table.insert(starts[q.startedBy], id)
            if q.npc then info[q.startedBy] = q.npc end

            local endNpc = q.finishedBy or q.startedBy
            ends[endNpc] = ends[endNpc] or {}
            table.insert(ends[endNpc], id)
            if q.npc and not info[endNpc] then info[endNpc] = q.npc end
        end
    end

    for npcId, npc in pairs(info) do
        local entry = {
            [k.name]              = npc.name,
            [k.minLevel]          = npc.level or 80,
            [k.maxLevel]          = npc.level or 80,
            [k.friendlyToFaction] = "AH",
        }
        if npc.zone and npc.coords then
            entry[k.spawns] = { [npc.zone] = { npc.coords } }
            entry[k.zoneID] = npc.zone
        end
        if starts[npcId] then entry[k.questStarts] = starts[npcId] end
        if ends[npcId]   then entry[k.questEnds]   = ends[npcId]   end
        out[npcId] = entry
    end

    return out
end)

-- ------------------------------------------------------ force a DB recompile --
-- Questie keeps the compiled database as a binary blob in its SavedVariables and
-- skips corrections entirely while that blob is considered current
-- (QuestieInit.lua). So whenever this quest list changes, the blob has to be
-- invalidated once, exactly the way Questie's own "Recompile Database" does it.
local function Signature()
    if not QuestieCircleQuests.IsEnabled() then return "disabled" end

    local ids = {}
    for id in pairs(QUESTS) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts = {}
    for _, id in ipairs(ids) do
        local q = QUESTS[id]
        parts[#parts + 1] = table.concat({
            id, q.kind or "", q.name or "", q.level or "",
            q.startedBy or "", q.finishedBy or "", q.objective or "",
        }, "/")
    end
    for kind, reminder in pairs(REMINDERS) do
        parts[#parts + 1] = kind .. "/" .. reminder.id .. "/" .. reminder.name
    end
    return table.concat(parts, ";")
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, addon)
    if addon ~= ADDON then return end
    self:UnregisterAllEvents()

    QuestieCircleQuestsDB = QuestieCircleQuestsDB or {}
    local signature = Signature()

    if QuestieCircleQuestsDB.signature ~= signature then
        QuestieCircleQuestsDB.signature = signature
        if Questie and Questie.db and Questie.db.global then
            Questie.db.global.dbIsCompiled = false
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff33ff99Circle quests|r: список квестов изменился, база Questie будет пересобрана.")
        end
    end
end)
