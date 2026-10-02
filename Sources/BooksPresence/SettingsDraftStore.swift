import SwiftUI
import BooksCore

/// Owned by the dashboard so changing destinations does not discard unsaved
/// reading or sharing settings. Saving and Revert remain explicit actions.
@MainActor
final class SettingsDraftStore: ObservableObject {
    var didLoadDrafts = false
    @Published var pageGoalDraft = "20"
    @Published var goalDraft = "20"
    @Published var dailyUnitDraft: DailyGoalUnit = .pages
    @Published var annualEnabledDraft = false
    @Published var annualGoalDraft = "12"
    @Published var uncertaintyDraft = "20"
    @Published var timezoneDraft = TimeZone.current.identifier
    @Published var discordApplicationIDDraft = ""
    @Published var discordAssetKeyDraft = "books"
    private var loadedReadingValues: [String] = []
    private var loadedSharingValues: [String] = []

    private var readingValues: [String] {
        [pageGoalDraft, goalDraft, dailyUnitDraft.rawValue, String(annualEnabledDraft),
         annualGoalDraft, uncertaintyDraft, timezoneDraft]
    }

    private var sharingValues: [String] { [discordApplicationIDDraft, discordAssetKeyDraft] }

    func loadIfNeeded(from model: AppModel) {
        // A clean form follows changes made elsewhere, such as the welcome
        // tour. A dirty form keeps the user's work when the view is recreated.
        if !didLoadDrafts || readingValues == loadedReadingValues { reloadReading(from: model) }
        if !didLoadDrafts || sharingValues == loadedSharingValues { reloadSharing(from: model) }
        didLoadDrafts = true
    }

    func reloadReading(from model: AppModel) {
        dailyUnitDraft = model.dailyGoalUnit
        annualEnabledDraft = model.annualBookGoal != nil
        annualGoalDraft = String(model.annualBookGoal ?? 12)
        pageGoalDraft = String(Int(model.pageGoal.rounded()))
        goalDraft = String(Int(model.goalMinutes.rounded()))
        uncertaintyDraft = String(Int(model.uncertaintyMinutes.rounded()))
        timezoneDraft = model.timezoneID
        loadedReadingValues = readingValues
    }

    func reloadSharing(from model: AppModel) {
        discordApplicationIDDraft = model.discordApplicationID
        discordAssetKeyDraft = model.discordAssetKey
        loadedSharingValues = sharingValues
    }

    var readingValuesAreValid: Bool {
        let activeGoal = dailyUnitDraft == .pages ? pageGoalDraft : goalDraft
        let activeRange = dailyUnitDraft == .pages ? 1...10_000 : 1...1_440
        guard let goal = Int(activeGoal), activeRange.contains(goal),
              let uncertainty = Int(uncertaintyDraft), (1...240).contains(uncertainty),
              TimeZone(identifier: timezoneDraft) != nil else { return false }
        return !annualEnabledDraft || Int(annualGoalDraft).map { (1...10_000).contains($0) } == true
    }
}
