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
// открытыми на том же экране — настоящим деревом разбиений, как в i3/bspwm
// и в dwindle-режиме Hyprland. Первое окно на весь экран, каждое следующее
// по умолчанию делит пополам ячейку АКТИВНОГО окна (совпадает с Hyprland:
// новое окно появляется рядом с тем, с чем человек как раз работает), а не
// произвольной последней ячейки. Направление деления — по пропорциям самой
// ячейки. Ячеек не больше пяти: окна сверх лимита складываются стопкой
// в самую мелкую ячейку, сверху — окно, и так впереди по системному
// z-порядку, до остальных можно добраться перебором Option+Tab.
// Между окнами и по краю экрана — зазор 8pt, такой же, как у Raycast Window
// Management. Раскладку не получают окна в настоящем системном
// полноэкранном режиме (тот же признак и в переборе) и окна, которым нельзя
// менять размер, — настройки системы, окна настроек программ по Command+,
// и подобные диалоги: их вместо этого ставит по центру экрана поверх
// остальных.
//
// Ручное вмешательство в отслеживаемое окно раскладка тоже подхватывает.
// Растянули почти на весь экран (Raycast, перетаскиванием и так далее) —
// временно отпускает его, остальные окна на этом экране пересчитываются на
// освободившееся место; вернули обычный размер — окно само возвращается.
// Переставили окно клавишами в чужую ячейку — окно вынимается из своего
// листа (сосед по дереву получает освободившееся место целиком) и ячейка
// цели делится заново: окно занимает половину, прежний хозяин — другую.
// Остальных ячеек, к перестановке отношения не имевших, это не касается.
//
// Сочетания:
//   Option + Tab                 — следующее окно по часовой стрелке
//   Option + Shift + Tab         — против часовой
//   Option + Command + Tab       — поменять активное окно местами со
//                                   следующим по тому же кругу
//   Option + Command + Shift + Tab — с предыдущим
//
// Приватных системных вызовов не использует: порядок окон берётся из
// CGWindowListCopyWindowInfo, а сами окна сопоставляются с ним по владельцу
// и координатам через штатный Accessibility API.

import AppKit
import Carbon.HIToolbox

struct WinRef {
    let pid: pid_t
    let element: AXUIElement
    let frame: CGRect
    let center: CGPoint
    /// Положение в системном списке окон: 0 — самое переднее.
    let depth: Int
    let windowID: CGWindowID
    /// Настоящий системный полноэкранный режим (AXFullScreen).
    let isFullScreenNow: Bool
    /// Окну вообще можно менять размер. Настройки системы, окна настроек
    /// программ по Command+, и подобные диалоги размер менять не дают —
    /// раскладке их трогать нельзя.
    let isResizable: Bool
    /// Только для журнала.
    let owner: String
}

// Дерево разбиений: узел либо лист (одно окно, а при переполнении сверх
// maxTiles — несколько на одном месте, стопкой), либо разрез на две области.
// Направление разреза (vertical: true — вертикальная черта, лево/право;
// false — горизонтальная, верх/низ) решается один раз, в момент деления,
// и дальше не пересматривается. Подробный разбор — в DESIGN.md и в
// комментарии перед MARK: тайлинг ниже.
private final class TileNode {
    enum Content {
        case leaf([CGWindowID])
        case split(vertical: Bool, TileNode, TileNode)
    }
    var content: Content
    init(_ content: Content) { self.content = content }
}

private enum Key {
    static let dimEnabled = "wincycle.dimEnabled"
    static let dimLevel = "wincycle.dimLevel"
    static let tilingEnabled = "wincycle.tilingEnabled"
}

private let dimSteps = [15, 25, 35, 45, 55, 70]

// Зазор между окнами и между окном и краем экрана — тот же, что даёт Raycast
// Window Management при Control+стрелка вверх (измерено вживую: маленькая
// область показывает выигрыш в отступе именно 8pt со всех сторон).
private let tileGap: CGFloat = 8

// Сколько ячеек раскладка делает максимум. Дальше делить бессмысленно:
// на экране ноутбука шестая ячейка уже уже трёхсот точек, читать в ней
// нечего. Всё, что сверх, уходит стопкой в последнюю ячейку.
private let maxTiles = 5

