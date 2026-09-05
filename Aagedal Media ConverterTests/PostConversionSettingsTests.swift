import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class PostConversionSettingsTests: XCTestCase {
    private func withSettings(_ body: (UserDefaults, PostConversionSettings) -> Void) {
        let suite = "PostConversionSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, PostConversionSettings(defaults: defaults))
    }

    func testMissingPreferencesKeepExistingDefaults() {
        withSettings { _, settings in
            let transcription = settings.transcriptionSnapshot()
            XCTAssertEqual(transcription.whisperModel.rawValue, AppConstants.defaultWhisperModel)
            XCTAssertEqual(transcription.whisperLanguage, AppConstants.defaultWhisperLanguage)
            XCTAssertEqual(transcription.parakeetModel.id, AppConstants.defaultParakeetModel)
            XCTAssertEqual(transcription.parakeetLanguage, AppConstants.defaultParakeetLanguage)
            XCTAssertFalse(transcription.embedSubtitles)
            let analytics = settings.analyticsSnapshot()
            XCTAssertEqual(analytics.enabledMetrics.map(\.rawValue), AppConstants.defaultAnalyticsEnabledMetrics)
            XCTAssertEqual(analytics.vmafModel.rawValue, AppConstants.defaultAnalyticsVMAFModel)
        }
    }

    func testInvalidModelsFallBackAndUnknownMetricsAreIgnored() {
        withSettings { defaults, settings in
            defaults.set("removed-model", forKey: AppConstants.whisperModelKey)
            defaults.set("removed-model", forKey: AppConstants.parakeetModelKey)
            defaults.set("removed-model", forKey: AppConstants.analyticsVMAFModelKey)
            defaults.set(["unknown", QualityMetric.allCases[0].rawValue], forKey: AppConstants.analyticsEnabledMetricsKey)
            XCTAssertEqual(settings.transcriptionSnapshot().whisperModel, .base)
            XCTAssertEqual(settings.transcriptionSnapshot().parakeetModel, ParakeetModel.allModels[0])
            XCTAssertEqual(settings.analyticsSnapshot().vmafModel, .vmaf_v0_6_1)
            XCTAssertEqual(settings.analyticsSnapshot().enabledMetrics, [QualityMetric.allCases[0]])
            defaults.set([], forKey: AppConstants.analyticsEnabledMetricsKey)
            XCTAssertTrue(settings.analyticsSnapshot().enabledMetrics.isEmpty)
        }
    }

    func testSnapshotsRemainStableWhileNextOperationUsesEditedPreferences() {
        withSettings { defaults, settings in
            defaults.set("en", forKey: AppConstants.whisperLanguageKey)
            defaults.set(true, forKey: AppConstants.embedSubtitlesKey)
            defaults.set([QualityMetric.allCases[0].rawValue], forKey: AppConstants.analyticsEnabledMetricsKey)
            let transcription = settings.transcriptionSnapshot()
            let analytics = settings.analyticsSnapshot()
            defaults.set("no", forKey: AppConstants.whisperLanguageKey)
            defaults.set(false, forKey: AppConstants.embedSubtitlesKey)
            defaults.set([], forKey: AppConstants.analyticsEnabledMetricsKey)
            XCTAssertEqual(transcription.whisperLanguage, "en")
            XCTAssertTrue(transcription.embedSubtitles)
            XCTAssertEqual(analytics.enabledMetrics, [QualityMetric.allCases[0]])
            XCTAssertEqual(settings.transcriptionSnapshot().whisperLanguage, "no")
            XCTAssertFalse(settings.transcriptionSnapshot().embedSubtitles)
            XCTAssertTrue(settings.analyticsSnapshot().enabledMetrics.isEmpty)
        }
    }

    func testOCRLanguageFollowsEngineAndStreamLanguageWins() {
        withSettings { defaults, settings in
            defaults.set("nor", forKey: AppConstants.tesseractLanguageKey)
            defaults.set("fra", forKey: AppConstants.visionLanguageKey)
            defaults.set(OCREngineKind.appleVision.rawValue, forKey: AppConstants.ocrEngineKey)
            let vision = settings.ocrSnapshot()
            XCTAssertEqual(vision.engine, .appleVision)
            XCTAssertEqual(vision.language(forStreamLanguage: nil), "fra")
            XCTAssertEqual(vision.language(forStreamLanguage: "deu"), "deu")
            defaults.set("invalid-engine", forKey: AppConstants.ocrEngineKey)
            XCTAssertEqual(settings.ocrSnapshot().engine, .tesseract)
            XCTAssertEqual(settings.ocrSnapshot().language, "nor")
            XCTAssertEqual(vision.engine, .appleVision)
        }
    }

    func testIndependentStoresDoNotLeakPreferences() {
        withSettings { firstDefaults, first in
            withSettings { secondDefaults, second in
                firstDefaults.set("en", forKey: AppConstants.parakeetLanguageKey)
                secondDefaults.set("no", forKey: AppConstants.parakeetLanguageKey)
                XCTAssertEqual(first.transcriptionSnapshot().parakeetLanguage, "en")
                XCTAssertEqual(second.transcriptionSnapshot().parakeetLanguage, "no")
            }
        }
    }
}
