-- Shows the Circle daily/weekly challenge in Questie's tracker even while it is
-- NOT in the quest log, so you can see "this is up, go take it".
--
-- The tracker renders whatever TrackerUtils:GetSortedQuestIds() hands back, and
-- questDetails[id].zoneName is what becomes the group header - independent of
-- the quest's zoneOrSort. So we wrap that one function and append our rows to
-- its result. Everything else (fonts, layout, collapsing) stays Questie's own.

if not QuestieLoader then return end

local QuestieDB       = QuestieLoader:ImportModule("QuestieDB")
local TrackerUtils    = QuestieLoader:ImportModule("TrackerUtils")
local TrackerLinePool = QuestieLoader:ImportModule("TrackerLinePool")
local QuestieTracker  = QuestieLoader:ImportModule("QuestieTracker")

local GROUP_HEADER = "WoW Circle Ежедневное и еженедельное"

-- На аккаунт можно выполнить ОДНО задание из группы за период: одно из четырёх
-- ежедневных в день и одно из семи еженедельных в неделю. Поэтому напоминание
-- одно на группу, а не по строке на каждый квест, и один сданный квест
-- закрывает всю группу до сброса.

-- Недельный сброс на Circle: среда, 04:00. 1=Вс, 2=Пн, 3=Вт, 4=Ср, ... 7=Сб.
-- Нужен только для того, чтобы понять, когда снимать аккаунтную отметку с
-- персонажей, которые сами квест не сдавали: для сдавшего персонажа сброс
-- определяется точно, по ответу сервера.
--
-- Сам момент берётся как первое ЕЖЕдневное сбрасывание, попадающее на среду
-- (GetQuestResetTime отдаёт его по времени сервера). Это точно совпадёт с
-- 04:00, если ежедневный сброс тоже в 04:00 - проверяется через /circle.
local WEEKLY_RESET_WDAY = 4

local QUERY_THROTTLE = 60
local QUERY_INTERVAL = 300

-- ------------------------------------------------------------ server state --
-- The server's "rewarded quests" set is the only reliable source for whether a
-- repeatable quest is done this period: it survives relogs, alts and crashes.
local completed = nil       -- nil until the first successful query
local lastQuery = 0

local function Quests()
    return (QuestieCircleQuests and QuestieCircleQuests.QUESTS) or {}
end

local function Reminders()
    return (QuestieCircleQuests and QuestieCircleQuests.REMINDERS) or {}
end

local function IsEnabled()
    return not QuestieCircleQuests
        or not QuestieCircleQuests.IsEnabled
        or QuestieCircleQuests.IsEnabled()
end

local function Query(force)
    if not QueryQuestsCompleted then return end
    local now = GetTime()
    if (not force) and (now - lastQuery) < QUERY_THROTTLE then return end
    lastQuery = now
    pcall(QueryQuestsCompleted)
end

-- Один проход по журналу вместо GetQuestLogIndexByID на каждый квест: тот шим
-- сам сканирует до 75 записей, а KindState дёргается на каждом обновлении
-- трекера - на 11 квестах это тысячи вызовов API впустую.
-- На этом клиенте GetQuestLogTitle отдаёт ID квеста девятым значением.
local logIndexMap, logIndexDirty = {}, true

local function LogIndex()
    if logIndexDirty then
        local map = {}
        local count = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
        for i = 1, count do
            local _, _, _, _, isHeader, _, _, _, id = GetQuestLogTitle(i)
            if id and not isHeader then map[id] = i end
        end
        logIndexMap, logIndexDirty = map, false
    end
    return logIndexMap
end

local function InQuestLog(questId)
    return LogIndex()[questId] ~= nil
end

-- ------------------------------------------------------ per-character state --
-- Клиент видит журнал заданий ТОЛЬКО текущего персонажа - узнать чужой напрямую
-- нельзя. Поэтому каждый персонаж, пока он в игре, пишет свой срез в аккаунтные
-- SavedVariables, а остальные его читают. Срез верен на момент последнего входа
-- этим персонажем, а офлайн прогресс измениться не может.

