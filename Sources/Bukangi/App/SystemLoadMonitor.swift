import Foundation

/// Samples overall CPU load every couple of seconds and reports when the Mac stays busy.
final class SystemLoadMonitor {
    /// Called with `true` when the Mac has been busy for a while, `false` once it calms down.
    var onChange: ((Bool) -> Void)?
    private(set) var isBusy = false
    /// Most recent overall CPU load, 0...1.
    private(set) var load = 0.0

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var busyStreak = 0

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTicks = nil
    }

    private func sample() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let t = info.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        let total = busy + UInt64(t.2)
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return }
        let load = Double(busy - last.busy) / Double(total - last.total)
        self.load = load

        busyStreak = load > 0.70 ? busyStreak + 1 : 0
        var next = isBusy
        if !isBusy && busyStreak >= 2 { next = true }
        if isBusy && load < 0.45 { next = false }
        guard next != isBusy else { return }
        isBusy = next
        onChange?(next)
    }
}
