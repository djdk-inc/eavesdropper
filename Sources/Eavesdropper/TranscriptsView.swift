import EavesdropperCore
import SwiftUI

@MainActor
final class MeetingList: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: Meeting.ID?
    let store: MeetingStore

    init(store: MeetingStore) {
        self.store = store
        reload()
    }

    func reload() { meetings = store.all() }
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
                MeetingDetail(meeting: meeting)
            } else {
                Text(list.meetings.isEmpty ? "No meetings yet" : "Select a meeting").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

struct MeetingDetail: View {
    let meeting: Meeting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(meeting.title).font(.title2.bold()).textSelection(.enabled)
                metadata
                Divider()
                transcript
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(meeting.transcript.map { line in
                    "[\(Duration.seconds(line.start).formatted(.time(pattern: .minuteSecond)))] \(line.speaker): \(line.text)"
                }.joined(separator: "\n"))
                .font(.body.monospaced())
                .textSelection(.enabled)
            }
        }
    }
}
