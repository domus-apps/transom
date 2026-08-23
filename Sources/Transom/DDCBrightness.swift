import AppKit
import IOKit

/* DDC/CI brightness for external monitors DisplayServices can't control
   (Dell, LG, BenQ, … — anything that isn't an Apple-class display).

   Apple silicon path: each connected external display is driven by a DCP
   coprocessor that exposes a `DCPAVServiceProxy` in the IORegistry; the
   private IOAVService API (exported by IOKit) opens an I2C channel through
   it, over which the monitor speaks DDC/CI (packet framing in DDCPacket).

   Mapping a CGDirectDisplayID to its proxy takes two hops, both keyed by
   the framebuffer name ("dispext0", …):

     CG display ──vendor/product/serial──▶ IOMobileFramebufferShim
                                           (IONameMatched = "dispext0,…")
     framebuffer name ──proxy's parent "dispext0:dcpav-service-epic:0"──▶
                                           DCPAVServiceProxy (External)

   EDID-UUID matching would be simpler but doesn't hold on current macOS:
   CGDisplayCreateUUIDFromDisplayID no longer returns the EDID-derived UUID
   the registry carries, so the product attributes are the join key.

   All symbols resolve via dlsym and every step degrades to "can't control",
   mirroring BrightnessController's DisplayServices handling. Intel Macs
   have no IOAVService (they'd need IOFramebuffer I2C) and fall out at
   symbol resolution. */
final class DDCBrightness {
    private typealias CreateServiceFn = @convention(c) (
        CFAllocator?, io_service_t
    ) -> Unmanaged<CFTypeRef>?
    /* Shared by IOAVServiceReadI2C / IOAVServiceWriteI2C:
       (service, chipAddress, dataAddress, buffer, length). */
    private typealias TransferI2CFn = @convention(c) (
        CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32
    ) -> IOReturn

    private let createService: CreateServiceFn?
    private let readI2C: TransferI2CFn?
    private let writeI2C: TransferI2CFn?

    private struct State {
        let service: CFTypeRef
        let maxValue: UInt16
        /* Last value we read or wrote, in 0...1 — the working value between
           keypresses, so autorepeat doesn't pay a ~40ms DDC read per tick. */
        var normalized: Float
        var lastTouched: TimeInterval
    }
    /* Nested optional on purpose: a missing key means "never probed", a
       stored nil means "probed, not controllable" — probing costs a DDC
       round-trip, so negative results must be cached too. */
    private var states: [CGDirectDisplayID: State?] = [:]

