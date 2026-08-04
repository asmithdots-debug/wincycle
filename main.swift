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

// Отдельного вкл/выкл нет ни у затемнения, ни у стекла — ползунок на 0%
// уже и есть «выключено», третье состояние было бы лишним.
private enum Key {
    static let dimLevel = "wincycle.dimLevel"
    static let glassTintLevel = "wincycle.glassTintLevel"
    // Настоящее значение NSGlassTintAmount до того, как WinCycle его вообще
    // тронул, — хранится на диске (не только в памяти Controller), потому
    // что ползунок теперь перезапускает процесс (см. relaunchSelf()): без
    // этого следующий процесс в цепочке перезапусков принял бы уже
    // записанное WinCycle значение за «оригинал» и в итоге не восстановил
    // бы настоящее системное при выключении.
    static let hasSavedSystemGlassTint = "wincycle.hasSavedSystemGlassTint"
    static let savedSystemGlassTint = "wincycle.savedSystemGlassTint"
    // У рамки, в отличие от затемнения и стекла, нет «силы» — только вкл/выкл.
    static let borderEnabled = "wincycle.borderEnabled"
}

// Системный ключ за ползунком «Liquid Glass» в Системные настройки → Оформ-
// ление (найден через `defaults read -g`, не документирован Apple). Это
// ГЛОБАЛЬНАЯ настройка на весь стакан Liquid Glass в системе, а не свойство
// одного окна: у самого NSGlassEffectView нет параметра силы размытия (см.
// DESIGN.md), поэтому единственный способ её регулировать — через этот
// ключ в NSGlobalDomain, а значит правка отражается на Safari, Finder,
// Системных настройках и так далее, пока WinCycle его не вернёт обратно.
//
// Читаем и пишем через сам /usr/bin/defaults, а не через CFPreferences
// напрямую: на этой версии системы CFPreferencesSetValue/CFPreferencesCopy-
// Value с kCFPreferencesAnyApplication (и явным "NSGlobalDomain") молча
// уходят в другое хранилище, не то же самое, что читает `defaults -g` и
// сама System Settings, — проверено эмпирически: запись через CFPreferences
// не отражалась во внешнем `defaults read -g`, а `defaults write -g` из
// шелла отражалась всегда. Раз единственный публично подтверждённый рабочий
// путь — сам CLI-инструмент, используем его, а не гадаем дальше про приватную
// прослойку cfprefsd.
private func readGlobalGlassTint() -> Double? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    task.arguments = ["read", "-g", "NSGlassTintAmount"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }
    return Double(text)
}

private func writeGlobalGlassTint(_ value: Double?) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    if let value {
        task.arguments = ["write", "-g", "NSGlassTintAmount", "-float", String(value)]
    } else {
        task.arguments = ["delete", "-g", "NSGlassTintAmount"]
    }
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return }
    task.waitUntilExit()
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

    // Виньетка вместо плоской заливки: в центре экрана прозрачно, к краям —
    // темнее, до dimAlpha. Тот же ползунок «Сила затемнения» задаёт
    // максимальную (краевую) темноту, просто форма другая — плоская заливка
    // выглядела как ровная серая пелена, виньетка мягче и меньше похожа на
    // «весь экран одним цветом».
    override func draw(_ dirtyRect: NSRect) {
        guard dimAlpha > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(dimAlpha).cgColor,
        ]
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
            locations: [0.4, 1.0])!
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(bounds.width, bounds.height) * 0.75
        ctx.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
            options: [])
    }
}

final class Overlay: NSWindow {
    let shade = ShadeView()
    // NSGlassEffectView существует только с macOS 26 — заведён как обычный
    // NSView?, чтобы не тащить условную компиляцию через весь файл.
    //
    // NSGlassEffectView читает глобальный NSGlassTintAmount (см. объявление
    // ключа у Controller) ровно один раз за весь процесс — не за окно, не
    // за конкретный экземпляр вью. Ни переписывание значения на месте, ни
    // пересоздание того же вью, ни даже создание совсем нового окна внутри
    // ТОГО ЖЕ процесса ничего не меняют — проверено попарным сравнением
    // скриншотов (пиксель в пиксель одинаковые при 2% и 91%, edge-энергия
    // совпадает с точностью до шума). Меняется только между разными
    // ПРОЦЕССАМИ. Поэтому единственный работающий способ дать пользователю
    // живой ползунок — перезапускать сам процесс WinCycle при отпускании
    // ползунка (Controller.relaunchSelf()), а не подстраивать это окно.
    private var glass: NSView?

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

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView(frame: container.bounds)
            glassView.autoresizingMask = [.width, .height]
            glassView.tintColor = .clear
            glassView.isHidden = true
            container.addSubview(glassView)
            glass = glassView
        }

        shade.frame = container.bounds
        shade.autoresizingMask = [.width, .height]
        container.addSubview(shade)

        contentView = container
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(alpha: CGFloat) {
        guard shade.dimAlpha != alpha else { return }
        shade.dimAlpha = alpha
        shade.needsDisplay = true
    }

    func setGlass(enabled: Bool) {
        glass?.isHidden = !enabled
    }
}