local function Snapshots()
    QuestieCircleQuestsDB = QuestieCircleQuestsDB or {}
    QuestieCircleQuestsDB.chars = QuestieCircleQuestsDB.chars or {}
    return QuestieCircleQuestsDB.chars
end

-- "Ежедневное испытание рейда" -> "рейда"
local function ShortName(quest)
    local name = quest and quest.name or "?"
    name = name:gsub("^Ежедневное испытание ", ""):gsub("^Испытание ", "")
    return name
end

local function UpdateSnapshot()
    if not IsEnabled() then return end
    local me = UnitName("player")
    if not me then return end

    local mine = {}
    for id in pairs(Quests()) do
        local index = LogIndex()[id]
        if index then
            local _, _, _, _, _, _, isComplete = GetQuestLogTitle(index)
            local collected, needed = 0, 1
            if (GetNumQuestLeaderBoards(index) or 0) > 0 then
                local text = GetQuestLogLeaderBoard(1, index)
                local c, n = tostring(text or ""):match("(%d+)%s*/%s*(%d+)")
                collected = tonumber(c) or 0
                needed = tonumber(n) or 1
            end
            mine[id] = { c = collected, n = needed, done = (isComplete == 1) }
        end
    end

    if next(mine) then
        mine.updated = time()
        Snapshots()[me] = mine
    else
        Snapshots()[me] = nil
    end
end

-- Кто из ДРУГИХ персонажей держит задание этой группы.
local function OthersHolding(kind)
    local me = UnitName("player")
    local held = {}
    for charName, entry in pairs(Snapshots()) do
        if charName ~= me and type(entry) == "table" then
            for id, info in pairs(entry) do
                local quest = Quests()[id]
                if quest and quest.kind == kind and type(info) == "table" then
                    held[#held + 1] = {
                        char = charName,
                        desc = ShortName(quest),
                        c = info.c or 0,
                        n = info.n or 1,
                        done = info.done,
                    }
                end
            end
        end
    end
    table.sort(held, function(a, b) return a.char < b.char end)
    return held
end

-- ------------------------------------------------------ account-wide state --
-- GetQuestsCompleted() отвечает ПРО ТЕКУЩЕГО ПЕРСОНАЖА, а лимит у Circle - на
-- аккаунт. Поэтому факт сдачи дублируется в SavedVariables аддона: они лежат в
-- WTF/Account/<АККАУНТ>/, то есть общие для всех персонажей аккаунта.
--
-- Персонаж, который квест сдал, записан в отметке. Для него сервер остаётся
-- источником правды: как только он скажет "не выполнено", отметка снимается -
-- значит сброс уже произошёл. Для остальных персонажей работает срок годности.

local function AccountDone()
    QuestieCircleQuestsDB = QuestieCircleQuestsDB or {}
    QuestieCircleQuestsDB.done = QuestieCircleQuestsDB.done or {}
    return QuestieCircleQuestsDB.done
end

local function NextDailyReset()
    local seconds = GetQuestResetTime and GetQuestResetTime() or 0
    if seconds and seconds > 60 and seconds < 86400 * 2 then
        return time() + seconds     -- время сервера, а не локальные часы
    end
    return time() + 86400
end

local function NextWeeklyReset()
    local dailyReset = NextDailyReset()
    for i = 0, 7 do
        local moment = dailyReset + i * 86400
        if (tonumber(date("%w", moment)) + 1) == WEEKLY_RESET_WDAY then
            return moment
        end
    end
    return dailyReset + 7 * 86400
end

local function ResetFor(kind)
    return (kind == "weekly") and NextWeeklyReset() or NextDailyReset()
end

