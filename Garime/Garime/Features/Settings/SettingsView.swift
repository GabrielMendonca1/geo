import SwiftUI

struct SettingsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case geral
        case status

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var status = ServiceStatusViewModel()
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system.rawValue
    @AppStorage(GarimeAgent.advancedKey) private var advanced = false
    @AppStorage(GarimeAgent.sessionKey) private var agentSession = GarimeAgent.fallbackSession
    @State private var tab: Tab

    init(initialSection: String? = nil) {
        _tab = State(initialValue: Tab(rawValue: initialSection ?? "") ?? .geral)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            List {
                switch tab {
                case .geral:
                    appearanceSection
                    hubSection
                    bridgeSection
                    connectionSection
                    advancedSection
                    footerSection
                case .status:
                    statusSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 44)
        }
        .glassSheet(detents: [.large])
        .animation(.spring(response: 0.34, dampingFraction: 1), value: tab)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: status.isRunning)
        .task(id: tab) {
            guard tab == .status else { return }
            await status.runChecks()
        }
        .tint(Color.slateText)
    }

    private var header: some View {
        GlassChrome {
            VStack(spacing: 12) {
                HStack {
                    Text("ajustes")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    doneButton
                }

                tabPicker
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
        }
    }

    private var doneButton: some View {
        Button {
            if viewModel.save() {
                dismiss()
            }
        } label: {
            Text("pronto")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassSurface(shape: Capsule(), interactive: true)
    }

    private var tabPicker: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { item in
                tabChip(item)
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.34, dampingFraction: 1)) { tab = item }
                    }
            }
        }
    }

    @ViewBuilder
    private func tabChip(_ item: Tab) -> some View {
        let label = Text(item.rawValue)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .frame(maxWidth: .infinity, minHeight: 44)

        if item == tab {
            label
                .foregroundStyle(Color.slateCanvas)
                .background(Color.slateText, in: Capsule())
        } else {
            label
                .foregroundStyle(.primary)
                .glassSurface(shape: Capsule(), interactive: true)
        }
    }

    private var appearanceSection: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(AppearancePreference.allCases) { option in
                    appearanceChip(option)
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                                appearance = option.rawValue
                            }
                        }
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        } header: {
            sectionHeader("aparência")
        }
    }

    @ViewBuilder
    private func appearanceChip(_ option: AppearancePreference) -> some View {
        let label = Text(option.label)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .frame(maxWidth: .infinity, minHeight: 44)

        if option.rawValue == appearance {
            label
                .foregroundStyle(Color.slateCanvas)
                .background(Color.slateText, in: Capsule())
        } else {
            label
                .foregroundStyle(.primary)
                .glassSurface(shape: Capsule(), interactive: true)
        }
    }

    private var hubSection: some View {
        Section {
            infoRow("URL base", viewModel.activeBaseURL)
            infoRow("agente", GarimeAgent.session(agentSession))
        } header: {
            sectionHeader("hub")
        }
    }

    private var advancedSection: some View {
        Section {
            Toggle(isOn: $advanced) {
                Text("modo avançado")
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .frame(minHeight: 44)

            if advanced {
                infoRow("terminal padrão", viewModel.defaultTerminalOrigin)

                fieldRow("sessão do agente") {
                    TextField(GarimeAgent.fallbackSession, text: $agentSession)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
        } header: {
            sectionHeader("avançado")
        } footer: {
            Text("o modo avançado libera as sessões de terminal na aba do agente")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var bridgeSection: some View {
        Section {
            fieldRow("URL") {
                TextField("https://bridge.example", text: $viewModel.baseURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            fieldRow("token") {
                SecureField("token", text: $viewModel.token)
            }

            fieldRow("terminal token") {
                SecureField("terminal token", text: $viewModel.termToken)
            }

            if let urlError = viewModel.urlError {
                Text(urlError)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            if let keychainError = viewModel.keychainError {
                Text(keychainError)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        } header: {
            sectionHeader("bridge")
        } footer: {
            Text("URL must be https, or http to a tailnet IP (100.64.0.0/10)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                Task { await viewModel.testConnection() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isTesting {
                        ProgressView().tint(.secondary)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("testar conexão")
                        .font(.body)
                        .foregroundStyle(viewModel.isTesting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isTesting)

            if let testResult = viewModel.testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("garime")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("v\(viewModel.appVersion)")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowBackground(Color.clear)
        }
    }

    private var statusSection: some View {
        Section {
            ForEach(status.checks) { check in
                statusRow(check)
            }
        } header: {
            HStack {
                sectionHeader("serviços")
                Spacer()
                Button {
                    Task { await status.runChecks() }
                } label: {
                    HStack(spacing: 6) {
                        if status.isRunning {
                            ProgressView().tint(.secondary)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        Text("atualizar")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(status.isRunning ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(status.isRunning)
                .textCase(nil)
            }
        }
    }

    private func statusRow(_ check: ServiceCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            indicator(check)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.name)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                if !check.detail.isEmpty {
                    Text(check.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let hint = check.hint {
                    Text(hint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(check.status)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(check.isFilled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .frame(minHeight: 44)
    }

    private func indicator(_ check: ServiceCheck) -> some View {
        StatusDot(level: check.level, size: 8)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
            .textCase(nil)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .frame(minHeight: 44)
    }

    private func fieldRow<Field: View>(
        _ label: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)

            field()
                .font(.body)
                .foregroundStyle(.primary)
                .tint(Color.slateText)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
    }
}

#Preview {
    SettingsView()
}
