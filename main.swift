// WinCycle — перебор окон удержанием Option и нажатиями Tab, плюс подсветка
// активного окна затемнением остальных.
//
// Никакого списка на экране не рисуется. Каждое нажатие Tab сразу делает
// следующее окно активным, а видно это по затемнению всего остального.
// Отпустили Option — ничего делать не надо, нужное окно уже активно.
//
// Затемнение устроено так: поверх экрана лежит тёмная подложка, которая
// ставится сразу под активное окно. Всё, что оказалось под ней, притушено,
// активное окно поверх неё — нет. Подложка не перехватывает мышь и висит
// на всех рабочих столах.
//
// Обход идёт по кругу на экране, а не по порядку слоёв: окна сортируются по углу
// вокруг общего центра, поэтому перебор ощущается как движение по часовой стрелке
// мимо окон, а не как прыжки по невидимой истории переключений.
//
// Порядок снимается один раз, в начале перебора, и держится до отпускания Option.
// Иначе список пересортировывался бы после каждой активации, и «дальше»
// превращалось бы в скачки между двумя окнами.
//
// Свёрнутые окна пропускаются.
//
// Отдельно: новое открытое окно само встраивается в раскладку рядом с уже
// открытыми на том же экране — по схеме dwindle, как в Hyprland по
// умолчанию. Первое окно на весь экран, каждое следующее делит пополам
// ячейку последнего добавленного, направление деления — по пропорциям этой
// ячейки. Получается спираль: одно большое окно и всё мельче остальные.
// Раскладку не получают только окна в настоящем системном полноэкранном
// режиме — тот же признак и в переборе.
//
// Сочетания:
//   Option + Tab         — следующее окно по часовой стрелке
//   Option + Shift + Tab — против часовой
//
// Приватных системных вызовов не использует: порядок окон берётся из
// CGWindowListCopyWindowInfo, а сами окна сопоставляются с ним по владельцу
// и координатам через штатный Accessibility API.

import AppKit
import Carbon.HIToolbox

struct WinRef {
    let pid: pid_t
    let element: AXUIElement
    let center: CGPoint
    /// Положение в системном списке окон: 0 — самое переднее.
    let depth: Int
    let windowID: CGWindowID
    /// Окно занимает почти весь экран прямо сейчас. Не значит «намеренно
    /// максимизировано пользователем» — так же выглядит и окно, которое
    /// сама раскладка растянула, будучи единственным на экране.
    let isFullScreenNow: Bool
    /// Только для журнала.
    let owner: String
}

private enum Key {
    static let dimEnabled = "wincycle.dimEnabled"
    static let dimLevel = "wincycle.dimLevel"
    static let tilingEnabled = "wincycle.tilingEnabled"
}

private let dimSteps = [15, 25, 35, 45, 55, 70]

// Приложения, чьи окна не попадают ни в перебор, ни в раскладку, даже когда
// формально проходят все обычные проверки (обычное окно, видимое, полная
// непрозрачность). Обнаружено на живом примере: фоновое окно VPN-клиента
// Happ технически неотличимо от настоящего рабочего окна — общего признака
// для таких окон в системе нет, поэтому решаем точечным списком.
private let ignoredBundleIDs: Set<String> = [
    "su.ffg.happ"
]

// MARK: - Подложка затемнения

final class ShadeView: NSView {
    var dimAlpha: CGFloat = 0.35

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        dirtyRect.fill()
    }
}

final class Overlay: NSWindow {
    let shade = ShadeView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame, styleMask: .borderless,
            backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]

        shade.frame = NSRect(origin: .zero, size: screen.frame.size)
        shade.autoresizingMask = [.width, .height]
        contentView = shade
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(alpha: CGFloat) {
        guard shade.dimAlpha != alpha else { return }
        shade.dimAlpha = alpha
        shade.needsDisplay = true
    }
}

