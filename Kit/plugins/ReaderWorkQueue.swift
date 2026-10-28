//
//  ReaderWorkQueue.swift
//  Kit
//
//  Copyright © 2026 Max Yu. All rights reserved.
//

import Foundation

/// Serializes synchronous reader work without making UI callers wait for it.
internal final class ReaderWorkQueue {
    private let queue = DispatchQueue(label: "eu.exelban.Stats.ReaderWork", qos: .utility)
    private let lock = NSLock()
    private var pending: (() -> Void)?
    private var scheduled = false

    func request(_ work: @escaping () -> Void) {
        self.lock.lock()
        self.pending = work
        let shouldSchedule = !self.scheduled
        self.scheduled = true
        self.lock.unlock()
        if shouldSchedule {
            self.queue.async { self.drain() }
        }
    }

    /// Running OS calls finish normally; queued refreshes are discarded.
    func cancelPending() {
        self.lock.lock()
        self.pending = nil
        self.lock.unlock()
    }

    private func drain() {
        while true {
            self.lock.lock()
            guard let work = self.pending else {
                self.scheduled = false
                self.lock.unlock()
                return
            }
            self.pending = nil
            self.lock.unlock()
            autoreleasepool { work() }
        }
    }
}