-- "done" | "inlog" | "available" for a whole group of quests.
local function KindState(kind)
    local inLog = false
    for id, quest in pairs(Quests()) do
        if quest.kind == kind then
            if completed and completed[id] then
                return "done"           -- сдано этим персонажем
            end
            if InQuestLog(id) then inLog = true end
        end
    end

    if inLog then return "inlog" end

    -- Задание может быть взято на другом персонаже аккаунта - тогда взять его
    -- здесь всё равно нельзя, но показать, где оно лежит, полезно.
    if #OthersHolding(kind) > 0 then return "elsewhere" end

    local record = AccountDone()[kind]
    if record then
        if record.expires and time() < record.expires then
            return "done"               -- сдано другим персонажем аккаунта
        end
        AccountDone()[kind] = nil       -- срок вышел, отметка больше не нужна
    end

    return "available"
end

-- Our DB entries carry no objective data, and Questie reads that as "this quest
-- has nothing to do, so it must be finished" - which paints the yellow turn-in
-- icon on a quest you have not even started. Take the progress from the live
-- quest log instead; that is authoritative and needs no database objectives.
local function LivePercent(questId)
    local index = LogIndex()[questId]
    if not index then return nil end

    local _, _, _, _, _, _, isComplete = GetQuestLogTitle(index)
    if isComplete == 1 then return 1 end
    if isComplete == -1 then return 0 end

    local total = GetNumQuestLeaderBoards(index) or 0
    if total == 0 then return 0 end

    local finishedCount = 0
    for i = 1, total do
        local _, _, finished = GetQuestLogLeaderBoard(i, index)
        if finished then finishedCount = finishedCount + 1 end
    end
    return finishedCount / total
end

