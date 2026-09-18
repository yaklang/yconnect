import Foundation

// SwiftUI cancels page tasks and their URLSession requests when navigating away.
enum AsyncCancellation {
    static func isExpected(_ error: Error) -> Bool {
        let errorValue = error as NSError
        return error is CancellationError
            || (errorValue.domain == NSURLErrorDomain && errorValue.code == NSURLErrorCancelled)
    }
}