    /* The monitor's own buttons (or another app) can move brightness behind
       our back; re-read before stepping when the cache hasn't been touched
       for a while. Within a keypress burst the cache is authoritative. */
    private let staleAfter: TimeInterval = 10

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: T.self)
        }
        createService = symbol("IOAVServiceCreateWithService", as: CreateServiceFn.self)
        readI2C = symbol("IOAVServiceReadI2C", as: TransferI2CFn.self)
        writeI2C = symbol("IOAVServiceWriteI2C", as: TransferI2CFn.self)
        if createService == nil {
            NSLog("Transom: IOAVService unavailable — DDC/CI displays will pass through")
        }

        /* Display IDs and framebuffer assignments shuffle on plug/unplug
           and sleep/wake; drop everything and re-probe lazily. */
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.states.removeAll()
        }
    }

    func canControl(_ display: CGDirectDisplayID) -> Bool {
        ensureState(display) != nil
    }

    /* One tick up or down, same contract as BrightnessController.step. */
    @discardableResult
    func step(_ display: CGDirectDisplayID, delta: Int, fine: Bool) -> Float? {
        guard var state = ensureState(display) else { return nil }

        let now = ProcessInfo.processInfo.systemUptime
        if now - state.lastTouched > staleAfter,
            let fresh = readLuminance(state.service) {
            state.normalized = Float(fresh.current) / Float(state.maxValue)
        }

        let steps = fine ? BrightnessMath.fineSteps : BrightnessMath.coarseSteps
        let next = BrightnessMath.stepped(from: state.normalized, delta: delta, steps: steps)
        guard writeLuminance(state.service, UInt16((next * Float(state.maxValue)).rounded()))
        else { return nil }
        state.normalized = next
        state.lastTouched = now
        states[display] = state
        return next
    }

    // MARK: - Probing

    private func ensureState(_ display: CGDirectDisplayID) -> State? {
        if let cached = states[display] { return cached }
        let probed = probe(display)
        states[display] = probed
        return probed
    }

    /* Resolves the display's AV service and proves DDC works with a real
       luminance read (plenty of externals — TVs, some hubs — expose the
       proxy but not DDC). Blocks the main thread for a few dozen ms in the
       worst case; runs once per display per configuration. */
    private func probe(_ display: CGDirectDisplayID) -> State? {
        guard
            CGDisplayIsBuiltin(display) == 0,
            let framebuffer = framebufferName(for: display),
            let service = avService(forFramebuffer: framebuffer),
            let (current, maxValue) = readLuminance(service),
            maxValue > 0
        else { return nil }
        return State(
            service: service,
            maxValue: maxValue,
            normalized: Float(current) / Float(maxValue),
            lastTouched: ProcessInfo.processInfo.systemUptime
        )
    }

    // MARK: - Registry matching

    private struct Panel {
        let framebuffer: String
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    /* Framebuffer name ("dispext0") for the display, via the shim whose
       panel attributes match the display's identity. */
    private func framebufferName(for display: CGDirectDisplayID) -> String? {
        let vendor = CGDisplayVendorNumber(display)
        let product = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)

        let candidates = panels()
            .filter {
                $0.vendor == vendor && $0.product == product
                    && (serial == 0 || $0.serial == 0 || $0.serial == serial)
            }
            .sorted { $0.framebuffer < $1.framebuffer }
        if candidates.count <= 1 { return candidates.first?.framebuffer }

        /* Several identical monitors (twins often share a serial, or report
           none): pair the Nth twin display with the Nth twin panel, both in
           stable order. */
        let twins = onlineDisplays()
            .filter {
                CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == product
            }
            .sorted()
        guard
            let rank = twins.firstIndex(of: display),
            rank < candidates.count
        else { return nil }
        return candidates[rank].framebuffer
    }

    private func panels() -> [Panel] {
        var found: [Panel] = []
        /* IOMobileFramebufferShim on current macOS; AppleCLCD2 was the
           class carrying DisplayAttributes on earlier releases. */
        for className in ["IOMobileFramebufferShim", "AppleCLCD2"] {
            forEachService(matching: className) { service in
                guard
                    let matched = property(service, "IONameMatched") as? String,
                    let attributes = property(service, "DisplayAttributes") as? [String: Any],
                    let product = attributes["ProductAttributes"] as? [String: Any]
                else { return }
                let framebuffer = String(matched.prefix(while: { $0 != "," }))
                guard !found.contains(where: { $0.framebuffer == framebuffer }) else { return }
                found.append(
                    Panel(
                        framebuffer: framebuffer,
                        vendor: (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0,
                        product: (product["ProductID"] as? NSNumber)?.uint32Value ?? 0,
                        serial: (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
                    ))
            }
        }
        return found
    }

    private func avService(forFramebuffer framebuffer: String) -> CFTypeRef? {
        guard let createService else { return nil }
        var found: CFTypeRef?
        forEachService(matching: "DCPAVServiceProxy") { service in
            guard
                found == nil,
                property(service, "Location") as? String == "External",
                framebufferName(ofProxy: service) == framebuffer
            else { return }
            found = createService(kCFAllocatorDefault, service)?.takeRetainedValue()
        }
        return found
    }

    /* The proxy's framebuffer, read off its ancestry: the enclosing DCP
       endpoint is named "dispext0:dcpav-service-epic:0"; failing that, the
       owning DCP device ("dcpext0", or "dcp" for the embedded panel) maps
       to the framebuffer name directly. */
    private func framebufferName(ofProxy proxy: io_service_t) -> String? {
        var entry = proxy
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<8 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            else { return nil }
            IOObjectRelease(entry)
            entry = parent

            var buffer = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { continue }
            let name = String(cString: buffer)
            if name.hasPrefix("disp"), let colon = name.firstIndex(of: ":") {
                return String(name[..<colon])
            }
            if name == "dcp" { return "disp0" }
            if name.hasPrefix("dcpext") { return "dispext" + name.dropFirst("dcpext".count) }
        }
        return nil
    }

    // MARK: - DDC transactions

    private func readLuminance(_ service: CFTypeRef) -> (current: UInt16, max: UInt16)? {
        guard let readI2C, let writeI2C else { return nil }
        var request = DDCPacket.getVCPRequest(DDCPacket.luminance)
        /* The spec allows the monitor 40ms to prepare a reply; slow firmware
           misses even that, hence the retries. */
        for attempt in 0..<3 {
            if attempt > 0 { usleep(20_000) }
            guard
                writeI2C(
                    service, DDCPacket.displayChipAddress, DDCPacket.hostDataAddress,
                    &request, UInt32(request.count)) == KERN_SUCCESS
            else { continue }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard
                readI2C(
                    service, DDCPacket.displayChipAddress, DDCPacket.hostDataAddress,
                    &reply, UInt32(reply.count)) == KERN_SUCCESS
            else { continue }
            if let parsed = DDCPacket.parseVCPReply(reply, code: DDCPacket.luminance) {
                return parsed
            }
        }
        return nil
    }

    private func writeLuminance(_ service: CFTypeRef, _ value: UInt16) -> Bool {
        guard let writeI2C else { return false }
        var request = DDCPacket.setVCPRequest(DDCPacket.luminance, value: value)
        return writeI2C(
            service, DDCPacket.displayChipAddress, DDCPacket.hostDataAddress,
            &request, UInt32(request.count)) == KERN_SUCCESS
    }

    // MARK: - IOKit helpers

    private func forEachService(matching className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            body(service)
        }
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
