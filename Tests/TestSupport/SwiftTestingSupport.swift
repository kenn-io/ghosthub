import Testing

/// Asserts that `body` throws an error equal to `expected`.
public func expectThrowsEqual<E: Error & Equatable, T>(
    _ expected: E,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> T
) {
    do {
        _ = try body()
        Issue.record(
            "Expected \(expected) to be thrown.",
            sourceLocation: sourceLocation
        )
    } catch let error as E {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record(
            "Expected \(expected) to be thrown, got \(error).",
            sourceLocation: sourceLocation
        )
    }
}

/// Async variant: asserts that `body` throws an error equal to `expected`.
public func expectThrowsEqual<E: Error & Equatable, T>(
    _ expected: E,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        Issue.record(
            "Expected \(expected) to be thrown.",
            sourceLocation: sourceLocation
        )
    } catch let error as E {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record(
            "Expected \(expected) to be thrown, got \(error).",
            sourceLocation: sourceLocation
        )
    }
}

/// Asserts that `body` throws any error, optionally inspecting it
/// via `errorHandler`.
public func expectThrows<T>(
    _ body: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ errorHandler: (any Error) -> Void = { _ in }
) {
    do {
        _ = try body()
        let renderedMessage = message().isEmpty
            ? "Expected error to be thrown."
            : message()
        Issue.record(
            Comment(rawValue: renderedMessage),
            sourceLocation: sourceLocation
        )
    } catch {
        errorHandler(error)
    }
}

/// Asserts that `body` throws an error of the given type.
public func expectThrows<E: Error, T>(
    _ errorType: E.Type,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> T
) {
    do {
        _ = try body()
        Issue.record(
            "Expected \(errorType) to be thrown.",
            sourceLocation: sourceLocation
        )
    } catch is E {
        // success
    } catch {
        Issue.record(
            "Expected \(errorType) to be thrown, got \(error).",
            sourceLocation: sourceLocation
        )
    }
}

/// Async variant: asserts that `body` throws an error of the given type.
public func expectThrows<E: Error, T>(
    _ errorType: E.Type,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        Issue.record(
            "Expected \(errorType) to be thrown.",
            sourceLocation: sourceLocation
        )
    } catch is E {
        // success
    } catch {
        Issue.record(
            "Expected \(errorType) to be thrown, got \(error).",
            sourceLocation: sourceLocation
        )
    }
}
