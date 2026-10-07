import Foundation

/// Runs blocking work (libmongoc calls, ssh startup) on GCD so it never parks a thread of Swift's cooperative pool.
nonisolated enum Blocking {
    private static let queue = DispatchQueue(label: "robo-tribute.blocking", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable, E: Error>(_ work: @escaping @Sendable () throws(E) -> T) async throws(E) -> T {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, E>, Never>) in
            queue.async { continuation.resume(returning: Result(catching: work)) }
        }
        return try result.get()
    }

    static func detach(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}
