// 레서 그림·움직임 코드: PlanLess(MIT, kanghyunmin-bot)에서 가져옴. LICENSE-PlanLess.txt 참고.
import Cocoa
import ImageIO

final class CompanionAssets {
 private var images: [String: NSImage] = [:]
 private var times: [String: [String: [Int]]] = [:]
 init() {
  if let url=Bundle.main.url(forResource:"animations",withExtension:"json",subdirectory:"Mascots"),
     let data=try? Data(contentsOf:url),let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
   times=json["characters"] as? [String:[String:[Int]]] ?? [:]
  }
 }
 func durations(_ character:String,_ mode:CompanionMode)->[Int] {
  times[character]?[mode.rawValue] ?? (mode == .complete ? [180,160,120,280,160,600]:[280,160,300,240,280,240])
 }
 func image(_ character:String,_ mode:CompanionMode,_ frame:Int)->NSImage? {
  let key="\(character)/\(mode.rawValue)/frame-\(String(format:"%02d",frame+1))"
  if let image=images[key] {return image}
  guard let url=Bundle.main.url(forResource:key,withExtension:"png",subdirectory:"Mascots"),
    let source=CGImageSourceCreateWithURL(url as CFURL,nil),let cg=CGImageSourceCreateImageAtIndex(source,0,nil) else {return nil}
  let image=NSImage(cgImage:cg,size:NSSize(width:80,height:80));images[key]=image;return image
 }
}

final class CompanionSpriteView: NSView {
 var sprite:NSImage? {didSet {if oldValue !== sprite {needsDisplay=true}}}
 var mirrored=false {didSet {if oldValue != mirrored {needsDisplay=true}}}   // 왼쪽으로 걸을 때 좌우 뒤집기
 private var gazeX:Double=0, gazeY:Double=0
 private var gazeColumn=1,gazeRow=1
 private var lastTurn:Double=0
 override func hitTest(_ point:NSPoint)->NSView? {nil}
 override func draw(_ dirtyRect:NSRect) {
  super.draw(dirtyRect)
  let size=min(bounds.width,bounds.height)
  NSGraphicsContext.current?.imageInterpolation = .none
  if mirrored {
   let t=NSAffineTransform();t.translateX(by:bounds.width,yBy:0);t.scaleX(by:-1,yBy:1);t.concat()
  }
  sprite?.draw(in:NSRect(x:(bounds.width-size)/2,y:(bounds.height-size)/2,width:size,height:size),
    from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.none.rawValue])
 }
 func idleFrame(at now:Double)->Int {
  guard let window else {return 4}
  let local=convert(NSPoint(x:bounds.midX,y:bounds.midY),to:nil)
  let center=window.convertToScreen(NSRect(origin:local,size:.zero)).origin
  let screen=window.screen?.frame ?? NSScreen.main?.frame ?? NSRect(x:0,y:0,width:1440,height:900)
  let mouse=NSEvent.mouseLocation
  let x=max(-1,min(1,Double(mouse.x-center.x)/max(120,Double(screen.width)*0.22)))
  let y=max(-1,min(1,Double(mouse.y-center.y)/max(100,Double(screen.height)*0.22)))
  gazeX += (x-gazeX)*0.24;gazeY += (y-gazeY)*0.24
  let column=gazeX < -0.28 ? 0:gazeX > 0.28 ? 2:abs(gazeX)<0.16 ? 1:gazeColumn
  let row=gazeY > 0.28 ? 0:gazeY < -0.28 ? 2:abs(gazeY)<0.16 ? 1:gazeRow
  // Move through connected intermediate body poses; don't snap from one
  // extreme to its opposite or chatter at a direction boundary.
  if now-lastTurn>=0.12 {
   if column != gazeColumn {gazeColumn += column>gazeColumn ? 1 : -1;lastTurn=now}
   else if row != gazeRow {gazeRow += row>gazeRow ? 1 : -1;lastTurn=now}
  }
  // Blink only in neutral, so a blink never teleports a turned head to center.
  if gazeRow==1 && gazeColumn==1 && row==1 && column==1 {
   let blink=now.truncatingRemainder(dividingBy:5.4)
   if blink<0.07 {return 9};if blink<0.16 {return 10};if blink<0.23 {return 11}
  }
  return gazeRow*3+gazeColumn
 }
}


