import GlintCore
import SwiftUI

struct UploadSettingsView: View {
    @Bindable var bucket: BucketAccess

    var body: some View {
        @Bindable var settings = bucket.settings
        Form {
            Section {
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
                        .disabled(bucket.connectionTest == .running)
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
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
