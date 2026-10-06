import Foundation

#if !compiler(>=5.9)
// Swift 5.8 (the Command Line Tools toolchain scripts/build-local.sh uses) predates
// MainActor.assumeIsolated. Callers only use it from main-thread run-loop callbacks.
extension MainActor {
    static func assumeIsolated<T>(_ operation: @MainActor () throws -> T) rethrows -> T {
        precondition(Thread.isMainThread, "MainActor.assumeIsolated called off the main thread")
        return try withoutActuallyEscaping(operation) { operation in
            try unsafeBitCast(operation, to: (() throws -> T).self)()
        }
    }
}
#endif
