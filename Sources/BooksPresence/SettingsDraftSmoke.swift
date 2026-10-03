import Foundation
import CSQLite

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
    try checkSharingSaveRetry()
    print("settings-draft-smoke: navigation persistence, active-unit validation, separate Revert, and sharing save retry passed")
}

@MainActor
private func checkSharingSaveRetry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-sharing-save-" + UUID().uuidString)
    let suite = "Stillleaf.SharingSave." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defaults.set("original-application", forKey: "discordApplicationID")
    defaults.set("original-artwork", forKey: "discordAssetKey")
    let model = try AppModel(support: directory, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    model.saveSettings()
    guard model.errorMessage == nil else { throw SettingsDraftSmokeError.failed("Could not prepare sharing settings fixture") }
    let drafts = SettingsDraftStore()
    drafts.loadIfNeeded(from: model)
    drafts.discordApplicationIDDraft = "  replacement-application  "
    drafts.discordAssetKeyDraft = "replacement-artwork"

    var database: OpaquePointer?
    guard sqlite3_open(directory.appendingPathComponent("history.sqlite").path, &database) == SQLITE_OK else {
        throw SettingsDraftSmokeError.failed("Could not open sharing save fixture")
    }
    defer { sqlite3_close(database) }
    let trigger = "CREATE TRIGGER reject_settings BEFORE INSERT ON goals BEGIN SELECT RAISE(ABORT, 'synthetic settings write failure'); END"
    guard sqlite3_exec(database, trigger, nil, nil, nil) == SQLITE_OK else {
        throw SettingsDraftSmokeError.failed("Could not install sharing save failure")
    }
    // Make saveSettings perform a real durable write before saving preferences.
    model.pageGoal = model.pageGoal == 10_000 ? 9_999 : model.pageGoal + 1
    guard !drafts.saveSharing(to: model), model.errorMessage != nil,
          model.discordApplicationID == "original-application", model.discordAssetKey == "original-artwork",
          defaults.string(forKey: "discordApplicationID") == "original-application",
          drafts.discordApplicationIDDraft == "  replacement-application  " else {
        throw SettingsDraftSmokeError.failed("Failed sharing save lost drafts or reported unsaved values as saved")
    }
    drafts.loadIfNeeded(from: model)
    guard drafts.discordAssetKeyDraft == "replacement-artwork" else {
        throw SettingsDraftSmokeError.failed("Navigating after a sharing failure discarded the retry draft")
    }
    guard sqlite3_exec(database, "DROP TRIGGER reject_settings", nil, nil, nil) == SQLITE_OK,
          drafts.saveSharing(to: model), model.errorMessage == nil,
          model.discordApplicationID == "replacement-application",
          drafts.discordApplicationIDDraft == "replacement-application",
          defaults.string(forKey: "discordAssetKey") == "replacement-artwork" else {
        throw SettingsDraftSmokeError.failed("Sharing settings could not retry after a write failure")
    }
}
