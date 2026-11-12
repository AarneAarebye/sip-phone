// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Observation

/// Re-runs `apply` whenever any @Observable property read inside it changes.
@MainActor func observe(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking { apply() } onChange: {
        Task { @MainActor in observe(apply) }
    }
}
