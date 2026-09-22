import WoodshedKit
import SwiftUI

struct BootstrapHomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Woodshed")
                        .font(.largeTitle.bold())
                    Text("A local-first practice log for musicians.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Native app foundation is ready", systemImage: "checkmark.circle")
                        Text("Session capture and the practice wall arrive in the next milestones.")
                            .foregroundStyle(.secondary)
                        Text("Domain core milestone: \(WoodshedKit.milestone).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .navigationTitle("Home")
        }
        .accessibilityIdentifier("bootstrap.home")
    }
}
