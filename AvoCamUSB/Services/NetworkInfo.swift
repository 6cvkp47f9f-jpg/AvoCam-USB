//
//  NetworkInfo.swift
//  AvoCamUSB
//
//  局域网网络信息 - 获取 iPhone 的 IP 地址，用于 WiFi 推流地址显示
//

import Foundation

/// 局域网网络信息
enum NetworkInfo {

    /// 获取所有 IPv4 地址（排除回环地址 127.0.0.1）
    static func ipv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = pointer {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let ip = String(cString: host)
                    if !ip.isEmpty && ip != "127.0.0.1" {
                        addresses.append(ip)
                    }
                }
            }
            pointer = interface.ifa_next
        }

        return addresses
    }

    /// 获取最可能的 WiFi IP（优先 en0 接口，其次任意非回环地址）
    static func wifiIP() -> String? {
        var en0IP: String?
        var fallbackIP: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = pointer {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == sa_family_t(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1" {
                        let name = String(cString: interface.ifa_name)
                        if name == "en0" {
                            en0IP = ip
                        } else if fallbackIP == nil {
                            fallbackIP = ip
                        }
                    }
                }
            }
            pointer = interface.ifa_next
        }

        return en0IP ?? fallbackIP
    }
}