-- Rows to inject. Only what is actually available: once a group is done for the
-- period it disappears from the tracker completely and comes back on reset.
local function RowsToShow()
    local rows = {}
    if not IsEnabled() then return rows end
    local reminders = Reminders()

    for _, kind in ipairs({ "daily", "weekly" }) do
        local reminder = reminders[kind]
        local state = reminder and KindState(kind)
        if state == "available" or state == "elsewhere" then
            rows[#rows + 1] = { id = reminder.id, kind = kind, state = state }
        end
    end

    return rows
end

local function ReminderKind(questId)
    for kind, reminder in pairs(Reminders()) do
        if reminder.id == questId then return kind end
    end
end

-- With zero real quests Questie hides the whole tracker frame, and it does not
-- know about our rows - so the "you can pick this up" line would never be seen
-- exactly when it matters most. Report that there is something to draw.
local originalHasQuest = TrackerUtils.HasQuest

TrackerUtils.HasQuest = function(...)
    if originalHasQuest(...) then return true end
    return #RowsToShow() > 0
end

-- ------------------------------------------------------------ the injection --
local originalGetSortedQuestIds = TrackerUtils.GetSortedQuestIds

TrackerUtils.GetSortedQuestIds = function(self, ...)
    local sortedQuestIds, questDetails = originalGetSortedQuestIds(self, ...)

    if (not IsEnabled())
        or type(sortedQuestIds) ~= "table" or type(questDetails) ~= "table" then
        return sortedQuestIds, questDetails
    end

    -- A stray click must never be able to hide our rows for good.
    local function keepTracked(id)
        if Questie and Questie.db and Questie.db.char and Questie.db.char.AutoUntrackedQuests then
            Questie.db.char.AutoUntrackedQuests[id] = nil
        end
    end

    -- Real quests already in the log: only correct their progress.
    for id in pairs(Quests()) do
        local details = questDetails[id]
        if details then
            local percent = LivePercent(id)
            if percent then details.questCompletePercent = percent end
        end
        keepTracked(id)
    end

    -- Inserted at the front, not appended: the tracker draws in list order, so
    -- this keeps our block above every other zone. Both rows sit next to each
    -- other, so they share one header.
    local insertAt = 1
    for _, row in ipairs(RowsToShow()) do
        keepTracked(row.id)
        if not questDetails[row.id] then
            local quest = QuestieDB.GetQuest(row.id)
            if quest then
                -- Строку цели трекер строит как "- <Description>: <Collected>/<Needed>",
                -- поэтому подставляем свои объекты - живого журнала у виртуальной
                -- записи нет и быть не может.
                local objectives = {}
                for i, held in ipairs(OthersHolding(row.kind)) do
                    objectives[i] = {
                        Index       = i,
                        questId     = row.id,
                        Description = held.char .. " - " .. held.desc
                                      .. (held.done and ", готово к сдаче" or ""),
                        Collected   = held.c,
                        Needed      = held.n,
                        Completed   = false,
                        Update      = function() end,
                    }
                end
                quest.Objectives = objectives

                table.insert(sortedQuestIds, insertAt, row.id)
                insertAt = insertAt + 1
                questDetails[row.id] = {
                    quest = quest,
                    zoneName = GROUP_HEADER,
                    questCompletePercent = 0,
                }
            end
        end
    end

    return sortedQuestIds, questDetails
end

-- ============================================================================
--  Взятие задания через игровое меню (.menu -> Особые задания -> раздел)
-- ============================================================================
-- Квесты Circle выдаёт не NPC, а серверное меню по чат-команде. Сервер отвечает
-- обычным gossip-окном, а выбор пункта в нём - это открытый API, разрешённый
-- аддонам. Официальный аддон сервера WCollections точно так же шлёт ".cooldown".
--
-- Срабатывает ТОЛЬКО по явному действию игрока (клик по строке или /circle take)
-- и живёт 8 секунд, чтобы не перехватить обычный разговор с NPC.
--
-- Аддон доводит до списка заданий и останавливается: в разделе несколько
-- квестов, и какой брать - решает игрок.

local MENU_COMMAND = ".menu"

-- Пункты ищутся по тексту, а не по номеру, чтобы новый раздел в меню ничего
-- не сломал. "Ежедневные" и "Еженедельные" не являются подстроками друг друга,
-- так что совпадение однозначное.
local MENU_PATH = {
    daily  = { "Особые задания", "Ежедневные испытания" },
    weekly = { "Особые задания", "Еженедельные испытания" },
}

local pendingMenu = nil

local function Norm(text)
    return (tostring(text or ""):lower():gsub("%s+", " "))
end

local function FindOption(needle)
    local count = GetNumGossipOptions and GetNumGossipOptions() or 0
    if count == 0 then return nil end
    local options = { GetGossipOptions() }
    needle = Norm(needle)
    for i = 1, count do
        local text = options[(i - 1) * 2 + 1]
        if text and Norm(text):find(needle, 1, true) then
            return i
        end
    end
end

-- Документация клиента обрезает список возвратов GetGossipActiveQuests, поэтому
-- шаг массива не берём на веру, а выводим из числа квестов.
local function FindActiveQuest(questName)
    if not (GetGossipActiveQuests and GetNumGossipActiveQuests) then return nil end
    local count = GetNumGossipActiveQuests() or 0
    if count == 0 then return nil end

    local list = { GetGossipActiveQuests() }
    local stride = math.floor(#list / count)
    if stride < 1 then return nil end

    questName = Norm(questName)
    for i = 1, count do
        local name = list[(i - 1) * stride + 1]
        if name and Norm(name):find(questName, 1, true) then
            return i
        end
    end
end

-- questName задаётся, когда надо не просто открыть раздел, а сразу открыть
-- окно сдачи конкретного задания.
local function OpenCircleMenu(kind, questName)
    if not SendChatMessage then return end
    pendingMenu = { kind = kind, step = 1, questName = questName, expires = GetTime() + 8 }
    SendChatMessage(MENU_COMMAND, "SAY")
end

local function HandleGossip()
    if not pendingMenu then return end
    if GetTime() > pendingMenu.expires then
        pendingMenu = nil
        return
    end

    local path = MENU_PATH[pendingMenu.kind] or MENU_PATH.daily
    local step = path[pendingMenu.step]

    if step then
        local index = FindOption(step)
        if index then
            pendingMenu.step = pendingMenu.step + 1
            pendingMenu.expires = GetTime() + 8
            SelectGossipOption(index)
            return
        end
    end

    -- Раздел открыт. Если шли за конкретным заданием - открываем окно сдачи.
    local questName = pendingMenu.questName
    pendingMenu = nil

    if questName then
        local index = FindActiveQuest(questName)
        if index then
            SelectGossipActiveQuest(index)
            return
        end
    end
    -- Не нашли: окно просто остаётся открытым.
end

-- --------------------------------------------------------------- the click --
-- Questie's own handler assumes the quest is in the log: it calls ShowQuestLog,
-- which falls through to UntrackQuestId when GetQuestLogIndexByID returns nil -
-- so the row would silently delete itself. Handle our own rows instead.
local originalOnClickQuest = TrackerLinePool.OnClickQuest

TrackerLinePool.OnClickQuest = function(self, button)
    if not IsEnabled() then return originalOnClickQuest(self, button) end

    local quest = self and self.Quest
    local id = quest and quest.Id
    local kind = id and ReminderKind(id)

    -- Настоящее задание Circle в журнале: левый клик ведёт к сдаче, а не в
    -- журнал заданий - у этих квестов нет NPC, сдаются они через меню.
    -- Правый клик отдаём Questie, чтобы её меню строки осталось на месте.
    local circleQuest = id and Quests()[id]
    if circleQuest and button ~= "RightButton" and InQuestLog(id) then
        local complete = (LivePercent(id) or 0) >= 1
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Circle|r: "
            .. (complete and "открываю окно сдачи..." or "открываю раздел заданий..."))
        OpenCircleMenu(circleQuest.kind, complete and circleQuest.name or nil)
        return
    end

    if kind then
        if button == "RightButton" then return end

        local label = (kind == "daily") and "ежедневное" or "еженедельное"
        if KindState(kind) == "done" then
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Circle|r: " .. label
                .. " задание уже выполнено в этом периоде.")
            return
        end

        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Circle|r: открываю раздел заданий...")
        OpenCircleMenu(kind)
        return
    end

    return originalOnClickQuest(self, button)
