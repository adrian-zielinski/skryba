import SwiftUI
import SkrybaKit

struct ModelManagerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ModelCatalog.all) { whisperModel in
                        ModelRow(model: whisperModel)
                        Divider()
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Modele transkrypcji")
                .font(.title2.bold())
            Text("Większy model = lepsza jakość, ale wolniej i więcej miejsca. Dla polskiego i długich nagrań poleca się **Large v3 Turbo**. Małe modele (tiny/base) nadają się na szybki szkic. Warianty „tylko angielski” są szybsze dla treści po angielsku.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Text("Wybrany: \(model.selectedModel.displayName)")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Gotowe") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    @EnvironmentObject var appModel: AppModel

    private var isInstalled: Bool { appModel.installedModelIDs.contains(model.id) }
    private var isSelected: Bool { appModel.selectedModelID == model.id }
    private var isDownloading: Bool { appModel.downloadingModelID == model.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                appModel.selectedModelID = model.id
                appModel.persist()
            } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.displayName).font(.headline)
                    if model.id == ModelCatalog.defaultModelID {
                        tag("zalecany", color: .accentColor)
                    }
                    if isInstalled {
                        tag("pobrany", color: .green)
                    }
                }
                HStack(spacing: 14) {
                    Label("\(sizeText)", systemImage: "internaldrive")
                    Label("jakość \(model.stars(model.quality))", systemImage: "sparkles")
                    Label("szybkość \(model.stars(model.speed))", systemImage: "bolt")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(model.recommendation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(spacing: 6) {
                if isDownloading {
                    ProgressView(value: appModel.modelDownloadProgress)
                        .frame(width: 90)
                    Text("\(Int(appModel.modelDownloadProgress * 100))%")
                        .font(.caption.monospacedDigit())
                } else if isInstalled {
                    Button(role: .destructive) {
                        appModel.deleteModel(model)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Usuń model z dysku")
                } else {
                    Button {
                        appModel.downloadModel(model)
                    } label: {
                        Label("Pobierz", systemImage: "arrow.down.circle")
                    }
                    .disabled(appModel.downloadingModelID != nil)
                }
            }
            .frame(width: 110)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            appModel.selectedModelID = model.id
            appModel.persist()
        }
    }

    private var sizeText: String {
        model.approxSizeMB >= 1000
            ? String(format: "%.1f GB", Double(model.approxSizeMB) / 1000)
            : "\(model.approxSizeMB) MB"
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
