import GhosthubTerminalSupport
import SwiftUI

public extension EnvironmentValues {
    /// Live background appearance derived from the libghostty config.
    /// Defaults to opaque so nothing flashes transparent before the
    /// terminal runtime loads its configuration.
    @Entry var terminalBackgroundAppearance: TerminalBackgroundAppearance = .opaque
}
