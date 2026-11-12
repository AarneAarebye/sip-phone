import Observation

/// Re-runs `apply` whenever any @Observable property read inside it changes.
@MainActor func observe(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking { apply() } onChange: {
        Task { @MainActor in observe(apply) }
    }
}