// MARK: - Рамка вокруг активного окна

// Альтернатива/дополнение к затемнению: вместо (или вместе с) притушенных
// соседей — акцент на самом активном окне, светящаяся обводка ровно по его
// границе. Чужие окна при этом вообще не трогаются, только своё окно поверх
// всех рисуем.
final class BorderShadeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset: CGFloat = 3
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 10, yRadius: 10)
        path.lineWidth = 4
        NSColor.systemBlue.setStroke()
        ctx.setShadow(
            offset: .zero, blur: 8, color: NSColor.systemBlue.withAlphaComponent(0.7).cgColor)
        path.stroke()
    }
}

final class BorderOverlay: NSWindow {
    private let borderView = BorderShadeView()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        contentView = borderView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(around frame: NSRect) {
        borderView.frame = NSRect(origin: .zero, size: frame.size)
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
    }
}

final class Controller: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    private var overlays: [Overlay] = []
    private var dimTimer: Timer?
    private var lastFront: CGWindowID = 0
    private var dimLevel = 35
    private var dimValueLabel: NSTextField?
    private var glassTintLevel = 0
    private var glassTintValueLabel: NSTextField?
    private var borderEnabled = false
    private var borderOverlay: BorderOverlay?
    private var lastBorderFrame: NSRect?
    // Значение NSGlassTintAmount в NSGlobalDomain, каким оно было ДО того,
    // как WinCycle его тронул, — чтобы вернуть на выходе. savedGlobalGlassTint
    // == nil среди прочего значит «ключа не было вовсе», тогда на выходе его
    // нужно не записать, а убрать; glassTintSaved отличает это от «ещё не
    // сохраняли».
    private var glassTintSaved = false
    private var savedGlobalGlassTint: Double?
    // true между вызовом relaunchSelf() и фактическим завершением процесса —
    // отличает намеренный самоперезапуск от настоящего выхода в
    // applicationWillTerminate(): при самоперезапуске откатывать
    // NSGlassTintAmount нельзя, иначе новый процесс увидит старое значение.
    private var isRelaunching = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Копий должно быть ровно одна: иначе два экземпляра дважды
        // переставляли бы подложки на каждом такте. Такое случается, когда
        // приложение поднимают и вручную, и службой автозапуска.
        let me = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "local.wincycle"
        func otherCopies() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me }
        }
        var twins = otherCopies()
        // Самоперезапуск (см. relaunchSelf()) на секунду-другую даёт увидеть
        // ещё живую предыдущую копию, пока та завершается, — не считать
        // это дублем сразу, а подождать немного, прежде чем сдаваться.
        var attempts = 0
        while !twins.isEmpty, attempts < 20 {
            Thread.sleep(forTimeInterval: 0.1)
            twins = otherCopies()
            attempts += 1
        }
        if !twins.isEmpty {
            log("уже запущена другая копия — выхожу")
            NSApp.terminate(nil)
            return
        }

        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.dimLevel: 35, Key.glassTintLevel: 0, Key.borderEnabled: false,
        ])
        dimLevel = defaults.integer(forKey: Key.dimLevel)
        glassTintLevel = defaults.integer(forKey: Key.glassTintLevel)
        borderEnabled = defaults.bool(forKey: Key.borderEnabled)

        log("запуск")
        buildStatusItem()
        startDimming()
        if glassTintLevel > 0 { applyGlobalGlassTint() }
    }

    func applicationWillTerminate(_ note: Notification) {
        // При самоперезапуске (isRelaunching) откатывать нечего — наоборот,
        // именно это новое значение должен увидеть свежий процесс.
        guard !isRelaunching else { return }
        // Подстраховка на случай выхода не через наш пункт «Выход» (Cmd+Q,
        // принудительное завершение через Activity Monitor и так далее) —
        // без этого глобальный NSGlassTintAmount остался бы гулять по всей
        // системе и после закрытия WinCycle.
        if glassTintSaved { restoreGlobalGlassTint() }
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

    // Обычные окна на экране, спереди назад, как их отдаёт системный список,
    // вместе с их рамкой (нужна рамке подсветки активного окна). Мелкие
    // всплывающие панельки, окна нерегулярных программ (значки в строке
    // меню и подобные, включая наши собственные подложки) и окна программ,
    // спрятанных через Command+H, в список не попадают.
    private func realWindows() -> [(id: CGWindowID, bounds: CGRect)] {
        let mine = Set(overlays.map { CGWindowID($0.windowNumber) })
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        var result: [(id: CGWindowID, bounds: CGRect)] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let number = info[kCGWindowNumber as String] as? CGWindowID,
                !mine.contains(number)
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.01 {
                continue
            }
            guard let rawBounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let bounds = CGRect(
                x: rawBounds["X"] ?? 0, y: rawBounds["Y"] ?? 0,
                width: rawBounds["Width"] ?? 0, height: rawBounds["Height"] ?? 0)
            // мелочь вроде всплывающих панелек не считаем отдельным окном
            if bounds.width < 100 || bounds.height < 100 { continue }
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let owner = NSRunningApplication(processIdentifier: pid)
            {
                if owner.activationPolicy != .regular { continue }
                if owner.isHidden { continue }
                if let bundleID = owner.bundleIdentifier, ignoredBundleIDs.contains(bundleID) {
                    continue
                }
            }
            result.append((number, bounds))
        }
        return result
    }

    private func updateDimming(force: Bool) {
        guard dimLevel > 0 || glassTintLevel > 0 || borderEnabled else {
            hideOverlays()
            hideBorder()
            return
        }
        let windows = realWindows()
        guard let frontWindow = windows.first else {
            hideOverlays()
            hideBorder()
            return
        }
        // Затемнять/подсвечивать относительно чего? Если реальное окно на
        // экране всего одно — сравнивать не с чем, и подложка (как и рамка)
        // только мешала бы.
        guard windows.count > 1 else {
            hideOverlays()
            hideBorder()
            return
        }
        let front = frontWindow.id
        let alpha = CGFloat(dimLevel) / 100
        for overlay in overlays {
            overlay.apply(alpha: alpha)
            overlay.setGlass(enabled: glassTintLevel > 0)
        }

        if borderEnabled {
            showBorder(around: frontWindow.bounds)
        } else {
            hideBorder()
        }

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

    // MARK: рамка вокруг активного окна

    // Рамка ставится по фактической рамке окна из системного списка —
    // тем же координатам, что уже отфильтрованы в realWindows(). CGWindowList
    // отдаёt их в системе координат «сверху слева, без переворота»; NSWindow
    // ждёт кокоавские (снизу слева), поэтому переворачиваем по высоте
    // главного экрана — тот же приём, что раньше использовался для фуллскрина.
    private func showBorder(around bounds: CGRect) {
        let overlay = borderOverlay ?? BorderOverlay()
        if borderOverlay == nil { borderOverlay = overlay }

        let flipBase = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoaFrame = CGRect(
            x: bounds.minX, y: flipBase - bounds.minY - bounds.height,
            width: bounds.width, height: bounds.height)
        guard cocoaFrame != lastBorderFrame else {
            if !overlay.isVisible { overlay.orderFrontRegardless() }
            return
        }
        lastBorderFrame = cocoaFrame
        overlay.show(around: cocoaFrame)
    }

    private func hideBorder() {
        lastBorderFrame = nil
        borderOverlay?.hide()
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

        let dimSliderItem = NSMenuItem()
        dimSliderItem.view = makeDimSliderView()
        menu.addItem(dimSliderItem)

        if #available(macOS 26.0, *) {
            let glassSliderItem = NSMenuItem()
            glassSliderItem.view = makeGlassSliderView()
            menu.addItem(glassSliderItem)
        }

        let borderItem = NSMenuItem(
            title: "Рамка вокруг активного окна", action: #selector(toggleBorder),
            keyEquivalent: "")
        borderItem.target = self
        borderItem.state = borderEnabled ? .on : .off
        menu.addItem(borderItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // MARK: NSGlassTintAmount (глобальный, см. объявление ключа выше)

    private func applyGlobalGlassTint() {
        if !glassTintSaved {
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: Key.hasSavedSystemGlassTint) {
                // Уже сохранён раньше — в том числе, возможно, ПРЕДЫДУЩИМ
                // процессом в этой же цепочке самоперезапусков. Текущее
                // значение NSGlassTintAmount сейчас — это уже значение,
                // которое туда положил сам WinCycle, а не настоящий
                // оригинал, так что читать его заново нельзя.
                savedGlobalGlassTint = defaults.object(forKey: Key.savedSystemGlassTint) as? Double
            } else {
                savedGlobalGlassTint = readGlobalGlassTint()
                defaults.set(true, forKey: Key.hasSavedSystemGlassTint)
                if let value = savedGlobalGlassTint {
                    defaults.set(value, forKey: Key.savedSystemGlassTint)
                } else {
                    defaults.removeObject(forKey: Key.savedSystemGlassTint)
                }
            }
            glassTintSaved = true
        }
        writeGlobalGlassTint(Double(glassTintLevel) / 100)
    }

    private func restoreGlobalGlassTint() {
        guard glassTintSaved else { return }
        writeGlobalGlassTint(savedGlobalGlassTint)
        glassTintSaved = false
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Key.hasSavedSystemGlassTint)
        defaults.removeObject(forKey: Key.savedSystemGlassTint)
    }

    // NSGlassEffectView читает NSGlassTintAmount ровно один раз за весь
    // процесс (см. комментарий у Overlay) — единственный способ показать
    // новое значение живьём - перезапустить сам процесс WinCycle.
    //
    // Пробовали execv (замена образа текущего процесса на свежий, тот же
    // PID) — технически перезапускает и подхватывает новое значение, но
    // соединение со строкой меню это не переживает: значок WinCycle просто
    // пропадает насовсем, потому что execv не даёт AppKit нормально закрыть
    // старое соединение с оконным сервером перед тем, как его заменят.
    // Вместо этого — честный новый процесс (`open -n`) и завершение
    // старого через обычный NSApp.terminate(nil): так строка меню
    // освобождается штатно, как при обычном выходе.
    private func relaunchSelf() {
        isRelaunching = true
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func makeGlassSliderView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 34))

        let label = NSTextField(labelWithString: "Размытие стекла: \(glassTintLevel)%")
        label.font = NSFont.menuFont(ofSize: 0)
        label.frame = NSRect(x: 18, y: 18, width: 190, height: 16)
        container.addSubview(label)
        glassTintValueLabel = label

        let slider = NSSlider(frame: NSRect(x: 18, y: 2, width: 190, height: 18))
        slider.minValue = 0
        slider.maxValue = 100
        slider.integerValue = glassTintLevel
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(glassSliderChanged(_:))
        container.addSubview(slider)

        return container
    }

    @objc private func glassSliderChanged(_ sender: NSSlider) {
        glassTintLevel = sender.integerValue
        glassTintValueLabel?.stringValue = "Размытие стекла: \(glassTintLevel)%"
        UserDefaults.standard.set(glassTintLevel, forKey: Key.glassTintLevel)

        // Ключ глобальный (см. объявление выше) — переставать его трогать
        // нужно ровно на переходе через 0, а не при каждом движении: 0%
        // и есть «выключено», applyGlobalGlassTint() сама решает, сохранять
        // ли оригинал заново (не сохранит второй раз, если уже включено).
        if glassTintLevel > 0 {
            applyGlobalGlassTint()
        } else if glassTintSaved {
            restoreGlobalGlassTint()
        }
        updateDimming(force: true)

        // Само значение стекло подхватит только в новом процессе (см.
        // relaunchSelf()) — перезапускаем не на каждый шаг перетаскивания
        // (иначе за одно движение ползунка их были бы десятки), а один раз,
        // когда мышь отпустили.
        if NSApp.currentEvent?.type == .leftMouseUp {
            relaunchSelf()
        }
    }

    // Ползунок живёт в собственном NSView внутри NSMenuItem — так меню не
    // закрывается и не перестраивается на каждое движение мыши, как было бы
    // с обычными пунктами меню. rebuildMenu() тут нарочно не вызываем при
    // движении — он пересоздал бы весь NSMenu прямо во время перетаскивания
    // и оборвал бы его.
    private func makeDimSliderView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 34))

        let label = NSTextField(labelWithString: "Сила затемнения: \(dimLevel)%")
        label.font = NSFont.menuFont(ofSize: 0)
        label.frame = NSRect(x: 18, y: 18, width: 190, height: 16)
        container.addSubview(label)
        dimValueLabel = label

        let slider = NSSlider(frame: NSRect(x: 18, y: 2, width: 190, height: 18))
        slider.minValue = 0
        slider.maxValue = 100
        slider.integerValue = dimLevel
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        container.addSubview(slider)

        return container
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        dimLevel = sender.integerValue
        dimValueLabel?.stringValue = "Сила затемнения: \(dimLevel)%"
        UserDefaults.standard.set(dimLevel, forKey: Key.dimLevel)
        updateDimming(force: true)
    }

    @objc private func toggleBorder() {
        borderEnabled.toggle()
        UserDefaults.standard.set(borderEnabled, forKey: Key.borderEnabled)
        rebuildMenu()
        updateDimming(force: true)
    }

    @objc private func quit() {
        hideOverlays()
        hideBorder()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
