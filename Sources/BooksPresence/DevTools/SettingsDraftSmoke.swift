import Foundation
import BooksCore
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
    try checkGlassControlLogic()
    print("settings-draft-smoke: navigation persistence, active-unit validation, separate Revert, sharing save retry, and glass control logic passed")
}

/// The arithmetic and navigation rules behind the settings controls. They are pure,
/// so a regression shows here without needing a window.
private func checkGlassControlLogic() throws {
    let pages = ReadingGoalLimits.dailyPages
    // Stepping clamps at both ends instead of leaving the valid range.
    guard GlassNumber.stepped("80", by: 1, in: pages) == 81,
          GlassNumber.stepped("80", by: -10, in: pages) == 70,
          GlassNumber.stepped("1", by: -1, in: pages) == pages.lowerBound,
          GlassNumber.stepped("9995", by: 10, in: pages) == pages.upperBound else {
        throw SettingsDraftSmokeError.failed("Stepping a number field left its range")
    }
    // An empty or out-of-range field steps back into range rather than crashing or keeping the bad value.
    guard GlassNumber.stepped("", by: 1, in: pages) == pages.lowerBound,
          GlassNumber.stepped("", by: -1, in: pages) == pages.lowerBound,
          GlassNumber.stepped("99999", by: -1, in: pages) == pages.upperBound else {
        throw SettingsDraftSmokeError.failed("Stepping an empty or out-of-range field did not recover")
    }
    // Typing keeps digits only and never grows past the widest valid value.
    guard GlassNumber.sanitize("1a2-3 ", maxLength: 5) == "123",
          GlassNumber.sanitize("1234567", maxLength: GlassNumber.maxLength(for: pages)) == "12345",
          GlassNumber.maxLength(for: pages) == 5, GlassNumber.maxLength(for: ReadingGoalLimits.dailyMinutes) == 4 else {
        throw SettingsDraftSmokeError.failed("A number field accepted non-digits or too many digits")
    }
    guard GlassNumber.isValid("10000", in: pages), !GlassNumber.isValid("0", in: pages),
          !GlassNumber.isValid("", in: pages), !GlassNumber.isValid("10001", in: pages) else {
        throw SettingsDraftSmokeError.failed("Number field validity disagrees with the goal limits")
    }
    // Arrow keys stop at the first and last segment instead of wrapping.
    guard GlassSegmentedControl<Int>.neighbour(of: 0, count: 4, forward: false) == nil,
          GlassSegmentedControl<Int>.neighbour(of: 3, count: 4, forward: true) == nil,
          GlassSegmentedControl<Int>.neighbour(of: 1, count: 4, forward: true) == 2,
          GlassSegmentedControl<Int>.neighbour(of: 1, count: 4, forward: false) == 0 else {
        throw SettingsDraftSmokeError.failed("Segmented control arrow keys wrapped or skipped a segment")
    }
    // The category strip needs distinct, non-empty titles and icons, and the order the page slides by.
    let categories = SettingsCategory.allCases
    guard Set(categories.map(\.title)).count == categories.count, categories.allSatisfy({ !$0.title.isEmpty && !$0.icon.isEmpty }),
          categories == [.reading, .appearance, .discord, .data] else {
        throw SettingsDraftSmokeError.failed("Settings categories lost their order, titles or icons")
    }
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
