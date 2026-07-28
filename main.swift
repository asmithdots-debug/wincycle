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
// Отдельно: новое открытое окно само встраивается в сетку рядом с уже
// открытыми на том же экране — остальные окна равномерно подвигаются,
// чтобы освободить ему место. Окна, растянутые почти на весь экран
// намеренно, сетка не трогает — как и в переборе.
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
    /// Только для журнала.
    let owner: String
}

private enum Key {
    static let dimEnabled = "wincycle.dimEnabled"
    static let dimLevel = "wincycle.dimLevel"
    static let tilingEnabled = "wincycle.tilingEnabled"
}

private let dimSteps = [15, 25, 35, 45, 55, 70]

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

    // MARK: сетка новых окон
    //
    // Тот же опрос раз в треть секунды, что двигает подложку затемнения,
    // заодно следит за появлением новых окон: если открылось окно, которого
    // не было на прошлом такте, все окна на ЕГО экране (другие мониторы не
    // трогаем) равномерно раскладываются заново в сетку. Порядок в сетке —
    // тот же обход по кругу, что и у Option+Tab: получается предсказуемо,
    // а не как попало.
    //
    // Набор окон для сетки — тот же orderedWindows(), что и для перебора,
    // то есть окно, растянутое почти на весь экран (например, вручную через
    // Raycast), в сетку не попадёт и останется как есть: раз его размер
    // выбрали намеренно, сетке трогать его незачем.

    private func checkForNewWindows() {
        guard tilingEnabled, !cycling else { return }

        let current = orderedWindows()
        let currentIDs = Set(current.map(\.windowID))
        defer { knownWindowIDs = currentIDs }

        // Первый такт после запуска — не «все окна только что открылись»,
        // а просто исходное состояние экрана. Раскладывать по сетке то, что
        // уже стояло на местах до запуска WinCycle, никто не просил.
        guard sawInitialWindows else {
            sawInitialWindows = true
            return
        }

        let newIDs = currentIDs.subtracting(knownWindowIDs)
        guard !newIDs.isEmpty,
            let newWindow = current.first(where: { newIDs.contains($0.windowID) }),
            let screen = screenContaining(newWindow.center)
        else { return }

        let onScreen = current.filter { screenContaining($0.center) === screen }
        guard onScreen.count > 1 else { return }
        tileWindows(onScreen, on: screen)
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

    // Равномерная сетка без пустот: количество столбцов — квадратный корень
    // из числа окон с округлением вверх, строк — сколько получится. Если
    // последняя строка неполная, её окна берут себе всю ширину поровну между
    // собой, а не оставляют пустое место с краю.
    private func tileWindows(_ windows: [WinRef], on screen: NSScreen) {
        let area = axRect(for: screen.visibleFrame)
        let n = windows.count
        let cols = Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cellHeight = area.height / CGFloat(rows)

        var i = 0
        for row in 0..<rows {
            let rowCount = min(cols, n - row * cols)
            guard rowCount > 0 else { break }
            let cellWidth = area.width / CGFloat(rowCount)

            for col in 0..<rowCount {
                var pos = CGPoint(
                    x: area.minX + CGFloat(col) * cellWidth,
                    y: area.minY + CGFloat(row) * cellHeight)
                var size = CGSize(width: cellWidth, height: cellHeight)
                let posVal = AXValueCreate(.cgPoint, &pos)!
                let sizeVal = AXValueCreate(.cgSize, &size)!
                AXUIElementSetAttributeValue(
                    windows[i].element, kAXPositionAttribute as CFString, posVal)
                AXUIElementSetAttributeValue(
                    windows[i].element, kAXSizeAttribute as CFString, sizeVal)
                i += 1
            }
        }
        log("сетка: \(n) окон, \(cols)×\(rows) — " + windows.map(\.owner).joined(separator: ", "))
    }

    // MARK: список окон

    // Порядок спереди назад даёт CGWindowList, а управлять окнами умеет только
    // Accessibility — поэтому одно сопоставляется с другим по владельцу и рамке.
    // Затем список пересортировывается по кругу.
    private func orderedWindows() -> [WinRef] {
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

            guard let match = windows.first(where: { close(axFrame(of: $0), frame) })
            else { continue }
            if isMinimized(match) { continue }
            // панели, всплывашки и диалоги тоже мимо: берём только обычные окна
            if !isStandardWindow(match) { continue }
            if isFullScreen(match, frame: frame) { continue }

            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            found.append(
                WinRef(
                    pid: pid, element: match,
                    center: CGPoint(x: frame.midX, y: frame.midY), depth: depth,
                    windowID: windowID, owner: owner.localizedName ?? "?"))
            depth += 1
        }

        return sortedClockwise(found)
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

    // Окно на весь экран пропускаем по двум независимым признакам: сама
    // macOS отмечает настоящий полноэкранный режим атрибутом AXFullScreen,
    // а окно, которое просто растянули почти на весь экран (Raycast, mpv,
    // Ghostty с fullscreen=yes), этим атрибутом не помечено.
    //
    // Для второго случая сравниваем не точный размер, а долю площади экрана:
    // Raycast с настроенным зазором в 8pt даёт не ровно 100%, а около 97–98%
    // (проверено на живом окне: Control+стрелка вверх даёт 1694×1057 при
    // видимой области экрана 1710×1073 — это 97.6%). Обычная раскладка в
    // половину или треть экрана останавливается заметно ниже порога, так что
    // 85% отделяет одно от другого с запасом.
    private func isFullScreen(_ window: AXUIElement, frame: CGRect) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
            == .success, (value as? Bool) == true
        {
            return true
        }
        let area = frame.width * frame.height
        return NSScreen.screens.contains {
            let visibleArea = $0.visibleFrame.width * $0.visibleFrame.height
            return visibleArea > 0 && area / visibleArea > 0.85
        }
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
            title: "Вписывать новые окна в сетку", action: #selector(toggleTiling),
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
