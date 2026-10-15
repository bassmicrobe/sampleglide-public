import SwiftUI

struct PlaybackSettingsView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PLAYBACK").font(.system(size: 12, weight: .semibold)).tracking(2).foregroundStyle(StudioTheme.accent)
                    Text("試聴設定").font(.system(size: 28, weight: .bold))
                }
                Spacer()
                Button("閉じる") { model.showPlaybackSettings = false }
                    .buttonStyle(StudioButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 14) {
                Toggle("選択時に自動試聴", isOn: $model.autoPreview)
                    .toggleStyle(.switch)
                    .font(.system(size: 18, weight: .semibold))
                Text("上下キーやクリックでサンプルを選ぶと、すぐに再生を始めます。オフにすると、スペースキーまたは再生ボタンで試聴できます。")
                    .font(.system(size: 15)).foregroundStyle(StudioTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("この Mac に自動保存されます", systemImage: "checkmark.circle")
                    .font(.system(size: 13)).foregroundStyle(StudioTheme.accent)
            }
            .padding(22)
            .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 10) {
                Label("DAW へのドラッグ", systemImage: "arrow.up.right.square")
                    .font(.system(size: 17, weight: .semibold))
                Text("未加工のサンプルは原音をそのままドラッグできます。範囲・テンポ・移調を変更した場合は、加工した音声を自動で準備します。")
                    .font(.system(size: 15)).foregroundStyle(StudioTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(30)
        .frame(width: 580)
        .foregroundStyle(StudioTheme.text)
        .background(StudioTheme.surface)
        .tint(StudioTheme.accent)
    }
}
