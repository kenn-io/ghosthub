import AppKit

func ensureRegularActivationPolicy(
    currentPolicy: NSApplication.ActivationPolicy,
    transition: () -> Bool
) -> Bool {
    currentPolicy == .regular || transition()
}