end

-- ---------------------------------------------------------------- refresh --
local function RefreshTracker()
    if InCombatLockdown() then return end
    if QuestieTracker and type(QuestieTracker.Update) == "function" then
        pcall(QuestieTracker.Update, QuestieTracker)
    end
end

-- ------------------------------------------------------ сдача без сервера --
-- Ядра TrinityCore не кладут ежедневные задания в список награждённых квестов
-- (еженедельные - кладут). Значит для дейликов GetQuestsCompleted молчит всегда,
-- и опираться только на него нельзя. Ловим момент, когда игрок реально забирает
-- награду: GetQuestReward - единственный надёжный сигнал сдачи на 3.3.5a.
local pendingTurnIn = nil

local function NoteTurnIn(questTitle)
    if not questTitle or not IsEnabled() then return end

    local title = Norm(questTitle)
    for id, quest in pairs(Quests()) do
        if quest.name and Norm(quest.name) == title then
            local me = UnitName("player")
            AccountDone()[quest.kind] = {
                expires = ResetFor(quest.kind),
                by      = me,
                questId = id,
                srv     = false,        -- замечено нами, сервер может молчать
            }
            RefreshTracker()
            return
        end
    end
end

hooksecurefunc("GetQuestReward", function()
    if pendingTurnIn then
        NoteTurnIn(pendingTurnIn)
        pendingTurnIn = nil
    end
end)

