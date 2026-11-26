import SwiftUI
import TokiCore

@MainActor
struct PreferencesView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            general.tabItem { Label(state.local("通用", "General"), systemImage: "gearshape") }
            display.tabItem { Label(state.local("显示", "Display"), systemImage: "rectangle.topthird.inset.filled") }
            sources.tabItem { Label(state.local("数据来源", "Sources"), systemImage: "externaldrive") }
        }
        .padding(12)
        .frame(width: 540, height: 410)
    }

    private var general: some View {
        Form {
            Toggle(state.local("登录时启动", "Launch at login"),
                   isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
            if let error = state.loginError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            Picker(state.local("语言", "Language"), selection: $state.language) {
                ForEach(Language.allCases) { language in
                    Text(language == .system ? state.local("跟随系统", "System") : language.title).tag(language)
                }
            }
            Picker(state.local("定时刷新", "Fallback refresh"), selection: $state.interval) {
                ForEach([15, 30, 60, 120, 300], id: \.self) { seconds in
                    Text(state.local("\(seconds) 秒", "\(seconds) seconds")).tag(seconds)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var display: some View {
        Form {
            Picker(state.local("菜单栏格式", "Menu bar format"), selection: $state.menuFormat) {
                ForEach(MenuFormat.allCases) { menu in Text(state.format(menu)).tag(menu) }
            }
            Picker(state.local("货币", "Currency"), selection: $state.currency) {
                ForEach(Currency.allCases) { currency in Text(currency.rawValue).tag(currency) }
            }
            TextField(state.local("每美元对应人民币", "CNY per USD"),
                      value: $state.cnyRate, format: .number.precision(.fractionLength(0...4)))
                .disabled(state.currency != .cny)
                .onChange(of: state.cnyRate) { _, rate in
                    if !rate.isFinite || rate <= 0 { state.cnyRate = 7.25 }
                }
        }
        .formStyle(.grouped)
    }

    private var sources: some View {
        Form {
            ForEach(state.sourceStatuses) { status in
                Section {
                    Toggle(isOn: Binding(get: { state.enabled.contains(status.provider) }, set: { enabled in
                        if enabled { state.enabled.insert(status.provider) }
                        else { state.enabled.remove(status.provider) }
                    })) {
                        HStack {
                            Circle().fill(status.provider.tint).frame(width: 7, height: 7)
                            Text(status.provider.name)
                            Spacer()
                            Text(state.sourceTitle(state.enabled.contains(status.provider) ? status.state : .disabled))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(status.paths, id: \.self) { path in
                        Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
