import Destinations
import RecorderCore
import RecordingControl
import RecorderRuntime
import SwiftUI
import UploadQueue

// 仮の画面。デザインは後で作り直すので、確認に必要な情報を素直に並べるだけにしている。

struct DebugRootView: View {
    let built: AppEnvironment.Built
    @EnvironmentObject private var service: RecordingService
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RecordButton()
                    if let error = service.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section("録音") {
                    ForEach(service.recordings) { recording in
                        RecordingRow(recording: recording, summary: service.summaries[recording.id])
                    }
                }
            }
            .navigationTitle("録音")
            .toolbar {
                Button("宛先") { showingSettings = true }
                Button("再送") { Task { await service.kickUploads() } }
            }
            .sheet(isPresented: $showingSettings) {
                DestinationSettingsView(built: built)
            }
            .refreshable { await service.refresh() }
        }
    }
}

struct RecordButton: View {
    @EnvironmentObject private var service: RecordingService

    var body: some View {
        Button {
            Task {
                if service.isRecording {
                    try? await service.stopRecording()
                } else {
                    try? await service.startRecording(trigger: .inApp)
                }
            }
        } label: {
            HStack {
                Image(systemName: service.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.largeTitle)
                VStack(alignment: .leading) {
                    Text(service.isRecording ? "停止" : "録音").font(.headline)
                    if let active = service.activeRecording {
                        Text(active.startedAt, style: .timer)
                        Text("区切り \(active.segments.count) 個\(service.isPaused ? "・一時停止中" : "")")
                            .font(.caption)
                    }
                }
            }
            .foregroundStyle(service.isRecording ? .red : .primary)
        }
    }
}

struct RecordingRow: View {
    let recording: Recording
    let summary: DeliverySummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.startedAt.formatted(date: .abbreviated, time: .standard)).font(.headline)
            Text("\(recording.status.rawValue)・\(Int(recording.totalDuration))秒・区切り \(recording.segments.count) 個")
                .font(.caption)
            ForEach(summary?.perDestination ?? [], id: \.destination) { row in
                HStack {
                    Image(systemName: row.isComplete ? "checkmark.circle.fill" : "arrow.up.circle")
                        .foregroundStyle(row.isComplete ? .green : (row.failing > 0 ? .orange : .secondary))
                    Text("\(row.destination.rawValue): \(row.delivered)/\(row.total)")
                    if let error = row.lastError, !row.isComplete {
                        Text(error).lineLimit(1).foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
            }
            if summary?.perDestination.isEmpty ?? true {
                Text("宛先が未設定です（iPhone 内には保存済み）").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct DestinationSettingsView: View {
    let built: AppEnvironment.Built
    @Environment(\.dismiss) private var dismiss
    @State private var configs: [DestinationConfig] = []
    @State private var newID = "r2-primary"
    @State private var newEndpoint = ""
    @State private var newToken = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("設定済みの宛先") {
                    ForEach(configs) { config in
                        VStack(alignment: .leading) {
                            Text(config.id.rawValue).font(.headline)
                            Text(config.endpoint.absoluteString).font(.caption)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { try? built.tokens.setToken(nil, for: configs[index].id) }
                        configs.remove(atOffsets: offsets)
                        save()
                    }
                }
                Section("宛先を追加（Worker の URL と端末トークン）") {
                    TextField("ID（例: r2-primary）", text: $newID).textInputAutocapitalization(.never)
                    TextField("https://…workers.dev", text: $newEndpoint)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                    SecureField("端末トークン", text: $newToken)
                    Button("追加") { add() }
                }
                if let message { Text(message).font(.footnote) }
            }
            .navigationTitle("宛先")
            .toolbar { Button("閉じる") { dismiss() } }
            .onAppear { configs = built.destinationConfigs.load() }
        }
    }

    private func add() {
        guard let url = URL(string: newEndpoint), url.scheme == "https", !newID.isEmpty, !newToken.isEmpty else {
            message = "https の URL・ID・トークンを入れてください"
            return
        }
        let id = DestinationID(rawValue: newID)
        do {
            try built.tokens.setToken(newToken, for: id)
            configs.removeAll { $0.id == id }
            configs.append(DestinationConfig(id: id, displayName: newID, endpoint: url))
            save()
            newToken = ""
            message = "追加しました"
        } catch {
            message = "保存に失敗: \(error)"
        }
    }

    private func save() {
        try? built.destinationConfigs.save(configs)
        Task { await AppEnvironment.reloadDestinations(built) }
    }
}
