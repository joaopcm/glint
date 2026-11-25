import AppKit
import GlintCore
import SwiftUI

struct UploadSettingsView: View {
    @Bindable var bucket: BucketAccess
    @State private var pastedURL = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var settings = bucket.settings
        ScrollViewReader { scroller in
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
                            .disabled(bucket.connectionTest.isRunning || bucket.makePublic == .running)
                            .accessibilityIdentifier(AccessibilityID.testConnection)
                        Spacer()
                        if let result = bucket.connectionTest.result {
                            CopyButton(title: "Copy Details", text: result.log)
                                .disabled(!result.isFinished)
                        }
                    }
                    if let result = bucket.connectionTest.result {
                        ForEach(result.steps) { step in
                            ConnectionStepRow(step: step) {
                                if step.id == .publicLink, let check = result.publicLink {
                                    PublicLinkFix(bucket: bucket, check: check)
                                }
                            }
                            .id(step.id)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 480)
            .onChange(of: bucket.connectionTest.isRunning) { _, isRunning in
                guard let result = bucket.connectionTest.result else { return }
                let target = isRunning
                    ? result.steps.last
                    : result.steps.first { $0.status == .failed } ?? result.steps.first { $0.status == .warning }
                guard let target else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    scroller.scrollTo(target.id, anchor: .bottom)
                }
            }
        }
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

private struct ConnectionStepRow<Fix: View>: View {
    let step: ConnectionTestStep
    @ViewBuilder let fix: Fix
    @State private var toggledOpen: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(step: ConnectionTestStep, @ViewBuilder fix: () -> Fix) {
        self.step = step
        self.fix = fix()
    }

    private var isExpanded: Bool { toggledOpen ?? step.status.startsExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 8) {
                    StepStatusIcon(status: step.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.id.title)
                        Text(step.outcome)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(step.hasDetails ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(step.status.rawValue)
            .accessibilityIdentifier(AccessibilityID.connectionStep(step.id.rawValue))
            if isExpanded, step.hasDetails {
                StepDetails(step: step) { fix }
                    .padding(.leading, 24)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
            }
        }
        .onChange(of: step.status) {
            toggledOpen = nil
        }
    }

    private func toggle() {
        guard step.hasDetails else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.2)) {
            toggledOpen = !isExpanded
        }
    }
}

private extension ConnectionTestStepStatus {
    var startsExpanded: Bool { self == .failed || self == .warning }
}

private struct StepStatusIcon: View {
    let status: ConnectionTestStepStatus

    var body: some View {
        Group {
            switch status {
            case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.mini)
            case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .padding(.top, 1)
    }
}

private struct StepDetails<Fix: View>: View {
    let step: ConnectionTestStep
    @ViewBuilder let fix: Fix

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let request = step.request {
                field("Request", request)
            }
            if let status = step.httpStatus {
                field("Response", "HTTP \(status)")
            }
            if let error = errorText {
                field(step.errorCode == nil ? "Error" : "S3 error", error)
            }
            if let text = step.fix {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fix
        }
        .textSelection(.enabled)
    }

    private var errorText: String? {
        switch (step.errorCode, step.errorMessage) {
        case (let code?, let message?): "\(code): \(message)"
        case (let code?, nil): code
        case (nil, let message?): message
        case (nil, nil): nil
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PublicLinkFix: View {
    let bucket: BucketAccess
    let check: PublicLinkCheck

    var body: some View {
        if let advice = bucket.publicLinkAdvice, needsFix {
            VStack(alignment: .leading, spacing: 10) {
                fix(advice)
            }
        }
    }

    private var needsFix: Bool {
        switch check {
        case .blocked, .unexpected: true
        case .opens, .unreachable: false
        }
    }

    @ViewBuilder
    private func fix(_ advice: PublicLinkAdvice) -> some View {
        if advice.canMakePublic {
            HStack {
                Button("Make Links Public") { Task { await bucket.makeLinksPublic() } }
                    .disabled(bucket.makePublic == .running || bucket.connectionTest.isRunning)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

private struct PolicyBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            CopyButton(title: "Copy", text: text)
                .controlSize(.small)
        }
    }
}

private struct CopyButton: View {
    let title: String
    let text: String
    @State private var copied: String?

    var body: some View {
        Button(copied == text ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = text
        }
    }
}