final class Controller: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeys: [EventHotKeyRef?] = []

    private var snapshot: [WinRef] = []
    private var index = 0
    private var cycling = false

    private var overlays: [Overlay] = []
    private var dimTimer: Timer?
    private var lastFront: CGWindowID = 0
    private var dimEnabled = true
    private var dimLevel = 35

    private var tilingEnabled = true
    private var knownWindowIDs: Set<CGWindowID> = []
    private var sawInitialWindows = false
    /// Порядок добавления окон в dwindle-раскладку, отдельно на каждый экран.
    private var tileOrder: [CGDirectDisplayID: [CGWindowID]] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Копий должно быть ровно одна: иначе на одно нажатие Tab сработали бы
        // два перехватчика и перебор прыгал бы через окно. Такое случается,
        // когда приложение поднимают и вручную, и службой автозапуска.
        let me = ProcessInfo.processInfo.processIdentifier
        let twins = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.wincycle"
        ).filter { $0.processIdentifier != me }
        if !twins.isEmpty {
            log("уже запущена другая копия — выхожу")
            NSApp.terminate(nil)
            return
        }

        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.dimEnabled: true, Key.dimLevel: 35, Key.tilingEnabled: true,
        ])
        dimEnabled = defaults.bool(forKey: Key.dimEnabled)
        dimLevel = defaults.integer(forKey: Key.dimLevel)
        tilingEnabled = defaults.bool(forKey: Key.tilingEnabled)

        log("запуск, доступ выдан: \(AXIsProcessTrusted())")
        requestAccessibility()
        buildStatusItem()
        registerHotKeys()
        watchModifiers()
        startDimming()
    }

    // MARK: затемнение

    private func startDimming() {
        rebuildOverlays()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Две независимые точки обновления: уведомление о смене активной
        // программы срабатывает мгновенно, но не ловит переключение между
        // окнами одной программы — это добирает опрос.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateDimming(force: false)
            self?.checkForNewWindows()
        }
        RunLoop.main.add(timer, forMode: .common)
        dimTimer = timer

        updateDimming(force: true)
    }

    @objc private func appActivated() { updateDimming(force: true) }

    @objc private func screensChanged() { rebuildOverlays() }

    private func rebuildOverlays() {
        for overlay in overlays { overlay.orderOut(nil) }
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
        lastFront = 0
        updateDimming(force: true)
    }

    private func hideOverlays() {
        for overlay in overlays where overlay.isVisible { overlay.orderOut(nil) }
        lastFront = 0
    }

    // Самое переднее обычное окно, не считая наших собственных подложек.
    private func frontWindowID() -> CGWindowID? {
        let mine = Set(overlays.map { CGWindowID($0.windowNumber) })
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let number = info[kCGWindowNumber as String] as? CGWindowID,
                !mine.contains(number)
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.01 {
                continue
            }
            return number
        }
        return nil
    }

    private func updateDimming(force: Bool) {
        guard dimEnabled else {
            hideOverlays()
            return
        }
        guard let front = frontWindowID() else {
            hideOverlays()
            return
        }
        // Затемнять относительно чего? Если реальное окно на экране всего
        // одно — не важно, само ли оно так открылось, растянула ли его наша
        // раскладка или пользователь развернул вручную, — сравнивать не с
        // чем, и подложка только мешала бы тёмной полосой по краям.
        guard collectWindows().count > 1 else {
            hideOverlays()
            return
        }
        let alpha = CGFloat(dimLevel) / 100
        for overlay in overlays { overlay.apply(alpha: alpha) }

        // Порядок окон трогаем только когда активное сменилось: постоянная
        // перестановка даёт мерцание.
        guard force || front != lastFront || overlays.contains(where: { !$0.isVisible })
        else { return }
        lastFront = front

        for overlay in overlays {
            overlay.orderFront(nil)
            overlay.order(.below, relativeTo: Int(front))
        }
    }

    // Журнал нужен для разбора полётов: снаружи не видно ни того, дошло ли
    // нажатие, ни того, отдала ли система список окон.
    private func log(_ text: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(text)\n"
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WinCycle.log")
        // журнал ведётся годами и никем не чистится — не даём ему разрастаться
        if let size = try? FileManager.default.attributesOfItem(atPath: path.path)[.size]
            as? Int, size > 200_000
        {
            try? FileManager.default.removeItem(at: path)
        }
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: path)
            }
        }
    }

    // MARK: разрешение

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: горячие клавиши

    private func registerHotKeys() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event = event else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                let forward = id.id == 1
                DispatchQueue.main.async { shared?.step(forward: forward) }
                return noErr
            }, 1, &spec, nil, nil)

        let signature = OSType(0x57_43_4C_31)  // 'WCL1'
        for (id, modifiers) in [
            (UInt32(1), UInt32(optionKey)),
            (UInt32(2), UInt32(optionKey | shiftKey)),
        ] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(
                UInt32(kVK_Tab), modifiers,
                EventHotKeyID(signature: signature, id: id),
                GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }

    // Отпускание Option завершает перебор: следующее нажатие начнёт новый,
    // со свежим порядком окон.
    private func watchModifiers() {
        let check: (NSEvent) -> Void = { [weak self] event in
            if !event.modifierFlags.contains(.option) { self?.cycling = false }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { check($0) }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            check($0)
            return $0
        }
    }

    // MARK: перебор

    func step(forward: Bool) {
        if !cycling {
            snapshot = orderedWindows()
            log(
                "нажатие (вперёд: \(forward)), окон в круге: \(snapshot.count)"
                    + " — \(snapshot.map(\.owner).joined(separator: ", "))")
            guard snapshot.count > 1 else { return }
            cycling = true
            // Список отсортирован по кругу, а не по давности переключений,
            // поэтому отсчёт начинаем от места, где в этом круге стоит
            // текущее активное окно — самое переднее в системном списке.
            let frontDepth = snapshot.map(\.depth).min() ?? 0
            index = snapshot.firstIndex { $0.depth == frontDepth } ?? 0
        }
        guard snapshot.count > 1 else { return }
        index = (index + (forward ? 1 : -1) + snapshot.count) % snapshot.count
        focus(snapshot[index])
    }

    private func focus(_ win: WinRef) {
        AXUIElementPerformAction(win.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            win.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: win.pid)?.activate(options: [])
        // Подложку двигаем сразу, не дожидаясь опроса, иначе на треть секунды
        // затемнённым окажется как раз то окно, на которое мы переключились.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.updateDimming(force: true)
        }
    }

    // MARK: dwindle-тайлинг новых окон
    //
    // Раскладка как в Hyprland по умолчанию (dwindle): первое окно занимает
    // весь экран. Каждое следующее делит пополам ячейку, где сейчас сидит
    // САМОЕ ПОСЛЕДНЕЕ добавленное окно — старые окна, кроме этого последнего,
    // свои места не меняют. Направление деления выбирается по пропорциям
    // самой ячейки: широкая делится вертикальной линией (получаются левая
    // и правая половины), высокая — горизонтальной (верх и низ). Из-за этого
    // получается спираль: одно большое окно и всё более мелкие рядом с ним.
    //
    // Тот же опрос раз в треть секунды, что двигает подложку затемнения,
    // заодно следит за появлением новых окон: если открылось окно, которого
    // не было на прошлом такте, оно дописывается в конец списка порядка для
    // ЕГО экрана (другие мониторы не трогаем) и вся раскладка на этом экране
    // пересчитывается по новому списку.
    //
    // Порядок нужно где-то хранить между тактами опроса — иначе непонятно,
    // какое окно «последнее» и чью ячейку делить дальше. Закрытие окна
    // (или его сворачивание, или Command+H — с точки зрения раскладки это
    // всё «пропало из отслеживаемых») точно так же пересчитывает раскладку
    // на его экране, освобождённое место сразу отдаётся соседям.
    //
    // Набор окон для тайлинга — ВСЕ подходящие окна, включая те, что сейчас
    // занимают почти весь экран. Это важно: если исключать такие окна отсюда
    // так же, как исключаем их из перебора, раскладка ломала бы сама себя —
    // единственное окно на экране dwindle сам растягивает на весь экран (это
    // и есть правильное поведение при n=1), а на следующем такте это же
    // окно перестало бы считаться «подходящим» и выпало бы из отслеживания.
    // Дальше уже ничего не с чем сравнивать: следующее открытое окно видит
    // пустой список, тайлинг не срабатывает вообще — ровно то, что и
    // случалось до этого исправления.
    //
    // Единственное окно, которое раскладка не забирает себе даже при первом
    // появлении, — то, что в настоящем системном полноэкранном режиме
    // (AXFullScreen): оно живёт на отдельном рабочем столе, и раскладке
    // там делать нечего. Всё остальное новое окно берёт в раскладку сразу,
    // независимо от того, каким размером оно открылось, — угадывать
    // «максимизировано специально» по одному текущему размеру нельзя: так
    // же выглядит и окно, которое сама раскладка растянула, будучи
    // единственным, и окно, которое приложение просто восстановило из
    // прошлой сессии в старой большой рамке.

    private func checkForNewWindows() {
        guard tilingEnabled, !cycling else { return }

        let current = collectWindows()
        let currentIDs = Set(current.map(\.windowID))
        defer { knownWindowIDs = currentIDs }

        // Первый такт после запуска — не «все окна только что открылись»,
        // а просто исходное состояние экрана. Раскладывать заново то, что
        // уже стояло на местах до запуска WinCycle, никто не просил.
        guard sawInitialWindows else {
            sawInitialWindows = true
            return
        }

        let newIDs = currentIDs.subtracting(knownWindowIDs)
        let closedIDs = knownWindowIDs.subtracting(currentIDs)
        guard !newIDs.isEmpty || !closedIDs.isEmpty else { return }
        let newOnes = current.filter { newIDs.contains($0.windowID) }

        // Экраны для пересчёта: те, где появилось новое окно, — они уже
        // известны по координатам самого окна. А вот при закрытии узнать
        // экран так не выйдет: окно уже пропало, спросить не у кого.
        // Поэтому если что-то закрылось, на всякий случай пересчитываем
        // все экраны, за которыми раскладка вообще следит, — лишний
        // холостой пересчёт дешевле, чем пропущенное схлопывание пустоты.
        var screens = Set(newOnes.compactMap { screenContaining($0.center) })
        if !closedIDs.isEmpty {
            for did in tileOrder.keys {
                if let screen = NSScreen.screens.first(where: { screenID($0) == did }) {
                    screens.insert(screen)
                }
            }
        }

        for screen in screens {
            guard let id = screenID(screen) else { continue }
            let onScreen = current.filter { screenContaining($0.center) === screen }
            let byID = Dictionary(uniqueKeysWithValues: onScreen.map { ($0.windowID, $0) })

            var order = (tileOrder[id] ?? []).filter { byID[$0] != nil }
            for win in onScreen where !order.contains(win.windowID) {
                if win.isFullScreenNow { continue }
                order.append(win.windowID)
            }
            tileOrder[id] = order

            let ordered = order.compactMap { byID[$0] }
            guard !ordered.isEmpty else { continue }
            tileWindows(ordered, on: screen)
        }
    }

    // NSScreen работает в кокоавских координатах (низ слева, экраны как
    // попало), а окна мы двигаем через Accessibility, где координаты общие
    // для всех экранов сразу и растут вниз от верхней границы главного
    // экрана. axRect переводит рамку экрана в эту же систему счисления, что
    // и мы уже делали при определении фуллскрина.
    private func axRect(for cocoaRect: CGRect) -> CGRect {
        let flipBase = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: cocoaRect.origin.x, y: flipBase - cocoaRect.origin.y - cocoaRect.height,
            width: cocoaRect.width, height: cocoaRect.height)
    }

    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { axRect(for: $0.frame).contains(point) }
    }

    // Идентификатор экрана для хранения порядка окон между тактами опроса —
    // сам NSScreen пересоздаётся при смене конфигурации мониторов, а этот
    // номер (CGDirectDisplayID) стабилен, пока экран физически не отключат.
    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    // Разбивает область на n прямоугольников по правилу dwindle: каждый
    // следующий делит пополам то, что осталось после предыдущего, — кроме
    // самого последнего, который забирает весь оставшийся остаток целиком.
    private func dwindleRects(count n: Int, in area: CGRect) -> [CGRect] {
        guard n > 0 else { return [] }
        var rects: [CGRect] = []
        var remaining = area

        for i in 0..<n {
            if i == n - 1 {
                rects.append(remaining)
                break
            }
            if remaining.width >= remaining.height {
                let half = remaining.width / 2
                rects.append(
                    CGRect(
                        x: remaining.minX, y: remaining.minY, width: half,
                        height: remaining.height))
                remaining = CGRect(
                    x: remaining.minX + half, y: remaining.minY,
                    width: remaining.width - half, height: remaining.height)
            } else {
                let half = remaining.height / 2
                rects.append(
                    CGRect(
                        x: remaining.minX, y: remaining.minY, width: remaining.width,
                        height: half))
                remaining = CGRect(
                    x: remaining.minX, y: remaining.minY + half,
                    width: remaining.width, height: remaining.height - half)
            }
        }
        return rects
    }

    // windows должен быть в порядке добавления: windows[0] — самое старое
    // окно на этом экране, оно получает первый (самый большой) кусок.
    private func tileWindows(_ windows: [WinRef], on screen: NSScreen) {
        let area = axRect(for: screen.visibleFrame)
        let rects = dwindleRects(count: windows.count, in: area)

        for (win, rect) in zip(windows, rects) {
            var pos = rect.origin
            var size = rect.size
            let posVal = AXValueCreate(.cgPoint, &pos)!
            let sizeVal = AXValueCreate(.cgSize, &size)!
            AXUIElementSetAttributeValue(win.element, kAXPositionAttribute as CFString, posVal)
            AXUIElementSetAttributeValue(win.element, kAXSizeAttribute as CFString, sizeVal)
        }
        log(
            "dwindle: \(windows.count) окон — "
                + windows.map(\.owner).joined(separator: ", "))
    }

    // MARK: список окон

    // Собирает все подходящие окна, включая те, что сейчас занимают почти
    // весь экран — этот фильтр применяется отдельно, только там, где он
    // действительно нужен (см. orderedWindows() и комментарий у тайлинга
    // выше). Порядок — спереди назад, как отдаёт CGWindowList; управлять
    // окнами умеет только Accessibility, поэтому одно сопоставляется
    // с другим по владельцу и рамке.
    private func collectWindows() -> [WinRef] {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        var found: [WinRef] = []
        var cache: [pid_t: [AXUIElement]] = [:]
        var depth = 0

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }

            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            // мелочь вроде всплывающих панелек в перебор не берём
            if frame.width < 100 || frame.height < 100 { continue }

            let windows = cache[pid] ?? axWindows(of: pid)
            cache[pid] = windows

            // Программы без своего места в Dock (значки в строке меню, подложки
            // вроде затемнения Dimsum) формально владеют окнами слоя 0, но
            // переключаться на них бессмысленно — в переборе им не место.
            guard let owner = NSRunningApplication(processIdentifier: pid),
                owner.activationPolicy == .regular
            else { continue }
            // Command+H прячет программу, но её окна остаются в системном
            // списке — просто без изображения. В перебор их брать не нужно.
            if owner.isHidden { continue }
            if let bundleID = owner.bundleIdentifier, ignoredBundleIDs.contains(bundleID) {
                continue
            }

            guard let match = windows.first(where: { close(axFrame(of: $0), frame) })
            else { continue }
            if isMinimized(match) { continue }
            // панели, всплывашки и диалоги тоже мимо: берём только обычные окна
            if !isStandardWindow(match) { continue }

            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            found.append(
                WinRef(
                    pid: pid, element: match,
                    center: CGPoint(x: frame.midX, y: frame.midY), depth: depth,
                    windowID: windowID, isFullScreenNow: isFullScreen(match, frame: frame),
                    owner: owner.localizedName ?? "?"))
            depth += 1
        }

        return found
    }

    // Список для перебора (Option+Tab): окно в настоящем системном
    // полноэкранном режиме сюда не попадает — оно живёт на отдельном
    // рабочем столе, переключаться на него через Tab всё равно не выйдет.
    private func orderedWindows() -> [WinRef] {
        sortedClockwise(collectWindows().filter { !$0.isFullScreenNow })
    }

    // Сортировка по кругу: считаем общий центр всех окон и раскладываем их
    // по углу относительно него.
    //
    // Экранные координаты растут вниз, поэтому угол у atan2 увеличивается
    // в направлении вправо → вниз → влево → вверх, то есть ровно по часовой
    // стрелке с точки зрения смотрящего. Дополнительно ничего разворачивать
    // не нужно.
    private func sortedClockwise(_ windows: [WinRef]) -> [WinRef] {
        guard windows.count > 2 else { return windows }
        let hub = CGPoint(
            x: windows.map(\.center.x).reduce(0, +) / CGFloat(windows.count),
            y: windows.map(\.center.y).reduce(0, +) / CGFloat(windows.count))
        return windows.sorted {
            atan2($0.center.y - hub.y, $0.center.x - hub.x)
                < atan2($1.center.y - hub.y, $1.center.x - hub.x)
        }
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value)
                == .success
        else { return false }
        return (value as? String) == (kAXStandardWindowSubrole as String)
    }

    // Настоящий системный полноэкранный режим — единственный надёжный
    // признак: AXFullScreen выставляет сама macOS, и подделать его нельзя.
    //
    // Раньше здесь была ещё эвристика по площади (окно, занимающее ≥85%
    // экрана, считалось «максимизировано намеренно»), но она угадывала
    // намерение по одному только текущему размеру — а различить по размеру
    // «пользователь только что растянул через Raycast» и «окно просто
    // такое большое» нельзя. На практике это ловило и то, что раскладка
    // растянула сама (ломая тайлинг после первого же окна — исправлено
    // отдельно), и то, что приложение при перезапуске восстановило из
    // прошлой сессии (например, Safari снова открылся в старой растянутой
    // рамке — и повторно не участвовал в раскладке, хотя пользователь его
    // только что открыл заново). Настоящий признак либо есть, либо его нет.
    private func isFullScreen(_ window: AXUIElement, frame: CGRect) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
            == .success && (value as? Bool) == true
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                window, kAXMinimizedAttribute as CFString, &value) == .success
        else { return false }
        return (value as? Bool) ?? false
    }

    private func axWindows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return [] }
        return windows
    }

    private func axFrame(of window: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        var value: CFTypeRef?

        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value)
            == .success, let v = value
        {
            AXValueGetValue(v as! AXValue, .cgPoint, &origin)
        }
        value = nil
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value)
            == .success, let v = value
        {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 3 && abs(a.origin.y - b.origin.y) < 3
            && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    // MARK: строка меню

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(
                systemSymbolName: "rectangle.stack", accessibilityDescription: "WinCycle")
            {
                button.image = image
            } else {
                button.title = "⧉"
            }
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        for text in [
            "Option + Tab — по часовой стрелке",
            "Option + Shift + Tab — против часовой",
        ] {
            let hint = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: "Затемнять неактивные окна", action: #selector(toggleDim),
            keyEquivalent: "")
        toggle.target = self
        toggle.state = dimEnabled ? .on : .off
        menu.addItem(toggle)

        if dimEnabled {
            let strength = NSMenuItem(title: "Сила затемнения", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for value in dimSteps {
                let item = NSMenuItem(
                    title: "\(value) %", action: #selector(setDim(_:)), keyEquivalent: "")
                item.target = self
                item.tag = value
                item.state = value == dimLevel ? .on : .off
                submenu.addItem(item)
            }
            strength.submenu = submenu
            menu.addItem(strength)
        }

        let tiling = NSMenuItem(
            title: "Вписывать новые окна в раскладку", action: #selector(toggleTiling),
            keyEquivalent: "")
        tiling.target = self
        tiling.state = tilingEnabled ? .on : .off
        menu.addItem(tiling)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleDim() {
        dimEnabled.toggle()
        UserDefaults.standard.set(dimEnabled, forKey: Key.dimEnabled)
        rebuildMenu()
        updateDimming(force: true)
    }

    @objc private func setDim(_ sender: NSMenuItem) {
        dimLevel = sender.tag
        UserDefaults.standard.set(dimLevel, forKey: Key.dimLevel)
        rebuildMenu()
        updateDimming(force: true)
    }

    @objc private func toggleTiling() {
        tilingEnabled.toggle()
        UserDefaults.standard.set(tilingEnabled, forKey: Key.tilingEnabled)
        rebuildMenu()
    }

    @objc private func quit() {
        hideOverlays()
        NSApp.terminate(nil)
    }
}

var shared: Controller?

let app = NSApplication.shared
let controller = Controller()
shared = controller
app.delegate = controller
app.run()
