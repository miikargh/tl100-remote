// TL100 Remote: a floating macOS widget for the Beurer TL100 lamp (and other lamps driven by the Beurer LightUp app).
// Build with ./build.sh. Launching the app again toggles the panel (the ⌃⌥⌘L Karabiner rule does exactly that).
//   TL100Remote --snapshot out.png [finder]   renders the UI to a PNG without touching Bluetooth
//   TL100Remote --icon out.png                renders the app icon
import SwiftUI
import CoreBluetooth

// MARK: - Lamp protocol (from https://github.com/Deadolus/ha-beurer)

let serviceID = CBUUID(string: "14839AC4-7D7E-415C-9A42-167340CF2339")
let writeID = CBUUID(string: "8B00ACE7-EB0B-49B0-BBE9-9AEE0A26E1A3")
let notifyID = CBUUID(string: "0734594A-A8E7-4B1A-A6B1-CD5243059A57")
let effects = ["Solid", "Random", "Rainbow", "Rainbow Slow", "Fusion", "Pulse", "Wave", "Chill", "Action", "Forest", "Summer"]
let sendInterval = 0.15 // seconds between packets, in line with the reference driver's 0.1-0.2. 0.07 also worked
                        // in short tests; it is untested over long sessions
let answerTimeout = 3.0 // seconds to wait for a reply to a status query before assuming the lamp is stuck

func packet(_ p: [UInt8]) -> Data {
    let n = UInt8(p.count)
    return Data([0xFE, 0xEF, 0x0A, n + 7, 0xAB, 0xAA, n + 2] + p + [p.reduce(n + 2, ^), 0x55, 0x0D, 0x0A])
}