// Сколько ждать, пока программа применит поставленную ей рамку, прежде чем
// считать расхождение ручным вмешательством.
private let settleTime: TimeInterval = 1.0

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
    /// Дерево разбиений на каждом экране — см. TileNode выше.
    private var trees: [CGDirectDisplayID: TileNode] = [:]
    /// Рамка, которую раскладка сама поставила каждому отслеживаемому окну —
    /// нужна, чтобы отличить «это раскладка его так растянула» от «кто-то
    /// подвинул или растянул окно сам, пока мы не смотрели».
    private var lastAppliedFrame: [CGWindowID: CGRect] = [:]
    /// Когда раскладка последний раз ставила окну рамку. Пока с этого момента
    /// не прошло settleTime, расхождение считается неуспевшим применением,
    /// а не ручным вмешательством — см. watchManualResize.
    private var appliedAt: [CGWindowID: Date] = [:]
    /// Окна, которые вручную растянули почти на весь экран (например, через
    /// Raycast) — временно выведены из раскладки, отдельно на каждый экран.
    /// Возвращаются обратно, как только перестают быть почти во весь экран.
    private var floated: [CGDirectDisplayID: Set<CGWindowID>] = [:]
    /// Окна с фиксированным размером, которые раскладка уже поставила по
    /// центру. Повторно не трогаем: пользователь мог отодвинуть окно сам.
    private var centered: Set<CGWindowID> = []
    /// Переднее окно на конец ПРОШЛОГО такта — то, что было активно до
    /// появления нового окна. К моменту, когда опрос вообще замечает новое
    /// окно, оно почти всегда уже само стало передним (открытие документа
    /// само крадёт фокус) — свежий front на этом такте показал бы само новое
    /// окно, а не то, где человек работал секунду назад. Используется только
    /// для выбора цели вставки нового окна, не для затемнения.
    private var lastObservedFrontID: CGWindowID?

    // MARK: кэши снимка окон
    //
    // Все решения приложения выводятся из системного списка окон: какие окна
    // есть, чьи они и где стоят. Пока этот список не изменился, ни одно
    // решение измениться не может — значит и пересобирать снимок незачем.
    // Опрос идёт три с лишним раза в секунду, а экран почти всё время стоит
    // без движения, так что подавляющее большинство тактов заканчивается
    // сравнением списка с прошлым и выходом.
    //
    // Заголовок окна в признак не входит намеренно: у терминала в заголовке
    // крутится значок ожидания, и признак менялся бы каждый такт, сводя весь
    // выигрыш на нет.
    private struct WindowKey: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect
    }
    /// Неизменяемые за время жизни окна свойства — спрашиваются один раз.
    private struct WindowTraits {
        let standard: Bool
        let resizable: Bool
    }
    private var lastKeys: [WindowKey] = []
    private var snapshotCache: [WinRef] = []
    /// Сопоставление окна из системного списка с элементом Accessibility.
    /// Оно постоянно на всё время жизни окна, а стоит дорого — по запросу
    /// рамки и заголовка на каждого кандидата.
    private var elementFor: [CGWindowID: AXUIElement] = [:]
    private var traitsFor: [CGWindowID: WindowTraits] = [:]
    /// Окна, пропавшие из снимка ровно на прошлом такте. Закрытыми считаем
    /// только те, что не вернулись и на следующем — см. checkForNewWindows.
    private var missingOnce: Set<CGWindowID> = []

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
            guard let self else { return }
            // Страховка: признак «идёт перебор» гасится по событию отпускания
            // Option, а событие можно и не получить — например, если Option
            // отпустили в момент, когда система не доставила нам flagsChanged.
            // Тогда признак остался бы взведённым навсегда, а вместе с ним
            // намертво замерла бы вся раскладка: и появление новых окон,
            // и слежение за ручными перестановками пропускают такт, пока
            // идёт перебор. Поэтому сверяемся с фактическим состоянием
            // клавиш — во время настоящего перебора Option зажат, и признак
            // остаётся на месте.
            if self.cycling, !NSEvent.modifierFlags.contains(.option) { self.cycling = false }
            // Системный список окон запрашивается один раз на такт, и снимок
            // по нему строится тоже один — им пользуются все три задачи.
            // Раньше затемнение собирало снимок отдельно, так что вся работа
            // с Accessibility делалась дважды за каждый такт.
            let list = self.windowList()
            let current = self.collectWindows(from: list)
            let front = self.frontWindowID(in: list)
            let previousFront = self.lastObservedFrontID
            self.updateDimming(list: list, windows: current, force: false)
            self.checkForNewWindows(current: current, frontID: previousFront)
            self.watchManualResize(current: current, frontID: front)
            if let front { self.lastObservedFrontID = front }
        }
        RunLoop.main.add(timer, forMode: .common)
        dimTimer = timer

        refreshDimming(force: true)
    }

    @objc private func appActivated() { refreshDimming(force: true) }

    @objc private func screensChanged() { rebuildOverlays() }

    private func rebuildOverlays() {
        for overlay in overlays { overlay.orderOut(nil) }
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
        lastFront = 0
        refreshDimming(force: true)
    }

    private func hideOverlays() {
        for overlay in overlays where overlay.isVisible { overlay.orderOut(nil) }
        lastFront = 0
    }

    // Самое переднее обычное окно, не считая наших собственных подложек.
    private func frontWindowID(in list: [[String: Any]]) -> CGWindowID? {
        let mine = Set(overlays.map { CGWindowID($0.windowNumber) })
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

    /// Точка входа для тех, у кого своего снимка нет (уведомления системы).
    private func refreshDimming(force: Bool) {
        let list = windowList()
        updateDimming(list: list, windows: collectWindows(from: list), force: force)
    }

    private func updateDimming(list: [[String: Any]], windows: [WinRef], force: Bool) {
        guard dimEnabled else {
            hideOverlays()
            return
        }
        guard let front = frontWindowID(in: list) else {
            hideOverlays()
            return
        }
        // Затемнять относительно чего? Если реальное окно на экране всего
        // одно — не важно, само ли оно так открылось, растянула ли его наша
        // раскладка или пользователь развернул вручную, — сравнивать не с
        // чем, и подложка только мешала бы тёмной полосой по краям.
        guard windows.count > 1 else {
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
                switch id.id {
                case 1: DispatchQueue.main.async { shared?.step(forward: true) }
                case 2: DispatchQueue.main.async { shared?.step(forward: false) }
                case 3: DispatchQueue.main.async { shared?.swap(forward: true) }
                case 4: DispatchQueue.main.async { shared?.swap(forward: false) }
                default: break
                }
                return noErr
            }, 1, &spec, nil, nil)

        let signature = OSType(0x57_43_4C_31)  // 'WCL1'
        for (id, modifiers) in [
            (UInt32(1), UInt32(optionKey)),
            (UInt32(2), UInt32(optionKey | shiftKey)),
            (UInt32(3), UInt32(optionKey | cmdKey)),
            (UInt32(4), UInt32(optionKey | cmdKey | shiftKey)),
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
            self.refreshDimming(force: true)
        }
    }

    // MARK: перестановка местами по клавишам
    //
    // Option+Command+Tab — активное окно меняется местами со следующим по
    // тому же кругу, что и обычный перебор (Option+Tab); Shift — с
    // предыдущим. С двумя окнами оба направления дают один и тот же
    // результат — переставляют их местами.
    //
    // Это настоящий обмен (в отличие от перестановки, распознанной по
    // перекрытию рамок — см. раздел 6 в DESIGN.md, там это специально НЕ
    // обмен, а каскад): здесь пользователь явно просит поменять местами
    // ровно эти два окна, и «поменять местами» означает именно это —
    // каждое занимает рамку другого целиком, соседей по дереву не касается.
    // Меняются местами только сами окна, а не весь список их соседей по
    // ячейке: если одно из них стоит в стопке, туда, куда оно стояло,
    // встаёт другое, а остальные окна той же стопки остаются на месте.
    func swap(forward: Bool) {
        let list = orderedWindows()
        guard list.count > 1,
            let frontID = frontWindowID(in: windowList()),
            let activeIndex = list.firstIndex(where: { $0.windowID == frontID })
        else { return }
        let targetIndex = (activeIndex + (forward ? 1 : -1) + list.count) % list.count
        let target = list[targetIndex]
        guard target.windowID != frontID else { return }
        swapWindows(frontID, target.windowID)
    }

    private func findLeafAcrossScreens(_ id: CGWindowID) -> (CGDirectDisplayID, TileNode)? {
        for (did, tree) in trees {
            if let leaf = findLeaf(tree, containing: id) { return (did, leaf) }
        }
        return nil
    }

    private func swapWindows(_ a: CGWindowID, _ b: CGWindowID) {
        guard let (didA, leafA) = findLeafAcrossScreens(a),
            let (didB, leafB) = findLeafAcrossScreens(b),
            leafA !== leafB,
            case .leaf(var idsA) = leafA.content, case .leaf(var idsB) = leafB.content,
            let ia = idsA.firstIndex(of: a), let ib = idsB.firstIndex(of: b)
        else { return }

        idsA[ia] = b
        idsB[ib] = a
        leafA.content = .leaf(idsA)
        leafB.content = .leaf(idsB)

        let current = collectWindows(from: windowList())
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.windowID, $0) })
        for did in Set([didA, didB]) {
            guard let tree = trees[did],
                let screen = NSScreen.screens.first(where: { screenID($0) == did })
            else { continue }
            let area = axRect(for: screen.visibleFrame).insetBy(dx: tileGap, dy: tileGap)
            let onScreenByID = Dictionary(
                uniqueKeysWithValues: current.filter { screenContaining($0.center) === screen }
                    .map { ($0.windowID, $0) })
            applyTree(tree, area: area, byID: onScreenByID)
        }
        // Клавиатурный фокус остаётся за тем же окном, которое было
        // активно, — просто на новом месте.
        if let win = byID[a] { focus(win) }
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

    private func checkForNewWindows(current: [WinRef], frontID: CGWindowID?) {
        guard tilingEnabled, !cycling else { return }

        let currentIDs = Set(current.map(\.windowID))

        // Окно, пропавшее ровно на один такт, закрытым не считаем. Пока
        // Raycast переставляет окно, системный список и Accessibility на
        // мгновение расходятся: один уже показывает новое место, другой ещё
        // старое, сопоставить их не удаётся и окно исчезает из снимка. Если
        // верить этому сразу, раскладка на треть секунды схлопывается по
        // числу оставшихся окон и тут же разворачивается обратно — видно как
        // рывок соседних окон туда-обратно. Ждём подтверждения на следующем
        // такте: настоящее закрытие никуда не денется, а мигание пройдёт.
        let vanished = knownWindowIDs.subtracting(currentIDs)
        let closedIDs = vanished.intersection(missingOnce)
        let stillPending = vanished.subtracting(closedIDs)
        missingOnce = stillPending
        defer { knownWindowIDs = currentIDs.union(stillPending) }

        // Первый такт после запуска — не «все окна только что открылись»,
        // а просто исходное состояние экрана. Раскладывать заново то, что
        // уже стояло на местах до запуска WinCycle, никто не просил, — но
        // взять эти окна под наблюдение нужно обязательно. Иначе выходит
        // так: раскладка знает только окна, открытые ПОСЛЕ её запуска, и
        // всё, что стояло на экране раньше, для неё не существует. Переставь
        // такое окно клавишами — и ничего не произойдёт, оно просто ляжет
        // поверх соседа. Особенно заметно после каждой пересборки: список
        // живёт только в памяти, перезапуск обнуляет его, и до первого
        // открытия или закрытия окна раскладка выглядит сломанной.
        //
        // Поэтому запоминаем окна как есть: порядок — по текущему положению
        // в системном списке, а «своей» рамкой для каждого объявляем ту, где
        // окно и так стоит. Двигать ничего не надо, вида экрана это не
        // меняет, зато следующая же перестановка или новое окно пересчитают
        // всё уже с ними.
        guard sawInitialWindows else {
            sawInitialWindows = true
            var byScreen: [CGDirectDisplayID: [WinRef]] = [:]
            for win in current {
                guard win.isResizable, !win.isFullScreenNow,
                    let screen = screenContaining(win.center), let did = screenID(screen)
                else { continue }
                byScreen[did, default: []].append(win)
            }
            for (did, wins) in byScreen {
                guard let screen = NSScreen.screens.first(where: { screenID($0) == did })
                else { continue }
                let area = axRect(for: screen.visibleFrame).insetBy(dx: tileGap, dy: tileGap)

                // Порядок восстанавливаем по геометрии, а не по слоям. В
                // спирали каждая следующая ячейка не больше предыдущей, так
                // что «от большего к меньшему» воспроизводит исходный порядок
                // раскладки, если она на экране уже была (а после каждой
                // пересборки она именно там и есть). Равные по площади —
                // последняя пара ячеек и окна одной стопки; их разводим по
                // положению, сверху вниз и слева направо.
                //
                // Брать порядок из системного списка окон нельзя: он идёт по
                // слоям и меняется от любого переключения. Записанный так
                // порядок не соответствовал реальным ячейкам, и первый же
                // пересчёт перекладывал всю раскладку заново.
                let ordered = wins.sorted {
                    let areaA = $0.frame.width * $0.frame.height
                    let areaB = $1.frame.width * $1.frame.height
                    if areaA != areaB { return areaA > areaB }
                    if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
                    if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
                    return $0.windowID < $1.windowID
                }

                // Дерево строится тем же способом, что и обычный рост (см.
                // insertNew), но реальные рамки окон не трогаем — окна и так
                // стоят там, где стоят, просто теперь под наблюдением.
                var tree: TileNode?
                for win in ordered {
                    insertNew(win.windowID, into: &tree, area: area, preferredTarget: nil)
                    lastAppliedFrame[win.windowID] = win.frame
                }
                trees[did] = tree
            }
            return
        }

        let newIDs = currentIDs.subtracting(knownWindowIDs)
        centered.formIntersection(currentIDs)
        guard !newIDs.isEmpty || !closedIDs.isEmpty else { return }
        let newOnes = current.filter { newIDs.contains($0.windowID) }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.windowID, $0) })

        // Окна с фиксированным размером в раскладку не берём — их всё равно
        // не растянуть под ячейку. Вместо этого ставим по центру экрана
        // поверх остальных: так их видно целиком и не приходится искать.
        for win in newOnes where !win.isResizable {
            centerOnTop(win)
        }

        for closedID in closedIDs {
            for did in trees.keys {
                trees[did] = trees[did].flatMap { removing(closedID, from: $0) }
            }
        }

        // Экраны для пересчёта: те, где появилось новое окно, — они уже
        // известны по координатам самого окна. А вот при закрытии узнать
        // экран так не выйдет: окно уже пропало, спросить не у кого.
        // Поэтому если что-то закрылось, на всякий случай пересчитываем
        // все экраны, за которыми раскладка вообще следит, — лишний
        // холостой пересчёт дешевле, чем пропущенное схлопывание пустоты.
        var screens = Set(newOnes.compactMap { screenContaining($0.center) })
        if !closedIDs.isEmpty {
            for win in current {
                if let screen = screenContaining(win.center) { screens.insert(screen) }
            }
            for did in trees.keys {
                if let screen = NSScreen.screens.first(where: { screenID($0) == did }) {
                    screens.insert(screen)
                }
            }
        }

        for screen in screens {
            guard let id = screenID(screen) else { continue }
            let area = axRect(for: screen.visibleFrame).insetBy(dx: tileGap, dy: tileGap)
            let onScreen = current.filter { screenContaining($0.center) === screen }
            let onScreenByID = Dictionary(uniqueKeysWithValues: onScreen.map { ($0.windowID, $0) })
            let floatedHere = floated[id] ?? []

            var tree = trees[id]
            for win in onScreen
            where win.isResizable && !win.isFullScreenNow && !floatedHere.contains(win.windowID)
                && findLeaf(tree, containing: win.windowID) == nil
            {
                let preferred = activeLeaf(tree: tree, frontID: frontID, byID: byID, on: screen)
                insertNew(win.windowID, into: &tree, area: area, preferredTarget: preferred)
            }
            trees[id] = tree

            if let tree {
                applyTree(tree, area: area, byID: onScreenByID)
            } else {
                log("раскладка на экране опустела")
            }
        }
    }

    /// Лист активного (переднего) окна, если оно отслеживается на этом же
    /// экране, — цель по умолчанию для новых окон. Если активное окно на
    /// другом экране или не отслеживается вовсе (не обычное окно, ещё не
    /// подхвачено), возвращающий nil означает «взять хвост спирали»,
    /// как и раньше.
    private func activeLeaf(
        tree: TileNode?, frontID: CGWindowID?, byID: [CGWindowID: WinRef], on screen: NSScreen
    ) -> TileNode? {
        guard let tree, let frontID, let front = byID[frontID],
            screenContaining(front.center) === screen
        else { return nil }
        return findLeaf(tree, containing: frontID)
    }

    // MARK: ручное изменение размера

    // Раскладка запоминает, какую рамку сама поставила каждому окну. Если на
    // очередном такте фактическая рамка отслеживаемого окна не совпадает
    // с тем, что мы туда ставили, — значит, кто-то подвинул или растянул его
    // сам, пока мы не смотрели (пользователь через Raycast, само приложение
    // и так далее). Дальше два разных случая:
    //
    //   а) окно стало занимать почти весь экран — намеренный разворот,
    //      раскладке лезть туда не нужно: окно выводится из неё («floated»),
    //      освободившееся место сразу отдаётся остальным окнам на экране.
    //
    //   б) иначе — окно переставили в другое место вручную, например
    //      клавишами в четверть экрана. Raycast и подобные команды не знают
    //      о тайлинге и просто переставляют окно в нужную область, не
    //      двигая то, что там уже было, — физически они накладываются друг
    //      на друга. Точного совпадения координат тут не бывает: свои
    //      четверти Raycast считает независимо от нашей раскладки, и даже
    //      если визуально это одно и то же место, пиксель в пиксель они не
    //      совпадут (для половин экрана иногда совпадает случайно, для
    //      четвертей — почти никогда). Поэтому ищем не точное совпадение
    //      рамки, а окно, которое новая рамка перекрывает больше всего, —
    //      оно и было «на этом месте». Переставленное окно вынимается из
    //      своего места в порядке и вставляется перед найденным — всё, что
    //      было после точки вставки, сдвигается по спирали на шаг, как при
    //      обычном открытии нового окна, а не изолированный обмен вдвоём.
    //
    // И наоборот: окно, выведенное как «почти весь экран», продолжаем
    // проверять — как только оно перестаёт быть таким (пользователь сам
    // вернул ему обычный размер), оно тут же возвращается в раскладку.
    private func watchManualResize(current: [WinRef], frontID: CGWindowID?) {
        guard tilingEnabled, !cycling else { return }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.windowID, $0) })

        for did in Set(trees.keys).union(floated.keys) {
            guard let screen = NSScreen.screens.first(where: { screenID($0) == did })
            else { continue }
            let area = axRect(for: screen.visibleFrame).insetBy(dx: tileGap, dy: tileGap)

            var tree = trees[did]
            // закрывшиеся выведенные окна больше нечего ждать — забываем их
            var floatSet = (floated[did] ?? []).filter { byID[$0] != nil }
            var changed = false

            let trackedIDs = tree.map(allWindowIDs) ?? []
            for id in trackedIDs {
                guard let win = byID[id], let expected = lastAppliedFrame[id],
                    !close(win.frame, expected)
                else { continue }

                // Просьба переставить окно выполняется не мгновенно: пока
                // программа её применяет (а многие ещё и анимируют), окно
                // отвечает старой рамкой. Если верить этому сразу, только
                // что размещённое окно тут же считается переставленным
                // вручную — по его СТАРОМУ месту, где оно открылось. На
                // каждое новое окно раскладка делала два пересчёта подряд,
                // второй из них по случайному поводу, и окно уезжало не
                // туда, куда его положила раскладка.
                if let at = appliedAt[id], Date().timeIntervalSince(at) < settleTime { continue }

                if isNearFullScreenArea(win.frame, on: screen) {
                    tree = tree.flatMap { removing(id, from: $0) }
                    floatSet.insert(id)
                    changed = true
                    continue
                }

                if let targetID = mostOverlapped(
                    win.frame, among: trackedIDs, excluding: id, byID: byID)
                {
                    moveInTree(id, onto: targetID, tree: &tree, area: area)
                    changed = true
                }
            }

            for id in floatSet {
                guard let win = byID[id], !isNearFullScreenArea(win.frame, on: screen)
                else { continue }
                floatSet.remove(id)
                let preferred = activeLeaf(tree: tree, frontID: frontID, byID: byID, on: screen)
                insertNew(id, into: &tree, area: area, preferredTarget: preferred)
                changed = true
            }

            trees[did] = tree
            floated[did] = floatSet
            guard changed else { continue }

            let onScreenByID = Dictionary(
                uniqueKeysWithValues: current.filter { screenContaining($0.center) === screen }
                    .map { ($0.windowID, $0) })
            if let tree {
                applyTree(tree, area: area, byID: onScreenByID)
            } else {
                log("раскладка на экране опустела")
            }
        }
    }

    // Тот же порог, что раньше использовался для угадывания «максимизировано
    // намеренно» при первом взгляде на окно, — но здесь безопасен, потому что
    // применяется только к окну, чья рамка разошлась с тем, что поставила
    // сама раскладка. Собственное растягивание раскладки под этот случай не
    // подпадает: сразу после applyTree() рамка совпадает с lastAppliedFrame.
    private func isNearFullScreenArea(_ frame: CGRect, on screen: NSScreen) -> Bool {
        let visibleArea = screen.visibleFrame.width * screen.visibleFrame.height
        guard visibleArea > 0 else { return false }
        return (frame.width * frame.height) / visibleArea > 0.85
    }

    // Среди отслеживаемых окон ищет то, чьё МЕСТО (не текущее положение —
    // именно рамка, которую туда в последний раз поставила сама раскладка)
    // новая рамка перекрывает сильнее всего. Это важно, если пользователь
    // переставил сразу два окна почти одновременно — если бы сравнивали
    // с текущим положением соседа, а не с его законным местом, оба окна
    // к моменту проверки уже съехали бы каждое со своего места, и они
    // просто не нашли бы друг друга. Доля считается от МЕНЬШЕЙ из двух
    // площадей, чтобы маленькое окно, вставшее внутрь большого, тоже
    // засчиталось, а не потерялось в знаменателе. Порог 30% — с запасом
    // ниже почти любой реальной перестановки (два окна, поставленные в одно
    // и то же место разными раскладками, обычно перекрываются почти
    // полностью) и заметно выше случайного касания краями соседних ячеек
    // спирали.
    private func mostOverlapped(
        _ frame: CGRect, among order: [CGWindowID], excluding: CGWindowID,
        byID: [CGWindowID: WinRef]
    ) -> CGWindowID? {
        var best: (id: CGWindowID, ratio: CGFloat)?
        let ownSlot = lastAppliedFrame[excluding]
        for other in order where other != excluding {
            guard byID[other] != nil, let otherSlot = lastAppliedFrame[other] else { continue }
            // Соседей по стопке пропускаем: у них с этим окном одна и та же
            // ячейка, перекрытие всегда полное, и любое мелкое расхождение
            // рамки внутри стопки читалось бы как «окно заняло чужое место».
            // Раскладка от этого перетасовывалась сама по себе, окна прыгали
            // между ячейками — особенно заметно при переборе, когда окно
            // стопки поднимают на передний план. Перестановка внутри своей
            // же ячейки перестановкой не является.
            if let ownSlot, close(ownSlot, otherSlot) { continue }
            let overlap = frame.intersection(otherSlot)
            guard !overlap.isNull else { continue }
            let smaller = min(frame.width * frame.height, otherSlot.width * otherSlot.height)
            guard smaller > 0 else { continue }
            let ratio = (overlap.width * overlap.height) / smaller
            if ratio > 0.3, best == nil || ratio > best!.ratio {
                best = (other, ratio)
            }
        }
        return best?.id
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

    // Окно с фиксированным размером ставим по центру его экрана и поднимаем
    // над остальными. Размер не трогаем вовсе — его и нельзя менять, ради
    // этого окно и выведено из раскладки.
    private func centerOnTop(_ win: WinRef) {
        guard !centered.contains(win.windowID),
            let screen = screenContaining(win.center)
        else { return }
        centered.insert(win.windowID)

        let area = axRect(for: screen.visibleFrame)
        var pos = CGPoint(
            x: area.midX - win.frame.width / 2,
            y: area.midY - win.frame.height / 2)
        let posVal = AXValueCreate(.cgPoint, &pos)!
        AXUIElementSetAttributeValue(win.element, kAXPositionAttribute as CFString, posVal)
        AXUIElementPerformAction(win.element, kAXRaiseAction as CFString)
        log("по центру поверх остальных (размер фиксированный): \(win.owner)")
    }

    // MARK: дерево разбиений — операции

    private func leafCount(_ node: TileNode?) -> Int {
        guard let node else { return 0 }
        switch node.content {
        case .leaf: return 1
        case .split(_, let a, let b): return leafCount(a) + leafCount(b)
        }
    }

    private func allWindowIDs(_ node: TileNode) -> [CGWindowID] {
        switch node.content {
        case .leaf(let ids): return ids
        case .split(_, let a, let b): return allWindowIDs(a) + allWindowIDs(b)
        }
    }

    private func findLeaf(_ node: TileNode?, containing id: CGWindowID) -> TileNode? {
        guard let node else { return nil }
        switch node.content {
        case .leaf(let ids):
            return ids.contains(id) ? node : nil
        case .split(_, let a, let b):
            return findLeaf(a, containing: id) ?? findLeaf(b, containing: id)
        }
    }

    // Прямоугольники всех листьев с учётом зазора между соседями. Порядок
    // деления и его направление уже решены на каждом узле заранее (см.
    // splitting) — здесь только считается геометрия, рекурсивно сверху вниз.
    private func rects(for node: TileNode, in area: CGRect) -> [(TileNode, CGRect)] {
        switch node.content {
        case .leaf:
            return [(node, area)]
        case .split(let vertical, let a, let b):
            let (rectA, rectB) = halves(area, vertical: vertical)
            return rects(for: a, in: rectA) + rects(for: b, in: rectB)
        }
    }

    private func halves(_ area: CGRect, vertical: Bool) -> (CGRect, CGRect) {
        if vertical {
            let half = (area.width - tileGap) / 2
            return (
                CGRect(x: area.minX, y: area.minY, width: half, height: area.height),
                CGRect(
                    x: area.minX + half + tileGap, y: area.minY,
                    width: area.width - half - tileGap, height: area.height)
            )
        }
        let half = (area.height - tileGap) / 2
        return (
            CGRect(x: area.minX, y: area.minY, width: area.width, height: half),
            CGRect(
                x: area.minX, y: area.minY + half + tileGap,
                width: area.width, height: area.height - half - tileGap)
        )
    }

    // Самый мелкий лист — хвост спирали. Цель по умолчанию, когда активное
    // окно не отслеживается, и всегда цель для окон сверх лимита ячеек:
    // переполнение уходит в самое маленькое место независимо от того, где
    // сейчас работает пользователь — так же, как раньше в плоском списке.
    private func tailLeaf(_ node: TileNode, in area: CGRect) -> TileNode {
        rects(for: node, in: area).min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }!.0
    }

    // Удаляет окно из дерева. Если оно было единственным в своём листе, узел
    // схлопывается — сосед по разрезу получает освободившееся место целиком,
    // а не делит его с кем-то ещё (в этом смысл дерева против прежнего
    // плоского списка: соседей, не участвовавших в перестановке, не
    // задевает). Если окон в раскладке не осталось, возвращается nil.
    private func removing(_ id: CGWindowID, from node: TileNode) -> TileNode? {
        switch node.content {
        case .leaf(let ids):
            let remaining = ids.filter { $0 != id }
            if remaining.count == ids.count { return node }
            if remaining.isEmpty { return nil }
            node.content = .leaf(remaining)
            return node
        case .split(let vertical, let a, let b):
            if findLeaf(a, containing: id) != nil {
                guard let newA = removing(id, from: a) else { return b }
                node.content = .split(vertical: vertical, newA, b)
                return node
            }
            if findLeaf(b, containing: id) != nil {
                guard let newB = removing(id, from: b) else { return a }
                node.content = .split(vertical: vertical, a, newB)
                return node
            }
            return node
        }
    }

    // Делит лист target пополам: прежний хозяин ячейки остаётся в одной
    // половине, id получает другую. Направление — по пропорциям текущей
    // рамки target (targetRect считает вызывающий заранее, до вставки).
    private func splitting(_ target: TileNode, insert id: CGWindowID, targetRect: CGRect) {
        guard case .leaf(let existing) = target.content else { return }
        let vertical = targetRect.width >= targetRect.height
        target.content = .split(
            vertical: vertical, TileNode(.leaf(existing)), TileNode(.leaf([id])))
    }

    // Присоединяет окно к стопке листа без деления — когда ячеек уже
    // максимум и создавать новую нельзя.
    private func appending(_ id: CGWindowID, to leaf: TileNode) {
        guard case .leaf(let ids) = leaf.content else { return }
        leaf.content = .leaf(ids + [id])
    }

    // Добавляет новое (ранее не отслеживаемое) окно в дерево этого экрана.
    // preferredTarget — лист активного окна, если оно отслеживается здесь;
    // nil означает «взять хвост спирали». При достижении maxTiles цель
    // всегда хвост, независимо от preferredTarget: переполнение не может
    // расталкивать активную ячейку, для него отведено ровно одно место.
    private func insertNew(
        _ id: CGWindowID, into tree: inout TileNode?, area: CGRect, preferredTarget: TileNode?
    ) {
        guard let root = tree else {
            tree = TileNode(.leaf([id]))
            return
        }
        if leafCount(root) >= maxTiles {
            appending(id, to: tailLeaf(root, in: area))
            return
        }
        let target = preferredTarget ?? tailLeaf(root, in: area)
        let targetRect = rects(for: root, in: area).first { $0.0 === target }?.1 ?? area
        splitting(target, insert: id, targetRect: targetRect)
    }

    // Переставляет уже отслеживаемое окно на место другого (targetID) —
    // вынимает его из своего листа и вставляет в лист цели. Если после
    // изъятия в дереве образовалось свободное место (окно было единственным
    // в своём листе), цель делится пополам, как при появлении нового окна —
    // прежний хозяин ячейки и переставленное окно получают по половине.
    // Если места не образовалось (окно было одним из нескольких в стопке —
    // изъятие одного её не опустошает), делить нечего: окно присоединяется
    // к листу цели без деления; если цель до этого была обычной ячейкой,
    // она тоже становится стопкой на двоих. Это единственное отступление от
    // «дерево, а не список» — задевает только редкий случай перетаскивания
    // окна из стопки прямо на видимую ячейку, сделано ради простоты.
    private func moveInTree(
        _ id: CGWindowID, onto targetID: CGWindowID, tree: inout TileNode?, area: CGRect
    ) {
        guard let root = tree, let after = removing(id, from: root) else { return }
        tree = after
        guard let targetLeaf = findLeaf(after, containing: targetID) else { return }
        if leafCount(after) < maxTiles {
            let targetRect = rects(for: after, in: area).first { $0.0 === targetLeaf }?.1 ?? area
            splitting(targetLeaf, insert: id, targetRect: targetRect)
        } else {
            appending(id, to: targetLeaf)
        }
    }

    // Применяет дерево к реальным окнам: считает прямоугольники листьев
    // и переставляет окна через Accessibility.
    private func applyTree(_ tree: TileNode, area: CGRect, byID: [CGWindowID: WinRef]) {
        var owners: [String] = []
        var stackedCount = 0

        for (leaf, rect) in rects(for: tree, in: area) {
            guard case .leaf(let ids) = leaf.content else { continue }
            if ids.count > 1 { stackedCount = ids.count }
            for id in ids {
                guard let win = byID[id] else { continue }
                var pos = rect.origin
                var size = rect.size
                let posVal = AXValueCreate(.cgPoint, &pos)!
                let sizeVal = AXValueCreate(.cgSize, &size)!
                AXUIElementSetAttributeValue(win.element, kAXPositionAttribute as CFString, posVal)
                AXUIElementSetAttributeValue(win.element, kAXSizeAttribute as CFString, sizeVal)
                lastAppliedFrame[id] = rect
                appliedAt[id] = Date()
                owners.append(win.owner)
            }
            // Сверху стопки — окно, и так впереди остальных по системному
            // z-порядку. Для только что открытого это оно само (новое окно
            // система кладёт наверх), для найденного перебором — тоже оно:
            // перебор его уже поднял. Если поднимать безусловно последнее
            // по списку, любой следующий пересчёт стирал бы выбор
            // пользователя — только что найденное перебором окно снова
            // уезжало бы под стопку.
            if ids.count > 1,
                let top = ids.compactMap({ byID[$0] }).min(by: { $0.depth < $1.depth })
            {
                AXUIElementPerformAction(top.element, kAXRaiseAction as CFString)
            }
        }

        log(
            "раскладка: \(owners.count) окон"
                + (stackedCount > 1 ? " (в стопке: \(stackedCount))" : "") + " — "
                + owners.joined(separator: ", "))
    }

    // MARK: список окон

    // Собирает все подходящие окна, включая те, что сейчас занимают почти
    // весь экран — этот фильтр применяется отдельно, только там, где он
    // действительно нужен (см. orderedWindows() и комментарий у тайлинга
    // выше). Порядок — спереди назад, как отдаёт CGWindowList; управлять
    // окнами умеет только Accessibility, поэтому одно сопоставляется
    // с другим по владельцу и рамке.
    private func windowList() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
    }

    private func collectWindows(from list: [[String: Any]]) -> [WinRef] {
        var keys: [WindowKey] = []
        var titles: [CGWindowID: String] = [:]

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }

            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            // мелочь вроде всплывающих панелек в перебор не берём
            if frame.width < 100 || frame.height < 100 { continue }

            keys.append(WindowKey(id: id, pid: pid, frame: frame))
            if let title = info[kCGWindowName as String] as? String { titles[id] = title }
        }

        // Экран не изменился — отдаём прошлый снимок, ни одного обращения
        // к Accessibility не делаем. Это основной путь: окна почти всё время
        // просто стоят на местах.
        if keys == lastKeys { return snapshotCache }
        lastKeys = keys

        let present = Set(keys.map(\.id))
        elementFor = elementFor.filter { present.contains($0.key) }
        traitsFor = traitsFor.filter { present.contains($0.key) }

        var axWindowsOf: [pid_t: [AXUIElement]] = [:]
        // Один элемент Accessibility — одному окну из системного списка.
        // Без этого два окна одной программы, оказавшиеся в один момент
        // на одинаковых координатах, оба сопоставлялись бы с первым
        // подходящим элементом (см. подробности у matchElement).
        var claimed: [pid_t: [AXUIElement]] = [:]
        // Уже известные сопоставления закрепляем до того, как начнём искать
        // новые: иначе только что открывшееся окно может забрать себе
        // элемент, давно принадлежащий соседнему.
        for key in keys where elementFor[key.id] != nil {
            claimed[key.pid, default: []].append(elementFor[key.id]!)
        }

        var found: [WinRef] = []
        var depth = 0

        for key in keys {
            // Программы без своего места в Dock (значки в строке меню, чужие
            // подложки) формально владеют окнами слоя 0, но переключаться на
            // них бессмысленно — в переборе им не место. Свёрнутые окна и
            // окна программ, спрятанных через Command+H, отдельной проверки
            // не требуют: система сама убирает их из этого списка.
            guard let owner = NSRunningApplication(processIdentifier: key.pid),
                owner.activationPolicy == .regular
            else { continue }
            if let bundleID = owner.bundleIdentifier, ignoredBundleIDs.contains(bundleID) {
                continue
            }

            let element: AXUIElement
            if let known = elementFor[key.id] {
                element = known
            } else {
                let windows = axWindowsOf[key.pid] ?? axWindows(of: key.pid)
                axWindowsOf[key.pid] = windows
                guard
                    let match = matchElement(
                        among: windows, frame: key.frame, title: titles[key.id],
                        taken: claimed[key.pid] ?? [])
                else { continue }
                claimed[key.pid, default: []].append(match.element)
                // Запоминаем только уверенное сопоставление. Если пришлось
                // выбирать из нескольких неразличимых кандидатов, ошибка
                // закрепилась бы навсегда, — лучше попробовать ещё раз на
                // следующем изменении, когда окна разъедутся.
                if match.confident { elementFor[key.id] = match.element }
                element = match.element
            }

            let traits: WindowTraits
            if let known = traitsFor[key.id] {
                traits = known
            } else {
                traits = WindowTraits(
                    standard: isStandardWindow(element), resizable: isResizable(element))
                traitsFor[key.id] = traits
            }
            // панели, всплывашки и диалоги мимо: берём только обычные окна
            guard traits.standard else { continue }

            found.append(
                WinRef(
                    pid: key.pid, element: element, frame: key.frame,
                    center: CGPoint(x: key.frame.midX, y: key.frame.midY), depth: depth,
                    windowID: key.id,
                    isFullScreenNow: mightBeFullScreen(key.frame) && isFullScreen(element),
                    isResizable: traits.resizable,
                    owner: owner.localizedName ?? "?"))
            depth += 1
        }

        snapshotCache = found
        return found
    }

    // Спрашивать систему о полноэкранном режиме есть смысл только у окна,
    // которое физически закрывает весь дисплей: настоящий полноэкранный
    // режим macOS всегда именно такой. Это не догадка о намерении, а
    // необходимое условие — обычная ячейка раскладки под него не подходит
    // никогда, и запрос для неё можно не делать вовсе.
    private func mightBeFullScreen(_ frame: CGRect) -> Bool {
        guard let screen = screenContaining(CGPoint(x: frame.midX, y: frame.midY))
        else { return true }
        let display = screen.frame
        guard display.width > 0, display.height > 0 else { return true }
        return (frame.width * frame.height) / (display.width * display.height) > 0.9
    }

    // Системный список окон (CGWindowList) и Accessibility — два независимых
    // взгляда на одни и те же окна, и общего идентификатора между ними
    // публичный API не даёт. Приходится сопоставлять по тому, что видно
    // с обеих сторон: программа-владелец, координаты, заголовок.
    //
    // Наивное «первый элемент, чья рамка совпала» ломается ровно в том
    // случае, ради которого вся раскладка и затевалась: пользователь
    // переставляет окно клавишами на место другого окна ТОЙ ЖЕ программы.
    // На один такт опроса оба окна стоят на одинаковых координатах, оба
    // сопоставляются с одним и тем же элементом Accessibility — и раскладка
    // дважды двигает одно окно, а второе не двигает никогда. Оно остаётся
    // не на своём месте, на следующем такте это снова считается ручным
    // вмешательством, и так до бесконечности: окна слипаются в одной
    // четверти, а журнал заполняется пересчётом по нескольку раз в секунду.
    //
    // Поэтому: (1) заголовок сильнее координат — два окна одной программы
    // на одном месте почти всегда отличаются заголовком; (2) из совпавших
    // по координатам берём ближайшее, а не первое попавшееся; (3) уже
    // занятый другим окном элемент второй раз не отдаём.
    private func matchElement(
        among windows: [AXUIElement], frame: CGRect, title: String?, taken: [AXUIElement]
    ) -> (element: AXUIElement, confident: Bool)? {
        let free = windows.filter { candidate in
            !taken.contains { CFEqual($0, candidate) }
        }
        guard !free.isEmpty else { return nil }
        // единственный свободный кандидат — выбирать не из чего, ошибиться негде
        if free.count == 1 { return (free[0], true) }

        if let title, !title.isEmpty {
            let sameTitle = free.filter { axTitle(of: $0) == title }
            if sameTitle.count == 1 { return (sameTitle[0], true) }
            // одинаковый заголовок у нескольких окон — разбираем координатами
            if sameTitle.count > 1 {
                return nearest(in: sameTitle, to: frame).map { ($0, false) }
            }
        }
        return nearest(in: free, to: frame).map { ($0, false) }
    }

    private func nearest(in windows: [AXUIElement], to frame: CGRect) -> AXUIElement? {
        var best: (element: AXUIElement, distance: CGFloat)?
        for candidate in windows {
            let other = axFrame(of: candidate)
            let distance =
                abs(other.minX - frame.minX) + abs(other.minY - frame.minY)
                + abs(other.width - frame.width) + abs(other.height - frame.height)
            if best == nil || distance < best!.distance { best = (candidate, distance) }
        }
        // допуск тот же, что и раньше, только теперь по сумме отклонений
        guard let best, best.distance <= 12 else { return nil }
        return best.element
    }

    private func axTitle(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    // Окна с намертво заданным размером — настройки системы, окна настроек
    // программ по Command+, и подобные диалоги. Система прямо отвечает, что
    // размер менять нельзя, так что гадать не приходится.
    private func isResizable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard
            AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
                == .success
        else { return true }
        return settable.boolValue
    }

    // Список для перебора (Option+Tab): окно в настоящем системном
    // полноэкранном режиме сюда не попадает — оно живёт на отдельном
    // рабочем столе, переключаться на него через Tab всё равно не выйдет.
    private func orderedWindows() -> [WinRef] {
        sortedClockwise(collectWindows(from: windowList()).filter { !$0.isFullScreenNow })
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
        // У окон одной стопки центр общий, значит и угол одинаковый. Без
        // второго признака их взаимный порядок брался бы из входного списка,
        // а он идёт по z-порядку и меняется от каждого переключения: перебор
        // застревал между двумя окнами стопки и дальше не шёл. Номер окна
        // произволен, но постоянен — этого достаточно, чтобы круг замкнулся.
        return windows.sorted {
            let a = atan2($0.center.y - hub.y, $0.center.x - hub.x)
            let b = atan2($1.center.y - hub.y, $1.center.x - hub.x)
            return a == b ? $0.windowID < $1.windowID : a < b
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
    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
            == .success && (value as? Bool) == true
    }

    // Проверки «свёрнуто ли окно» здесь больше нет намеренно: свёрнутые окна
    // и окна программ, спрятанных через Command+H, система сама убирает из
    // CGWindowList с флагом «только то, что на экране». Проверено вживую на
    // обоих способах. Отдельный запрос к Accessibility на каждое окно каждый
    // такт спрашивал ровно то, что уже сказал системный список.

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
            "Option + Command + Tab — поменять местами со следующим",
            "Option + Command + Shift + Tab — с предыдущим",
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
        refreshDimming(force: true)
    }

    @objc private func setDim(_ sender: NSMenuItem) {
        dimLevel = sender.tag
        UserDefaults.standard.set(dimLevel, forKey: Key.dimLevel)
        rebuildMenu()
        refreshDimming(force: true)
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
