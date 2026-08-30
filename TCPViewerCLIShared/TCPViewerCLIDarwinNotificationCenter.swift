//
//  TCPViewerCLIDarwinNotificationCenter.swift
//  TCPViewer
//
//  Created by Proxyman LLC on 30/8/26.
//

import Foundation

enum TCPViewerCLINotificationName {
    static let request = "com.proxyman.tcpviewer.cli.request"
    static let response = "com.proxyman.tcpviewer.cli.response"
}
protocol TCPViewerCLINotificationObserving: AnyObject {}

protocol TCPViewerCLINotificationCentering {
    func post(_ name: String)
    func observe(_ name: String, handler: @escaping () -> Void) -> any TCPViewerCLINotificationObserving
}

final class TCPViewerCLIDarwinNotificationCenter: TCPViewerCLINotificationCentering {
    static let shared = TCPViewerCLIDarwinNotificationCenter()

    func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    func observe(_ name: String, handler: @escaping () -> Void) -> any TCPViewerCLINotificationObserving {
        TCPViewerCLIDarwinObserver(name: name, handler: handler)
    }
}

private final class TCPViewerCLIDarwinObserver: TCPViewerCLINotificationObserving {
    private let name: String
    private let handler: () -> Void

    init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let instance = Unmanaged<TCPViewerCLIDarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                instance.handler()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }
}