func rgb(hue: Double, saturation: Double) -> [UInt8] { // HSV at full brightness
    [5.0, 3.0, 1.0].map { n in
        let k = (n + hue * 6).truncatingRemainder(dividingBy: 6)
        return UInt8((255 * (1 - saturation * max(0, min(k, 4 - k, 1)))).rounded())
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

/// A saved light: either the white light at a level, or the mood light with its colour or effect.
struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var mood: Bool // false = white light
    var level: Double
    var hue = 0.0, saturation = 0.0, effect = 0

    var title: String {
        let name = !mood ? "White" : effect == 0 ? "Colour" : effects[min(effect, effects.count - 1)]
        return "\(name) \(Int((level * 100).rounded()))%"
    }
    /// Same light, allowing for the rounding the lamp does (whole percents, 8-bit colour).
    func matches(_ o: Preset) -> Bool {
        guard mood == o.mood, abs(level - o.level) < 0.015 else { return false }
        return !mood || (effect == o.effect && (effect != 0 || (abs(hue - o.hue) < 0.02 && abs(saturation - o.saturation) < 0.03)))
    }
}

func selfCheck() { // packets captured from the real app
    precondition(packet([0x37, 1]) == Data([0xFE, 0xEF, 0x0A, 0x09, 0xAB, 0xAA, 0x04, 0x37, 0x01, 0x32, 0x55, 0x0D, 0x0A]))
    precondition(packet([0x32] + rgb(hue: 0, saturation: 1)) == Data([0xFE, 0xEF, 0x0A, 0x0B, 0xAB, 0xAA, 0x06, 0x32, 0xFF, 0x00, 0x00, 0xCB, 0x55, 0x0D, 0x0A]))
    let saved = Preset(mood: true, level: 0.8, hue: 0.6, saturation: 0.9)
    precondition(try! JSONDecoder().decode([Preset].self, from: JSONEncoder().encode([saved])) == [saved])
    precondition(saved.matches(Preset(mood: true, level: 0.8, hue: 0.61, saturation: 0.9)) && !saved.matches(Preset(mood: false, level: 0.8)))
    precondition(rgb(hue: 1.0 / 3, saturation: 1) == [0, 255, 0] && rgb(hue: 0.5, saturation: 0) == [255, 255, 255])
}

// MARK: - Lamp: Bluetooth connection + state

struct Found: Identifiable { let id: UUID; let name: String }

final class Lamp: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var connected = false
    @Published var status = "Starting…" { didSet { NSLog("status: %@", status) } }
    @Published var nearby: [Found] = [] // offered as a picker until a lamp has been chosen once
    @Published var whiteOn = false
    @Published var whiteLevel = 0.6 // 0...1
    @Published var moodOn = false
    @Published var moodLevel = 0.6
    @Published var hue = 0.08 // 0...1
    @Published var saturation = 1.0
    @Published var effect = 0

    var color: Color { Color(hue: hue, saturation: saturation, brightness: 1) }

    // MARK: Presets

    @Published var presets = UserDefaults.standard.data(forKey: "presets").flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
    /// What the lamp is showing now, as a preset; nil while both lights are off.
    var current: Preset? {
        moodOn ? Preset(mood: true, level: moodLevel, hue: hue, saturation: saturation, effect: effect)
            : whiteOn ? Preset(mood: false, level: whiteLevel) : nil
    }
    func savePreset() { if let now = current { presets.append(now); storePresets() } }
    func deletePreset(_ p: Preset) { presets.removeAll { $0.id == p.id }; storePresets() }
    private func storePresets() { UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: "presets") }
    func apply(_ p: Preset) {
        guard p.mood else { return setWhite(level: p.level) }
        if p.effect == 0 { setColor(hue: p.hue, saturation: p.saturation) } else { setEffect(min(p.effect, effects.count - 1)) }
        setMood(level: p.level)
    }

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var lamp: CBPeripheral?
    private var tx: CBCharacteristic?
    private var queue: [(key: String, bytes: [UInt8])] = []
    private var lastWrite = Date.distantPast
    private var needsSync = false  // a command went out; ask the lamp what it did once the controls go quiet
    private var unanswered: Date?  // when the oldest status query still waiting for a reply was written
    private var silences = 0       // status queries in a row that got no reply
    var probe: [[UInt8]] = []      // diagnostics, see runProbe()
    var probing = false
    private let savedLamp = "lampIdentifier"

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
        let timer = Timer(timeInterval: sendInterval, repeats: true) { [weak self] _ in self?.flush() }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Commands

    /// Queues a packet. A key means "only the newest matters": a waiting packet with the same key is replaced,
    /// so dragging a slider never builds a backlog.
    private func send(_ bytes: UInt8..., key: String = "") {
        guard connected else { return }
        if bytes[0] != 0x30 { needsSync = true }
        if !key.isEmpty, let i = queue.firstIndex(where: { $0.key == key }) { queue[i].bytes = bytes } else { queue.append((key, bytes)) }
    }

    private func flush() {
        guard !probing, let lamp, let tx, lamp.state == .connected else { return }
        let now = Date()
        if let since = unanswered, now.timeIntervalSince(since) > answerTimeout { return wentQuiet(lamp) }
        guard !queue.isEmpty else {
            if needsSync, now.timeIntervalSince(lastWrite) > 0.5 { needsSync = false; refresh() }
            return
        }
        let bytes = queue.removeFirst().bytes
        if bytes[0] == 0x30, unanswered == nil { unanswered = now }
        lastWrite = now
        NSLog("sent: %@", hex(bytes))
        lamp.writeValue(packet(bytes), for: tx, type: tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
    }

    /// Diagnostics: `--probe "37 01, 31 01 32"` sends each packet on its own, asks for the lamp's status after each
    /// and logs every reply, so the log shows exactly which command the lamp stops answering after.
    private func runProbe() {
        guard let lamp, let tx, lamp.state == .connected else { return } // a reconnect picks the script up again
        guard !probe.isEmpty else { NSLog("probe: done"); exit(0) }
        let write = { (b: [UInt8]) in
            NSLog("probe: sent %@", hex(b))
            lamp.writeValue(packet(b), for: tx, type: tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        }
        write(probe.removeFirst())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { write([0x30, 1]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { write([0x30, 2]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.runProbe() }
    }

    /// The link is up but the lamp ignores us. A fresh connection usually wakes it; if two don't, only a power cycle will.
    private func wentQuiet(_ lamp: CBPeripheral) {
        unanswered = nil; silences += 1
        NSLog("lamp silent x%d", silences)
        if silences > 2 { status = "Lamp isn't answering. Unplug it for a few seconds."; return }
        central.cancelPeripheralConnection(lamp) // didDisconnect reconnects
    }

    private func percent(_ level: Double) -> UInt8 { UInt8(max(1, min(100, (level * 100).rounded()))) }
    private func sendColor() { let c = rgb(hue: hue, saturation: saturation); send(0x32, c[0], c[1], c[2], key: "rgb") }
    private func ensureMood() { if !moodOn { setMood(on: true) } }

    func refresh() { send(0x30, 1, key: "q1"); send(0x30, 2, key: "q2") } // ask the lamp for its white + mood state

    // The lamp runs one light at a time: switching one on switches the other off. And it locks up (dark, deaf
    // until a button on it is pressed) if it gets a brightness or colour for the light that is off, so the
    // widget's idea of which light is on must never lag behind.
    func setWhite(on: Bool) { whiteOn = on; if on { moodOn = false }; send(on ? 0x37 : 0x35, 1) }
    func setWhite(level: Double) {
        whiteLevel = level
        if !whiteOn { setWhite(on: true) }
        send(0x31, 1, percent(level), key: "white")
    }
    func setMood(on: Bool) {
        moodOn = on
        if on { whiteOn = false }
        send(on ? 0x37 : 0x35, 2)
        guard on else { return }
        send(0x34, UInt8(effect), key: "fx") // the lamp wakes up in rainbow mode; put back what the widget shows
        if effect == 0 { sendColor() }
    }
    func setMood(level: Double) { moodLevel = level; ensureMood(); send(0x31, 2, percent(level), key: "mood") }
    func setColor(hue: Double, saturation: Double) {
        self.hue = hue; self.saturation = saturation
        ensureMood()
        if effect != 0 { effect = 0; send(0x34, 0, key: "fx") } // not on every drag step: that doubled the traffic
        sendColor()
    }
    func setEffect(_ i: Int) {
        effect = i
        ensureMood(); send(0x34, UInt8(i), key: "fx")
        if i == 0 { sendColor() }
    }

    // MARK: Finding and connecting

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: findLamp()
        case .unauthorized: status = "Allow Bluetooth in System Settings → Privacy & Security"
        case .poweredOff: connected = false; status = "Bluetooth is off"
        default: connected = false; status = "Bluetooth unavailable"
        }
    }

    private func findLamp() {
        // 1. the lamp chosen last time  2. a lamp this Mac is already connected to (e.g. through Chrome)  3. scan
        if let id = UserDefaults.standard.string(forKey: savedLamp).flatMap(UUID.init(uuidString:)),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first { return connect(p) }
        if let p = central.retrieveConnectedPeripherals(withServices: [serviceID]).first { return connect(p) }
        status = "Looking for your lamp…"
        central.scanForPeripherals(withServices: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        guard let name = ad[CBAdvertisementDataLocalNameKey] as? String ?? p.name else { return }
        peripherals[p.identifier] = p
        let advertised = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if advertised.contains(serviceID) || name.uppercased().hasPrefix("TL100") { return connect(p) } // unmistakably a lamp
        if !nearby.contains(where: { $0.id == p.identifier }) { nearby.append(Found(id: p.identifier, name: name)) }
    }

    func choose(_ id: UUID) { if let p = peripherals[id] { connect(p) } }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        nearby = []
        lamp = p
        p.delegate = self
        status = "Connecting to \(p.name ?? "lamp")…"
        central.connect(p) // never times out: completes whenever the lamp is powered and in range
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices(nil) }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services, services.contains(where: { $0.uuid == serviceID }) else {
            status = "\(p.name ?? "That device") isn't a LightUp lamp"
            return forget(keepStatus: true)
        }
        services.forEach { p.discoverCharacteristics([writeID, notifyID], for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            if c.uuid == notifyID { p.setNotifyValue(true, for: c) }
            if c.uuid == writeID {
                tx = c
                UserDefaults.standard.set(p.identifier.uuidString, forKey: savedLamp)
                connected = true
                status = p.name ?? "Connected"
                if probing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runProbe() } } else { refresh() }
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { reconnect(p) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { reconnect(p) }
    private func reconnect(_ p: CBPeripheral) {
        guard p == lamp else { return }
        connected = false; tx = nil; queue = []; unanswered = nil; needsSync = false
        status = "Reconnecting to \(p.name ?? "lamp")…"
        central.connect(p)
    }

    /// Drops the remembered lamp and goes back to looking.
    func forget(keepStatus: Bool = false) {
        let old = lamp
        lamp = nil; tx = nil; connected = false; queue = []
        UserDefaults.standard.removeObject(forKey: savedLamp)
        if let old { central.cancelPeripheralConnection(old) }
        let message = status
        findLamp()
        if keepStatus { status = message }
    }

    // MARK: Status from the lamp

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let r = c.value.map([UInt8].init), r.count > 10 else { return }
        NSLog("heard: %@", hex(r))
        unanswered = nil; silences = 0
        switch r[8] {
        case 0: central.cancelPeripheralConnection(p) // lamp says it is shutting down; it needs a new connection to listen again
        case 1: // white light
            whiteOn = r[9] == 1
            if r[10] > 0 { whiteLevel = Double(r[10]) / 100 }
        case 2 where r.count > 16: // mood light
            moodOn = r[9] == 1
            if r[10] > 0 { moodLevel = Double(r[10]) / 100 }
            if moodOn { effect = min(Int(r[16]), effects.count - 1) }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            NSColor(srgbRed: CGFloat(r[13]) / 255, green: CGFloat(r[14]) / 255, blue: CGFloat(r[15]) / 255, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            if b > 0 { hue = h; saturation = s }
        case 255: whiteOn = false; moodOn = false // lamp switched off
        default: break
        }
    }
}

// MARK: - Views

let daylight = Color(red: 1, green: 0.80, blue: 0.42)
let panelSize = CGSize(width: 300, height: 474)

struct Widget: View {
    @EnvironmentObject var lamp: Lamp
    private var glow: Color? { lamp.moodOn ? lamp.color : lamp.whiteOn ? daylight : nil }

    var body: some View {
        VStack(spacing: 12) {
            Header(glow: glow)
            if lamp.connected {
                Presets()
                Card(icon: "sun.max.fill", title: "White light", tint: daylight,
                     isOn: Binding(get: { lamp.whiteOn }, set: { lamp.setWhite(on: $0) })) {
                    LevelSlider(label: "White brightness", value: lamp.whiteLevel, tint: daylight) { lamp.setWhite(level: $0) }
                }
                Card(icon: "sparkles", title: "Mood light", tint: lamp.color,
                     isOn: Binding(get: { lamp.moodOn }, set: { lamp.setMood(on: $0) })) {
                    ColorPad(hue: lamp.hue, saturation: lamp.saturation) { lamp.setColor(hue: $0, saturation: $1) }
                    LevelSlider(label: "Mood brightness", value: lamp.moodLevel, tint: lamp.color) { lamp.setMood(level: $0) }
                    EffectChips()
                }
            } else {
                LampFinder()
            }
        }
        .padding(14)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .top)
        .background(alignment: .top) { // the lamp's light spilling in from the top edge
            let g = glow ?? .clear
            RadialGradient(colors: [g.opacity(0.75), g.opacity(0.3), g.opacity(0)], center: .top, startRadius: 0, endRadius: 210)
                .frame(height: 210)
                .opacity(0.35 + 0.5 * (lamp.moodOn ? lamp.moodLevel : lamp.whiteLevel))
        }
        .background(Color.black.opacity(0.42))
        .background(Glass())
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.25), value: lamp.connected)
        .animation(.easeOut(duration: 0.25), value: glow)
    }
}

struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct Header: View {
    @EnvironmentObject var lamp: Lamp
    let glow: Color?
    @State private var grab: (mouse: NSPoint, origin: NSPoint)?

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(glow ?? Color.white.opacity(0.14))
                .frame(width: 30, height: 30)
                .shadow(color: (glow ?? .clear).opacity(0.9), radius: 9)
                .overlay(Image(systemName: glow == nil ? "lightbulb" : "lightbulb.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(glow == nil ? Color.white.opacity(0.6) : Color.black.opacity(0.6)))
            VStack(alignment: .leading, spacing: 1) {
                Text("TL100 Remote").font(.system(size: 14, weight: .semibold))
                Text(lamp.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Hand & music modes…") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Applications/TL100 Remote Web.app")) }
                Button("Choose another lamp") { lamp.forget() }
                Divider()
                Button("Hide") { panel?.orderOut(nil) }
                Button("Quit TL100 Remote") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).frame(width: 26, height: 26)
                    .background(.white.opacity(0.10), in: Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More")
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2).onChanged { _ in // drag the header to move the panel
            guard let panel else { return }
            let mouse = NSEvent.mouseLocation
            let start = grab ?? (mouse, panel.frame.origin)
            grab = start
            panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
        }.onEnded { _ in
            grab = nil
            panel?.saveFrame(usingName: "widget")
        })
    }

    private var panel: NSPanel? { (NSApp.delegate as? AppDelegate)?.panel }
}

