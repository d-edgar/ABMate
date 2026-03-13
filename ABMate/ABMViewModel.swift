//
//  ABMViewModel.swift
//  ABMate
//
//  © Created by Somesh Pathak on 23/06/2025.
//

import Foundation
import SwiftUI

@MainActor
class ABMViewModel: ObservableObject {
    // MARK: - Toast Alerts
    @Published var activeToast: ToastAlert?

    @Published var devices: [OrgDevice] = []
    @Published var mdmServers: [MDMServer] = []
    @Published var activityStatus: ActivityStatusResponse?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var lastActivityId: String?

    // Credentials
    @Published var clientId = ""
    @Published var keyId = ""
    @Published var privateKey = ""

    // Connection Profiles
    @Published var savedProfiles: [ConnectionProfile] = []
    @Published var activeProfileId: UUID?

    // MARK: - Jamf Pro Connection
    @Published var jamfURL = ""
    @Published var jamfClientId = ""
    @Published var jamfClientSecret = ""
    @Published var jamfSavedProfiles: [JamfConnectionProfile] = []
    @Published var activeJamfProfileId: UUID?
    @Published var isJamfConnected = false
    @Published var jamfStatusMessage: String?
    @Published var jamfErrorMessage: String?
    @Published var isJamfLoading = false

    let jamfAPIService = JamfAPIService()

    // MARK: - Bulk Sync State
    @Published var devicesNotInJamf: Set<String> = []  // serial numbers not found in Jamf
    @Published var bulkSyncLog: [BulkSyncLogEntry] = []
    @Published var bulkSyncSummary: BulkSyncSummary?
    @Published var bulkSyncPhase: BulkSyncPhase = .idle
    @Published var bulkSyncProgress: String = ""
    @Published var bulkSyncCancelled = false
    /// Jamf devices found during last comparison (serial → device)
    var lastJamfDeviceMap: [String: JamfBulkDevice] = [:]
    /// ASM serials that matched a Jamf device and have data differences
    var matchedSerials: Set<String> = []
    /// ASM serials that matched but data was already the same
    var skippedSerials: Set<String> = []
    /// Currently running sync task (for cancellation)
    var bulkSyncTask: Task<Void, Never>?

    enum BulkSyncPhase: Equatable {
        case idle
        case fetching           // pulling from Jamf
        case compared           // comparison done, awaiting confirmation
        case syncing            // pushing purchasing data
        case done               // finished
    }

    var activeJamfProfileName: String? {
        jamfSavedProfiles.first(where: { $0.id == activeJamfProfileId })?.name
    }

    var activeProfileName: String? {
        savedProfiles.first(where: { $0.id == activeProfileId })?.name
    }

    /// Whether we have an active JWT and have fetched data
    var isConnected: Bool {
        clientAssertion != nil && (!devices.isEmpty || !mdmServers.isEmpty)
    }

    /// Returns "ASM" if connected via SCHOOLAPI, "ABM" otherwise
    var connectionLabel: String {
        clientId.hasPrefix("SCHOOLAPI.") ? "ASM" : "ABM"
    }

    internal let apiService = APIService()
    internal var clientAssertion: String?
    
