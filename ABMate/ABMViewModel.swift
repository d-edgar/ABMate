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

    // MARK: - Activity History
    @Published var activityHistory: [ActivityEntry] = []

    func logActivity(_ category: ActivityEntry.ActivityCategory, title: String, detail: String = "") {
        let entry = ActivityEntry(category: category, title: title, detail: detail)
        activityHistory.insert(entry, at: 0) // newest first
        // Keep last 200 entries
        if activityHistory.count > 200 {
            activityHistory = Array(activityHistory.prefix(200))
        }
        // Persist the sanitized audit trail
        persistActivityHistory()
    }

    // MARK: - Activity Persistence (sanitized audit trail)

    /// File URL for the persisted activity log — stored in Application Support
    private static var activityLogURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("ABMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("activity_log.json")
    }

    /// Strip sensitive specifics from detail strings before writing to disk.
    /// Keeps the "what" and "when" but not the "how much" or "where".
    private func sanitizeDetail(_ detail: String, category: ActivityEntry.ActivityCategory) -> String {
        switch category {
        case .connection:
            // Strip URLs, device counts — just note that a connection happened
            if detail.lowercased().contains("failed") { return "Connection attempt failed" }
            return "Connected successfully"
        case .sync:
            // Strip exact counts but keep the outcome description
            if detail.lowercased().contains("failed") && detail.lowercased().contains("succeeded") {
                // "X succeeded, Y failed" → just the outcome
                return "Sync completed"
            }
            if detail.lowercased().contains("matched") {
                return "Inventory comparison completed"
            }
            return "Sync action performed"
        case .assignment:
            // Strip device counts and activity IDs
            if detail.lowercased().contains("failed") { return "Assignment failed" }
            return "Device assignment completed"
        case .export:
            // Strip filenames — just note that an export happened
            return "Data exported"
        }
    }

    private func persistActivityHistory() {
        guard let url = Self.activityLogURL else { return }
        // Build sanitized entries for disk
        struct SafeEntry: Codable {
            let id: UUID
            let timestamp: Date
            let category: String
            let title: String
            let detail: String  // sanitized
        }
        let safeEntries = activityHistory.prefix(200).map { entry in
            SafeEntry(
                id: entry.id,
                timestamp: entry.timestamp,
                category: entry.category.rawValue,
                title: entry.title,
                detail: sanitizeDetail(entry.detail, category: entry.category)
            )
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(safeEntries)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to persist activity log: \(error)")
        }
    }

    func loadActivityHistory() {
        guard let url = Self.activityLogURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        struct SafeEntry: Codable {
            let id: UUID
            let timestamp: Date
            let category: String
            let title: String
            let detail: String
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let safeEntries = try decoder.decode([SafeEntry].self, from: data)
            activityHistory = safeEntries.compactMap { safe in
                guard let cat = ActivityEntry.ActivityCategory(rawValue: safe.category) else { return nil }
                return ActivityEntry(
                    id: safe.id,
                    timestamp: safe.timestamp,
                    category: cat,
                    title: safe.title,
                    detail: safe.detail
                )
            }
        } catch {
            print("Failed to load activity log: \(error)")
        }
    }

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
    @Published var matchedSerials: Set<String> = []
    /// ASM serials that matched but data was already the same
    @Published var skippedSerials: Set<String> = []
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
                    logActivity(.connection, title: "ASM Connected", detail: "\(devices.count) devices, \(mdmServers.count) MDM servers loaded")
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
        loadActivityHistory()
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
                    logActivity(.connection, title: "ASM Reconnected", detail: "\(devices.count) devices refreshed")
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
                logActivity(.connection, title: "MDM Connected", detail: "Jamf Pro at \(jamfURL)")
            } catch {
                isJamfConnected = false
                jamfErrorMessage = error.localizedDescription
                showToast("MDM connection failed", type: .error)
                logActivity(.connection, title: "MDM Connection Failed", detail: error.localizedDescription)
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

                // Fetch purchasing data for mobile devices via Classic API
                // (v2 list endpoint doesn't return purchasing fields)
                if !mobiles.isEmpty {
                    addLog("Fetching purchasing data for \(mobiles.count) mobile devices...", level: .info)
                    await jamfAPIService.fetchMobilePurchasingData(
                        devices: &allJamf,
                        token: token
                    ) { fetched, total in
                        // Progress is reported from background tasks — just print
                        if fetched % 50 == 0 || fetched == total {
                            print("Mobile purchasing fetch: \(fetched)/\(total)")
                        }
                    }
                    addLog("Mobile purchasing data fetched.", level: .info)
                }

                guard !Task.isCancelled else { handleCancellation(); return }

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
                        let jamfWarranty = (jamfDevice.currentWarrantyDate ?? "").trimmingCharacters(in: .whitespaces)
                        let jamfAppleCare = (jamfDevice.currentAppleCareId ?? "").trimmingCharacters(in: .whitespaces)

                        // Check if core data differs
                        let poMatches = asmPO == jamfPO || (asmPO.isEmpty && jamfPO.isEmpty)
                        let vendorMatches = jamfVendor.lowercased() == "apple" || jamfVendor.isEmpty

                        // Warranty/AppleCare: if Jamf has no warranty data, flag for sync
                        let warrantyPopulated = !jamfWarranty.isEmpty
                        let appleCarePopulated = !jamfAppleCare.isEmpty
                        let warrantyLikelyComplete = warrantyPopulated || appleCarePopulated

                        if !poMatches || !vendorMatches || !warrantyLikelyComplete {
                            needsSync.insert(serial)
                        } else {
                            noChange.insert(serial)
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
                logActivity(.sync, title: "Inventory Comparison", detail: "\(needsSync.count + noChange.count) matched, \(needsSync.count) need sync, \(noChange.count) up to date, \(notFound.count) not in MDM")

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
    func bulkSyncPush(serialsToSync: Set<String>? = nil, maxDevices: Int? = nil, computersOnly: Bool = false, mobileOnly: Bool = false) {
        guard bulkSyncPhase == .compared || bulkSyncPhase == .done else { return }
        bulkSyncPhase = .syncing
        bulkSyncCancelled = false

        let targetSerials = serialsToSync ?? matchedSerials
        let limit = maxDevices ?? targetSerials.count

        // Diagnostic: count device types in the target set
        if computersOnly || mobileOnly {
            let typeLabel = computersOnly ? "computers" : "mobile devices"
            var typeCount = 0
            for d in devices {
                let s = d.serialNumber.uppercased()
                if targetSerials.contains(s), let j = lastJamfDeviceMap[s] {
                    if computersOnly && j.deviceType == .computer { typeCount += 1 }
                    if mobileOnly && j.deviceType == .mobileDevice { typeCount += 1 }
                }
            }
            addLog("Found \(typeCount) \(typeLabel) in the \(targetSerials.count) devices that need sync. Will process up to \(limit).", level: .info)
        }

        addLog("Starting bulk purchasing sync for \(min(limit, targetSerials.count)) devices\(maxDevices != nil ? " (test mode)" : "")...", level: .info)
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

                // Filter by device type if requested
                if computersOnly && jamfDevice.deviceType != .computer { continue }
                if mobileOnly && jamfDevice.deviceType != .mobileDevice { continue }

                // Stop early if we've hit the test limit
                if processed >= limit { break }

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
                // Call the API service directly to avoid polluting errorMessage during bulk
                // Retries once on transient network errors
                var warrantyEndDate: String?
                var appleCareAgreement: String?

                addLog("\(serial): Looking up coverage for ASM device ID: \(device.id)", level: .info, serial: serial)

                if let assertion = clientAssertion {
                    for attempt in 1...2 {
                        do {
                            let asmToken = try await apiService.getAccessToken(
                                clientAssertion: assertion,
                                clientId: clientId
                            )
                            let coverages = try await apiService.getAppleCareCoverage(
                                deviceId: device.id,
                                accessToken: asmToken
                            )
                            addLog("\(serial): AppleCare API returned \(coverages.count) coverage entries", level: .info, serial: serial)

                            if !coverages.isEmpty {
                                // Check for active coverages first
                                let activeCoverages = coverages.filter { $0.attributes.status == "ACTIVE" }
                                let expiredCoverages = coverages.filter { $0.attributes.status != "ACTIVE" }

                                if !activeCoverages.isEmpty {
                                    let appleCare = activeCoverages.first(where: { ($0.attributes.description ?? "").contains("AppleCare") })
                                    let latestCoverage = activeCoverages.max(by: {
                                        ($0.attributes.endDateTime ?? "") < ($1.attributes.endDateTime ?? "")
                                    })

                                    if let agreement = appleCare?.attributes.agreementNumber, !agreement.isEmpty {
                                        appleCareAgreement = agreement
                                    }
                                    if let best = latestCoverage, let endDate = best.attributes.endDateTime {
                                        warrantyEndDate = String(endDate.prefix(10))
                                    }
                                    addLog("\(serial): Warranty=\(warrantyEndDate ?? "none"), AppleCareID=\(appleCareAgreement ?? "none")", level: .info, serial: serial)
                                } else if !expiredCoverages.isEmpty {
                                    // All coverage is expired — keep nil for Jamf (no valid date to send)
                                    addLog("\(serial): All coverage expired — skipping warranty fields", level: .info, serial: serial)
                                }
                            } else {
                                // No coverage data returned
                                addLog("\(serial): No coverage entries — warranty fields will be empty", level: .info, serial: serial)
                            }
                            break // Success, stop retrying
                        } catch let error as NSError where error.domain == NSURLErrorDomain && attempt == 1 {
                            // Transient network error — retry once after brief pause
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            continue
                        } catch {
                            // Coverage lookup failed (404 = no coverage, or other error)
                            addLog("\(serial): AppleCare lookup failed — \(error.localizedDescription)", level: .warning, serial: serial)
                            break
                        }
                    }
                } else {
                    addLog("\(serial): No ASM assertion available — skipping AppleCare lookup", level: .warning, serial: serial)
                }

                // Build purchasing data from ASM + AppleCare
                // Use the "Added to Org" date as the PO date
                let poDate: String? = {
                    if let added = device.addedDate, !added.isEmpty {
                        return String(added.prefix(10)) // yyyy-MM-dd
                    }
                    return nil
                }()

                // If no warranty date found and we have a PO date, calculate PO date + 4 years
                if warrantyEndDate == nil, let poDateStr = poDate {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd"
                    if let date = df.date(from: poDateStr),
                       let fourYearsLater = Calendar.current.date(byAdding: .year, value: 4, to: date) {
                        warrantyEndDate = df.string(from: fourYearsLater)
                        addLog("\(serial): No warranty data — set to PO date + 4 years (\(warrantyEndDate!))", level: .info, serial: serial)
                    }
                }

                // Sanitize appleCareId — don't send non-ID values like "expired"
                if let acid = appleCareAgreement, acid.lowercased() == "expired" {
                    appleCareAgreement = nil
                }

                let purchasing = JamfPurchasing(
                    purchased: true,
                    leased: false,
                    poNumber: device.orderNumber,
                    poDate: poDate,
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
                    let typeLabel = jamfDevice.deviceType == .mobileDevice ? "mobile" : "computer"
                    addLog("\(serial): Pushing \(typeLabel) (Jamf ID: \(jamfDevice.id))...", level: .info, serial: serial)
                    try await jamfAPIService.updateDevicePurchasing(
                        match: match,
                        purchasing: purchasing,
                        token: token
                    )
                    bulkSyncSummary?.pushSuccessCount += 1
                    addLog("\(serial): \(typeLabel.capitalized) updated successfully", level: .success, serial: serial)

                    // Update cached Jamf data so re-comparison sees this device as up to date
                    if var cached = lastJamfDeviceMap[serial] {
                        cached.currentPONumber = purchasing.poNumber
                        cached.currentVendor = purchasing.vendor
                        cached.currentWarrantyDate = purchasing.warrantyDate
                        cached.currentAppleCareId = purchasing.appleCareId
                        lastJamfDeviceMap[serial] = cached
                    }

                    // Move from needsSync to skipped (up to date)
                    matchedSerials.remove(serial)
                    skippedSerials.insert(serial)
                } catch {
                    bulkSyncSummary?.pushFailCount += 1
                    bulkSyncSummary?.failedSerials.append(serial)
                    addLog("\(serial): Push failed — \(error)", level: .error, serial: serial)
                }
            }

            let successCount = bulkSyncSummary?.pushSuccessCount ?? 0
            let failCount = bulkSyncSummary?.pushFailCount ?? 0
            addLog("Bulk sync complete. \(successCount) succeeded, \(failCount) failed.", level: successCount > 0 ? .success : .warning)
            logActivity(.sync, title: "Purchasing Sync Complete", detail: "\(successCount) succeeded, \(failCount) failed")

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
        report += "Already Up to Date: \(skippedSerials.count)\n"
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
