import Foundation

/// Envelope de resultado — espelha `core/result/AppResult` do Kotlin.
/// Ver port_spec_network_contracts §2.
public enum AppResult<T> {
    case success(T)
    case failure(ApiError)
}

extension AppResult: Sendable where T: Sendable {}
extension AppResult: Equatable where T: Equatable {}

public extension AppResult {
    func map<R>(_ transform: (T) -> R) -> AppResult<R> {
        switch self {
        case .success(let value): return .success(transform(value))
        case .failure(let error): return .failure(error)
        }
    }

    @discardableResult
    func onSuccess(_ action: (T) -> Void) -> AppResult<T> {
        if case .success(let value) = self { action(value) }
        return self
    }

    @discardableResult
    func onFailure(_ action: (ApiError) -> Void) -> AppResult<T> {
        if case .failure(let error) = self { action(error) }
        return self
    }

    /// Valor em caso de sucesso, senão `nil` (equivalente a `getOrNull`).
    var value: T? {
        if case .success(let value) = self { return value }
        return nil
    }

    var error: ApiError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
