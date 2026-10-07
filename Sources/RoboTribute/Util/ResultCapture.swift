import Foundation

nonisolated extension Result where Failure == any Error {
    /// Xcode 26's standard library has no async `Result(catching:)`.
    static func capture(_ body: () async throws -> Success) async -> Result {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}
