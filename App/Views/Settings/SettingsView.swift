import DoxiCore
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfileRecord]
    @State private var apiKey = ""
    @State private var hasStoredKey = KeychainStore.get(KeychainStore.anthropicAccount) != nil

    var body: some View {
        @Bindable var settings = services.settings
        NavigationStack {
            Form {
                Section {
                    if let profile = profiles.first {
                        NavigationLink {
                            ProfileEditorView(profile: profile)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(profile.name.isEmpty ? "Set up your identity" : profile.name)
                                if !profile.businessName.isEmpty { Text(profile.businessName).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: {
                    Text("Your identity")
                } footer: {
                    Text("Used to recognise which party is you in a document, so payments show as owed to you or owed by you.")
                }

                Section {
                    LabeledContent("On-device rules", value: "Always on")
                    let onDevice = OnDeviceModel.availability
                    Toggle("Apple on-device model", isOn: $settings.useOnDeviceModel)
                        .disabled(!onDevice.available)
                    if !onDevice.available {
                        Text(onDevice.reason).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Extraction on this device")
                } footer: {
                    Text("Text recognition, extraction and search run on your iPhone or iPad.")
                }

                Section {
                    Toggle("Allow Claude cloud extraction", isOn: $settings.cloudExtractionEnabled)
                    if settings.cloudExtractionEnabled {
                        SecureField(hasStoredKey ? "API key saved — enter to replace" : "Anthropic API key", text: $apiKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        HStack {
                            Button("Save key") {
                                KeychainStore.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: KeychainStore.anthropicAccount)
                                apiKey = ""
                                hasStoredKey = KeychainStore.get(KeychainStore.anthropicAccount) != nil
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            Spacer()
                            if hasStoredKey {
                                Button("Remove key", role: .destructive) {
                                    KeychainStore.set(nil, for: KeychainStore.anthropicAccount)
                                    hasStoredKey = false
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        TextField("Model", text: $settings.cloudModel)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Toggle("Use for every new document", isOn: $settings.cloudForNewDocuments)
                    }
                } header: {
                    Text("Cloud AI (optional)")
                } footer: {
                    Text("When used, the recognised text of a document (not the file) is sent to Anthropic to find parties, payments and obligations. Every result is checked against the document and shown with its source before you confirm it. Anthropic does not train models on API data by default. Your key is stored in the Keychain on this device. Off by default; you can also send individual documents from Review.")
                }

                Section {
                    ForEach(AppSettings.availableOffsets, id: \.self) { days in
                        Toggle(AppSettings.offsetLabel(days), isOn: Binding(
                            get: { settings.reminderOffsets.contains(days) },
                            set: { on in
                                if on { settings.reminderOffsets.append(days) } else { settings.reminderOffsets.removeAll { $0 == days } }
                                settings.reminderOffsets.sort(by: >)
                            }))
                    }
                    DatePicker("Time", selection: Binding(
                        get: { Calendar.current.date(from: DateComponents(hour: settings.reminderHour, minute: settings.reminderMinute)) ?? .now },
                        set: { d in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                            settings.reminderHour = c.hour ?? 9
                            settings.reminderMinute = c.minute ?? 0
                            services.rescheduleReminders(context: context)
                        }), displayedComponents: .hourAndMinute)
                    notificationStatus
                } header: {
                    Text("Default reminders")
                } footer: {
                    Text("Applies to new obligations. Each obligation's reminders can be changed on its own screen. iOS limits apps to 64 scheduled notifications, so Doxi schedules the nearest ones and refreshes them every time you open the app.")
                }

                Section {
                    Toggle("Lock with \(AppLock.biometryName)", isOn: $settings.appLockEnabled)
                } header: {
                    Text("Security")
                } footer: {
                    Text("Documents are stored in Doxi's private storage with iOS data protection and are unreadable while your device is locked.")
                }
            }
            .navigationTitle("Settings")
            .task {
                if profiles.isEmpty {
                    context.insert(UserProfileRecord())
                    try? context.save()
                }
                await services.notifications.refreshAuthorization()
            }
        }
    }

    @ViewBuilder var notificationStatus: some View {
        switch services.notifications.authorization {
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications are off for Doxi.", systemImage: "bell.slash").foregroundStyle(.orange)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .notDetermined:
            Button("Allow notifications") { Task { await services.notifications.requestAuthorizationIfNeeded(); services.rescheduleReminders(context: context) } }
        default:
            LabeledContent("Scheduled reminders", value: "\(services.notifications.scheduledCount)")
                .accessibilityIdentifier("scheduledReminders")
        }
    }
}

struct ProfileEditorView: View {
    @Bindable var profile: UserProfileRecord
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Query private var documents: [DocumentRecord]
    @State private var aliasText = ""

    var body: some View {
        Form {
            ProfileFields(name: $profile.name, businessName: $profile.businessName,
                          gstin: Binding(get: { profile.gstin ?? "" }, set: { profile.gstin = $0.isEmpty ? nil : $0.uppercased() }),
                          aliasText: $aliasText)
        }
        .navigationTitle("Your identity")
        .onAppear { aliasText = profile.aliases.joined(separator: ", ") }
        .onDisappear {
            profile.aliases = ProfileFields.parseAliases(aliasText)
            profile.updatedAt = .now
            // Re-check documents whose identity was not chosen by the user.
            let identity = profile.identity.isComplete ? profile.identity : nil
            for doc in documents where doc.identityDecision != .userChosen {
                services.processor.matchIdentity(doc, profile: identity)
            }
            try? context.save()
        }
    }
}

struct ProfileFields: View {
    @Binding var name: String
    @Binding var businessName: String
    @Binding var gstin: String
    @Binding var aliasText: String

    var body: some View {
        Section {
            TextField("Your name", text: $name).textContentType(.name)
            TextField("Business or freelancer name", text: $businessName).textContentType(.organizationName)
        } footer: {
            Text("For example: Harshit Rana · Rana Digital Studio")
        }
        Section {
            TextField("Other names, separated by commas", text: $aliasText, axis: .vertical)
        } header: {
            Text("Also known as")
        } footer: {
            Text("Short or old names that appear in documents, e.g. “Harshit, Rana Digital”.")
        }
        Section {
            TextField("GSTIN (optional)", text: $gstin)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
    }

    static func parseAliases(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// One-time setup of the user's identity.
struct OnboardingView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfileRecord]
    @State private var name = ""
    @State private var businessName = ""
    @State private var gstin = ""
    @State private var aliasText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Every document you sign knows what you agreed to.").font(.title3.weight(.semibold))
                        Text("Tell Doxi who you are so it can tell which party is you in contracts and invoices — and whether money is owed to you or by you. If it can't tell, it will ask.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ProfileFields(name: $name, businessName: $businessName, gstin: $gstin, aliasText: $aliasText)
            }
            .navigationTitle("Welcome")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { services.settings.hasCompletedOnboarding = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    func save() {
        let profile: UserProfileRecord
        if let existing = profiles.first {
            profile = existing
        } else {
            profile = UserProfileRecord()
            context.insert(profile)
        }
        profile.name = name.trimmingCharacters(in: .whitespaces)
        profile.businessName = businessName.trimmingCharacters(in: .whitespaces)
        profile.aliases = ProfileFields.parseAliases(aliasText)
        let g = gstin.trimmingCharacters(in: .whitespaces).uppercased()
        profile.gstin = g.isEmpty ? nil : g
        profile.updatedAt = .now
        try? context.save()
        services.settings.hasCompletedOnboarding = true
    }
}
