//
//  CachePersistence.swift
//  SourceArchitecture
//
//  Copyright (c) 2022 Daniel Hall
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif


// A type to describe how an item should be cached (expiration time, retention policy, etc.)
public struct CacheDescriptor {

    public enum CacheRetentionPolicy: Comparable {
        case discardFirst
        case discardUnderMemoryPressure
        case discardLast
        case discardNever
    }

    let key: String
    let retentionPolicy: CacheRetentionPolicy
    let expireAfter: TimeInterval?
    public init(key: String, expireAfter: TimeInterval? = nil, retentionPolicy: CacheRetentionPolicy = .discardUnderMemoryPressure) {
        self.key = key
        self.expireAfter = expireAfter
        self.retentionPolicy = retentionPolicy
    }
}

/// A protocol that includes possible generic options for configuring CachePersistence
public protocol CachePersistenceOptions { }

/// An option that allows the CachePersistence to be configured with a maximum size
public struct WithMaxSize: CachePersistenceOptions {
    fileprivate let maxSize: Int
}

/// A protocol that must be adopted by any values that will be stored in a CachePersistence configured with a maximum size. The protocol reports the size (in bytes) of the value
public protocol CacheSizeRepresentable {
    var cacheSize: Int { get }
}

/// An option that allows the CachePersistence to be configured with a maximum number of cached items
public struct WithMaxCount: CachePersistenceOptions {
    fileprivate let maxCount: Int
}

/// An option that allows the CachePersistence to be configured with a maximum size and a maximum number of cached items
public struct WithMaxSizeAndMaxCount: CachePersistenceOptions {
    fileprivate let maxSize: Int
    fileprivate let maxCount: Int
}

/// An option that specifies that a CachePersistence should have no limits to the size it occupies or number of items. It will still respond to low memory notifications however.
public struct Unbounded: CachePersistenceOptions { }



/// A Source-based implementation of caching that can optionally flush items to keep within a count or size limit
public class CachePersistence<Options: CachePersistenceOptions> {
    private let _lock = NSRecursiveLock()
    private var _dictionary = [String: Source<CachedItem>]()
    private var _maxCount: Int?
    private var _maxSize: Int?
    private var _currentSize: Int {
        _lock.lock()
        defer { _lock.unlock() }
        return _dictionary.reduce(0) { $0 + ($1.value.model.size ?? 0) }
    }

    private var _currentCount: Int {
        _dictionary.filter { !$0.value.model.isEmpty }.count
    }

    // Sort in order of which items should be flushed first (empty, expired, lower priority, older)
    private var sortedItems: [(key: String, value: Source<CachedItem>)] {
        _dictionary = _dictionary.filter { !($0.value.model.isEmpty && $0.value.model.retentionPolicy != .discardNever) }
        return _dictionary
            .filter { !$0.value.model.isEmpty }
            .sorted {
                ($0.1.model.isExpired() && !$1.1.model.isExpired() )
                || ($0.1.model.isExpired() && $1.1.model.isExpired() )
                || ($0.1.model.retentionPolicy < $1.1.model.retentionPolicy && !$1.1.model.isExpired())
                || ($0.1.model.retentionPolicy == $1.1.model.retentionPolicy && !$1.1.model.isExpired() && $0.1.model.dateLastSet < $1.1.model.dateLastSet )
            }
    }

    private var adjustmentWorkItem: DispatchWorkItem?

