import AppKit
import EavesdropperCore
import SwiftUI

@MainActor
final class MeetingList: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: Meeting.ID?
    /// The meeting whose transcript was just copied, for brief "Copied" feedback.
    @Published var copied: Meeting.ID?
    /// Meetings being summarized right now, and the last error per meeting.
    @Published var summarizing: Set<Meeting.ID> = []
    @Published var summaryErrors: [Meeting.ID: String] = [:]
    let store: MeetingStore

    init(store: MeetingStore) {
        self.store = store
        reload()
    }

    func reload() { meetings = store.all() }

    func summarize(_ meeting: Meeting) {
        summarizing.insert(meeting.id)
        summaryErrors[meeting.id] = nil
        Task {
            do {
                var updated = store.all().first(where: { $0.id == meeting.id }) ?? meeting
                updated.summary = try await Eavesdropper.summarize(updated)
                try store.save(updated)
            } catch {
                summaryErrors[meeting.id] = "\(error)"
            }
            summarizing.remove(meeting.id)
            reload()
        }
    }

    func copyTranscript(of meeting: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(meeting.transcript), forType: .string)
        copied = meeting.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.copied == meeting.id { self?.copied = nil }
        }
    }
}

struct TranscriptsView: View {
    @ObservedObject var list: MeetingList

    var body: some View {
        NavigationSplitView {
            List(list.meetings, selection: $list.selection) { meeting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).lineLimit(1)
                    Text("\(meeting.app.rawValue) · \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let meeting = list.meetings.first(where: { $0.id == list.selection }) {
                MeetingDetail(meeting: meeting, list: list)
            } else {
                Text(list.meetings.isEmpty ? "No meetings yet" : "Select a meeting").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject var list: MeetingList

    var body: some View {
        ScrollView { page }
    }

    /// The page without its scroll view, so it can also be rendered to an image (`--render`).
    var page: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meeting.title).font(.title2.bold()).textSelection(.enabled)
                    Spacer()
                    Button(list.copied == meeting.id ? "Copied" : "Copy Transcript", systemImage: list.copied == meeting.id ? "checkmark" : "doc.on.doc") {
                        list.copyTranscript(of: meeting)
                    }
                    .disabled(meeting.transcript.isEmpty)
                }
                metadata
                Divider()
                summary
                Divider()
                transcript
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var summary: some View {
        let busy = list.summarizing.contains(meeting.id)
        HStack {
            Text("Summary").font(.headline)
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
                Text("Summarizing on this Mac…").foregroundStyle(.secondary)
            } else {
                Button(meeting.summary == nil ? "Summarize" : "Summarize Again", systemImage: "text.badge.star") {
                    list.summarize(meeting)
                }
                .disabled(meeting.status != .done || meeting.transcript.isEmpty)
            }
        }
        if let error = list.summaryErrors[meeting.id] {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
        if let summary = meeting.summary {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(noteBlocks(summary.text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .heading(title):
                        Text(title).font(.subheadline.bold()).padding(.top, 8)
                    case let .line(text):
                        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                    }
                }
            }
            .textSelection(.enabled)
            Text("Written on this Mac by Apple's on-device model, \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("App", meeting.app.rawValue)
            row("Started", meeting.startedAt.formatted(date: .complete, time: .shortened))
            if let end = meeting.endedAt {
                row("Duration", Duration.seconds(end.timeIntervalSince(meeting.startedAt)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
            }
            row("Link", meeting.meetingURL ?? meeting.event?.conferenceURL)
            if let event = meeting.event {
                row("Scheduled", event.start.map { s in "\(s.formatted(date: .omitted, time: .shortened)) – \(event.end?.formatted(date: .omitted, time: .shortened) ?? "")" })
                row("Organizer", event.organizer)
                row("Attendees", event.attendees.isEmpty ? nil : event.attendees.joined(separator: "\n"))
                row("Location", event.location)
                row("Description", event.details)
            } else {
                row("Calendar", "No matching invite")
            }
            row("Status", meeting.status == .failed ? "failed: \(meeting.error ?? "")" : meeting.status.rawValue)
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow(alignment: .top) {
                Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value)
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        switch meeting.status {
        case .recording: Text("Recording…").foregroundStyle(.secondary)
        case .transcribing: Text("Transcribing…").foregroundStyle(.secondary)
        case .done, .failed:
            if meeting.transcript.isEmpty {
                Text("No speech found").foregroundStyle(.secondary)
            } else {
                Text(transcriptText(meeting.transcript))
                .font(.body.monospaced())
                .textSelection(.enabled)
            }
        }
    }
}
