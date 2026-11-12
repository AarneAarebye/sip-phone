import Foundation

public enum ContactFilter {
    /// True when `query` is empty or matches the contact's name, any number, or phone book name (case-insensitive).
    public static func matches(_ contact: Contact, _ query: String) -> Bool {
        if query.isEmpty { return true }
        return contact.name.localizedCaseInsensitiveContains(query)
            || contact.numbers.contains { $0.number.contains(query) }
            || (contact.phoneBook?.localizedCaseInsensitiveContains(query) ?? false)
    }
}
