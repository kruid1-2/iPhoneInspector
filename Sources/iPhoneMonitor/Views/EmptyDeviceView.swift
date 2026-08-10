import SwiftUI

struct EmptyDeviceView: View {
    let onRefresh: () -> Void

    var body: some View {
        SectionCard("尚未读取到 iPhone", subtitle: "按以下顺序检查连接") {
            VStack(alignment: .leading, spacing: 10) {
                instruction(1, "用数据线连接 iPhone")
                instruction(2, "解锁 iPhone")
                instruction(3, "在手机上点击“信任此电脑”")
                instruction(4, "保持手机亮屏")
                instruction(5, "点击刷新")

                Button("立即刷新", action: onRefresh)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(.quaternary, in: Circle())
            Text(text)
        }
    }
}
