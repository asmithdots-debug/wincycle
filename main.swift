// WinCycle — притушивает все окна, кроме активного, чтобы сразу было видно,
// какое окно сейчас в фокусе.
//
// Поверх каждого экрана лежит прозрачная тёмная подложка, которая всегда
// стоит сразу под самым передним окном: всё, что оказалось под ней,
// притушено, само активное окно — нет. Подложка не перехватывает мышь и
// висит на всех рабочих столах.
//
// Если реальное окно на экране одно — подложка прячется: сравнивать не с
// чем, и тёмная рамка по краям только мешала бы.
//
// Список окон и их порядок берутся из публичного API
// CGWindowListCopyWindowInfo — никаких приватных вызовов и разрешений
// (Accessibility, «Запись экрана») для этого не нужно.

import AppKit

// Отдельного вкл/выкл нет — ползунок на 0% уже и есть «выключено», третье
// состояние было бы лишним.
private enum Key {
    static let dimLevel = "wincycle.dimLevel"
}

// Приложения, чьи окна не должны учитываться при затемнении, даже когда
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

    // Закрашивает всю подложку одним полупрозрачным чёрным цветом — сила
    // (dimAlpha) задаётся ползунком «Сила затемнения».
    override func draw(_ dirtyRect: NSRect) {
        guard dimAlpha > 0 else { return }
        NSColor.black.withAlphaComponent(dimAlpha).setFill()
        bounds.fill()
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

    private var overlays: [Overlay] = []
    private var dimTimer: Timer?
    private var lastFront: CGWindowID = 0
    private var dimLevel = 35
    private var dimValueLabel: NSTextField?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Копий должно быть ровно одна: иначе два экземпляра дважды
        // переставляли бы подложки на каждом такте. Такое случается, когда
        // приложение поднимают и вручную, и службой автозапуска.
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
        defaults.register(defaults: [Key.dimLevel: 35])
        dimLevel = defaults.integer(forKey: Key.dimLevel)

        log("запуск")
        buildStatusItem()
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

        // Такт опроса — 50 мс. Переключение между окнами ОДНОЙ программы
        // система не сообщает ничем, его ловит только опрос, поэтому такт и
        // есть верхняя граница задержки в этом случае: при 0.3 с реакция
        // отставала в среднем на 120 мс и до 215 мс в худшем случае (замерено)
        // — это и ощущалось как провал. Один такт стоит доли миллисекунды,
        // так что 50 мс обходятся примерно в полпроцента одного ядра.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateDimming(force: false)
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        dimTimer = timer

        updateDimming(force: true)
    }

    // Уведомление о смене активной программы приходит РАНЬШЕ, чем система
    // перестраивает список окон: в момент сигнала самым передним нередко
    // всё ещё числится окно старой программы (проверено — так бывает не
    // всегда, но регулярно). Если сразу поверить списку, подложка встанет
    // под старое окно, то есть на мгновение потемнеет ровно то окно, на
    // которое переключились, и разошлось бы это только следующим тактом.
    // Поэтому ждём, пока переднее окно не окажется окном той программы, о
    // которой пришло уведомление.
    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        followActivation(of: app?.processIdentifier, until: Date().addingTimeInterval(0.4))
    }

    // Предел в 0.4 с — на случай, когда переднего окна у программы так и не
    // появится (активировали программу вообще без окон, например): тогда
    // просто обновляемся по тому, что есть.
    private func followActivation(of pid: pid_t?, until deadline: Date) {
        guard let pid, realWindows().first?.owner != pid, Date() < deadline else {
            updateDimming(force: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            self?.followActivation(of: pid, until: deadline)
        }
    }

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

    // Обычные окна на экране, спереди назад, как их отдаёт системный список,
    // вместе с pid программы-владельца (нужен, чтобы после переключения
    // дождаться, когда система реально поднимет окно новой программы).
    // Мелкие всплывающие панельки, окна нерегулярных программ (значки в
    // строке меню и подобные, включая наши собственные подложки) и окна
    // программ, спрятанных через Command+H, в список не попадают.
    //
    // Дальше двух подходящих окон список не строим: наружу нужно только
    // самое переднее окно и признак «оно тут не одно». Опрос идёт двадцать
    // раз в секунду, и разбирать на каждом такте весь список — ровно та
    // лишняя работа, ради которой такт раньше и держали редким.
    //
    // По той же причине список держим как NSArray/NSDictionary, а не
    // приводим к [[String: Any]]: приведение переводит в свифтовые типы
    // ВЕСЬ массив разом, включая окна, до которых мы не дойдём. Ленивый
    // разбор поэлементно дешевле втрое (замерено).
    private func realWindows() -> [(id: CGWindowID, owner: pid_t)] {
        let mine = Set(overlays.map { CGWindowID($0.windowNumber) })
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray?
        else { return [] }

        var result: [(id: CGWindowID, owner: pid_t)] = []
        for entry in list {
            guard let info = entry as? NSDictionary else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let number = info[kCGWindowNumber as String] as? CGWindowID,
                !mine.contains(number)
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.01 {
                continue
            }
            // мелочь вроде всплывающих панелек не считаем отдельным окном
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary {
                let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
                let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                if width < 100 || height < 100 { continue }
            }
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if pid != 0, let owner = NSRunningApplication(processIdentifier: pid) {
                if owner.activationPolicy != .regular { continue }
                if owner.isHidden { continue }
                if let bundleID = owner.bundleIdentifier, ignoredBundleIDs.contains(bundleID) {
                    continue
                }
            }
            result.append((number, pid))
            if result.count >= 2 { break }
        }
        return result
    }

    private func updateDimming(force: Bool) {
        guard dimLevel > 0 else {
            hideOverlays()
            return
        }
        let windows = realWindows()
        guard let front = windows.first?.id else {
            hideOverlays()
            return
        }
        // Затемнять относительно чего? Если реальное окно на экране всего
        // одно — сравнивать не с чем, и подложка только мешала бы тёмной
        // полосой по краям.
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
            // Именно orderFrontRegardless: обычный orderFront у программы,
            // которая не активна (а WinCycle не активна никогда), AppKit
            // вправе отложить до её активации.
            overlay.orderFrontRegardless()
            overlay.order(.below, relativeTo: Int(front))
        }
    }

    // Журнал нужен для разбора полётов: снаружи не видно, дошло ли
    // уведомление и что видит опрос.
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

    // MARK: строка меню
    //
    // Раньше здесь был настоящий NSMenu с ползунком в кастомном NSView
    // внутри NSMenuItem — стандартный на вид приём, но с багом: у NSMenu
    // есть отдельная, недокументированная сессия отслеживания мыши для
    // вью внутри пункта меню, и после ПЕРВОГО полного перетаскивания
    // (mouseDown → mouseDragged → mouseUp) она перестаёт передавать
    // дальнейшие события вью, пока меню не закроется и не откроется заново.
    // Один раз ползунок подвинуть можно, второй раз в ТОМ ЖЕ открытом меню —
    // уже нет; закрыть и открыть меню заново — и снова можно подвинуть ровно
    // один раз. Подтверждено вживую (см. DESIGN.md).
    //
    // NSPopover, в отличие от NSMenu, — обычное окно AppKit без этой особой
    // сессии отслеживания: обычные виджеты внутри него ведут себя как в
    // любом другом окне, ползунок можно двигать сколько угодно раз подряд.

    private let popover = NSPopover()

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
            button.target = self
            button.action = #selector(toggleStatusPopover(_:))
        }

        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = makePopoverContentView()
    }

    @objc private func toggleStatusPopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func makePopoverContentView() -> NSView {
        // Раскладка сверху вниз через накопительный y с явным зазором между
        // блоками — фиксированные координаты впритык (без зазора) визуально
        // читались как наложение подписи на ползунок и ползунка на кнопку.
        var y: CGFloat = 12

        let quit = NSButton(title: "Выход", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.frame = NSRect(x: 18, y: y, width: 80, height: 20)
        y += 20 + 12

        let label = NSTextField(labelWithString: "Сила затемнения: \(dimLevel)%")
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.frame = NSRect(x: 18, y: y + 18, width: 184, height: 16)
        dimValueLabel = label

        let slider = NSSlider(frame: NSRect(x: 18, y: y, width: 184, height: 18))
        slider.minValue = 0
        slider.maxValue = 100
        slider.integerValue = dimLevel
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        y += 34 + 12

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: y))
        container.addSubview(label)
        container.addSubview(slider)
        container.addSubview(quit)
        return container
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        dimLevel = sender.integerValue
        dimValueLabel?.stringValue = "Сила затемнения: \(dimLevel)%"
        UserDefaults.standard.set(dimLevel, forKey: Key.dimLevel)
        updateDimming(force: true)
    }

    @objc private func quit() {
        hideOverlays()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
