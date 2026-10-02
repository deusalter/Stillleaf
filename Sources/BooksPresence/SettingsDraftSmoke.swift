import Foundation

private enum SettingsDraftSmokeError: Error { case failed(String) }

/// Exercises the same shared draft lifecycle used when Settings is recreated
/// after sidebar navigation or an external dashboard/category request.
@MainActor
func runSettingsDraftSmoke(model: AppModel) throws {
    let drafts = SettingsDraftStore()
    drafts.loadIfNeeded(from: model)
    drafts.pageGoalDraft = "41"
    drafts.discordApplicationIDDraft = "unsaved-sharing-id"
    drafts.loadIfNeeded(from: model)
    guard drafts.pageGoalDraft == "41", drafts.discordApplicationIDDraft == "unsaved-sharing-id" else {
        throw SettingsDraftSmokeError.failed("Re-entering Settings discarded unsaved reading or sharing drafts")
    }

    drafts.annualEnabledDraft = false
    drafts.uncertaintyDraft = "20"
    drafts.timezoneDraft = "Etc/UTC"
    drafts.dailyUnitDraft = .minutes
    drafts.pageGoalDraft = ""
    drafts.goalDraft = "20"
    guard drafts.readingValuesAreValid else {
        throw SettingsDraftSmokeError.failed("An invalid hidden page goal blocked the visible minute goal")
    }
    drafts.dailyUnitDraft = .pages
    guard !drafts.readingValuesAreValid else {
        throw SettingsDraftSmokeError.failed("An empty active page goal was accepted")
    }
    drafts.pageGoalDraft = "10000"
    drafts.goalDraft = "1441"
    guard drafts.readingValuesAreValid else {
        throw SettingsDraftSmokeError.failed("A valid page goal was blocked by hidden minute input")
    }
    drafts.dailyUnitDraft = .minutes
    guard !drafts.readingValuesAreValid else {
        throw SettingsDraftSmokeError.failed("An out-of-range active minute goal was accepted")
    }

    drafts.reloadReading(from: model)
    guard drafts.pageGoalDraft == String(Int(model.pageGoal.rounded())),
          drafts.discordApplicationIDDraft == "unsaved-sharing-id" else {
        throw SettingsDraftSmokeError.failed("Reverting reading settings discarded sharing edits")
    }
    drafts.reloadSharing(from: model)
    guard drafts.discordApplicationIDDraft == model.discordApplicationID else {
        throw SettingsDraftSmokeError.failed("Revert did not restore saved sharing settings")
    }
    print("settings-draft-smoke: navigation persistence, active-unit validation, and separate Revert passed")
}