-- ------------------------------------------------------ галочка в Questie --
-- Questie собирает вкладку Tracker через QuestieOptions.tabs.tracker:Initialize()
-- и отдаёт таблицу опций. Оборачиваем её и дописываем свой пункт - файлы Questie
-- при этом не трогаются.
local function SetEnabled(value)
    QuestieCircleQuestsDB = QuestieCircleQuestsDB or {}
    QuestieCircleQuestsDB.disabled = (not value) or nil

    -- Строки трекера и перехват кликов гаснут сразу. А вот задания живут в
    -- скомпилированной базе Questie - убрать или вернуть их можно только
    -- пересборкой, а она идёт при загрузке. Поэтому просто помечаем базу и
    -- ждём, пока игрок сам перезагрузит интерфейс.
    if Questie and Questie.db and Questie.db.global then
        Questie.db.global.dbIsCompiled = false
    end

    RefreshTracker()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Circle|r: задания "
        .. (value and "включены" or "выключены")
        .. ". Для базы Questie нужен |cffffff00/reload|r.")
end

local QuestieOptions = QuestieLoader:ImportModule("QuestieOptions")
local trackerTab = QuestieOptions and QuestieOptions.tabs and QuestieOptions.tabs.tracker

if trackerTab and type(trackerTab.Initialize) == "function" then
    local originalInitialize = trackerTab.Initialize

    trackerTab.Initialize = function(self, ...)
        local options = originalInitialize(self, ...)

        if type(options) == "table" and type(options.args) == "table" then
            options.args.circleQuestsHeader = {
                type = "header",
                order = 20,
                name = "WoW Circle",
            }
            options.args.circleQuestsEnabled = {
                type = "toggle",
                order = 21,
                width = "full",
                name = "Ежедневные и еженедельные задания Circle",
                desc = "Строка-напоминание в трекере, отметка о выполнении на весь "
                    .. "аккаунт и открытие меню по клику. Выключение убирает всё разом, "
                    .. "включая записи в базе Questie - для этого нужен /reload.",
                get = function() return IsEnabled() end,
                set = function(_, value) SetEnabled(value) end,
            }
        end

        return options
    end
end

local ev = CreateFrame("Frame")
local queryDelay, pollTimer = nil, 0

ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("QUEST_QUERY_COMPLETE")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("QUEST_FINISHED")
ev:RegisterEvent("GOSSIP_SHOW")
ev:RegisterEvent("QUEST_COMPLETE")

ev:SetScript("OnEvent", function(_, event)
    if event == "GOSSIP_SHOW" then
        HandleGossip()

    elseif event == "PLAYER_ENTERING_WORLD" then
        queryDelay = 5
        logIndexDirty = true
        UpdateSnapshot()

    elseif event == "QUEST_QUERY_COMPLETE" then
        if not GetQuestsCompleted then return end
        local t = {}
        local ok, r = pcall(GetQuestsCompleted, t)
        if not ok then return end
        if type(r) == "table" then t = r end

        local changed = false
        for id in pairs(Quests()) do
            local was = completed and completed[id] or false
            if was ~= (t[id] or false) then changed = true end
        end
        completed = t

        -- Синхронизируем аккаунтную отметку с тем, что сказал сервер.
        local me = UnitName("player")
        local done = AccountDone()
        for _, kind in ipairs({ "daily", "weekly" }) do
            local finishedId
            for id, quest in pairs(Quests()) do
                if quest.kind == kind and t[id] then finishedId = id break end
            end

            local record = done[kind]
            if finishedId then
                if (not record) or record.questId ~= finishedId or record.by ~= me then
                    changed = true
                end
                done[kind] = {
                    expires  = ResetFor(kind),
                    by       = me,
                    questId  = finishedId,
                    srv      = true,        -- подтверждено сервером
                }
            elseif record and record.srv and record.by == me then
                -- Сервер по тому же персонажу, что и ставил отметку, говорит
                -- "не выполнено" - значит сброс прошёл. Отметки, поставленные
                -- по факту сдачи вручную, так снимать нельзя: сервер про них
                -- вообще молчит, и мы бы стирали их сразу же.
                done[kind] = nil
                changed = true
            end
        end

        if changed then RefreshTracker() end

    elseif event == "QUEST_COMPLETE" then
        pendingTurnIn = GetTitleText and GetTitleText() or nil

    elseif event == "QUEST_FINISHED" then
        queryDelay = 3

    elseif event == "QUEST_LOG_UPDATE" then
        logIndexDirty = true
        UpdateSnapshot()
        Query()
    end
end)