    public init(_ options: Options) {
        switch options {
        case let options as WithMaxSize:
            _maxSize = options.maxSize
        case let options as WithMaxSizeAndMaxCount:
            _maxSize = options.maxSize
            _maxCount = options.maxCount
        case let options as WithMaxCount:
            _maxCount = options.maxCount
        default: break
        }
        #if canImport(UIKit)
            NotificationCenter.default.addObserver(self, selector: #selector(handleLowMemory), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #endif
    }

    private func adjustCount() {
        _lock.lock()
        defer { _lock.unlock() }
        var currentCount = _currentCount
        guard let maxCount = _maxCount, currentCount > maxCount else { return }
        var sorted = sortedItems
        while currentCount > maxCount, sorted.count > 0 {
            let next = sorted.removeFirst()
            _dictionary[next.key] = nil
            currentCount -= 1
        }
    }

    private func adjustSize() {
        _lock.lock()
        defer { _lock.unlock() }
        var currentSize = _currentSize
        guard let maxSize = _maxSize, currentSize > maxSize else {
            return
        }
        var sorted = sortedItems
        while currentSize > maxSize, sorted.count > 0 {
            let next = sorted.removeFirst()
            let size = next.value.model.size ?? 0
            _dictionary[next.key] = nil
            currentSize -= size
        }
    }

    // If low memory, discard all items of lower priority
    @objc private func handleLowMemory() {
        _lock.lock()
        sortedItems.prefix { $0.value.model.retentionPolicy <= .discardUnderMemoryPressure }.forEach { _dictionary[$0.key] = nil }
        _lock.unlock()
    }

    private func retrieve(_ descriptor: CacheDescriptor) -> Source<CachedItem> {
        _lock.lock()
        defer {
            _lock.unlock()
        }
        if _dictionary[descriptor.key] == nil {
            _dictionary[descriptor.key] = CachePersistenceSource { [weak self] in
                self?._lock.lock()
                self?.adjustmentWorkItem?.cancel()
                let workItem = DispatchWorkItem {
                    self?.adjustCount()
                    self?.adjustSize()
                }
                self?.adjustmentWorkItem = workItem
                self?._lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15, execute: workItem)
            }.eraseToSource()
        }
        return _dictionary[descriptor.key]!
    }
}


// MARK: - CachePersistence Configuration-Based Extensions -

public extension CachePersistence where Options == WithMaxSize {
    var maxSize: Int {
        get { _maxSize ?? 0 }
        set {
            _maxSize = newValue
            adjustSize()
        }
    }

    var currentSize: Int {
        get { _currentSize }
    }

    func persistableSource<Value: CacheSizeRepresentable>(for descriptor: CacheDescriptor) -> Source<Persistable<Value>> {
        retrieve(descriptor).map { $0.asPersistable() }
    }
}


public extension CachePersistence where Options == WithMaxSizeAndMaxCount {
    var maxSize: Int {
        get { _maxSize ?? 0 }
        set {
            _maxSize = newValue
            adjustSize()
        }
    }

    var currentSize: Int {
        get { _currentSize }
    }

    var maxCount: Int {
        get { _maxCount ?? 0 }
        set {
            _maxCount = newValue
            adjustCount()
        }
    }

    var currentCount: Int {
        _currentCount
    }

    func persistableSource<Value: CacheSizeRepresentable>(for descriptor: CacheDescriptor) -> Source<Persistable<Value>> {
        retrieve(descriptor).map { $0.asPersistable() }
    }
}


public extension CachePersistence where Options == WithMaxCount {
    var maxCount: Int {
        get { _maxCount ?? 0 }
        set {
            _maxCount = newValue
            adjustCount()
        }
    }

    var currentCount: Int {
        _currentCount
    }

    func persistableSource<Value>(for descriptor: CacheDescriptor) -> Source<Persistable<Value>> {
        return retrieve(descriptor).map { $0.asPersistable() }
    }
}


public extension CachePersistence where Options == Unbounded {
    func persistableSource<Value>(for descriptor: CacheDescriptor) -> Source<Persistable<Value>> {
        retrieve(descriptor).map { $0.asPersistable() }
    }
}


// MARK: - CacheItem Model stored by CachePersistence Source -

private struct CachedItem {
    let value: Any?
    let isEmpty: Bool
    let size: Int?
    let retentionPolicy: CacheDescriptor.CacheRetentionPolicy
    let expireAfter: TimeInterval?
    let dateLastSet: Date
    let isExpired: () -> Bool
    let set: Action<CachedItem>
    let clear: Action<Void>
}

extension CachedItem {
    func asPersistable<Value>() -> Persistable<Value> {
        if let value = value as? Value, !isEmpty {
            return .found(.init(value: value, isExpired: isExpired, set: set.map {
                .init(value: $0, isEmpty: isEmpty, size: nil, retentionPolicy: retentionPolicy, expireAfter: expireAfter, dateLastSet: Date(), isExpired: isExpired, set: set, clear: clear)
            }, clear: clear))
        }
        return .notFound(.init(set: set.map { .init(value: $0, isEmpty: isEmpty, size: nil, retentionPolicy: retentionPolicy, expireAfter: expireAfter, dateLastSet: Date(), isExpired: isExpired, set: set, clear: clear) } ))
    }

