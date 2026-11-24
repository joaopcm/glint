import AppKit
import GlintCore
import SwiftUI

struct UploadHistoryView: View {
    let history: UploadHistory
    let bucket: BucketAccess
    @State private var copyError: String?

    var body: some View {
        Form {
            if history.records.isEmpty {
                Text("Nothing uploaded yet. Uploaded captures show up here so you can copy their links again or delete them from the bucket.")
                    .foregroundStyle(.secondary)
            }
            ForEach(history.records) { record in
                row(record)
            }
            if let message = copyError ?? history.error {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(AccessibilityID.uploadHistoryError)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
    }

    private func row(_ record: UploadRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.link.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(AccessibilityID.uploadHistoryLink)
                Text(record.date, format: .dateTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy") { copy(record) }
            Button("Delete") {
                Task { await history.delete(record) { try await bucket.deleteObject($0) } }
            }
            .disabled(history.deleting.contains(record.key))
            .accessibilityIdentifier(AccessibilityID.deleteUpload)
        }
    }

    private func copy(_ record: UploadRecord) {
        do {
            try NSPasteboard.general.copyText(record.link.absoluteString)
            copyError = nil
        } catch {
            copyError = "Couldn't copy \(record.link.absoluteString): \(error.localizedDescription)"
        }
    }
}
