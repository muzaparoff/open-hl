// SPDX-License-Identifier: MIT

import Foundation
import HyperliquidAPI
import OSLog
import OpenHLCore

private let logger = Logger(subsystem: "xyz.hyperliquid.openhl", category: "AddressEntry")

/// View-facing error states for the address entry screen.
enum ViewErrorState: Sendable, Equatable {
    case offline
    case timeout
    case badRequest
    case serverError(Int)
    case unexpectedResponse
    case unknown
}

@MainActor
@Observable
final class AddressEntryViewModel {

    // MARK: - View-facing state

    /// The raw text currently in the address field.
    var addressText: String = ""

    /// Inline validation error message, shown below the field after
    /// submit or focus-loss. Cleared on any text change.
    var validationError: String?

    /// True while the fetch is in-flight.
    var isLoading: Bool = false

    /// Network/API error message, distinct from format validation.
    var fetchError: ViewErrorState?

    /// Set when a successful fetch completes; triggers navigation.
    var loadedState: ClearinghouseState?

    // MARK: - Dependencies

    private let client: any HyperliquidClient
    private let addressStore: any AddressStore
    private let clock: any Clock

    /// Optional pre-filled address (for the "change address" modal).
    private let existingAddress: Address?

    // MARK: - Init

    init(
        client: any HyperliquidClient,
        addressStore: any AddressStore,
        clock: any Clock,
        existingAddress: Address? = nil
    ) {
        self.client = client
        self.addressStore = addressStore
        self.clock = clock
        self.existingAddress = existingAddress
        self.addressText = existingAddress?.rawValue ?? ""
    }

    // MARK: - Computed helpers

    var isAddressValid: Bool {
        Address(validating: addressText) != nil
    }

    /// True while loading (used to disable the text field).
    var isFieldDisabled: Bool { isLoading }

    // MARK: - Actions

    /// Called by the view when the field loses focus or the user taps submit
    /// with invalid input. Shows validation error inline.
    func validateAddress() {
        guard !addressText.isEmpty else {
            validationError = nil
            return
        }
        do {
            _ = try Address(addressText)
            validationError = nil
        } catch let error as Address.ValidationError {
            validationError = errorMessage(for: error)
        } catch {
            validationError = "Invalid address format."
        }
    }

    /// Called by the view whenever the text field content changes.
    func onAddressTextChanged() {
        validationError = nil
        fetchError = nil
    }

    /// Submits the address: validates, then fetches. The view drives this
    /// via `.task(id:)` — do not call directly from a `Button` action.
    func submitAddress() async {
        fetchError = nil

        let address: Address
        do {
            address = try Address(addressText)
        } catch let error as Address.ValidationError {
            validationError = errorMessage(for: error)
            return
        } catch {
            validationError = "Invalid address format."
            return
        }

        validationError = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let state = try await client.clearinghouseState(for: address)
            guard !Task.isCancelled else { return }
            addressStore.save(address)
            loadedState = state
        } catch is CancellationError {
            // Cancelled — do nothing; the view is gone or the user navigated away.
        } catch let error as HyperliquidError {
            guard !Task.isCancelled else { return }
            fetchError = viewErrorState(from: error)
            logger.error("Fetch failed: \(String(describing: error), privacy: .public)")
        } catch {
            guard !Task.isCancelled else { return }
            fetchError = .unknown
            logger.error("Unexpected error: \(error, privacy: .public)")
        }
    }

    // MARK: - Error copy

    func fetchErrorMessage(for state: ViewErrorState) -> String {
        switch state {
        case .offline:
            return "No internet connection. Connect and try again."
        case .timeout:
            return "Request timed out. Hyperliquid may be slow — try again."
        case .serverError(let code):
            return "Hyperliquid returned an error (HTTP \(code)). Try again in a moment."
        case .badRequest:
            return "The request was rejected (HTTP 4xx). Check the address and try again."
        case .unexpectedResponse:
            return "Could not read the account data. The API response was unexpected."
        case .unknown:
            return "Could not reach Hyperliquid. Check your connection and try again."
        }
    }

    // MARK: - Private helpers

    private func errorMessage(for error: Address.ValidationError) -> String {
        switch error {
        case .empty:
            return "Enter a wallet address."
        case .missingPrefix:
            return "Address must start with 0x."
        case .wrongLength(let actual):
            return "Address must be 0x followed by 40 hex characters (0–9, a–f). Got \(actual) characters total."
        case .nonHexCharacter:
            return "Address must be 0x followed by 40 hex characters (0–9, a–f)."
        }
    }

    private func viewErrorState(from error: HyperliquidError) -> ViewErrorState {
        switch error {
        case .offline:
            return .offline
        case .timeout:
            return .timeout
        case .httpStatus(let code):
            if code >= 500 {
                return .serverError(code)
            }
            return .badRequest
        case .decoding, .unexpectedResponse:
            return .unexpectedResponse
        case .transport:
            return .unknown
        }
    }
}