// MARK: - 상단바 레서 (PlanLess 레서를 한 주 쌓기 블록에 맞춘 버전)

/// Today's blocks as companion goals: done → 2, the block happening right now → 1 (working), else 0.
func lesserSnapshot(_ root: [String: Any], now: Date = Date()) -> CompanionSnapshot {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    let today = f.string(from: now)
    let cal = Calendar(identifier: .gregorian)
    let slot = cal.component(.hour, from: now) * 6 + cal.component(.minute, from: now) / 10
    let version = (root["v"] as? NSNumber)?.intValue ?? 0
    let factor = version >= 4 ? 1 : 3
    let shift = version >= 3 ? 0 : 16
    let rows = (root["blocks"] as? [[String: Any]]) ?? []
    let goals: [CompanionGoal] = rows.compactMap { r in
        guard let id = r["id"] as? String, let name = r["name"] as? String, r["date"] as? String == today else { return nil }
        let start = (((r["start"] as? NSNumber)?.intValue ?? 0) + shift) * factor
        let len = ((r["len"] as? NSNumber)?.intValue ?? 1) * factor
        let done = (r["done"] as? NSNumber)?.boolValue ?? false
        let status = done ? 2 : (start <= slot && slot < start + len ? 1 : 0)
        return CompanionGoal(id: id, day: today, subject: "", title: name, status: status)
    }
    return CompanionSnapshot(goals: goals)
}

final class MenuBarLesser: NSObject {
    private var language = HanjuLanguage.system
    private func text(_ ko: String, _ en: String) -> String { HanjuLanguage.text(ko, en, language: language) }
    let playback = CompanionPlayback()
    let assets = CompanionAssets()
    private let statusItem = NSStatusBar.system.statusItem(withLength: 34)
    private let sprite = CompanionSpriteView()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    var character = "planner"
    /// 절전 모드: one still frame, no animation timer.
    var saver = false { didSet { if saver != oldValue { restart() } } }
    var onOpen: (() -> Void)?
    var onCharacter: ((String) -> Void)?
    var onPlace: ((DesktopLesserPlace) -> Void)?
    var place: DesktopLesserPlace = .desktop