struct Card<Content: View>: View {
    let icon: String, title: String, tint: Color
    @Binding var isOn: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isOn) {
                HStack(spacing: 7) {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(isOn ? tint : Color.secondary).frame(width: 16)
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
            }
            .toggleStyle(SwitchStyle(tint: tint))
            content().opacity(isOn ? 1 : 0.5)
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SwitchStyle: ToggleStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Capsule().fill(configuration.isOn ? tint : Color.white.opacity(0.16))
                .frame(width: 38, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).overlay(Circle().strokeBorder(.black.opacity(0.18)))
                        .padding(2).shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

/// A fat capsule slider, 1...100 %. Dragging anywhere on it sets the level.
struct LevelSlider: View {
    let label: String, value: Double, tint: Color
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule().fill(tint).frame(width: max(28, geo.size.width * value))
                    Image(systemName: value > 0.5 ? "sun.max.fill" : "sun.min.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.6)).frame(width: 28)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { onChange(min(1, max(0.01, $0.location.x / geo.size.width))) })
            }
            .frame(height: 28)
            Text("\(Int((value * 100).rounded()))%").font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { onChange(min(1, max(0.01, value + ($0 == .increment ? 0.1 : -0.1)))) }
    }
}

/// Hue runs left to right, saturation fades to white towards the bottom.
struct ColorPad: View {
    let hue: Double, saturation: Double
    let onChange: (Double, Double) -> Void
    private let knob = 22.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - knob, h = geo.size.height - knob // the knob's centre stays inside the pad
            ZStack {
                LinearGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }, startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                Circle().fill(Color(hue: hue, saturation: saturation, brightness: 1))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .offset(x: hue * w, y: (1 - saturation) * h)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                onChange(min(1, max(0, ($0.location.x - knob / 2) / w)), 1 - min(1, max(0, ($0.location.y - knob / 2) / h)))
            })
        }
        .frame(height: 124)
        .accessibilityElement()
        .accessibilityLabel("Colour")
        .accessibilityValue("Hue \(Int(hue * 360)) degrees")
        .accessibilityAdjustableAction { onChange((hue + ($0 == .increment ? 0.05 : 0.95)).truncatingRemainder(dividingBy: 1), saturation) }
    }
}