ev:SetScript("OnUpdate", function(_, elapsed)
    if queryDelay then
        queryDelay = queryDelay - elapsed
        if queryDelay <= 0 then
            queryDelay = nil
            Query(true)
        end
    end

    pollTimer = pollTimer + elapsed
    if pollTimer >= QUERY_INTERVAL then
        pollTimer = 0
        Query()
    end
end)

-- ------------------------------------------------------------ diagnostics --
SLASH_CIRCLEQUESTS1 = "/circle"
SlashCmdList["CIRCLEQUESTS"] = function(msg)
    local function say(m) DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Circle|r: " .. m) end

    local arg = strlower(strtrim(msg or ""))

    if not IsEnabled() then
        say("|cffff8080выключено|r в настройках Questie, вкладка Tracker")
        return
    end

    if arg == "daily" or arg == "weekly" then
        say("открываю раздел заданий...")
        OpenCircleMenu(arg)
        return
    end

    if arg == "take" then
        for _, kind in ipairs({ "daily", "weekly" }) do
            if KindState(kind) == "available" then
                say("открываю раздел заданий...")
                OpenCircleMenu(kind)
                return
            end
        end
        say("нечего брать - всё либо в журнале, либо уже выполнено")
        return
    end

    if not completed then
        say("|cffff8080ответа сервера ещё нет|r, запрос отправлен - повтори через пару секунд")
        Query(true)
    end

    for _, kind in ipairs({ "daily", "weekly" }) do
        local state = KindState(kind)
        local label = (kind == "daily") and "Ежедневные" or "Еженедельные"
        local text = (state == "done" and "|cff888888выполнено в этом периоде|r")
                  or (state == "inlog" and "|cffffff00взято этим персонажем|r")
                  or (state == "elsewhere" and "|cffffff00взято на другом персонаже|r")
                  or "|cff00ff00можно взять|r"
        say(label .. ": " .. text)

        local record = AccountDone()[kind]
        if record and record.expires and record.expires > time() then
            local left = (record.expires or 0) - time()
            local hours = math.floor(left / 3600)
            say(("   отметка аккаунта: сдал %s (%s), сброс через %dч %02dм"):format(
                tostring(record.by),
                record.srv and "подтверждено сервером" or "замечено при сдаче",
                hours, math.floor((left % 3600) / 60)))
        end

        for _, held in ipairs(OthersHolding(kind)) do
            say(("   |cffffff00%s|r - %s: %d/%d%s"):format(
                held.char, held.desc, held.c, held.n,
                held.done and " |cff6fdc9a(готово к сдаче)|r" or ""))
        end

        for id, quest in pairs(Quests()) do
            if quest.kind == kind then
                local mark
                if completed and completed[id] then
                    mark = "|cff888888выполнен|r"
                elseif InQuestLog(id) then
                    mark = "|cffffff00в журнале|r"
                else
                    mark = "-"
                end
                say(("   %d  %s  %s"):format(id, quest.name or "?", mark))
            end
        end
    end

    say(("сброс: ежедневный %s, недельный %s"):format(
        date("%d.%m %H:%M", NextDailyReset()),
        date("%d.%m %H:%M", NextWeeklyReset())))
    say("команды: |cff00ff00/circle take|r, |cff00ff00/circle daily|r, |cff00ff00/circle weekly|r")
end
