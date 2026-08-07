import Foundation

public enum TmuxLaunchProfileValidation {
    public static func message(
        for profile: TmuxLaunchProfile,
        in profiles: [TmuxLaunchProfile]
    ) -> String? {
        let name = profile.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else { return "Name is required." }
        guard !profile.command.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return "Command is required."
        }
        let normalizedName = name.lowercased()
        let duplicates = profiles.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == normalizedName
        }
        guard duplicates.count < 2 else {
            return "Profile names must be unique."
        }
        return nil
    }
}