    func asPersistable<Value: CacheSizeRepresentable>() -> Persistable<Value> {
        if let value = value as? Value, !isEmpty {
            return .found(.init(value: value, isExpired: isExpired, set: set.map {
                .init(value: $0, isEmpty: isEmpty, size: $0.cacheSize, retentionPolicy: retentionPolicy, expireAfter: expireAfter, dateLastSet: Date(), isExpired: isExpired, set: set, clear: clear)
            }, clear: clear))
        }
        return .notFound(.init(set: set.map { .init(value: $0, isEmpty: isEmpty, size: $0.cacheSize, retentionPolicy: retentionPolicy, expireAfter: expireAfter, dateLastSet: Date(), isExpired: isExpired, set: set, clear: clear) } ))
    }
}


// MARK: - CachePersistence Source -

/// The Source that manages each cached value. If multiple client sites are using the same Cached item, they will have a reference to the same Source and get updates when the value is changed elsewhere, etc.
fileprivate final class CachePersistenceSource: CustomSource {

    class Actions: ActionMethods {
        var set = ActionMethod(CachePersistenceSource.set)
        var clear = ActionMethod(CachePersistenceSource.clear)
    }

    class Threadsafe: ThreadsafeProperties {
        var expireWorkItem: DispatchWorkItem?
    }

    lazy var defaultModel = CachedItem(value: nil, isEmpty: true, size: nil, retentionPolicy: .discardUnderMemoryPressure, expireAfter: nil, dateLastSet: Date(), isExpired: { false }, set: actions.set, clear: actions.clear)
    let updateClosure: () -> Void

    init(updateClosure: @escaping () -> Void) {
        self.updateClosure = updateClosure
        updateClosure()
    }

    fileprivate func set(_ cachedItem: CachedItem) {
        if cachedItem.size != nil { updateClosure() }
        let cachedDate = Date()
        let isExpired = cachedItem.expireAfter.flatMap { expireAfter in
            threadsafe.expireWorkItem?.cancel()
            threadsafe.expireWorkItem = .init { [weak self] in
                guard let self = self else { return }
                self.model = .init(value: self.model.value, isEmpty: self.model.isEmpty, size: self.model.size, retentionPolicy: self.model.retentionPolicy, expireAfter: self.model.expireAfter, dateLastSet: Date(), isExpired: { true }, set: self.model.set, clear: self.model.clear)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + expireAfter, execute: threadsafe.expireWorkItem!)
            return { cachedDate.distance(to: Date()) < expireAfter }
        } ?? { false }

        model = .init(value: cachedItem.value, isEmpty: false, size: cachedItem.size, retentionPolicy: cachedItem.retentionPolicy, expireAfter: nil, dateLastSet: Date(), isExpired: isExpired, set: actions.set, clear: actions.clear)
    }

    fileprivate func clear() {
        updateClosure()
        model = .init(value: nil, isEmpty: true, size: nil, retentionPolicy: model.retentionPolicy, expireAfter: model.expireAfter, dateLastSet: Date(), isExpired: model.isExpired, set: model.set, clear: model.clear)
    }
}


// MARK: - Protocol Static Member Extensions -

public extension CachePersistenceOptions where Self == WithMaxSize {
    static func withMaxSize(_ maxSize: Int) -> WithMaxSize {
        .init(maxSize: maxSize)
    }
}

public extension CachePersistenceOptions where Self == WithMaxCount {
    static func withMaxCount(_ maxCount: Int) -> WithMaxCount {
        .init(maxCount: maxCount)
    }
}

public extension CachePersistenceOptions where Self == WithMaxSizeAndMaxCount {
    static func withMaxSizeAndMaxCount(size: Int, count: Int) -> WithMaxSizeAndMaxCount {
        .init(maxSize: size, maxCount: count)
    }
}

public extension CachePersistenceOptions where Self == Unbounded {
    static var unbounded: Unbounded {
        .init()
    }
}