//
//  UserDefaultsPersistence.swift
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


/// A basic implementation of UserDefaults-based persistence. Given a descriptor with a user defaults key, this can read and write to it. Note that this implementation uses a weak dictionary which will hold a shared instance of the user defaults data in memory as long as some client code is referencing it. When all references are released, the latest data will be written to file and released from memory. This optimization minimizes memory usage and synchronization requirements.
public class UserDefaultsPersistence {

    public struct Descriptor<Value> {

        public let key: String
        public let expireAfter: TimeInterval?
        public let decode: (Data) throws -> Value
        public let encode: (Value) throws -> Data

        public init(key: String, expireAfter: TimeInterval? = nil, encode: @escaping(Value) throws -> Data, decode: @escaping(Data) throws -> Value) {
            self.key = key
            self.expireAfter = expireAfter
            self.encode = encode
            self.decode = decode
        }
    }

    private let dictionary = WeakDictionary<String, AnyObject>()

    public init() { }

    public subscript<Value>(descriptor: Descriptor<Value>) -> Source<Persistable<Value>> {
        dictionary[descriptor.key] { UserDefaultsSource(descriptor: descriptor).eraseToSource() }
    }
}

private struct UserDefaultsRecord: Codable {
    let persistedDate: Date
    let data: Data
}

private final class UserDefaultsSource<Value>: SourceOf<Persistable<Value>> {

    @Action(UserDefaultsSource.set) private var setAction
    @Action(UserDefaultsSource.clear) private var clearAction
    @Threadsafe private var expiredWorkItem: DispatchWorkItem?

    fileprivate lazy var initialModel = Persistable<Value>.notFound(.init(set: setAction))
    private let descriptor: UserDefaultsPersistence.Descriptor<Value>

    fileprivate init(descriptor: UserDefaultsPersistence.Descriptor<Value>) {
        self.descriptor = descriptor
        super.init()
        if let data = UserDefaults.standard.data(forKey: descriptor.key) {
            do {
                let record = try JSONDecoder().decode(UserDefaultsRecord.self, from: data)
                var isExpired = { false }
                if let expireAfter = descriptor.expireAfter {
                    isExpired = { expireAfter < Date.timeIntervalSinceReferenceDate - record.persistedDate.timeIntervalSinceReferenceDate }
                    // If an expiration date is set, schedule an update at that time so that downstream subscribers are updated
                    let refreshTime = (record.persistedDate.timeIntervalSinceReferenceDate + expireAfter) - Date.timeIntervalSinceReferenceDate
                    if refreshTime > 0 {
                        let workItem = DispatchWorkItem { [weak self] in
                            guard let self = self else { return }
                            if case .found(let found) = self.model, found.isExpired {
                                self.model = .found(found)
                            }
                        }
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + refreshTime, execute: workItem)
                        expiredWorkItem = workItem
                    }
                }
                let value = try descriptor.decode(record.data)
                model = .found(.init(value: value, isExpired: isExpired, set: setAction, clear: clearAction))
            } catch {
                model = .notFound(.init(error: error, set: setAction))
            }
        } else {
            model = .notFound(.init(set: setAction))
        }
    }

    private func set(value: Value) {
        expiredWorkItem?.cancel()
        do {
            let record = try UserDefaultsRecord(persistedDate: Date(), data: descriptor.encode(value))
            let data = try JSONEncoder().encode(record)
            UserDefaults.standard.set(data, forKey: descriptor.key)
            var isExpired = { false }
            if let expireAfter = descriptor.expireAfter {
                isExpired = {
                    expireAfter < Date.timeIntervalSinceReferenceDate - record.persistedDate.timeIntervalSinceReferenceDate
                }
                // If an expiration date is set, schedule an update at that time so that downstream subscribers are updated
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    if case .found(let found) = self.model, found.isExpired {
                        self.model = .found(found)
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + expireAfter, execute: workItem)
                expiredWorkItem = workItem
            }
            model = .found(.init(value: value, isExpired: isExpired, set: setAction, clear: clearAction))
        } catch {
            model = .notFound(.init(error: error, set: setAction))
        }
    }

    private func clear() {
        expiredWorkItem?.cancel()
        UserDefaults.standard.removeObject(forKey: descriptor.key)
        model = .notFound(.init(set: setAction))
    }
}
