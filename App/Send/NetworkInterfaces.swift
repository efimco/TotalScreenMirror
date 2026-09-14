import Foundation

/// Enumerates the device's own IPv4 addresses so the send screen can tell you which URL
/// to open on the monitoring device.
///
/// The app works this out itself rather than asking the extension: both run on the same
/// device and see the same interfaces, which sidesteps needing an App Group to pass the
/// value across — a paid-account capability this project deliberately avoids.
enum NetworkInterfaces {
    struct Address: Identifiable, Hashable {
        let interface: String
        let ip: String
        var id: String { interface + ip }

        /// Personal Hotspot puts the phone at 172.20.10.1 on `bridge100`; a joined Wi-Fi
        /// network shows up on `en0`. Both are worth offering, but hotspot is the one
        /// people reach for on location where there is no network to join.
        var label: String {
            switch interface {
            case "bridge100", "bridge101": return "Personal Hotspot"
            case "en0": return "Wi-Fi"
            case "en1", "en2": return "Ethernet"
            default: return interface
            }
        }

        var isHotspot: Bool { interface.hasPrefix("bridge") }
    }

    static func current() -> [Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var results: [Address] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            let name = String(cString: pointer.pointee.ifa_name)
            let ip = String(cString: buffer)
            // Skip link-local self-assigned addresses; nothing can route to them usefully.
            guard !ip.hasPrefix("169.254."), !ip.isEmpty else { continue }
            results.append(Address(interface: name, ip: ip))
        }

        // Hotspot first, then Wi-Fi, then anything else — matching how likely each is to
        // be the one you actually want on a shoot.
        return results.sorted { lhs, rhs in
            func rank(_ address: Address) -> Int {
                if address.isHotspot { return 0 }
                if address.interface == "en0" { return 1 }
                return 2
            }
            return rank(lhs) == rank(rhs) ? lhs.ip < rhs.ip : rank(lhs) < rank(rhs)
        }
    }
}