    override init() {
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            sprite.frame = button.bounds
            sprite.autoresizingMask = [.width, .height]
            button.addSubview(sprite)
            button.toolTip = "한 주 쌓기 · 레서"
        }
        restart()
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.timer?.invalidate(); self?.timer = nil })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart() })
    }

    func update(_ root: [String: Any]) {
        language = HanjuLanguage.resolve(root["language"])
        statusItem.button?.toolTip = text("한 주 쌓기 · 레서", "HanjuStack · Lesser")
        playback.update(lesserSnapshot(root), at: ProcessInfo.processInfo.systemUptime)
        tick()
    }

    private func restart() {
        timer?.invalidate()
        // 24fps normally; 절전 모드 only refreshes the still pose every few seconds.
        let t = Timer(timeInterval: saver ? 5 : 1.0 / 24, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = saver ? 1 : 0.008
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let p = playback.presentation(at: now)
        let frame: Int
        if saver {
            frame = p.mode == .idle ? 4 : 0
        } else {
            frame = p.mode == .idle ? sprite.idleFrame(at: now)
                : CompanionPlayback.frame(at: p.elapsed, milliseconds: assets.durations(character, p.mode))
        }
        sprite.sprite = assets.image(character, p.mode, frame)
    }

    @objc private func clicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { onOpen?() }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: text("한 주 쌓기 열기", "Open HanjuStack"), action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        for (i, title) in [text("계획단장 레서", "Planner Lesser"), text("열정 레서", "Passion Lesser")].enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            item.state = character == (i == 0 ? "planner" : "passion") ? .on : .off
        }
        menu.addItem(.separator())
        let places: [(String, DesktopLesserPlace)] = [(text("바탕화면 레서: 바탕화면에서", "Desktop Lesser: on desktop"), .desktop),
                                                      (text("바탕화면 레서: 모든 창 위에서", "Desktop Lesser: above all windows"), .top), (text("바탕화면 레서: 끄기", "Desktop Lesser: off"), .off)]
        for (i, (title, value)) in places.enumerated() {
            let item = menu.addItem(withTitle: title, action: #selector(pickPlace(_:)), keyEquivalent: "")
            item.target = self; item.tag = i; item.state = place == value ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: text("한 주 쌓기 종료", "Quit HanjuStack"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if let button = statusItem.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
    }

    @objc private func openApp() { onOpen?() }
    @objc private func pickPlace(_ sender: NSMenuItem) {
        place = [DesktopLesserPlace.desktop, .top, .off][sender.tag]
        onPlace?(place)
    }
    @objc private func pick(_ sender: NSMenuItem) {
        character = sender.tag == 1 ? "passion" : "planner"
        onCharacter?(character)
        tick()
    }
}


// MARK: - 바탕화면 레서: 화면 아래쪽을 돌아다니는 투명 창

enum DesktopLesserPlace: String { case off, desktop, top }

final class DesktopLesser: NSObject {
    let assets = CompanionAssets()
    private let panel: NSPanel
    private let sprite = CompanionSpriteView()
    private var timer: Timer?
    private var x: CGFloat = 200
    private var target: CGFloat = 200
    private var pauseUntil: Double = 0
    private var walkStart: Double = 0
    private let size: CGFloat = 96
    private let speed: CGFloat = 46          // points per second

    var character = "planner"
    weak var playback: CompanionPlayback?    // shared with the menu bar 레서
    var saver = false { didSet { if saver != oldValue { restart() } } }
    var place: DesktopLesserPlace = .desktop { didSet { if place != oldValue { applyPlace() } } }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 96, height: 96),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // never gets in the way of clicks
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = sprite
        if let screen = NSScreen.main { x = screen.visibleFrame.midX; target = x }
        applyPlace()
    }

    private func applyPlace() {
        switch place {
        case .off:
            panel.orderOut(nil)
        case .desktop:
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.orderFrontRegardless()
        case .top:
            panel.level = .floating
            panel.orderFrontRegardless()
        }
        restart()
    }

    private func restart() {
        timer?.invalidate(); timer = nil
        guard place != .off else { return }
        let t = Timer(timeInterval: saver ? 5 : 1.0 / 24, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = saver ? 1 : 0.008
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let now = ProcessInfo.processInfo.systemUptime
        let p = playback?.presentation(at: now) ?? CompanionPresentation(mode: .idle, elapsed: 0, celebrationNumber: 0)
        var frame = 4
        var mode = p.mode
        if saver {
            frame = p.mode == .idle ? 4 : 0
        } else if p.mode == .complete {
            // stop and celebrate
            frame = CompanionPlayback.frame(at: p.elapsed, milliseconds: assets.durations(character, .complete))
        } else if now < pauseUntil {
            frame = p.mode == .idle ? sprite.idleFrame(at: now)
                : CompanionPlayback.frame(at: p.elapsed, milliseconds: assets.durations(character, .working))
        } else {
            // walk toward the target, bouncing with the working frames
            let step = speed / 24
            if abs(target - x) <= step {
                x = target
                pauseUntil = now + Double.random(in: 3...9)
                let margin = size
                target = CGFloat.random(in: (area.minX + margin)...(area.maxX - margin))
            } else {
                x += target > x ? step : -step
                sprite.mirrored = target < x
            }
            if walkStart == 0 { walkStart = now }
            mode = .working
            frame = CompanionPlayback.frame(at: now - walkStart, milliseconds: assets.durations(character, .working))
        }
        x = min(max(x, area.minX + size / 2), area.maxX - size / 2)
        panel.setFrame(NSRect(x: x - size / 2, y: area.minY, width: size, height: size), display: false)
        sprite.sprite = assets.image(character, mode, frame)
    }
}
