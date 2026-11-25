import AppKit
import GlintCore
import SwiftUI

struct UploadSettingsView: View {
    @Bindable var bucket: BucketAccess
    @State private var pastedURL = ""

    var body: some View {
        @Bindable var settings = bucket.settings
        Form {
            Section {
                HStack {
                    TextField("Bucket URL", text: $pastedURL, prompt: Text("Paste https://my-bucket.s3.us-east-2.amazonaws.com"))
                        .onSubmit(fillFromPastedURL)
                    Button("Fill In", action: fillFromPastedURL)
                        .disabled(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = bucket.bucketURLError {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                LabeledContent("Provider") {
                    Menu(bucket.provider?.name ?? "Other") {
                        ForEach(StorageProvider.allCases, id: \.self) { provider in
                            Button(provider.name) { bucket.apply(provider) }
                        }
                    }
                    .fixedSize()
                    .help("Fill in the endpoint, region and path style this provider uses. Bucket and key prefix stay as they are.")
                }
                TextField("Endpoint URL", text: $settings.bucketEndpoint, prompt: Text("https://s3.us-east-1.amazonaws.com"))
                TextField("Region", text: $settings.bucketRegion, prompt: Text("us-east-1"))
                TextField("Bucket", text: $settings.bucketName)
                Toggle("Path-style URLs", isOn: $settings.bucketPathStyle)
                    .help("Put the bucket in the path (endpoint/bucket/key) instead of the host. MinIO needs this.")
                TextField("Key prefix", text: $settings.bucketKeyPrefix, prompt: Text("shots"))
                TextField("Public base URL", text: $settings.bucketPublicBaseURL, prompt: Text("https://shots.example.com"))
            }
            Section {
                TextField("Access key ID", text: $bucket.accessKeyID)
                SecureField("Secret access key", text: $bucket.secretAccessKey)
                if let error = bucket.credentialError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if bucket.provider == .aws {
                    uploadPolicy(settings)
                }
            } footer: {
                Text("The keys are stored in your Keychain.")
            }
            Section {
                Toggle("Upload after capture", isOn: $settings.uploadAfterCapture)
                    .help("Upload every new capture and copy its link, as if you clicked Upload on its thumbnail.")
            }
            Section {
                HStack {
                    Button("Test Connection") { Task { await bucket.testConnection() } }
                        .disabled(bucket.connectionTest == .running || bucket.makePublic == .running)
                        .accessibilityIdentifier(AccessibilityID.testConnection)
                    if bucket.connectionTest == .running {
                        ProgressView().controlSize(.small)
                    }
                }
                if case .finished(let result) = bucket.connectionTest {
                    Text(result.log)
                        .font(.callout.monospaced())
                        .foregroundStyle(result.succeeded ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(AccessibilityID.connectionTestResult)
                    if let publicLink = result.publicLink {
                        PublicLinkView(bucket: bucket, check: publicLink)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func fillFromPastedURL() {
        bucket.fill(fromBucketURL: pastedURL)
        if bucket.bucketURLError == nil {
            pastedURL = ""
        }
    }

    private func uploadPolicy(_ settings: GlintSettings) -> some View {
        let name = settings.bucketName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = settings.bucketKeyPrefix.split(separator: "/").joined(separator: "/")
        return DisclosureGroup("IAM policy for these keys") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Give Glint keys of its own with only this policy. Don't paste admin keys: anyone who reads them from this Mac could do anything in the account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                PolicyBlock(text: BucketPolicy.uploadAccess(bucket: name.isEmpty ? "<bucket>" : name, keyPrefix: prefix))
                Text("Make Links Public also needs \(BucketPolicy.makePublicActions.joined(separator: ", ")) on arn:aws:s3:::\(name.isEmpty ? "<bucket>" : name).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct PublicLinkView: View {
    let bucket: BucketAccess
    let check: PublicLinkCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(headline, systemImage: check == .opens ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check == .opens ? Color.green : Color.orange)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.publicLinkResult)
            if case .blocked = check, let advice = bucket.publicLinkAdvice {
                fix(advice)
            } else if case .unexpected = check, let advice = bucket.publicLinkAdvice {
                fix(advice)
            }
        }
    }

    private var headline: String {
        switch check {
        case .opens:
            "Copied links open in a browser."
        case .blocked(let status, let code):
            "Copied links won't open: the bucket isn't publicly readable (HTTP \(status)\(code.map { " \($0)" } ?? ""))."
        case .unexpected(let status, let code):
            "Copied links won't open: the link answered HTTP \(status)\(code.map { " \($0)" } ?? "")."
        case .unreachable(let reason):
            "Copied links won't open: \(reason)"
        }
    }

    @ViewBuilder
    private func fix(_ advice: PublicLinkAdvice) -> some View {
        if advice.canMakePublic {
            HStack {
                Button("Make Links Public") { Task { await bucket.makeLinksPublic() } }
                    .disabled(bucket.makePublic == .running || bucket.connectionTest == .running)
                    .accessibilityIdentifier(AccessibilityID.makeLinksPublic)
                if bucket.makePublic == .running {
                    ProgressView().controlSize(.small)
                }
            }
            Text("Uses these keys to allow public bucket policies on this bucket and add a read-only statement for the key prefix.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if case .finished(let result) = bucket.makePublic {
                Text(result.log)
                    .font(.callout.monospaced())
                    .foregroundStyle(result.succeeded ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                if let policy = result.policyToPaste {
                    steps(advice.steps)
                    PolicyBlock(text: policy)
                }
            }
            if !showsPolicyToPaste, bucket.makePublic != .running, let policy = advice.bucketPolicy {
                DisclosureGroup("Do it by hand") {
                    VStack(alignment: .leading, spacing: 8) {
                        steps(advice.steps)
                        PolicyBlock(text: policy)
                    }
                }
            }
        } else {
            steps(advice.steps)
        }
    }

    private var showsPolicyToPaste: Bool {
        if case .finished(let result) = bucket.makePublic { return result.policyToPaste != nil }
        return false
    }

    private func steps(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text(steps.count > 1 ? "\(index + 1). \(step)" : step)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

private struct PolicyBlock: View {
    let text: String
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Button(copied == text ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = text
            }
            .controlSize(.small)
        }
    }
}