struct EffectChips: View {
    @EnvironmentObject var lamp: Lamp
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(effects.indices, id: \.self) { i in
                    Button { lamp.setEffect(i) } label: {
                        Text(effects[i]).font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(lamp.effect == i ? Color.black : Color.white.opacity(0.85))
                            .background(lamp.effect == i ? Color.white : Color.white.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(lamp.effect == i ? .isSelected : [])
                }
            }
            .padding(.trailing, 24)
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)) // hints that the row scrolls
    }
}

/// A row of saved lights. Click one to apply it, + to save what the lamp is showing now, right-click to delete.
struct Presets: View {
    @EnvironmentObject var lamp: Lamp
    var body: some View {
        HStack(spacing: 8) {
            if lamp.presets.isEmpty {
                Text("Save this light as a preset").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 3)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(lamp.presets) { preset in
                            Button { lamp.apply(preset) } label: { Swatch(preset: preset, active: lamp.current?.matches(preset) == true) }
                                .buttonStyle(.plain)
                                .help("\(preset.title). Right-click to delete.")
                                .accessibilityLabel("Preset: \(preset.title)")
                                .accessibilityAction(named: "Delete preset") { lamp.deletePreset(preset) }
                                .contextMenu { Button("Delete preset") { lamp.deletePreset(preset) } }
                        }
                    }
                    .padding(3) // room for the active ring
                }
            }
            Button { lamp.savePreset() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
                    .background(.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(lamp.current == nil)
            .opacity(lamp.current == nil ? 0.4 : 1)
            .help("Save the current light as a preset")
            .accessibilityLabel("Save the current light as a preset")
        }
        .padding(.leading, 9).padding(.trailing, 12).padding(.vertical, 6)
        .frame(height: 44)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A preset as a dot of its own light: dimmer presets look dimmer, effects are a colour wheel, white carries a sun.
struct Swatch: View {
    let preset: Preset, active: Bool
    var body: some View {
        let dim = 0.35 + 0.65 * preset.level
        ZStack {
            if !preset.mood {
                Circle().fill(daylight.opacity(dim))
                Image(systemName: "sun.max.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black.opacity(0.55))
            } else if preset.effect == 0 {
                Circle().fill(Color(hue: preset.hue, saturation: preset.saturation, brightness: 1).opacity(dim))
            } else {
                Circle().fill(AngularGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 0.9, brightness: 1) }, center: .center)).opacity(dim)
            }
        }
        .frame(width: 26, height: 26)
        .overlay(Circle().strokeBorder(.white.opacity(0.22)))
        .padding(3)
        .overlay(Circle().strokeBorder(.white, lineWidth: active ? 2 : 0))
        .padding(-3)
        .contentShape(Circle())
    }
}

