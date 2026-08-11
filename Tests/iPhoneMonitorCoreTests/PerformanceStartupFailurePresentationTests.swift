import Foundation
import XCTest
@testable import iPhoneMonitorCore

final class PerformanceStartupFailurePresentationTests: XCTestCase {
    func testDefiniteFilePermissionFailureUsesDocumentsRecoveryWithoutTechnicalDetails() {
        let denied = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.EACCES.rawValue)
        )
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: denied]
        )
        let error = PerformanceMonitorServiceError.helperProcess(
            .launchFailed(PerformanceHelperLaunchFailure(error: wrapped))
        )

        let presentation = PerformanceStartupFailurePresenter.presentation(
            for: error,
            documentsAccessMayBeRelevant: true
        )

        XCTAssertEqual(presentation.kind, .fileAccessDenied)
        XCTAssertEqual(presentation.title, "无法访问性能监控所需文件")
        XCTAssertEqual(
            presentation.recoverySuggestion,
            "请在 macOS 提示中允许 iPhone Inspector 访问“文稿”文件夹，然后再次尝试。"
        )
        XCTAssertFalse(presentation.userMessage.contains("EACCES"))
        XCTAssertFalse(presentation.userMessage.contains("EPERM"))
    }

    func testReadyTimeoutUsesConditionalDocumentsHintWithoutClaimingDenial() {
        let presentation = PerformanceStartupFailurePresenter.presentation(
            for: PerformanceMonitorServiceError.timedOut("helper_ready"),
            documentsAccessMayBeRelevant: true
        )
        let genericPresentation = PerformanceStartupFailurePresenter.presentation(
            for: PerformanceMonitorServiceError.timedOut("helper_ready"),
            documentsAccessMayBeRelevant: false
        )
        let laterStartupTimeout = PerformanceStartupFailurePresenter.presentation(
            for: PerformanceMonitorServiceError.timedOut("session_started"),
            documentsAccessMayBeRelevant: true
        )

        XCTAssertEqual(presentation.kind, .readyTimeout)
        XCTAssertEqual(presentation.title, "性能监控启动超时")
        XCTAssertEqual(
            presentation.recoverySuggestion,
            "如果 macOS 正在请求访问“文稿”文件夹，请先允许，然后再次尝试。"
        )
        XCTAssertFalse(presentation.userMessage.contains("权限被拒绝"))
        XCTAssertFalse(presentation.userMessage.contains("helper_ready"))
        XCTAssertEqual(genericPresentation.kind, .readyTimeout)
        XCTAssertFalse(genericPresentation.userMessage.contains("文稿"))
        XCTAssertEqual(laterStartupTimeout.kind, .unknown)
        XCTAssertFalse(laterStartupTimeout.userMessage.contains("文稿"))
    }

    func testDocumentsHintRequiresHelperPathInsideDocumentsDirectory() {
        let documents = URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true)
        let inside = PerformanceHelperLocation(
            executableURL: documents.appendingPathComponent("project/.performance-tools/helper/run_helper.sh"),
            workingDirectoryURL: documents.appendingPathComponent("project/.performance-tools/helper"),
            source: .projectDirectory
        )
        let sibling = PerformanceHelperLocation(
            executableURL: URL(fileURLWithPath: "/Users/example/Documents-old/helper/run_helper.sh"),
            workingDirectoryURL: URL(fileURLWithPath: "/Users/example/Documents-old/helper"),
            source: .projectDirectory
        )

        XCTAssertTrue(
            PerformanceStartupFailurePresenter.documentsAccessMayBeRelevant(
                for: inside,
                documentDirectoryURL: documents
            )
        )
        XCTAssertFalse(
            PerformanceStartupFailurePresenter.documentsAccessMayBeRelevant(
                for: sibling,
                documentDirectoryURL: documents
            )
        )
    }

    func testHelperNotFoundUsesConciseRecoveryWithoutSearchedPaths() {
        let error = PerformanceMonitorServiceError.helperLocation(
            .notFound(searched: ["/Users/example/private/project/.performance-tools/helper/run_helper.sh"])
        )

        let presentation = PerformanceStartupFailurePresenter.presentation(
            for: error,
            documentsAccessMayBeRelevant: false
        )

        XCTAssertEqual(presentation.kind, .helperNotFound)
        XCTAssertEqual(presentation.title, "找不到性能监控组件")
        XCTAssertEqual(
            presentation.recoverySuggestion,
            "请重新构建并从项目生成的 iPhone Inspector.app 启动。"
        )
        XCTAssertFalse(presentation.userMessage.contains("/Users/"))
    }

    func testUnknownErrorUsesGenericFallback() {
        let error = NSError(domain: "UnexpectedFixture", code: 99)

        let presentation = PerformanceStartupFailurePresenter.presentation(
            for: error,
            documentsAccessMayBeRelevant: false
        )

        XCTAssertEqual(presentation.kind, .unknown)
        XCTAssertEqual(presentation.title, "性能监控未能启动")
        XCTAssertEqual(
            presentation.recoverySuggestion,
            "请再次尝试；如果问题持续出现，请查看详细诊断信息。"
        )
        XCTAssertFalse(presentation.userMessage.contains("UnexpectedFixture"))
    }
}