    // Generate JWT
    func generateJWT() {
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        
        Task {
            do {
                let credentials = APICredentials(
                    clientId: clientId,
                    keyId: keyId,
                    privateKey: privateKey
                )
                
                clientAssertion = try JWTGenerator.createClientAssertion(credentials: credentials)
                statusMessage = "JWT generated successfully"
                saveCredentials()
            } catch {
                errorMessage = "JWT Error: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }
    
    // Fetch devices
    func fetchDevices() {
        guard let assertion = clientAssertion else {
            errorMessage = "Generate JWT first"
            return
        }
        
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        
        Task {
            do {
                let token = try await apiService.getAccessToken(
                    clientAssertion: assertion,
                    clientId: clientId
                )
                
                devices = try await apiService.fetchDevices(accessToken: token)
                statusMessage = "Fetched \(devices.count) devices"
            } catch {
                errorMessage = "API Error: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }
    
    // Connect to ABM (with one automatic retry on transient network errors)
    func connectToABM() {
        guard let assertion = clientAssertion else {
            errorMessage = "Generate JWT first"
            return
        }

        isLoading = true
        errorMessage = nil
        statusMessage = nil

        Task {
            var lastError: Error?

            for attempt in 1...2 {
                do {
                    let token = try await apiService.getAccessToken(
                        clientAssertion: assertion,
                        clientId: clientId
                    )

                    print("Successfully obtained access token. Fetching data...")

                    // Fetch devices and servers — only replace on success
                    let fetchedDevices = try await apiService.fetchDevices(accessToken: token)
                    print("Successfully fetched \(fetchedDevices.count) devices.")

                    let fetchedServers = try await apiService.fetchMDMServers(accessToken: token)
                    print("Successfully fetched \(fetchedServers.count) servers.")

                    devices = fetchedDevices
                    mdmServers = fetchedServers

                    statusMessage = "Connected to ABM. Fetched \(devices.count) devices and \(mdmServers.count) servers."
                    showToast("\(connectionLabel) connected — \(devices.count) devices loaded", type: .success)
                    lastError = nil
                    break
                } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == -1005 {
                    lastError = error
                    if attempt == 1 {
                        print("Network connection lost, retrying in 3s...")
                        statusMessage = "Connection interrupted, retrying..."
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                } catch {
                    lastError = error
                    break
                }
            }

            if let error = lastError {
                print("Error during ABM connection: \(error)")
                statusMessage = nil
                errorMessage = "ABM Connection Error: \(error.localizedDescription)"
                showToast("\(connectionLabel) connection failed", type: .error)
            }
            isLoading = false
        }
    }

    // Save credentials to UserDefaults
    private func saveCredentials() {
        UserDefaults.standard.set(clientId, forKey: "clientId")
        UserDefaults.standard.set(keyId, forKey: "keyId")
    }

    // Load saved credentials
    func loadCredentials() {
        clientId = UserDefaults.standard.string(forKey: "clientId") ?? ""
        keyId = UserDefaults.standard.string(forKey: "keyId") ?? ""
        loadProfiles()
        loadJamfProfiles()
    }

    // MARK: - Connection Profiles

    func saveProfile(name: String) {
        let profile = ConnectionProfile(
            name: name,
            clientId: clientId,
            keyId: keyId,
            privateKey: privateKey
        )

        // Replace if a profile with the same name exists
        if let index = savedProfiles.firstIndex(where: { $0.name == name }) {
            // Clean up old Keychain entry if UUID changed
            let oldId = savedProfiles[index].id
            if oldId != profile.id {
                KeychainHelper.deletePrivateKey(forProfileId: oldId)
            }
            savedProfiles[index] = profile
        } else {
            savedProfiles.append(profile)
        }

        // Store private key securely in Keychain
        KeychainHelper.savePrivateKey(privateKey, forProfileId: profile.id)

        activeProfileId = profile.id
        persistProfiles()
    }

    func switchToProfile(_ profile: ConnectionProfile) {
        clientId = profile.clientId
        keyId = profile.keyId
        privateKey = profile.privateKey
        activeProfileId = profile.id

        // Reset connection state when switching
        clientAssertion = nil
        devices = []
        mdmServers = []
        statusMessage = nil
        errorMessage = nil
        lastActivityId = nil

        saveCredentials()
        UserDefaults.standard.set(profile.id.uuidString, forKey: "activeProfileId")
    }

    func deleteProfile(_ profile: ConnectionProfile) {
        KeychainHelper.deletePrivateKey(forProfileId: profile.id)
        savedProfiles.removeAll { $0.id == profile.id }
        if activeProfileId == profile.id {
            activeProfileId = nil
        }
        persistProfiles()
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(savedProfiles) {
            UserDefaults.standard.set(data, forKey: "connectionProfiles")
        }
        if let id = activeProfileId {
            UserDefaults.standard.set(id.uuidString, forKey: "activeProfileId")
        }
    }

    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: "connectionProfiles"),
           var profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {

            // Migrate: check if old JSON has privateKey that hasn't been moved to Keychain yet
            var needsResave = false
            if let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for (i, rawProfile) in rawArray.enumerated() where i < profiles.count {
                    if let legacyKey = rawProfile["privateKey"] as? String, !legacyKey.isEmpty {
                        // Old format had the key in JSON — migrate it to Keychain
                        if KeychainHelper.readPrivateKey(forProfileId: profiles[i].id) == nil {
                            KeychainHelper.savePrivateKey(legacyKey, forProfileId: profiles[i].id)
                            profiles[i].privateKey = legacyKey
                            needsResave = true
                        }
                    }
                }
            }

            // Hydrate private keys from Keychain
            for i in profiles.indices {
                if profiles[i].privateKey.isEmpty,
                   let key = KeychainHelper.readPrivateKey(forProfileId: profiles[i].id) {
                    profiles[i].privateKey = key
                }
            }
            savedProfiles = profiles

            // Re-persist to strip privateKey from UserDefaults JSON after migration
            if needsResave {
                persistProfiles()
            }
        }
        if let idString = UserDefaults.standard.string(forKey: "activeProfileId"),
           let id = UUID(uuidString: idString) {
            activeProfileId = id
            // Also restore the active profile's credentials into the fields
            if let profile = savedProfiles.first(where: { $0.id == id }) {
                clientId = profile.clientId
                keyId = profile.keyId
                privateKey = profile.privateKey
            }
        }
    }
    
    
    // MARK: - Toast Helpers

    func showToast(_ message: String, type: ToastAlert.ToastType) {
        activeToast = ToastAlert(message: message, type: type)
    }

    func dismissToast() {
        activeToast = nil
    }

    // Quick reconnect: generates JWT then connects to ABM in one step
    // Includes one automatic retry on network errors (e.g. after switching profiles)
    func reconnect() {
        guard !clientId.isEmpty, !keyId.isEmpty, !privateKey.isEmpty else {
            errorMessage = "Missing credentials. Open Connection Settings to configure."
            return
        }

        isLoading = true
        errorMessage = nil
        statusMessage = nil

        Task {
            var lastError: Error?

            for attempt in 1...2 {
                do {
                    let credentials = APICredentials(
                        clientId: clientId,
                        keyId: keyId,
                        privateKey: privateKey
                    )
                    clientAssertion = try JWTGenerator.createClientAssertion(credentials: credentials)

                    let token = try await apiService.getAccessToken(
                        clientAssertion: clientAssertion!,
                        clientId: clientId
                    )

                    // Only replace data on success
                    let fetchedDevices = try await apiService.fetchDevices(accessToken: token)
                    let fetchedServers = try await apiService.fetchMDMServers(accessToken: token)

                    devices = fetchedDevices
                    mdmServers = fetchedServers

                    statusMessage = "Connected to ABM. Fetched \(devices.count) devices and \(mdmServers.count) servers."
                    showToast("\(connectionLabel) connected — \(devices.count) devices loaded", type: .success)
                    lastError = nil
                    break
                } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == -1005 {
                    // Network connection lost — likely a transient HTTP/2 issue
                    lastError = error
                    if attempt == 1 {
                        statusMessage = "Connection interrupted, retrying..."
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                    }
                } catch {
                    lastError = error
                    break // Non-network error, don't retry
                }
            }

            if let error = lastError {
                statusMessage = nil
                errorMessage = "Reconnect Error: \(error.localizedDescription)"
                showToast("\(connectionLabel) connection failed", type: .error)
            }
            isLoading = false
        }
    }

    // Get current access token
    func getCurrentAccessToken() async -> String? {
        guard let assertion = clientAssertion else { return nil }

        do {
            return try await apiService.getAccessToken(
                clientAssertion: assertion,
                clientId: clientId
            )
        } catch {
            return nil
        }
    }

    // MARK: - Jamf Pro Connection

    /// Connect to Jamf Pro using OAuth 2.0 Client Credentials
    /// Generic MDM reconnect — routes to whichever MDM provider is active.
    /// Use this instead of calling provider-specific methods directly.
    func reconnectMDM() {
        // Currently only Jamf Pro is supported; add future providers here
        connectToJamf()
    }

    func connectToJamf() {
        guard !jamfURL.isEmpty, !jamfClientId.isEmpty, !jamfClientSecret.isEmpty else {
            jamfErrorMessage = "Fill in all Jamf Pro connection fields."
            return
        }

        isJamfLoading = true
        jamfErrorMessage = nil
        jamfStatusMessage = nil

        Task {
            do {
                try await jamfAPIService.authenticate(
                    baseURL: jamfURL,
                    clientId: jamfClientId,
                    clientSecret: jamfClientSecret
                )
                isJamfConnected = true
                jamfStatusMessage = "Connected to Jamf Pro"
                showToast("MDM connected", type: .success)
            } catch {
                isJamfConnected = false
                jamfErrorMessage = error.localizedDescription
                showToast("MDM connection failed", type: .error)
            }
            isJamfLoading = false
        }
    }

    /// Get a valid Jamf token, auto-refreshing if needed
    func getJamfToken() async throws -> String {
        try await jamfAPIService.getToken(
            baseURL: jamfURL,
            clientId: jamfClientId,
            clientSecret: jamfClientSecret
        )
    }

    /// Disconnect from Jamf Pro
    func disconnectJamf() {
        jamfAPIService.clearToken()
        isJamfConnected = false
        jamfStatusMessage = nil
        jamfErrorMessage = nil
    }

    // MARK: - Jamf Pro Profiles

    func saveJamfProfile(name: String) {
        let profile = JamfConnectionProfile(
            name: name,
            jamfURL: jamfURL,
            clientId: jamfClientId,
            clientSecret: jamfClientSecret
        )

        if let index = jamfSavedProfiles.firstIndex(where: { $0.name == name }) {
            let oldId = jamfSavedProfiles[index].id
            if oldId != profile.id {
                KeychainHelper.delete(key: "jamf-clientSecret-\(oldId.uuidString)")
            }
            jamfSavedProfiles[index] = profile
        } else {
            jamfSavedProfiles.append(profile)
        }

        KeychainHelper.save(key: "jamf-clientSecret-\(profile.id.uuidString)", value: jamfClientSecret)
        activeJamfProfileId = profile.id
        persistJamfProfiles()
    }

    func switchToJamfProfile(_ profile: JamfConnectionProfile) {
        jamfURL = profile.jamfURL
        jamfClientId = profile.clientId
        jamfClientSecret = profile.clientSecret
        activeJamfProfileId = profile.id

        // Reset connection
        disconnectJamf()
        saveJamfCredentials()
        UserDefaults.standard.set(profile.id.uuidString, forKey: "activeJamfProfileId")
    }

    func deleteJamfProfile(_ profile: JamfConnectionProfile) {
        KeychainHelper.delete(key: "jamf-clientSecret-\(profile.id.uuidString)")
        jamfSavedProfiles.removeAll { $0.id == profile.id }
        if activeJamfProfileId == profile.id {
            activeJamfProfileId = nil
        }
        persistJamfProfiles()
    }

    private func saveJamfCredentials() {
        UserDefaults.standard.set(jamfURL, forKey: "jamfURL")
        UserDefaults.standard.set(jamfClientId, forKey: "jamfClientId")
    }

    private func persistJamfProfiles() {
        if let data = try? JSONEncoder().encode(jamfSavedProfiles) {
            UserDefaults.standard.set(data, forKey: "jamfConnectionProfiles")
        }
        if let id = activeJamfProfileId {
            UserDefaults.standard.set(id.uuidString, forKey: "activeJamfProfileId")
        }
    }

    func loadJamfProfiles() {
        if let data = UserDefaults.standard.data(forKey: "jamfConnectionProfiles"),
           var profiles = try? JSONDecoder().decode([JamfConnectionProfile].self, from: data) {
            // Hydrate secrets from Keychain
            for i in profiles.indices {
                if profiles[i].clientSecret.isEmpty,
                   let secret = KeychainHelper.read(key: "jamf-clientSecret-\(profiles[i].id.uuidString)") {
                    profiles[i].clientSecret = secret
                }
            }
            jamfSavedProfiles = profiles
        }

        if let idString = UserDefaults.standard.string(forKey: "activeJamfProfileId"),
           let id = UUID(uuidString: idString) {
            activeJamfProfileId = id
            if let profile = jamfSavedProfiles.first(where: { $0.id == id }) {
                jamfURL = profile.jamfURL
                jamfClientId = profile.clientId
                jamfClientSecret = profile.clientSecret
            }
        }
    }

    // MARK: - Bulk Sync

    /// Phase 1: Fetch all Jamf devices and compare against loaded ASM data.
    /// Only flags devices where the purchasing data actually differs.
    func bulkSyncCompare() {
        bulkSyncLog = []
        bulkSyncSummary = BulkSyncSummary()
        bulkSyncPhase = .fetching
        bulkSyncCancelled = false
        matchedSerials = []
        skippedSerials = []
        lastJamfDeviceMap = [:]

        addLog("Starting bulk comparison...", level: .info)

        bulkSyncTask = Task {
            do {
                let token = try await getJamfToken()

                // Fetch all Jamf computers
                addLog("Fetching computers from MDM...", level: .info)
                let computers = try await jamfAPIService.fetchAllComputers(token: token)
                bulkSyncSummary?.jamfComputerCount = computers.count
                addLog("Found \(computers.count) computers in MDM.", level: .info)

                guard !Task.isCancelled else { handleCancellation(); return }

                // Fetch all Jamf mobile devices
                addLog("Fetching mobile devices from MDM...", level: .info)
                let mobiles = try await jamfAPIService.fetchAllMobileDevices(token: token)
                bulkSyncSummary?.jamfMobileCount = mobiles.count
                addLog("Found \(mobiles.count) mobile devices in MDM.", level: .info)

                guard !Task.isCancelled else { handleCancellation(); return }

                // Merge into one map
                var allJamf = computers
                allJamf.merge(mobiles) { existing, _ in existing }
                lastJamfDeviceMap = allJamf

                // Compare against ASM — check for actual data differences
                let asmCount = devices.count
                bulkSyncSummary?.asmDeviceCount = asmCount
                var needsSync = Set<String>()
                var noChange = Set<String>()
                var notFound = Set<String>()

                for device in devices {
                    let serial = device.serialNumber.uppercased()
                    if let jamfDevice = allJamf[serial] {
                        let asmPO = (device.orderNumber ?? "").trimmingCharacters(in: .whitespaces)
                        let jamfPO = (jamfDevice.currentPONumber ?? "").trimmingCharacters(in: .whitespaces)
                        let jamfVendor = (jamfDevice.currentVendor ?? "").trimmingCharacters(in: .whitespaces)

                        // Check if data actually differs
                        let poMatches = asmPO == jamfPO || (asmPO.isEmpty && jamfPO.isEmpty)
                        let vendorMatches = jamfVendor.lowercased() == "apple" || jamfVendor.isEmpty

                        if poMatches && vendorMatches {
                            noChange.insert(serial)
                        } else {
                            needsSync.insert(serial)
                        }
                    } else {
                        notFound.insert(serial)
                    }
                }

                matchedSerials = needsSync
                skippedSerials = noChange
                devicesNotInJamf = notFound
                bulkSyncSummary?.matchedCount = needsSync.count + noChange.count
                bulkSyncSummary?.skippedNoChangeCount = noChange.count
                bulkSyncSummary?.notInJamfCount = notFound.count

                addLog("Comparison complete.", level: .success)
                addLog("\(needsSync.count + noChange.count) devices found in both \(connectionLabel) and MDM.", level: .success)
                addLog("\(needsSync.count) devices have data differences and need syncing.", level: needsSync.isEmpty ? .info : .success)

                if !noChange.isEmpty {
                    addLog("\(noChange.count) devices already up to date — will be skipped.", level: .info)
                }
                if !notFound.isEmpty {
                    addLog("\(notFound.count) \(connectionLabel) devices NOT found in MDM.", level: .warning)
                }

                bulkSyncPhase = .compared

            } catch {
                if !Task.isCancelled {
                    addLog("Error during comparison: \(error.localizedDescription)", level: .error)
                    bulkSyncPhase = .idle
                }
            }
        }
    }

    /// Phase 2: Push purchasing data from ASM to Jamf for matched devices with differences.
    /// Refreshes token proactively every 50 devices to avoid 401 expiry.
    func bulkSyncPush(serialsToSync: Set<String>? = nil) {
        guard bulkSyncPhase == .compared || bulkSyncPhase == .done else { return }
        bulkSyncPhase = .syncing
        bulkSyncCancelled = false

        let targetSerials = serialsToSync ?? matchedSerials
        addLog("Starting bulk purchasing sync for \(targetSerials.count) devices...", level: .info)
        bulkSyncSummary?.pushSuccessCount = 0
        bulkSyncSummary?.pushFailCount = 0
        bulkSyncSummary?.failedSerials = []
        bulkSyncSummary?.startTime = Date()
        bulkSyncSummary?.endTime = nil

        bulkSyncTask = Task {
            var processed = 0
            let refreshInterval = 50  // Re-auth every 50 devices to avoid token expiry

            for device in devices {
                guard !Task.isCancelled else {
                    handleCancellation()
                    return
                }

                let serial = device.serialNumber.uppercased()
                guard targetSerials.contains(serial), let jamfDevice = lastJamfDeviceMap[serial] else { continue }

                processed += 1
                bulkSyncProgress = "Syncing \(processed)/\(targetSerials.count): \(serial)"

                // Proactively refresh token every N devices
                if processed % refreshInterval == 0 {
                    do {
                        _ = try await getJamfToken()
                    } catch {
                        addLog("Token refresh failed, continuing with current token...", level: .warning)
                    }
                }

                // Fetch AppleCare coverage from ASM for this device
                var warrantyEndDate: String?
                var appleCareAgreement: String?

                let coverages = await getAppleCareCoverage(deviceId: device.id)
                if !coverages.isEmpty {
                    // Find the AppleCare+ entry (longest coverage), fall back to Limited Warranty
                    let appleCare = coverages.first(where: { ($0.attributes.description ?? "").contains("AppleCare") })
                    let warranty = coverages.first(where: { ($0.attributes.description ?? "").contains("Warranty") })
                    let best = appleCare ?? warranty

                    if let endDate = best?.attributes.endDateTime {
                        // Convert ISO date to Jamf-friendly format (yyyy-MM-dd)
                        warrantyEndDate = String(endDate.prefix(10))
                    }
                    if let agreement = appleCare?.attributes.agreementNumber {
                        appleCareAgreement = agreement
                    }
                }

                // Build purchasing data from ASM + AppleCare
                let purchasing = JamfPurchasing(
                    purchased: true,
                    leased: false,
                    poNumber: device.orderNumber,
                    poDate: nil,
                    vendor: "Apple",
                    warrantyDate: warrantyEndDate,
                    appleCareId: appleCareAgreement,
                    leaseDate: nil,
                    purchasePrice: nil,
                    lifeExpectancy: nil,
                    purchasingAccount: nil,
                    purchasingContact: nil
                )

                do {
                    // Get a fresh token for each request to handle expiry gracefully
                    let token = try await getJamfToken()
                    let match = JamfDeviceMatch(
                        id: jamfDevice.id,
                        name: jamfDevice.name,
                        serial: jamfDevice.serial,
                        model: jamfDevice.model,
                        deviceType: jamfDevice.deviceType,
                        currentPurchasing: nil
                    )
                    try await jamfAPIService.updateDevicePurchasing(
                        match: match,
                        purchasing: purchasing,
                        token: token
                    )
                    bulkSyncSummary?.pushSuccessCount += 1
                    addLog("\(serial): Updated successfully", level: .success, serial: serial)
                } catch {
                    bulkSyncSummary?.pushFailCount += 1
                    bulkSyncSummary?.failedSerials.append(serial)
                    addLog("\(serial): Push failed — \(error.localizedDescription)", level: .error, serial: serial)
                }
            }

            let successCount = bulkSyncSummary?.pushSuccessCount ?? 0
            let failCount = bulkSyncSummary?.pushFailCount ?? 0
            addLog("Bulk sync complete. \(successCount) succeeded, \(failCount) failed.", level: successCount > 0 ? .success : .warning)

            bulkSyncSummary?.endTime = Date()
            bulkSyncPhase = .done
            bulkSyncProgress = ""
        }
    }

    /// Retry only the devices that failed in the last sync
    func bulkSyncRetryFailed() {
        guard let summary = bulkSyncSummary, !summary.failedSerials.isEmpty else { return }
        let failedSet = Set(summary.failedSerials)
        addLog("Retrying \(failedSet.count) failed devices...", level: .info)
        bulkSyncPush(serialsToSync: failedSet)
    }

    /// Cancel a running bulk sync
    func bulkSyncCancel() {
        bulkSyncCancelled = true
        bulkSyncTask?.cancel()
        bulkSyncTask = nil
    }

    private func handleCancellation() {
        addLog("Sync cancelled by user.", level: .warning)
        bulkSyncSummary?.endTime = Date()
        bulkSyncPhase = .done
        bulkSyncProgress = ""
    }

    /// Reset bulk sync state
    func bulkSyncReset() {
        bulkSyncCancel()
        bulkSyncPhase = .idle
        bulkSyncLog = []
        bulkSyncSummary = nil
        bulkSyncProgress = ""
        bulkSyncCancelled = false
        matchedSerials = []
        skippedSerials = []
        lastJamfDeviceMap = [:]
        // Note: devicesNotInJamf is intentionally NOT cleared — it persists for the Devices view
    }

    /// Generate a text report of the last bulk sync
    func bulkSyncReportText() -> String {
        guard let summary = bulkSyncSummary else { return "No sync data available." }

        var report = "ABMate Bulk Sync Report\n"
        report += "=======================\n"
        report += "Generated: \(Date().formatted(date: .abbreviated, time: .standard))\n\n"

        report += "INVENTORY COMPARISON\n"
        report += "--------------------\n"
        report += "MDM Computers:      \(summary.jamfComputerCount)\n"
        report += "MDM Mobile Devices: \(summary.jamfMobileCount)\n"
        report += "\(connectionLabel) Devices:    \(summary.asmDeviceCount)\n"
        report += "Matched (total):    \(summary.matchedCount)\n"
        report += "Data Differences:   \(matchedSerials.count)\n"
        report += "Already Up to Date: \(summary.skippedNoChangeCount)\n"
        report += "Not Found in MDM:   \(summary.notInJamfCount)\n\n"

        report += "SYNC RESULTS\n"
        report += "------------\n"
        report += "Succeeded: \(summary.pushSuccessCount)\n"
        report += "Failed:    \(summary.pushFailCount)\n"
        if bulkSyncCancelled {
            report += "Status:    Cancelled by user\n"
        }
        if let end = summary.endTime {
            let duration = end.timeIntervalSince(summary.startTime)
            report += "Duration:  \(String(format: "%.1f", duration))s\n"
        }

        if !summary.failedSerials.isEmpty {
            report += "\nFAILED DEVICES\n"
            report += "--------------\n"
            for serial in summary.failedSerials {
                report += "  \(serial)\n"
            }
        }

        if !devicesNotInJamf.isEmpty {
            report += "\nDEVICES NOT IN MDM (\(devicesNotInJamf.count))\n"
            report += String(repeating: "-", count: 30) + "\n"
            for serial in devicesNotInJamf.sorted() {
                report += "  \(serial)\n"
            }
        }

        report += "\nFULL LOG\n"
        report += "--------\n"
        for entry in bulkSyncLog {
            let time = entry.timestamp.formatted(date: .omitted, time: .standard)
            let levelTag: String
            switch entry.level {
            case .info: levelTag = "INFO"
            case .success: levelTag = "OK"
            case .warning: levelTag = "WARN"
            case .error: levelTag = "ERROR"
            }
            let serialPart = entry.serial.isEmpty ? "" : " [\(entry.serial)]"
            report += "[\(time)] \(levelTag)\(serialPart) \(entry.message)\n"
        }

        return report
    }

    private func addLog(_ message: String, level: BulkSyncLogEntry.LogLevel, serial: String = "") {
        bulkSyncLog.append(BulkSyncLogEntry(
            timestamp: Date(),
            serial: serial,
            message: message,
            level: level
        ))
    }
}