/// Shown until a lamp is connected: a spinner, or a one-time "which one is yours?" list.
struct LampFinder: View {
    @EnvironmentObject var lamp: Lamp
    var body: some View {
        VStack(spacing: 10) {
            if lamp.nearby.isEmpty {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Make sure the lamp is plugged in and the phone app is closed.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                Spacer()
            } else {
                Text("Which one is your lamp?").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(lamp.nearby) { found in
                            Button { lamp.choose(found.id) } label: {
                                HStack {
                                    Text(found.name).font(.system(size: 13))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppIcon: View { // 1024 pt canvas, artwork on the standard 824 pt rounded square
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
            Circle().fill(AngularGradient(colors: [.pink, .purple, .blue, .teal, .orange, .pink], center: .center))
                .frame(width: 560, height: 560).blur(radius: 70)
            Circle().fill(RadialGradient(colors: [.white, Color(red: 1, green: 0.93, blue: 0.8), Color(red: 1, green: 0.85, blue: 0.6).opacity(0)],
                                         center: .center, startRadius: 40, endRadius: 210))
                .frame(width: 420, height: 420)
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous))
        .frame(width: 1024, height: 1024)
    }
}

// MARK: - App

final class Panel: NSPanel { override var canBecomeKey: Bool { true } }
final class ClickThroughHost<V: View>: NSHostingView<V> { // act on the first click even though the panel isn't key
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let lamp = Lamp()
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = Panel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = ClickThroughHost(rootView: Widget().environmentObject(lamp))
        if panel.setFrameUsingName("widget") { // the remembered frame may be an older size: keep its top-left corner
            let old = panel.frame
            panel.setFrame(NSRect(x: old.minX, y: old.maxY - panelSize.height, width: panelSize.width, height: panelSize.height), display: false)
        } else if let screen = NSScreen.main?.visibleFrame { // first run: top right corner
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panelSize.width - 20, y: screen.maxY - panelSize.height - 20))
        }
        lamp.start()
        show()
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool { // launched again = toggle
        if panel.isVisible { panel.orderOut(nil); NSLog("hidden") } else { show() }
        return false
    }

    private func show() {
        panel.orderFrontRegardless()
        lamp.refresh()
        NSLog("shown")
    }
}

@MainActor func render<V: View>(_ view: V, size: CGSize, to path: String) {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

@main enum Main {
    @MainActor static func main() {
        selfCheck()
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--icon") {
            let image = ImageRenderer(content: AppIcon()).cgImage!
            try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
        } else if let i = args.firstIndex(of: "--snapshot") {
            let lamp = Lamp()
            if args.last == "finder" {
                lamp.status = "Looking for your lamp…"
                lamp.nearby = ["TL100-8842", "WH-1000XM3", "Kitchen speaker"].map { Found(id: UUID(), name: $0) }
            } else {
                lamp.connected = true; lamp.status = "TL100-8842"
                lamp.whiteOn = false; lamp.moodOn = true; lamp.hue = 0.83; lamp.saturation = 0.75; lamp.moodLevel = 0.7
                lamp.presets = args.last == "empty" ? [] : [
                    Preset(mood: false, level: 1), Preset(mood: false, level: 0.3),
                    Preset(mood: true, level: 0.7, hue: 0.83, saturation: 0.75), Preset(mood: true, level: 0.9, hue: 0.05, saturation: 1),
                    Preset(mood: true, level: 0.4, hue: 0.6, saturation: 0.8), Preset(mood: true, level: 0.8, effect: 2),
                ]
            }
            render(Widget().environmentObject(lamp).background(Color(white: 0.2)), size: panelSize, to: args[i + 1])
        } else if let i = args.firstIndex(of: "--probe") {
            let lamp = Lamp()
            lamp.probing = true
            lamp.probe = args[i + 1].split(separator: ",").map { $0.split(separator: " ").compactMap { UInt8($0, radix: 16) } }
            lamp.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { NSLog("probe: timed out"); exit(1) }
            app.setActivationPolicy(.accessory)
            app.run()
        } else {
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
