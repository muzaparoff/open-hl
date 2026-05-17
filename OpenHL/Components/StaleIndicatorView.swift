// SPDX-License-Identifier: MIT

import SwiftUI

/// A small "Reconnecting…" pill displayed at the top of a list when the
/// WebSocket connection is stale or reconnecting. Hidden when the
/// connection is fresh or disconnected (backgrounded).
///
/// Usage: place inside a `Section` (or `VStack`) at the top of a `List`
/// and make it conditional on `liveStore.connectionState != .connected`.
///
/// The pill uses `.secondary` fill so it doesn't compete with list
/// content and disappears automatically via opacity animation once the
/// connection recovers.
struct StaleIndicatorView: View {

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.caption)
                .accessibilityHidden(true)
            Text("Reconnecting…")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
        )
        .accessibilityLabel("Connection stale, reconnecting")
        .accessibilityAddTraits(.isStaticText)
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 20) {
            StaleIndicatorView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
#endif
