// SPDX-License-Identifier: MIT

import HyperliquidAPI
import OpenHLCore
import SwiftUI
import UIKit

/// The address entry screen. Shown on first launch or when the user
/// wants to change the saved address.
///
/// When `onSuccess` fires, the caller navigates to (or reloads)
/// the positions screen. The view model persists the address internally
/// after a successful fetch.
struct AddressEntryView: View {
    @State var viewModel: AddressEntryViewModel

    /// Called when the fetch succeeded and the address has been stored.
    var onSuccess: (ClearinghouseState) -> Void

    /// When non-nil this view is presented modally with a cancel affordance.
    var onCancel: (() -> Void)?

    // MARK: - Internal state

    @State private var submitTrigger: Int = 0
    @State private var clipboardHasAddress: Bool = false
    @FocusState private var fieldIsFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrollable content
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 60)

                    // App name
                    Text("open-hl")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("open-hl")
                        .padding(.bottom, 32)

                    // Address text field
                    addressField

                    // Validation error or paste button
                    Group {
                        if let validationError = viewModel.validationError {
                            validationErrorView(validationError)
                        } else if let fetchError = viewModel.fetchError {
                            fetchErrorView(fetchError)
                        } else if clipboardHasAddress && !viewModel.isLoading {
                            pasteButton
                        }
                    }
                    .padding(.top, 8)

                    Spacer(minLength: 100)  // room for sticky footer

                    // Footer trust signal
                    VStack(spacing: 4) {
                        Text("Hyperliquid public address")
                        Text("No data leaves your device.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Hyperliquid public address. No data leaves your device.")

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.immediately)

            // Sticky footer: submit or loading
            submitArea
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.regularMaterial)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle(onCancel != nil ? "Address" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
        .onAppear { checkClipboard() }
        .onChange(of: scenePhase) { _, _ in checkClipboard() }
        .task(id: submitTrigger) {
            guard submitTrigger > 0 else { return }
            await viewModel.submitAddress()
            if let state = viewModel.loadedState {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                onSuccess(state)
            } else if viewModel.fetchError != nil {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.error)
            }
        }
    }

    // MARK: - Subviews

    private var addressField: some View {
        TextField("0x\u{2026}", text: $viewModel.addressText)
            .font(.system(.footnote, design: .monospaced))
            .keyboardType(.asciiCapable)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .textContentType(.none)
            .disabled(viewModel.isFieldDisabled)
            .focused($fieldIsFocused)
            .onSubmit {
                viewModel.validateAddress()
            }
            .onChange(of: viewModel.addressText) { _, _ in
                viewModel.onAddressTextChanged()
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        viewModel.validationError != nil
                            ? Color.red : Color(uiColor: .separator),
                        lineWidth: viewModel.validationError != nil ? 1.5 : 0.5
                    )
            )
            .accessibilityLabel("Hyperliquid wallet address")
            .accessibilityHint(viewModel.addressText.isEmpty ? "Enter your 0x wallet address" : "")
    }

    private var pasteButton: some View {
        Button {
            pasteFromClipboard()
        } label: {
            Label("Paste address from clipboard", systemImage: "doc.on.clipboard")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Paste address from clipboard")
    }

    private func validationErrorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .imageScale(.small)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
        .accessibilityFocused($errorFocused)
        .onAppear { errorFocused = true }
    }

    private func fetchErrorView(_ state: ViewErrorState) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text(viewModel.fetchErrorMessage(for: state))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(viewModel.fetchErrorMessage(for: state))")
        .accessibilityFocused($errorFocused)
        .onAppear { errorFocused = true }
    }

    @ViewBuilder
    private var submitArea: some View {
        if viewModel.isLoading {
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                Text("Fetching\u{2026}")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .accessibilityLabel("Fetching account data")
        } else {
            Button {
                let action = viewModel.fetchError != nil ? "retry" : "submit"
                _ = action  // used for intent clarity
                guard viewModel.isAddressValid else {
                    viewModel.validateAddress()
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.error)
                    return
                }
                submitTrigger += 1
            } label: {
                Label(
                    viewModel.fetchError != nil ? "Try again" : "View account",
                    systemImage: "arrow.right"
                )
                .labelStyle(TrailingIconLabelStyle())
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.isAddressValid)
            .minimumScaleFactor(0.8)
            .accessibilityLabel(viewModel.fetchError != nil ? "Try again" : "View account")
        }
    }

    // MARK: - Clipboard

    private func checkClipboard() {
        // `hasStrings` does not trigger the iOS clipboard-access banner.
        // We show the paste button when there's any string present; the actual
        // content is only read when the user taps Paste (which triggers the
        // system's one-time access notification — acceptable UX per spec).
        clipboardHasAddress = UIPasteboard.general.hasStrings
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string else { return }
        viewModel.addressText = text
        viewModel.onAddressTextChanged()
        clipboardHasAddress = false
        // Run validation immediately after paste
        if !viewModel.isAddressValid {
            viewModel.validateAddress()
        }
    }
}

// MARK: - Label style with trailing icon

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - Preview

#Preview("Empty") {
    NavigationStack {
        AddressEntryView(
            viewModel: AddressEntryViewModel(
                client: PreviewHyperliquidClient(),
                addressStore: InMemoryAddressStore(),
                clock: SystemClock()
            ),
            onSuccess: { _ in }
        )
    }
}

#Preview("Modal (change address)") {
    NavigationStack {
        AddressEntryView(
            viewModel: AddressEntryViewModel(
                client: PreviewHyperliquidClient(),
                addressStore: InMemoryAddressStore(),
                clock: SystemClock(),
                existingAddress: Address(validating: "0x0000000000000000000000000000000000000001")
            ),
            onSuccess: { _ in },
            onCancel: {}
        )
    }
}
