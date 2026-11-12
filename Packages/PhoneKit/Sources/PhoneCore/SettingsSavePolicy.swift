import Foundation

public enum SettingsSavePolicy {
    /// The Settings window closes after Save only when there is nothing the user must read.
    public static func shouldCloseAfterSave(saveError: String?, loginItemMessage: String?) -> Bool {
        saveError == nil && loginItemMessage == nil
    }
}
