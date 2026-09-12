import Foundation

public enum PerformanceStartupFailureKind: String, Equatable, Sendable {
    case helperNotFound
    case fileAccessDenied
    case helperLaunchFailed
    case readyTimeout
    case unknown
}

public struct PerformanceStartupFailurePresentation: Equatable, Sendable {
    public let kind: PerformanceStartupFailureKind
    public let title: String
    public let recoverySuggestion: String

    public var userMessage: String {
        "\(title)。\(recoverySuggestion)"
    }
}

public enum PerformanceStartupFailurePresenter {
    public static func presentation(
        for error: Error,
        documentsAccessMayBeRelevant: Bool
    ) -> PerformanceStartupFailurePresentation {
        switch kind(for: error) {
        case .helperNotFound:
            return PerformanceStartupFailurePresentation(
                kind: .helperNotFound,
                title: "找不到性能监控组件",
                recoverySuggestion: "请重新构建并从项目生成的 iPhone Inspector.app 启动。"
            )
        case .fileAccessDenied:
            let suggestion = documentsAccessMayBeRelevant
                ? "请在 macOS 提示中允许 iPhone Inspector 访问“文稿”文件夹，然后再次尝试。"
                : "请确认 iPhone Inspector 可以访问性能监控组件，然后再次尝试。"
            return PerformanceStartupFailurePresentation(
                kind: .fileAccessDenied,
                title: "无法访问性能监控所需文件",
                recoverySuggestion: suggestion
            )
        case .helperLaunchFailed:
            return PerformanceStartupFailurePresentation(
                kind: .helperLaunchFailed,
                title: "性能监控组件无法启动",
                recoverySuggestion: "请再次尝试；如果问题持续出现，请查看详细诊断信息。"
            )
        case .readyTimeout:
            let suggestion = documentsAccessMayBeRelevant && isHelperReadyTimeout(error)
                ? "如果 macOS 正在请求访问“文稿”文件夹，请先允许，然后再次尝试。"
                : "请再次尝试；如果问题持续出现，请查看详细诊断信息。"
            return PerformanceStartupFailurePresentation(
                kind: .readyTimeout,
                title: "性能监控启动超时",
                recoverySuggestion: suggestion
            )
        case .unknown:
            return PerformanceStartupFailurePresentation(
                kind: .unknown,
                title: "性能监控未能启动",
                recoverySuggestion: "请再次尝试；如果问题持续出现，请查看详细诊断信息。"
            )
        }
    }

    public static func documentsAccessMayBeRelevant(
        for location: PerformanceHelperLocation?,
        documentDirectoryURL: URL?
    ) -> Bool {
        guard let location, let documentDirectoryURL else { return false }
        let documentsComponents = documentDirectoryURL.standardizedFileURL.pathComponents
        let executableComponents = location.executableURL.standardizedFileURL.pathComponents
        guard executableComponents.count >= documentsComponents.count else { return false }
        return Array(executableComponents.prefix(documentsComponents.count)) == documentsComponents
    }

    private static func kind(for error: Error) -> PerformanceStartupFailureKind {
        if let serviceError = error as? PerformanceMonitorServiceError {
            switch serviceError {
            case .helperLocation(let locatorError):
                return kind(for: locatorError)
            case .helperProcess(let processError):
                return kind(for: processError)
            case .timedOut(let step):
                return step == "helper_ready" ? .readyTimeout : .unknown
            case .processExited:
                return .helperLaunchFailed
            case .invalidTransition, .helperError:
                return .unknown
            }
        }

        if let locatorError = error as? PerformanceHelperLocatorError {
            switch locatorError {
            case .notFound:
                return .helperNotFound
            case .notExecutable:
                return .helperLaunchFailed
            }
        }

        if let processError = error as? PerformanceHelperProcessError {
            switch processError {
            case .launchFailed(let failure):
                return failure.isFileAccessDenied ? .fileAccessDenied : .helperLaunchFailed
            case .alreadyRunning, .notRunning, .inputClosed, .invalidCommand:
                return .helperLaunchFailed
            }
        }

        if PerformanceHelperLaunchFailure(error: error).isFileAccessDenied {
            return .fileAccessDenied
        }
        return .unknown
    }

    private static func isHelperReadyTimeout(_ error: Error) -> Bool {
        guard let serviceError = error as? PerformanceMonitorServiceError,
              case .timedOut(let step) = serviceError
        else { return false }
        return step == "helper_ready"
    }
}
